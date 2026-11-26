;;;; main.lsp --- CLI entry point (run with sbcl --script).
;;;;
;;;; Kept outside enchiridion.asd so loading the system never starts an agent.

;; Load ASDF before defpackage so UIOP/ASDF exist at read time under --script.
(require :sb-posix)
(require :asdf)

(defun initialize-supervisor-asdf ()
  "Initialize root's ASDF registries without HOME or XDG configuration files."
  (when (zerop (sb-posix:geteuid))
    (flet ((without-inheritance (configuration)
             (append (remove-if (lambda (entry)
                                  (member (if (consp entry) (car entry) entry)
                                          '(:inherit-configuration
                                            :ignore-inherited-configuration)))
                                configuration)
                     '(:ignore-inherited-configuration))))
      (asdf:initialize-source-registry
       (without-inheritance
        (or (asdf/source-registry:parse-source-registry-string
             (uiop:getenv "CL_SOURCE_REGISTRY"))
            `(:source-registry
              (:directory ,(uiop:pathname-parent-directory-pathname
                            (uiop:pathname-directory-pathname *load-pathname*)))))))
      (asdf:initialize-output-translations
       (without-inheritance
        (or (asdf/output-translations:parse-output-translations-string
             (uiop:getenv "ASDF_OUTPUT_TRANSLATIONS"))
            '(:output-translations (t nil))))))))

(initialize-supervisor-asdf)

(defpackage #:enchiridion.main
  (:use #:cl)
  (:import-from
   #:uiop
   #:getenv
   #:pathname-directory-pathname)
  (:export
   #:main #:project-root #:resolve-project-root #:agent-directory
   #:environment-value #:load-config #:first-launch-p #:run-command
   #:join-arguments #:load-configured-secrets)
  (:documentation
   "Process entry: roots, configuration, argument handling, and first launch."))

(in-package #:enchiridion.main)

;; Silence harmless duplicate contrib .asd scan warnings during CLI startup.
(let ((package (find-package "ASDF/SOURCE-REGISTRY")))
  (when package
    (let ((symbol (find-symbol "*VERBOSE-OUT*" package)))
      (when symbol
        (setf (symbol-value symbol) nil)))))

;; Muffle DBI's known DEFTYPE-to-class redefinition warnings on load; let all
;; other warnings through.
(defun muffled-library-warning-p (condition)
  "Return T for DBI's DEFTYPE-to-class redefinition warning."
  (let ((report (princ-to-string condition)))
    (and (>= (length report) 40)
         (eql 0 (search "redefining DEFTYPE type to be a class" report)))))

(handler-bind ((warning (lambda (condition)
                          (when (muffled-library-warning-p condition)
                            (muffle-warning condition)))))
  (asdf:load-system "enchiridion" :verbose nil))

;;;; Roots.

(declaim (ftype (function (pathname) (or null pathname)) parent-directory))

(defun parent-directory (directory)
  "Return the directory above DIRECTORY, or NIL at the top of the tree.
At the top, pathname-directory-pathname returns the same directory, so the
walk has to be told to stop rather than left to notice."
  (let ((parent (pathname-directory-pathname directory)))
    (unless (equal (truename directory) (truename parent))
      parent)))

(defun project-root ()
  "Return the project root as a path, searching upward from the load path for
enchiridion.asd."
  (let ((start (truename (pathname-directory-pathname (or *load-pathname* #p"./")))))
    (or (loop for directory = start then (parent-directory directory)
              while directory
              thereis (when (probe-file (merge-pathnames "enchiridion.asd" directory))
                        directory))
        start)))

(defun resolve-project-root ()
  "Return the project root as a namestring with no trailing slash."
  (let ((root (namestring (project-root))))
    (if (and (plusp (length root)) (char= (char root (1- (length root))) #\/))
        (subseq root 0 (1- (length root)))
        root)))

(defun environment-value (name)
  "Return the value of environment variable NAME as a string, or NIL when it
is unset or empty."
  (let ((value (getenv name)))
    (if (and value (plusp (length value))) value nil)))

(defun agent-directory ()
  "Return the agent directory as a namestring, with a trailing slash.
ENCHIRIDION_HOME wins when it is set: inside the container the installed
source is read only and the agent directory has to be on the volume.

Without ENCHIRIDION_HOME the current directory is the root. A checkout has no
writable source tree under /nix/store, and `nix run` starts in the checkout,
so the current directory is the one place the operator can own."
  (enchiridion:agent-directory))

(defun broker-socket-path ()
  "Return the socket path for the one-shot broker.
Inside the container the state volume is the writable tree, so the socket
lives under it. A checkout uses the agent directory, which the operator owns."
  (let ((home (environment-value "ENCHIRIDION_HOME")))
    (if home
        (merge-pathnames "run/broker.sock"
                         (uiop:ensure-directory-pathname home))
        (merge-pathnames "broker.sock" (agent-directory)))))

;;;; Configuration.
;;;;
;;;; An absent config.lsp is not an error. It means defaults, which is how a
;;;; first time user writes nothing at all. Env vars override the file. The
;;;; file never holds a secret, because a file in the repository is a file
;;;; that ends up in a store path.

(defun load-config ()
  "Load config.lsp, make it active, and return the configuration plist.
The file is required. A missing file is a configuration error with exit 2,
because the shipped defaults are not a complete configuration for an install:
the operator has to choose a provider and a state layout."
  (let ((config (enchiridion:read-config)))
    (when (eq enchiridion:*config-source* :defaults)
      (error 'enchiridion.errors:configuration-error
             :key :config
             :detail "config.lsp is required. Copy config.example.lsp to config.lsp and edit it."))
    (setf enchiridion.git:*git-identity*
          (cons (enchiridion:config-setting config :sandbox :agent-uid)
                (enchiridion:config-setting config :sandbox :agent-gid)))
    config))

;;;; The agent context.
;;;;
;;;; One object holds everything a command needs: the configuration, the
;;;; store, the backend, the broker, the agent, and the session. Building it
;;;; starts nothing, because `enchiridion version` must not open a socket.
;;;; A command that needs the broker calls ENSURE-STARTED.

(defun agent-uid (config)
  "Return the uid agent code runs as, from the :SANDBOX section."
  (enchiridion:config-setting config :sandbox :agent-uid))

(defun agent-gid (config)
  "Return the gid agent code runs as, from the :SANDBOX section."
  (enchiridion:config-setting config :sandbox :agent-gid))

(defun sandbox-home ()
  "Return the home directory that holds agents/ and run/."
  (uiop:pathname-parent-directory-pathname
   (uiop:ensure-directory-pathname (enchiridion:run-directory))))

(defun sandbox-directories ()
  "Return the directories the agent uid owns in a split run."
  (let ((home (sandbox-home)))
    (list (merge-pathnames "agents/" home)
          (uiop:ensure-directory-pathname (enchiridion:run-directory))
          (merge-pathnames "tmp/" home))))

(defun check-sandbox-traversal (home)
  "Signal a configuration error when HOME or an ancestor is not traversable by
the agent. Root can chown the state tree, but it should not chown the operator's
home directory, so the home directory itself must already allow the agent to
enter it."
  (let ((home (uiop:ensure-directory-pathname home)))
    (loop for directory = home then (parent-directory directory)
          while directory
          do (let ((mode (enchiridion.compat:file-mode directory)))
               (when (and mode (zerop (logand mode #o001)))
                 (error 'enchiridion.errors:configuration-error
                        :key :sandbox
                        :detail (format nil "The agent uid cannot traverse ~A. Set ENCHIRIDION_HOME to a directory below a world executable parent, such as /var/lib/enchiridion." directory)))))))

(defun check-sandbox-directory (directory)
  "Refuse a symbolic link at a writable state directory."
  (when (enchiridion.compat:symlink-target (string-right-trim "/" (namestring directory)))
    (error 'enchiridion.errors:configuration-error
           :key :sandbox :detail (format nil "State directory must not be a symlink: ~A" directory))))

(defun chown-tree (directory uid gid)
  "Give DIRECTORY and its contents to UID and GID. Signal on failure."
  (let ((owner (if (plusp gid)
                   (format nil "~D:~D" uid gid)
                   (format nil "~D" uid)))
        (path (string-right-trim "/" (namestring directory))))
    (multiple-value-bind (output status)
        (enchiridion.compat:run-program-capture
         "chown" (list "-h" "-R" "-P" owner path) :timeout 60)
      (unless (eql 0 status)
        (error 'enchiridion.errors:configuration-error
               :key :sandbox
               :detail (format nil "Could not give ~A to ~A: ~A"
                               path owner output))))))

(defun prepare-sandbox (config)
  "Prepare the state tree for the agent uid when this process is root.
A non-root process has no way to split, so it returns NIL. A root process
creates the state directories, checks that the agent can traverse the parents,
and gives the tree to the agent uid and gid."
  (let ((uid (agent-uid config))
        (gid (agent-gid config)))
    (when (and (plusp uid) (zerop (enchiridion.compat:process-uid)))
      (let ((home (sandbox-home))
            (directories (sandbox-directories))
            (agent (agent-directory)))
        (dolist (directory directories)
          (check-sandbox-directory directory)
          (ensure-directories-exist (merge-pathnames "x" directory)))
        (check-sandbox-directory agent)
        (ensure-directories-exist (merge-pathnames "x" agent))
        (check-sandbox-traversal home)
        (dolist (directory directories)
          (chown-tree directory uid gid)))
      t)))

(defun memory-store-path (config)
  "Return the store file CONFIG names, or the default beside the agent files.

The configured path wins because the container puts the store on the state
volume. The default is the file the agent directory owns, which is what a
checkout uses and what the search tool in the broker resolves on its own."
  (or (enchiridion:config-memory-db config)
      (enchiridion.memory.store:default-store-path (agent-directory))))

(defun open-agent-store (config)
  "Open the store CONFIG names, or return NIL and say why.

A store that cannot be opened must not cost the operator the turn: the reply
still prints, and the one line on stderr says the transcript was not kept. The
mode is set only when this process is root, which is the container case: the
broker runs as uid 1000 and SQLite cannot lock a file its user cannot write."
  (handler-case
      (let ((store (enchiridion.memory.store:open-store
                    :path (memory-store-path config)
                    :mode (when (zerop (enchiridion.compat:process-uid)) #o666))))
        (setf enchiridion.memory.store:*store-path*
              (enchiridion.memory.store:store-path store))
        store)
    (error (condition)
      (format *error-output* "~&enchiridion: not keeping a transcript: ~A~%" condition)
      (finish-output *error-output*)
      nil)))

(declaim (ftype (function () pathname) secrets-path))

(defun secrets-path ()
  "Return the resolved .env path (container tmpfs, then cwd, then source root)."
  (enchiridion.llm.secrets:operator-secrets-file))

(declaim (ftype (function (&optional t) string) load-configured-secrets))

(defun load-configured-secrets (&optional config)
  "Load configured and provider secrets into memory, unset them from the process
environment, unlink /run/secrets/.env if applicable, and return the active API key.

Refuses a world-readable secrets file before reading any entries."
  (let* ((config (or config (load-config)))
         (path (secrets-path))
         (present (probe-file path))
         (configured (enchiridion:configured-secret-names config))
         (names (append configured
                        (enchiridion.llm:provider-key-names config))))
    (when (and present
               (not (enchiridion.llm.secrets:secret-file-mode-ok-p path)))
      (error 'enchiridion.errors:configuration-error
             :key :secrets
             :detail (format nil "~A is mode #o~O and every uid can read it.~
                                  ~%Run chmod 600 ~A."
                             path
                             (enchiridion.compat:file-mode path)
                             path)))
    (enchiridion.llm.secrets:load-secrets
     :path (and present path)
     :names names)
    (dolist (name names)
      (enchiridion.compat:unset-environment-variable name))
    (dolist (entry (enchiridion.compat:environment))
      (let ((name (car entry)))
        (when (enchiridion.llm.secrets:credential-variable-p name)
          (enchiridion.compat:unset-environment-variable name))))
    (let ((discarded (enchiridion.llm.secrets:discard-secrets-file path)))
      (when (and (not discarded)
                 (probe-file path)
                 (uiop:pathname-equal
                  path enchiridion.llm.secrets:+container-secrets-path+))
        (format *error-output* "~&enchiridion: ~A~%"
                (enchiridion.llm.secrets:scrub
                 (format nil "could not unlink ~A; the secrets file is still on disk."
                         path)))
        (finish-output *error-output*)))
    (let ((value (enchiridion.llm.secrets:secret-value
                  (enchiridion.llm:default-api-key-env config))))
      (if (and value (plusp (length value))) value ""))))

;; directory is the agent directory, generation is the last generation that
;; loaded, and started-p says whether the broker is up.
(defstruct (context (:constructor %make-context))
  (directory "" :type string)
  (config nil :type t)
  (store nil :type t)
  (backend nil :type t)
  (broker nil :type t)
  (agent nil :type t)
  (session nil :type t)
  (generation 0 :type integer)
  (started-p nil :type boolean)
  (provider-refresh nil :type t))

(declaim (ftype (function (t) list) agent-budget-plist))

(defun agent-budget-plist (config)
  "Return the token caps from the :BUDGET section, as the plist an agent takes.

The caps live outside the :LLM section, so CONFIG-SECTION-VALUE reads them.
An agent built without them answers BUDGET-EXHAUSTED-P with NIL forever, which
is how a configured cap becomes no cap at all."
  (list :max-tokens-per-tick
        (enchiridion:config-setting config :budget :max-tokens-per-tick)
        :max-tokens-per-day
        (enchiridion:config-setting config :budget :max-tokens-per-day)))

(declaim (ftype (function (t) integer) heartbeat-interval))

(defun heartbeat-interval (config)
  "Return the sleep interval in whole seconds from the :SLEEP section.
Anything that is not a positive whole number of seconds is the shipped
interval: an interval of zero is a tick loop and a string is a mistyped key."
  (let ((value (enchiridion:config-setting config :sleep :interval-seconds)))
    (if (and (integerp value) (plusp value))
        value
        (enchiridion:config-setting (enchiridion:default-config)
                                    :sleep :interval-seconds))))

(declaim (ftype (function (t) boolean) refresh-provider-knowledge))

(defun refresh-provider-knowledge (config)
  "Refresh the models.dev catalog and the active provider's model list when stale.
Return T if both succeeded (or :OFFLINE is set), NIL if either failed."
  (let ((complete-p t))
    (unless (enchiridion:config-value config :offline)
      (let ((ttl (enchiridion:config-value config :providers-ttl-seconds)))
        (when (enchiridion.llm::catalog-expired-p
               (enchiridion.llm::catalog-path) ttl)
          (handler-case (enchiridion.llm:refresh-catalog)
            (enchiridion.errors:enchiridion-error (condition)
              (setf complete-p nil)
              (format *error-output* "~&enchiridion: ~A~%" condition)
              (finish-output *error-output*)))))
      (handler-case
          (let ((provider (enchiridion.llm:resolve-provider config)))
            (enchiridion.llm:provider-models provider :refresh t))
        (enchiridion.errors:enchiridion-error (condition)
          (setf complete-p nil)
          (format *error-output* "~&enchiridion: ~A~%" condition)
          (finish-output *error-output*))))
    complete-p))

(declaim (ftype (function (t) t) start-provider-refresh))

(defun start-provider-refresh (context)
  "Run provider refresh on a background thread and return a status reader.
The reader returns (:state STATE :report TEXT) with STATE in :pending, :done,
:failed, or :skipped."
  (let* ((config (context-config context))
         (state (list :pending "")))
    (flet ((record (new report)
             (setf (first state) new (second state) report)))
      (cond
        ((null config) (record :skipped "no configuration"))
        ((enchiridion:config-value config :offline) (record :skipped "offline"))
        ((null (context-backend context)) (record :skipped "no API key"))
        (t
         (bordeaux-threads:make-thread
          (lambda ()
            (handler-case
                (if (refresh-provider-knowledge config)
                    (record :done "")
                    (record :failed "a refresh was skipped; the cache is in use"))
              (error (condition)
                (let ((report (enchiridion.llm.secrets:scrub
                               (princ-to-string condition))))
                  (record :failed report)
                  (format *error-output*
                          "~&enchiridion: provider refresh failed: ~A~%" report)
                  (finish-output *error-output*)))))
          :name "enchiridion provider refresh"))))
    (lambda () (list :state (first state) :report (second state)))))

(defparameter +turn-requirements+
  '(:config :directory :secrets :store :backend :agent)
  "The capabilities a command that runs a turn needs.")

(declaim (ftype (function (list t) boolean) requirement-p))

(defun requirement-p (requirements capability)
  "Return T when REQUIREMENTS names CAPABILITY."
  (not (null (member capability requirements))))

(declaim (ftype (function (t t t) t) install-memory-instruments))

(defun install-memory-instruments (config backend key)
  "Install the deriver, the embedder, and the reranker BACKEND can provide.

The T2 parser has a backend of its own, resolved with :T2-DERIVER-MAX-TOKENS as
the reply cap: a reasoning model spent the turn's 4096 thinking and returned no
text at all. Dense retrieval has its own endpoint and key, so a store can use an
embeddings provider other than the chat one."
  (setf enchiridion.memory:*assertion-deriver*
        (when backend
          (enchiridion.memory:make-model-assertion-deriver
           (enchiridion.llm:resolve-backend
            :config (enchiridion:config-with-llm-value
                     config :max-tokens enchiridion.memory:*t2-deriver-max-tokens*)
            :api-key key)
           :model (or enchiridion.memory:*t2-deriver-model*
                      (enchiridion:model-for :cheap)))))
  (let ((settings enchiridion.memory::*memory-embed-settings*))
    (setf enchiridion.memory:*memory-embedder* nil)
    (when (getf settings :enabled)
      (let ((key (enchiridion.llm.secrets:secret-value (getf settings :key-env))))
        (if (and key (plusp (length key)))
            (setf enchiridion.memory:*memory-embed-model* (getf settings :model)
                  enchiridion.memory:*memory-embedder*
                  (enchiridion.memory:make-backend-embedder
                   (enchiridion.llm:openai-backend :base-url (getf settings :base-url)
                                                   :api-key key)
                   :model (getf settings :model)
                   :dimensions (getf settings :dimensions)))
            (format *error-output*
                    "~&enchiridion: :embed is on but ~A is empty; dense retrieval is off.~%"
                    (getf settings :key-env))))))
  (setf enchiridion.memory:*memory-reranker*
        (when (and backend enchiridion.memory::*memory-rerank-p*)
          (enchiridion.memory:make-model-reranker
           backend :model (enchiridion:model-for :cheap))))
  backend)

(declaim (ftype (function (list &key (:refresh-models t)) context)
                make-command-state))

(defun make-command-state (requirements &key (refresh-models nil))
  "Build only the context subsystems named in REQUIREMENTS, leaving others NIL.
When REFRESH-MODELS is T (used by ASK), refresh stale provider catalogs first."
  (let* ((config (when (requirement-p requirements :config) (load-config)))
         (tool-rounds (when (requirement-p requirements :agent)
                        (enchiridion:config-tool-rounds config))))
    ;; One ownership pass, before anything reads or writes the agent tree. A
    ;; command that only reads the tree still needs it when this process is
    ;; root: the tools that read it run as the agent uid, and a root-owned
    ;; directory is a directory they cannot open.
    (when (and config
               (or (requirement-p requirements :store)
                   (requirement-p requirements :directory)
                   (requirement-p requirements :git)))
      (prepare-sandbox config))
    (let* ((directory (agent-directory))
         (key (when (requirement-p requirements :secrets)
                (load-configured-secrets config)))
         (store (when (requirement-p requirements :store)
                  (when (and refresh-models key (plusp (length key)))
                    (refresh-provider-knowledge config))
                  (open-agent-store config)))
         (backend (when (requirement-p requirements :backend)
                    (when (and key (plusp (length key)))
                      (enchiridion.llm:resolve-backend :config config :api-key key))))
         (broker (when (requirement-p requirements :agent)
                   (enchiridion.tools.broker:make-broker
                    :socket (broker-socket-path)
                    :uid (agent-uid config)
                    :gid (agent-gid config)
                    :timeout 30
                    :log (merge-pathnames "broker.log"
                                          (uiop:ensure-directory-pathname
                                           (enchiridion:run-directory))))))
         (agent (when (requirement-p requirements :agent)
                  (enchiridion.kernel:make-agent
                   :name "default"
                   :backend backend
                   :directory directory
                   :budget (agent-budget-plist config)
                   :tool-rounds tool-rounds
                   :store store
                   :broker broker))))
    (when config (enchiridion.memory:configure-memory config))
    (when (and config backend) (install-memory-instruments config backend key))
    (enchiridion.tools.builtin:register-builtin-tools)
    (%make-context :directory directory
                   :config config
                   :store store
                   :backend backend
                   :broker broker
                   :agent agent
                   :generation (handler-case
                                   (enchiridion.memory:state-generation directory)
                                 (error () 0))))))

(defun stage-agent-proxies (context manifests generation)
  "Return a complete unpublished proxy registry for GENERATION."
  (let ((enchiridion.tools::*registry*
          (alexandria:copy-hash-table (enchiridion.tools:registry)))
        (enchiridion.plugin::*plugins*
          (copy-list (enchiridion.plugin:plugin-registry))))
    (enchiridion.plugin:discard-generation (context-generation context))
    (dolist (manifest manifests)
      (enchiridion.tools:register-tool
       (enchiridion.tools:make-tool
        :name (enchiridion.plugin:manifest-name manifest)
        :description (enchiridion.plugin:manifest-description manifest)
        :schema (enchiridion.plugin:manifest-schema manifest)
        :generation generation
        :broker-side-p t
        :handler (lambda (arguments)
                   (declare (ignore arguments))
                   (error 'enchiridion.errors:configuration-error
                          :key :broker
                          :detail "This tool runs in the broker.")))))
    enchiridion.tools::*registry*))

(defun load-agent-generation (context &key generation)
  "Verify and activate one source snapshot, then publish its staged proxies."
  (let* ((directory (context-directory context))
         (generation (or generation (1+ (context-generation context))))
         (snapshot (enchiridion.plugin:snapshot-sources directory))
         (digests (enchiridion.plugin:source-snapshot-digest snapshot))
         (sources (enchiridion.plugin:agent-source-files directory))
         (manifests (enchiridion.plugin:plugin-manifests sources))
         (registry (stage-agent-proxies context manifests generation)))
    (when sources
      (multiple-value-bind (ok-p report)
          (enchiridion.tools.broker:broker-verify-plugin
           (uiop:ensure-directory-pathname directory)
           :uid (agent-uid (context-config context))
           :gid (agent-gid (context-config context))
           :digests digests)
        (unless ok-p
          (error 'enchiridion.errors:tool-error :tool "reload" :detail report))))
    (let ((reply (enchiridion.tools.broker:broker-load-generation
                  (context-broker context) directory
                  :generation generation :digests digests)))
      (unless (and (hash-table-p reply) (gethash "ok" reply)
                   (eql generation (gethash "generation" reply))
                   (equal digests (gethash "digests" reply)))
        (error 'enchiridion.errors:tool-error
               :tool "reload"
               :detail (if (hash-table-p reply)
                           (or (gethash "report" reply)
                               (gethash "error" reply)
                               "The broker returned a mismatched generation.")
                           "The broker returned no generation report.")))
      (setf enchiridion.tools::*registry* registry
            (context-generation context) generation)
      (values generation (or (gethash "report" reply) "")))))

(defun start-broker-with-status (broker)
  "Start BROKER, and show a status line on standard error while it takes more
than a second. A warm start never prints; a slow one says what it waits for,
and the line is finished either way so the next output starts on its own."
  (let ((shown nil))
    (let ((enchiridion.tools.broker:*start-progress-function*
            (lambda (seconds)
              (when (>= seconds 2)
                (setf shown t)
                (format *error-output* "~Cenchiridion: starting the tool broker... ~Ds"
                        #\Return seconds)
                (finish-output *error-output*)))))
      (unwind-protect
           (progn (enchiridion.tools.broker:broker-start broker)
                  (when shown
                    (format *error-output* " ready.")))
        (when shown
          (terpri *error-output*)
          (finish-output *error-output*))))))

(defun ensure-started (context)
  "Start the broker, load the agent's generation, and open a session.
Idempotent. A generation that fails to load is reported and does not stop the
turn: the builtins still work, and the agent is told what happened."
  (unless (context-started-p context)
    (start-broker-with-status (context-broker context))
    (handler-case (load-agent-generation context)
      (error (condition)
        (format *error-output* "~&enchiridion: agent code did not load: ~A~%"
                condition)
        (finish-output *error-output*)))
    (setf (context-session context)
          (enchiridion.kernel:make-session :agent (context-agent context)))
    (setf (context-started-p context) t))
  context)

(defun close-context (context)
  "Stop the broker, close the session and the store, and return NIL."
  (when (context-started-p context)
    (ignore-errors (enchiridion.tools.broker:broker-stop (context-broker context))))
  (when (context-session context)
    (ignore-errors (enchiridion.kernel:end-session (context-session context))))
  (when (context-store context)
    (ignore-errors (enchiridion.memory.store:close-store (context-store context))))
  nil)

;;;; The agent repository.
;;;;
;;;; The repository is created by ENCHIRIDION.MEMORY:INIT-AGENT, so that `init`
;;;; and the first launch cannot disagree about whether one exists, and the
;;;; commit that follows a turn lives in the kernel, so that every path to a
;;;; turn commits and no caller has to remember to.

(defun verify-plugin-directory (directory &key (uid 1000) (gid 1000))
  "Verify DIRECTORY in a child process and print its report. Return an exit
status. The child drops to the agent uid and gid before it reads a single agent
file."
  (multiple-value-bind (ok-p output)
      (enchiridion.tools.broker:broker-verify-plugin
       (uiop:ensure-directory-pathname directory) :uid uid :gid gid)
    (write-string output)
    (finish-output)
    (if ok-p 0 1)))

(defun doctor-condition-label (condition)
  "Return CONDITION's type without its potentially sensitive report text."
  (string-downcase (symbol-name (type-of condition))))

(declaim (ftype (function (list) integer) run-doctor))

(defun run-doctor (arguments)
  "Check local runtime dependencies without constructing an agent or backend.

Provider variables are reported by name and presence only. Condition reports
are deliberately omitted because arbitrary text may contain a credential."
  (when arguments
    (format *error-output* "enchiridion: doctor takes no arguments.~%")
    (finish-output *error-output*)
    (return-from run-doctor 2))
  (let ((healthy t)
        (configuration nil))
    (labels ((report (name ok &optional detail)
               (format t "doctor ~A: ~:[failed~;ok~]~@[: ~A~]~%"
                       name ok detail)
               (unless ok (setf healthy nil))
               (finish-output)
               ok)
             (condition-report (name condition)
               (report name nil (doctor-condition-label condition))))
      (handler-case
          (report "git" (enchiridion.git:git-available-p)
                  (if (enchiridion.git:git-available-p) "available" "missing"))
        (error (condition) (condition-report "git" condition)))
      (handler-case
          (progn
            (setf configuration (load-config))
            (report "config" t "loaded"))
        (error (condition)
          (setf configuration (enchiridion:default-config))
          (condition-report "config" condition)))
      (handler-case
          (progn
            (load-configured-secrets configuration)
            (dolist (name (remove-duplicates
                           (enchiridion.llm:provider-key-names configuration)
                           :test #'string=))
              (let ((value (enchiridion.llm.secrets:secret-value name)))
                (format t "doctor provider key ~A: ~:[missing~;present~]~%"
                        name (and value (plusp (length value))))))
            (finish-output))
        (error (condition) (condition-report "provider keys" condition)))
      ;; A check must not create what it reports on. An absent store is a fresh
      ;; install, not a fault, and opening one here would migrate or create a
      ;; database the operator never asked for.
      (let ((store nil)
            (path (memory-store-path configuration)))
        (unwind-protect
             (handler-case
                 (if (probe-file path)
                     (progn
                       (setf store (enchiridion.memory.store:open-store :path path))
                       (enchiridion.memory.store:close-store store)
                       (setf store nil)
                       (report "store open/close" t))
                     (report "store open/close" t "absent; nothing created"))
               (error (condition) (condition-report "store open/close" condition)))
          (when store
            (ignore-errors (enchiridion.memory.store:close-store store)))))
      (let ((broker nil)
            (started nil))
        (unwind-protect
             (progn
               (handler-case
                   (progn
                     ;; A private socket and log under the temporary
                     ;; directory: a check must not collide with a supervisor
                     ;; that is already serving, and it must not leave a stale
                     ;; socket or log in run/ if it dies.
                     (let ((scratch (uiop:ensure-directory-pathname
                                     (enchiridion.compat:temp-directory))))
                       (ensure-directories-exist (merge-pathnames "x" scratch))
                       (setf broker
                             (enchiridion.tools.broker:make-broker
                              :socket (merge-pathnames
                                       (format nil "doctor-~D-~D.sock"
                                               (get-universal-time)
                                               (random 1000000))
                                       scratch)
                              :uid (agent-uid configuration)
                              :gid (agent-gid configuration)
                              :timeout 10
                              :log (merge-pathnames
                                    (format nil "doctor-~D-~D.log"
                                            (get-universal-time)
                                            (random 1000000))
                                    scratch))))
                     (enchiridion.tools.broker:broker-start broker)
                     (setf started t)
                     (report "broker start" t))
                 (error (condition) (condition-report "broker start" condition)))
               (if started
                   (handler-case
                       (report "broker ping"
                               (enchiridion.tools.broker:broker-health broker))
                     (error (condition) (condition-report "broker ping" condition)))
                   (report "broker ping" nil "not run"))
               (handler-case
                   (progn
                     (if broker
                         (enchiridion.tools.broker:broker-stop broker)
                         (error "No broker was constructed."))
                     (report "broker stop" t))
                 (error (condition) (condition-report "broker stop" condition))))
          (when broker
            (ignore-errors (enchiridion.tools.broker:broker-stop broker)))))
      (handler-case
          (report "seed" (enchiridion.memory:agent-seeded-p (agent-directory))
                  (if (enchiridion.memory:agent-seeded-p (agent-directory))
                      "present" "missing; run enchiridion init"))
        (error (condition) (condition-report "seed" condition)))
      (handler-case
          (format t "doctor bootstrap: ~A~%"
                  (enchiridion.llm.secrets:scrub
                   (enchiridion.memory:bootstrap-status-line (agent-directory))))
        (error (condition) (condition-report "bootstrap" condition)))
      (finish-output)
      (if healthy 0 1))))

;;;; Driving a command.
;;;;
;;;; One table backs both the shell and the REPL, and it lives in the channel
;;;; package. This file builds the context that table reads, hands the command
;;;; over, and closes what it opened. A command that needs a live agent gets
;;;; one lazily through RESPOND, so `enchiridion version` opens no socket.

(defun bootstrap-line (directory)
  "Return the one line bootstrap state for the status file, or an empty string.
A directory that cannot answer is not an error here: the status file is a
report, and a report that fails must not stop the agent."
  (handler-case (enchiridion.memory:bootstrap-status-line directory)
    (error () "")))

(defun print-completion (completion config)
  "Print the reply and the token line for COMPLETION.

The optional cache fields are built as strings and appended. A ~@[ clause
keeps the tested value for the body, so it would print the boolean instead of
the count, which is worse than printing nothing."
  (let ((model (enchiridion.llm:completion-model completion))
        (fallback (or (enchiridion:config-value config :model-primary)
                      (enchiridion.llm:primary-model)))
        (cache-read (enchiridion.llm:completion-cache-read-tokens completion))
        (cache-write (enchiridion.llm:completion-cache-write-tokens completion)))
    (let ((text (enchiridion.llm:completion-text completion)))
      (if (plusp (length text))
          (format t "~A~%" (enchiridion.llm.secrets:scrub text))
          ;; An empty line reads as a hang or a lost reply. Say what happened.
          (format *error-output* "~&enchiridion: the model returned no reply text~:[~; (it still asked for tools)~].~%"
                  (enchiridion.llm:completion-tool-calls completion))))
    (format *error-output* "~A  in ~D  out ~D~A~A~%"
            (if (plusp (length model)) model fallback)
            (enchiridion.llm:completion-input-tokens completion)
            (enchiridion.llm:completion-output-tokens completion)
            (if (plusp cache-read)
                (format nil "  cached ~D" cache-read)
                "")
            (if (plusp cache-write)
                (format nil "  wrote ~D" cache-write)
                ""))
    (finish-output)
    (finish-output *error-output*)))

;;;; Turn progress.
;;;;
;;;; A turn can spend a minute in model calls and tools before the reply
;;;; prints, and silence for that long reads as a hang. The kernel reports each
;;;; step through *TURN-PROGRESS-FUNCTION*, and this is the terminal's view of
;;;; it. It writes to standard error, so standard output is still the reply
;;;; alone and a script that captures it gets nothing else.

(defparameter +progress-width+ 100
  "The most characters one progress line shows of a reasoning, an argument
list, or a result.")

(defun progress-text (text &optional (width +progress-width+))
  "Return TEXT scrubbed, on one line, and cut to WIDTH characters."
  (let* ((flat (string-trim " "
                            (substitute-if #\Space
                                           (lambda (character)
                                             (member character '(#\Newline #\Return #\Tab)))
                                           (enchiridion.llm.secrets:scrub
                                            (or text "")))))
         (cut (> (length flat) width)))
    (if cut
        (format nil "~A..." (subseq flat 0 width))
        flat)))

(defun make-progress-printer (stream)
  "Return a progress function that writes a turn's steps to STREAM.

On a terminal the step in flight is one line with a running clock, redrawn
by a ticker thread, and replaced by its outcome when the step ends. Anywhere
else only the finished steps are written, one plain line each. The event
:FINISH stops the ticker, and the caller sends it however the turn ends."
  (let ((terminal (interactive-stream-p stream))
        (lock (bordeaux-threads:make-lock "enchiridion progress"))
        (ticker nil)
        (ticking nil)
        (label "")
        (started 0))
    (labels ((elapsed ()
               (floor (- (get-internal-real-time) started)
                      internal-time-units-per-second))
             (draw ()
               (format stream "~C~C[K~C[2m~A ~Ds~C[0m"
                       #\Return #\Esc #\Esc label (elapsed) #\Esc)
               (finish-output stream))
             (start (text)
               (setf label text
                     started (get-internal-real-time))
               (when terminal
                 (bordeaux-threads:with-lock-held (lock)
                   (setf ticking t)
                   (draw))
                 (setf ticker
                       (bordeaux-threads:make-thread
                        (lambda ()
                          (loop
                            (sleep 0.25)
                            (bordeaux-threads:with-lock-held (lock)
                              (unless ticking (return))
                              (draw))))
                        :name "enchiridion progress"))))
             (stop ()
               (when ticker
                 (bordeaux-threads:with-lock-held (lock)
                   (setf ticking nil))
                 (bordeaux-threads:join-thread ticker)
                 (setf ticker nil)
                 (format stream "~C~C[K" #\Return #\Esc)
                 (finish-output stream)))
             (say (control &rest arguments)
               (if terminal
                   (format stream "~C[2m~?~C[0m~%" #\Esc control arguments #\Esc)
                   (format stream "~?~%" control arguments))
               (finish-output stream)))
      (lambda (event details)
        (case event
          (:request
           (start "  thinking..."))
          (:response
           (stop)
           (let ((reasoning (getf details :reasoning))
                 (text (getf details :text)))
             (when (plusp (length reasoning))
               (say "  thought: ~A" (progress-text reasoning)))
             (when (plusp (length text))
               (say "  said: ~A" (progress-text text)))))
          (:tool-start
           (start (format nil "  -> ~A ~A"
                          (getf details :name)
                          (progress-text (getf details :arguments) 70))))
          (:tool-end
           (let ((seconds (elapsed))
                 (result (or (getf details :result) "")))
             (stop)
             (if (getf details :failed)
                 (say "~A  failed: ~A" label
                      (progress-text (if (eql 0 (search "error: " result))
                                         (subseq result (length "error: "))
                                         result)))
                 (say "~A  ok, ~D line~:P~[~:;, ~:*~Ds~]"
                      label
                      (if (plusp (length result))
                          (1+ (count #\Newline (string-right-trim '(#\Newline) result)))
                          0)
                      seconds))))
          (:round-limit
           (say "  tool round limit reached after ~D rounds; asking for an answer"
                (getf details :rounds)))
          (:finish
           (stop)))))))

(declaim (ftype (function (t) string) condition-line))

(defun condition-line (condition)
  "Return CONDITION as one line: its report, then its detail when it has one."
  (let ((detail (and (typep condition 'enchiridion.errors:enchiridion-error)
                     (enchiridion.errors:error-detail condition))))
    (if (stringp detail)
        (format nil "~A ~A" condition detail)
        (princ-to-string condition))))

(declaim (ftype (function (t &key (:block-p t) (:allow-silence-p t)) function)
                make-channel-turn))


(defun broker-reload (context supervisor)
  "Return the result of staging and activating one generation for SUPERVISOR."
  (let ((previous (enchiridion.supervisor:supervisor-generation supervisor)))
    (handler-case
        (multiple-value-bind (generation report)
            (load-agent-generation context :generation (1+ previous))
          (list :ok-p t :generation generation :report report))
      (error (condition)
        (list :ok-p nil :generation previous :report (condition-line condition))))))

(defun make-respond (context cancelled &key (channel :cli))
  "Return the function the command table calls for one turn.

A turn the operator stopped is reported as stopped and not as a failure: the
tokens are spent either way, and the operator asked for it.

CHANNEL is the surface the turn arrived on. It is recorded on every spend row
and every transcript row, and it names the git commit, so a turn that came in
over the webhook is not filed as a turn typed at the terminal."
  (lambda (text)
    (handler-case
        (progn
          (unless (context-backend context)
            (error 'enchiridion.errors:configuration-error
                   :key :api-key
                   :detail (format nil "No API key. Put ~A in .env or the environment."
                                   (enchiridion.llm:default-api-key-env
                                    (context-config context)))))
          (ensure-started context)
          ;; A /stop is for the turn in flight. The REPL only reads one between
          ;; turns, so a flag left over from it would cancel this turn and every
          ;; turn after it.
          (setf (car cancelled) nil)
          (let* ((printer (make-progress-printer *error-output*))
                 (completion
                   (unwind-protect
                        (let ((enchiridion.kernel:*turn-progress-function* printer))
                          (enchiridion.kernel:run-turn
                           (context-agent context) text
                           :session (context-session context)
                           :store (context-store context)
                           :channel channel
                           :cancel-p (lambda () (car cancelled))))
                     (funcall printer :finish nil))))
            (print-completion completion (context-config context))
            0))
      (enchiridion.errors:turn-cancelled (condition)
        (format *error-output* "~&~A~%" condition)
        (finish-output *error-output*)
        1)
      (enchiridion.errors:enchiridion-error (condition)
        (format *error-output* "~&~A~%" condition)
        (let ((detail (enchiridion.errors:error-detail condition)))
          (when (stringp detail)
            (format *error-output* "~A~%" detail)))
        (finish-output *error-output*)
        1))))

;;;; Channels.
;;;;
;;;; A channel never sees an agent, a store or a supervisor: it sees functions.
;;;; Everything a route needs is built here, in the process that owns the live
;;;; objects, which is what keeps the channel files above the kernel.

(declaim (ftype (function (keyword string) list) channel-failure))

(defun channel-failure (reason message)
  "Return the plist a channel reports when a turn did not run."
  (list :ok-p nil :reply "" :error message :reason reason :usage nil))

(defun make-channel-turn (context &key (block-p nil) (allow-silence-p nil))
  "Return a turn handler for a channel, returning a result plist
(:ok-p :reply :silent-p :error :reason :status :usage).
When BLOCK-P is NIL (default), return :busy if another turn is in flight;
when T, wait for the agent lock."
  (lambda (message &optional steer prior-work)
    (handler-case
        (let ((text (enchiridion.channel:msg-text message))
              (channel (enchiridion.channel:msg-channel message)))
          (unless (context-backend context)
            (error 'enchiridion.errors:configuration-error
                   :key :api-key
                   :detail (format nil "No API key. Put ~A in .env or the environment."
                                   (enchiridion.llm:default-api-key-env
                                    (context-config context)))))
          (ensure-started context)
          (let* ((agent (context-agent context))
                 (before (enchiridion.kernel:spend-count agent)))
            ;; RUN-TURN's second value is the presence proposal a tool made
            ;; this turn. It travels beside the reply so a channel that does
            ;; not show presence ignores it, and a refused proposal costs the
            ;; reply nothing.
            (multiple-value-bind (completion proposal silent-p work)
                (enchiridion.kernel:run-turn
                 agent text
                 :session (context-session context)
                 :store (context-store context)
                 :channel channel
                 :block-p block-p
                 :allow-silence-p allow-silence-p
                 :steer steer
                 :reuse-p (eq channel :fluxer)
                 :prior-work prior-work)
              (list :ok-p t
                    :work work
                    :silent-p silent-p
                    :reply (enchiridion.llm.secrets:scrub
                            (enchiridion.llm:completion-text completion))
                    :error ""
                    :reason nil
                    :status proposal
                    :usage (enchiridion.kernel:spend-summary
                            (enchiridion.kernel:spend-since agent before))))))
      (enchiridion.errors:turn-busy (condition)
        (channel-failure :busy (condition-line condition)))
      (enchiridion.errors:turn-cancelled (condition)
        (channel-failure :cancelled (condition-line condition)))
      (enchiridion.errors:enchiridion-error (condition)
        (channel-failure :failed (condition-line condition)))
      (error (condition)
        (channel-failure :failed (condition-line condition))))))

(declaim (ftype (function (t) list) heartbeat-health))

(defun heartbeat-health (supervisor)
  "Return the heartbeat row GET /health reports.

ENABLED requires a tick function, as the status file's row does: a schedule with
no hook is off. ALIVE is the thread, so a heartbeat that died while the flag
stayed true is visible rather than looking like a quiet schedule."
  (let ((enabled (and (enchiridion.supervisor:supervisor-heartbeat-p supervisor)
                      (not (null (enchiridion.supervisor:supervisor-tick-function
                                  supervisor))))))
    (list :enabled enabled
          :alive (not (null (enchiridion.supervisor:supervisor-heartbeat-live-p supervisor)))
          :requested (enchiridion.supervisor:supervisor-tick-requested-p supervisor)
          :ticks (enchiridion.supervisor:supervisor-ticks supervisor)
          :last-tick (enchiridion.supervisor:supervisor-last-tick supervisor)
          :ok (enchiridion.supervisor:supervisor-tick-ok-p supervisor)
          :running (enchiridion.supervisor:supervisor-tick-running-p supervisor)
          :report (enchiridion.llm.secrets:scrub
                   (enchiridion.supervisor:supervisor-tick-report supervisor)))))

(declaim (ftype (function () list) persistence-health))

(defun persistence-health ()
  "Return the persistence row GET /health reports.

Failures are reported and not gated on readiness: the counter belongs to the
process and never resets, so one transient failed write would keep readiness red
for the rest of the run. A growing count is the signal, and the last detail says
what the store refused. :NULL rather than NIL, which the route would write as
false and read like a real answer."
  (let ((last (enchiridion.kernel:last-persistence-failure)))
    (list :failures (enchiridion.kernel:persistence-failures)
          :last (if (consp last)
                    (list :kind (string-downcase (string (car last)))
                          :detail (enchiridion.llm.secrets:scrub
                                   (or (cdr last) "")))
                    :null))))

(declaim (ftype (function (t) list) provider-health))

(defun provider-health (context)
  "Return the provider refresh row GET /health reports."
  (let ((reader (context-provider-refresh context)))
    (or (and reader (funcall reader))
        (list :state :none :report ""))))

(declaim (ftype (function (t t) t) make-http-health))

(defun make-http-health (supervisor context)
  "Return the health callback for GET /health.
Reports not ready if any enabled channel is failed/stopped or an enabled
heartbeat thread is dead."
  (lambda ()
    (when (enchiridion.supervisor:supervisor-running-p supervisor)
      (let* ((rows (enchiridion.supervisor:supervisor-channel-rows supervisor))
             (heartbeat (heartbeat-health supervisor))
             (unready (loop for row across rows
                            for state = (gethash "state" row)
                            when (and (gethash "enabled" row)
                                      (member state '("failed" "stopped")
                                              :test #'string=))
                              collect (format nil "channel ~A is ~A"
                                              (gethash "name" row) state))))
        (when (and (getf heartbeat :enabled)
                   (not (getf heartbeat :alive)))
          (push "the heartbeat thread is not running" unready))
        (let ((ready-p (null unready)))
          (list :ok-p ready-p
                :ready ready-p
                :reasons (coerce (nreverse unready) 'vector)
                :uptime (max 0 (- (get-universal-time)
                                  (enchiridion.supervisor:supervisor-started supervisor)))
                :channels rows
                :heartbeat heartbeat
                :persistence (persistence-health)
                :providers (provider-health context)
                :writes (enchiridion.supervisor:supervisor-write-report)))))))

(declaim (ftype (function (t) t) make-ledger-reader))

(defun make-ledger-reader (store)
  "Return the function GET /usage reads.
A store that refuses the read is reported rather than signalled: the route
answers 503 with the reason and the process keeps running."
  (lambda (limit)
    (if store
        (handler-case
            (list :ok-p t :rows (enchiridion.memory.store:usage-rows store :limit limit))
          (error (condition) (list :ok-p nil :error (princ-to-string condition))))
        (list :ok-p nil :error "no memory store is open"))))

(declaim (ftype (function (t list) list) http-entry))

(defun http-entry (config options)
  "Return the :http channel entry with the command line flags applied.
The entry is a copy: the flags belong to this process, not to the loaded
configuration, and writing them back would make the next command see them.
The port is parsed here because a command line flag is text and the service
takes an integer; VALIDATE-OPTIONS has already refused anything that is not a
number in range."
  (let ((entry (copy-list (enchiridion:channel-config :http config))))
    (when (getf options :bind)
      (setf (getf entry :bind) (getf options :bind)))
    (when (getf options :port)
      (setf (getf entry :port) (parse-integer (getf options :port) :junk-allowed t)))
    (when (getf options :token-env)
      (setf (getf entry :token-env) (getf options :token-env)))
    entry))

(declaim (ftype (function (list) (or null string)) http-token))

(defun http-token (entry)
  "Return the webhook token named by ENTRY, or NIL.

The value is named by :token-env and read through the loader, so the scrubber
knows it. A literal :token is accepted for a loopback bind and for tests and
is registered here for the same reason. Anything read from the environment is
registered before it is returned: an unregistered token is the one kind the
shape filter cannot catch."
  (let ((name (let ((value (getf entry :token-env)))
                (if (and (stringp value) (plusp (length value)))
                    value
                    "ENCHIRIDION_HTTP_TOKEN")))
        (literal (getf entry :token)))
    (cond
      ((and (stringp literal) (plusp (length literal)))
       (unless (enchiridion.llm.secrets:secret-present-p name)
         (enchiridion.llm.secrets:register-secret name literal :argument))
       literal)
      (t
       (or (enchiridion.llm.secrets:secret-value name)
           (let ((value (enchiridion.compat:environment-value name)))
             (when (and value (plusp (length value)))
               (enchiridion.llm.secrets:register-secret name value :env)
               value)))))))

(declaim (ftype (function (t t t list string) (values list list)) build-channels))

(defun build-channels (context supervisor command-context options command)
  "Return two values: the initially running channels and their factories.

The factory alist maps lowercase channel names to zero-argument constructors.
Every call returns a fresh stopped channel, so enabling a channel that was
disabled at startup never reuses a stopped or failed instance.

CHAT owns its foreground REPL directly. SERVE supervises the CLI channel beside
the network channels."
  (let* ((config (context-config context))
         (requested (getf options :channel))
         (http-p (or (and (stringp requested) (string-equal requested "http"))
                     (enchiridion:channel-enabled-p :http)))
         (fluxer-p (or (and (stringp requested) (string-equal requested "fluxer"))
                       (enchiridion:channel-enabled-p :fluxer)))
         (channels '())
         (factories '()))
    (flet ((add-channel (name enabled-p constructor)
             (push (cons name constructor) factories)
             (when enabled-p
               (push (funcall constructor) channels))))
      (when (string= command "serve")
        (add-channel "cli" t
                     (lambda ()
                       (enchiridion.channel.cli:make-cli-channel
                        :context command-context))))
      (let* ((entry (http-entry config options))
             (bind (or (getf entry :bind) "127.0.0.1"))
             (port (or (getf entry :port) 8787)))
        (add-channel
         "http" http-p
         (lambda ()
           (enchiridion.channel.http:make-http-channel
            :service (enchiridion.channel.http:make-http-service
                      :turn (make-channel-turn context)
                      :health (make-http-health supervisor context)
                      :usage (make-ledger-reader (context-store context))
                      :token (http-token entry)
                      :bind bind
                      :port port
                      :body-limit (or (getf entry :max-body-bytes)
                                      enchiridion.channel.http:+http-body-limit+))))))
      ;; The channel resolves its own allowlist and token from the configuration
      ;; it is handed, so a factory and the initial instance use the same reader.
      (add-channel
       "fluxer" fluxer-p
       (lambda ()
         (enchiridion.channel.fluxer:make-fluxer-channel
          :turn (make-channel-turn context :block-p t :allow-silence-p t)
          :followups-p t
          :config config))))
    (values (nreverse channels) (nreverse factories))))

(declaim (ftype (function (list) null) check-channel-policy))

(defun check-channel-policy (channels)
  "Refuse a webhook that would answer the network without a token, before the
supervisor starts. CHANNEL-START checks again; this one exists so that a bad
flag is one line and an exit status instead of a channel that dies and
restarts every second."
  (dolist (channel channels)
    (when (typep channel 'enchiridion.channel.http:http-channel)
      (enchiridion.channel.http:check-http-policy
       (enchiridion.channel.http:http-channel-service channel))))
  nil)

(declaim (ftype (function (t) null) print-condition))

(defun print-condition (condition)
  "Write CONDITION and its detail, when it has one, to the error stream."
  (format *error-output* "~&~A~%" condition)
  (let ((detail (and (typep condition 'enchiridion.errors:enchiridion-error)
                     (enchiridion.errors:error-detail condition))))
    (when (stringp detail)
      (format *error-output* "~A~%" detail)))
  (finish-output *error-output*)
  nil)

(defun make-application-supervisor (context)
  "Return the supervisor this process owns, with the broker round trip as its
reload hook and the heartbeat as its tick hook.

RELOAD-FUNCTION is the whole reason the supervisor is generic: it calls a
function, and this process supplies one that never loads agent code here. The
tick hook is the same idea one step further: the supervisor schedules the
heartbeat, and the kernel owns what a tick does."
  (let ((config (context-config context)))
    (enchiridion.supervisor:make-supervisor
     :directory (context-directory context)
     :config config
     :store (context-store context)
     :agent (context-agent context)
     :session (context-session context)
     :generation (context-generation context)
     :heartbeat-p (enchiridion:config-setting config :sleep :enabled)
     :heartbeat-interval (heartbeat-interval config)
     :tick-function #'enchiridion.kernel:heartbeat
     :bootstrap-line (bootstrap-line (context-directory context))
     :reload-function (lambda (supervisor) (broker-reload context supervisor)))))

(defun command-context-for (context &key supervisor respond cancel)
  "Return the command table's view of CONTEXT."
  (enchiridion.channel.cli:make-command-context
   :directory (context-directory context)
   :config (context-config context)
   :store (context-store context)
   :agent (context-agent context)
   :session (context-session context)
   :broker (context-broker context)
   :generation (context-generation context)
   :channel :cli
   :supervisor supervisor
   :respond respond
   :cancel cancel))

(defun join-arguments (arguments)
  "Return ARGUMENTS as one string, so that an unquoted question still reads
the way the operator typed it."
  (with-output-to-string (stream)
    (loop for argument in arguments
          for first = t then nil
          do (unless first (write-char #\Space stream))
             (write-string argument stream))))

(declaim (ftype (function (string list) integer) run-command))

(defun command-requirements (name arguments)
  "Return the capabilities NAME needs for ARGUMENTS, from the command table."
  (nth-value 0 (enchiridion.channel.cli:command-requirements name arguments)))

(defun run-command (name arguments)
  "Run NAME with ARGUMENTS through the shared command table.
Return an exit status.

Only what the command table says the command needs is built. A command with no
capabilities loads no configuration, opens no store, resolves no backend, and
builds no agent: `enchiridion help` and `enchiridion version` answer on a fresh
install with no configuration file, and a `--help` never creates a database.

Only ASK refreshes the provider knowledge: it is the one command here that
spends a turn."
  (let ((requirements (command-requirements name arguments)))
    (if (null requirements)
        (let ((enchiridion.channel.cli:*command-context*
                (enchiridion.channel.cli:make-command-context)))
          (enchiridion.tools.builtin:register-builtin-tools)
          (enchiridion.channel.cli:run-command name arguments))
        (progn
          (when (requirement-p requirements :git) (require-git))
          (let ((context (make-command-state requirements
                                             :refresh-models (string= name "ask"))))
            (let ((status
                    (unwind-protect
                         (let* ((cancelled (list nil))
                                (enchiridion.channel.cli:*command-context*
                                  (command-context-for
                                   context
                                   :respond (make-respond context cancelled)
                                   :cancel (lambda () (setf (car cancelled) t)))))
                           (enchiridion.channel.cli:run-command name arguments))
                      (close-context context))))
              ;; Seed files and the store are created by the command, so the
              ;; ownership pass runs again after it as well as before.
              (when (context-config context)
                (prepare-sandbox (context-config context)))
              status))))))

(declaim (ftype (function (string) boolean) supervisor-command-p))

(defun supervisor-command-p (name)
  "Return T for the two commands that own a supervisor process."
  (not (null (member name '("chat" "serve") :test #'string=))))

(declaim (ftype (function (t &key (:seconds real)) null) stop-control-poll))

(defun stop-control-poll (poll &key (seconds 2))
  "Wait up to SECONDS for POLL, the control thread, to leave, then destroy it.
Return NIL.

The supervisor has already cleared its running flag, so the loop exits after the
control request in flight. Waiting lets that request publish its answer instead
of dying mid reload or channel stop."
  (when (and poll (bordeaux-threads:thread-alive-p poll))
    (let ((deadline (+ (get-internal-real-time)
                       (* seconds internal-time-units-per-second))))
      (loop while (and (bordeaux-threads:thread-alive-p poll)
                       (< (get-internal-real-time) deadline))
            do (sleep 0.02)))
    (when (bordeaux-threads:thread-alive-p poll)
      (ignore-errors (bordeaux-threads:destroy-thread poll))))
  nil)

(declaim (ftype (function (string list &optional list) integer) run-supervised-command))

(defun run-supervised-command (name arguments &optional options)
  "Run `chat` or `serve` with a supervisor owned by this process.
Starts provider refresh on a background thread and wires channels and
factories before starting the supervisor."
  (when (and (string= name "serve")
             (not (enchiridion.memory:agent-seeded-p (agent-directory))))
    (error 'enchiridion.errors:configuration-error
           :key :agent-directory
           :detail "Run enchiridion init and edit the identity files before serving."))
  (let ((context (make-command-state +turn-requirements+)))
    (unwind-protect
         (progn
           (when (and (string= name "serve") (not (context-store context)))
             (error 'enchiridion.errors:configuration-error
                    :key :memory-db :detail "Serving requires a usable memory store."))
           (require-git)
           (ensure-started context)
           (setf (context-provider-refresh context)
                 (start-provider-refresh context))
           (let* ((supervisor (make-application-supervisor context))
                  (cancelled (list nil))
                  (poll nil)
                  (command-context
                    (command-context-for
                     context
                     :supervisor supervisor
                     :respond (make-respond context cancelled)
                     :cancel (lambda () (setf (car cancelled) t)))))
             (multiple-value-bind (channels factories)
                 (build-channels context supervisor command-context options name)
               (setf (enchiridion.supervisor:supervisor-channels supervisor) channels
                     (enchiridion.supervisor:supervisor-channel-factory supervisor)
                     (lambda (channel-name)
                       (let ((constructor (cdr (assoc channel-name factories
                                                      :test #'string-equal))))
                         (when constructor (funcall constructor))))))
             (check-channel-policy
              (enchiridion.supervisor:supervisor-channels supervisor))
             (unwind-protect
                  (let ((enchiridion.channel.cli:*command-context* command-context))
                    (when (string= name "chat")
                      (enchiridion.supervisor:supervisor-start supervisor)
                      (setf poll
                            (bordeaux-threads:make-thread
                             (lambda ()
                               (handler-case
                                   (enchiridion.supervisor:supervisor-poll-loop
                                    supervisor)
                                 (error () nil)))
                             :name "enchiridion control poll")))
                    (enchiridion.channel.cli:run-command name arguments))
               (ignore-errors
                 (enchiridion.supervisor:supervisor-stop supervisor))
               ;; The supervisor clears its running flag before its own drains,
               ;; so the loop leaves after a control request in flight; killing
               ;; the thread first truncated a reload or a channel stop
               (stop-control-poll poll))))
      (close-context context))))

(declaim (ftype (function (list) t) split-options))

(defun split-options (argv)
  "Return two values: the options at the front of ARGV and what follows them.

A flag and its value are pushed as a pair, and a flag whose value is missing
is pushed with :MISSING so that MAIN can say which flag it was. A value that
starts with a dash is the next flag, not a value: --bind --port is a mistake,
and reading --port as the bind address would hide it."
  (let ((options '()))
    (loop while (and argv
                     (stringp (first argv))
                     (> (length (first argv)) 2)
                     (string= "--" (subseq (first argv) 0 2)))
          do (let* ((flag (subseq (first argv) 2))
                    (value (second argv))
                    (usable (and (stringp value)
                                 (not (and (> (length value) 1)
                                           (string= "--" (subseq value 0 2)))))))
               (if (member flag '("channel" "bind" "port" "token-env") :test #'string=)
                   (progn
                     (push (intern (string-upcase flag) :keyword) options)
                     (push (if usable value :missing) options)
                     (setf argv (if usable (cddr argv) (rest argv))))
                   (return (values (nreverse options) argv)))))
    (values (nreverse options) argv)))

(declaim (ftype (function (list) (or null string)) validate-options))

(defun validate-options (options)
  "Return one line about the first unusable option, or NIL.

The command line is read by a person, so every failure here is a sentence
rather than a condition: a flag with no value, a channel that does not exist,
a port that is not a port."
  (let ((channel (getf options :channel))
        (port (getf options :port)))
    (let ((missing (loop for (key value) on options by #'cddr
                         when (eq value :missing)
                           return key)))
      (cond
        (missing
         (format nil "The --~(~A~) flag needs a value." missing))
        ((and channel (not (member channel '("cli" "http" "fluxer") :test #'string=)))
         (format nil "There is no channel called ~A. The channels are cli, http and fluxer."
                 channel))
        ((and (or (getf options :bind) (getf options :port) (getf options :token-env))
              (not (and channel (string= channel "http"))))
         "The --bind, --port and --token-env flags belong to --channel http.")
        ((and port
              (let ((number (parse-integer port :junk-allowed t)))
                (or (null number) (< number 1) (> number 65535))))
         (format nil "The port must be a number between 1 and 65535, not ~A." port))
        (t nil)))))

(defun require-git ()
  "Signal a configuration error when the Git executable does not answer.
Git is a runtime dependency: the agent directory is a repository, and every
turn commits to it. The container installs Git, and the Nix wrapper puts the
store Git on PATH and in ENCHIRIDION_GIT. A host install must do the same."
  (unless (enchiridion.git:git-available-p)
    (error 'enchiridion.errors:configuration-error
           :key :git
           :detail "Git is required. Install Git and put it on PATH, or set ENCHIRIDION_GIT.")))

(declaim (ftype (function (&rest t) integer) main))

(defun main (&rest argv)
  "Read ARGV, everything after the script name, and run the named command.
Return an exit status.

A bad flag, an unknown channel and a refused configuration are exit 2, the
status the command table already uses for a call it could not use. A first
launch is checked before the channel flags, because nothing may start before
the operator has had a chance to edit the seed files."
  ;; SBCL starts every process from the same random state, so without this
  ;; every session id and temporary file name repeats from one run to the next.
  (setf *random-state* (make-random-state t))
  ;; The command table reaches the health check through the process that owns
  ;; the state paths, so `enchiridion doctor` and `doctor` inside the REPL run
  ;; the same code.
  (setf enchiridion.channel.cli:*doctor-function* #'run-doctor)
  (handler-case
      (multiple-value-bind (options arguments) (split-options argv)
        (let ((command (or (first arguments) ""))
              (problem (validate-options options)))
          (when problem
            (format *error-output* "~&enchiridion: ~A~%" problem)
            (finish-output *error-output*)
            (return-from main 2))
          (cond
            ((string= command "--verify-plugin")
             (let ((directory (second arguments)))
               (unless directory
                 (format *error-output* "--verify-plugin takes a directory.~%")
                 (finish-output *error-output*)
                 (return-from main 2))
               (let ((config (load-config)))
                 (verify-plugin-directory directory
                                          :uid (agent-uid config)
                                          :gid (agent-gid config)))))
            ((plusp (length command))
             (if (supervisor-command-p command)
                 ;; The flags come before the command. They are also read after
                 ;; it, because `serve --channel http` is what a person types
                 ;; and silently serving with no channels is worse than
                 ;; accepting both spellings.
                 (multiple-value-bind (later rest-arguments) (split-options (rest arguments))
                   (let ((all (append options later))
                         (later-problem nil))
                     (setf later-problem (validate-options all))
                     (when later-problem
                       (format *error-output* "~&enchiridion: ~A~%" later-problem)
                       (finish-output *error-output*)
                       (return-from main 2))
                     (let ((problem (enchiridion.channel.cli:command-problem
                                     command rest-arguments)))
                       (when problem
                         (format t "~&~A~%" problem)
                         (finish-output)
                         (return-from main 2))
                       (run-supervised-command command rest-arguments all))))
                 ;; An unknown name and a wrong argument count are answered from
                 ;; the table, before a configuration is read or a store opened.
                 (let ((problem (enchiridion.channel.cli:command-problem
                                 command (rest arguments))))
                   (if problem
                       (progn (format t "~&~A~%" problem)
                              (finish-output)
                              2)
                       (run-command command (rest arguments))))))
            ;; Nothing before this point loaded a configuration, so the paths
            ;; that only print a line work on a fresh install with no config.
            ((first-launch-p)
             (load-config)
             (require-git)
             (print-first-launch))
            ;; `enchiridion --channel http --bind 127.0.0.1 --port 8787` is a
            ;; whole invocation with no subcommand, so a channel flag with no
            ;; command is a request to serve.
            (options (run-supervised-command "serve" '() options))
            (t
             (format t "~&Agent directory is ready. Run `enchiridion chat`, or `enchiridion help`.~%")
             (finish-output)
             0))))
    (enchiridion.errors:usage-error (condition)
      (print-condition condition)
      2)
    (enchiridion.errors:configuration-error (condition)
      (print-condition condition)
      2)
    (error (condition)
      (print-condition condition)
      ;; A command line tool that dies with no trace is a tool the operator
      ;; cannot report a bug about.
      (format *error-output* "~A~%" (enchiridion.compat:backtrace-string 12))
      (finish-output *error-output*)
      1)))

;;;; First launch.
;;;;
;;;; The first run creates the agent directory and stops. Nothing starts until
;;;; the operator has had a chance to edit the seed files, because an agent
;;;; that wakes up before its personality is written will overwrite it.

(defun first-launch-p ()
  "Return T when the agent directory has no seed file in it yet."
  (not (enchiridion.memory:agent-seeded-p (agent-directory))))

(defun print-first-launch ()
  "Create the agent directory and print what happened. Return an exit status."
  ;; The directory has to belong to the agent uid before INIT-AGENT runs, not
  ;; after: init creates the repository, and repository Git runs as that uid.
  (prepare-sandbox (enchiridion:config))
  (let ((result (enchiridion.memory:init-agent (agent-directory))))
    (format t "~A~%" (enchiridion.memory:init-status-line result))
    (dolist (name (enchiridion.memory:init-created result))
      (format t "  ~A~%" name))
    (if (enchiridion.memory:init-problems result)
        (progn
          (format t "~&Could not write:~%")
          (dolist (problem (enchiridion.memory:init-problems result))
            (format t "  ~A: ~A~%" (car problem) (cdr problem)))
          (format t "~&Fix the problem above, then run again.~%")
          (finish-output)
          1)
        (progn
          (prepare-sandbox (enchiridion:config))
          (format t "~&Bootstrap has not started. Edit SOUL.md, OPERATOR.md, and WORLD.md first,~%")
          (format t "then run `enchiridion chat`. See agents/default/GUIDE.md for the walkthrough.~%")
          (finish-output)
          0))))

;;;; Entry.

;; An interrupt is the one exit that does not come from a command. Ctrl-C is
;; handled here rather than inside MAIN so that LOAD-CONFIG is covered too, and
;; because the throw unwinds through every UNWIND-PROTECT on the way out: serve
;; stops its channels, chat stops its supervisor, and ask closes its context.
;; SIGTERM and SIGHUP join Ctrl-C on the same path, so `docker stop` and a
;; closed terminal stop the process the same way. The status is 130, the shell
;; convention for a process ended by SIGINT.
(enchiridion.compat:exit-with
 (catch 'enchiridion-interrupt
   (enchiridion.compat:with-interrupt-handler
       ((lambda (condition)
          (declare (ignore condition))
          (format *error-output* "~&enchiridion: interrupted.~%")
          (finish-output *error-output*)
          (throw 'enchiridion-interrupt 130)))
     ;; Installed inside the handler, so there is no window where SIGTERM
     ;; reaches a process that has not armed it yet.
     (enchiridion.compat:install-shutdown-signals)
     ;; apply, not a plain call: MAIN is &rest over the arguments, so passing
     ;; the list as one argument would nest it and every command would look
     ;; absent.
     (apply #'main (enchiridion.compat:script-arguments)))))
