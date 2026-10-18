;;;; main.cl --- The entry point.
;;;;
;;;; Run with sbcl --script. It reads the command line, loads config.cl when
;;;; there is one, and hands the command to the command table.
;;;;
;;;; This file is a script rather than a system component on purpose: loading a
;;;; system must never start an agent, and the top level form of this file is
;;;; the program. #check compiles it separately so it is still covered.

;; ASDF first, before the defpackage. The standard prefers that defpackage
;; opens a file, and this is the one place where it cannot: this file is a
;; script, so nothing has loaded the system yet, and both UIOP and ASDF have
;; to exist at read time for the import and the qualified references below.
;; SBCL accepts it.
(require :asdf)

(defpackage #:enchiridion.main
  (:use #:cl)
  (:import-from
   #:uiop
   #:getcwd
   #:getenv
   #:pathname-directory-pathname)
  (:export
   #:main #:project-root #:resolve-project-root #:agent-directory
   #:environment-value #:load-config #:first-launch-p #:run-command
   #:join-arguments #:load-configured-secrets)
  (:documentation
   "Process entry: roots, configuration, argument handling, and first launch."))

(in-package #:enchiridion.main)

;; ASDF adds the SBCL implementation directory to its wrapping source
;; registry. SBCL ships duplicate .asd files in contrib, and ASDF warns about
;; each duplicate only while *VERBOSE-OUT* is true. The duplicates are
;; harmless and the warnings are noise, so a command-line run silences the
;; scan. The package and the symbol are looked up by name: both are ASDF
;; internals, and a version that renames one must not stop the program.
(let ((package (find-package "ASDF/SOURCE-REGISTRY")))
  (when package
    (let ((symbol (find-symbol "*VERBOSE-OUT*" package)))
      (when symbol
        (setf (symbol-value symbol) nil)))))

;; DBI's DEFCLASS/A and DEFINE-CONDITION/A macros define a DEFTYPE for each
;; <NAME> and then redefine that same name as a class, so SBCL warns nineteen
;; times on every load of the library. The pattern is the library's own and it
;; changes nothing here, but it is not something the operator should read on
;; every run. Only that exact message is muffled: any other warning still
;; reaches the terminal, which is what makes this a silence and not a blindfold.
(defun muffled-library-warning-p (condition)
  "Return T for the one library warning this program does not print.

The test is on the report and not on SIMPLE-CONDITION-FORMAT-CONTROL, because
SBCL keeps that control as an SB-FORMAT::FMT-CONTROL object rather than as the
string the operator sees."
  (let ((report (princ-to-string condition)))
    (and (>= (length report) 40)
         (eql 0 (search "redefining DEFTYPE type to be a class" report)))))

;; ASDF binds *VERBOSE-OUT* to the standard output while it loads a system,
;; so setting the variable globally is not enough. VERBOSE NIL is the switch
;; that reaches the source-registry scan. REQUIRE has no such argument.
(handler-bind ((warning (lambda (condition)
                          (when (muffled-library-warning-p condition)
                            (muffle-warning condition)))))
  (asdf:load-system "enchiridion" :verbose nil))

;; The command table lives in the channel package now. This file only builds
;; the context a command reads, so nothing here is forward referenced.

;;;; Roots.
;;;;
;;;; The wrapper sets ENCHIRIDION_SOURCE to the directory it installed and
;;;; ENCHIRIDION_HOME to where the agent directory belongs. A checkout sets
;;;; neither, so the nearest directory holding an enchiridion.asd wins. That
;;;; is how a checkout and a container both land somewhere sensible from one
;;;; code path.

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
;;;; An absent config.cl is not an error. It means defaults, which is how a
;;;; first time user writes nothing at all. Env vars override the file. The
;;;; file never holds a secret, because a file in the repository is a file
;;;; that ends up in a store path.

(defun load-config ()
  "Load config.cl when it is there and return the configuration plist, or the
defaults. The reader lives in the config module, so the shell and the system
cannot disagree about what a configured model is."
  (enchiridion:read-config))

;;;; The agent context.
;;;;
;;;; One object holds everything a command needs: the configuration, the
;;;; store, the backend, the broker, the agent, and the session. Building it
;;;; starts nothing, because `enchiridion version` must not open a socket.
;;;; A command that needs the broker calls ENSURE-STARTED.

(defun agent-uid (config)
  "Return the uid agent code runs as, from the :SANDBOX section."
  (or (second (assoc :agent-uid (enchiridion:config-section config :sandbox)
                     :test #'eq))
      1000))

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
  "Return the .env path to read. The container tmpfs wins, then the current
directory, then the source root. The checkout keeps .env beside the code, and
`nix run` executes a script in the store while the operator stands in the
checkout, so the current directory is the one that can see the host file."
  (enchiridion.llm.secrets:secrets-file
   :directories (list (getcwd) (enchiridion:project-root))))

(declaim (ftype (function (&optional t) string) load-configured-secrets))

(defun load-configured-secrets (&optional config)
  "Load every secret the configuration names, then unset those names, and
return the API key.

The key comes from the loader rather than from getenv so that there is one
path to a secret. .env is read here, held in memory by the loader, and not
written anywhere; the process is short lived and nothing is logged.

Every name the configuration mentions is read, not only the LLM key: a Fluxer
bot token and a webhook token are secrets too, and a token that never reaches
the loader is a token the scrubber does not know and the shape filter cannot
recognise. Loading them here is also what lets `enchiridion secrets` list them
by name and source without ever printing a value.

The names are then removed from this process's environment, which is the step
PLAN.md section 5.2 promises: a child inherits nothing and a later read of
/proc finds nothing. The value stays in memory for the life of the process."
  (let* ((config (or config (load-config)))
         (path (secrets-path))
         (names (enchiridion:configured-secret-names config)))
    ;; Load .env before choosing the provider. A key in the file is a key the
    ;; provider detection can see, and the file is not the process environment.
    (enchiridion.llm.secrets:load-secrets
     :path (and (probe-file path) path)
     :names names)
    (dolist (name names)
      (enchiridion.compat:unset-environment-variable name))
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
  (started-p nil :type boolean))

(declaim (ftype (function (t) list) agent-budget-plist))

(defun agent-budget-plist (config)
  "Return the token caps from the :BUDGET section, as the plist an agent takes.

The caps live outside the :LLM section, so CONFIG-SECTION-VALUE reads them.
An agent built without them answers BUDGET-EXHAUSTED-P with NIL forever, which
is how a configured cap becomes no cap at all."
  (list :max-tokens-per-tick
        (enchiridion:config-section-value config :budget :max-tokens-per-tick)
        :max-tokens-per-day
        (enchiridion:config-section-value config :budget :max-tokens-per-day)))

(declaim (ftype (function (t) integer) heartbeat-interval))

(defun heartbeat-interval (config)
  "Return the sleep interval in whole seconds from the :SLEEP section.
Anything that is not a positive whole number of seconds is the shipped fifteen
minutes: an interval of zero is a tick loop and a string is a mistyped key."
  (let ((value (enchiridion:config-section-value config :sleep :interval-seconds 900)))
    (if (and (integerp value) (plusp value)) value 900)))

(defun make-context ()
  "Build the context for one command. Start nothing and open no socket.

The store is opened before the agent because the agent's prompt is compiled
from the blocks, and two of those blocks are rows in the store."
  (let* ((config (load-config))
         (directory (agent-directory))
         (key (load-configured-secrets config))
         (store (open-agent-store config))
         (backend (when (plusp (length key))
                    (enchiridion.llm:resolve-backend :config config :api-key key)))
         (broker (enchiridion.tools.broker:make-broker
                  :socket (broker-socket-path)
                  :uid (agent-uid config)
                  :timeout 30))
         (agent (enchiridion.kernel:make-agent
                 :name "default"
                 :backend backend
                 :directory directory
                 :budget (agent-budget-plist config)
                 :store store
                 :broker broker)))
    (enchiridion.tools.builtin:register-builtin-tools)
    (%make-context :directory directory
                   :config config
                   :store store
                   :backend backend
                   :broker broker
                   :agent agent
                   :generation (handler-case
                                   (enchiridion.memory:state-generation directory)
                                 (error () 0)))))

(defun install-agent-proxies (context sources generation)
  "Register one proxy tool per agent plugin and record GENERATION.

The model has to see each authored schema, and the supervisor must not hold the
handler. A proxy is the tool the model sees with a handler that refuses: every
call is routed to the broker before dispatch reaches it."
  (enchiridion.plugin:discard-generation (context-generation context))
  (dolist (manifest (handler-case (enchiridion.plugin:plugin-manifests sources)
                      (error () '())))
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
  (setf (context-generation context) generation)
  generation)

(defun load-agent-generation (context)
  "Verify the agent's skills and tools in a one-shot child, then load them in
the broker and register the proxy tools the model sees. Return the generation.

The supervisor never compiles agent code. The child does it as the agent user,
and only a generation that exits zero is loaded for real."
  (let* ((directory (context-directory context))
         (generation (1+ (context-generation context)))
         (sources (enchiridion.plugin:agent-source-files directory)))
    (when sources
      (multiple-value-bind (ok-p output)
          (enchiridion.tools.broker:broker-verify-plugin
           (uiop:ensure-directory-pathname directory)
           :uid (agent-uid (context-config context)))
        (unless ok-p
          (error 'enchiridion.errors:tool-error :tool "reload" :detail output))
        (install-agent-proxies context sources generation)
        (enchiridion.tools.broker:broker-load-generation
         (context-broker context) directory :generation generation)))
    (setf (context-generation context) generation)
    generation))

(defun ensure-started (context)
  "Start the broker, load the agent's generation, and open a session.
Idempotent. A generation that fails to load is reported and does not stop the
turn: the builtins still work, and the agent is told what happened."
  (unless (context-started-p context)
    (enchiridion.tools.broker:broker-start (context-broker context))
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

(defun verify-plugin-directory (directory)
  "Verify DIRECTORY in a child process and print its report. Return an exit
status. The child drops to the agent uid before it reads a single agent file."
  (multiple-value-bind (ok-p output)
      (enchiridion.tools.broker:broker-verify-plugin
       (uiop:ensure-directory-pathname directory) :uid 1000)
    (write-string output)
    (finish-output)
    (if ok-p 0 1)))

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
    (format t "~A~%"
            (enchiridion.llm.secrets:scrub
             (enchiridion.llm:completion-text completion)))
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

(defun broker-reload (context supervisor)
  "Verify the agent files in a one-shot child, load them in the broker, and
return the plist the supervisor records: :OK-P, :GENERATION and :REPORT.

The supervisor process never compiles agent code. The child does it as the
agent user, and only a generation that exits zero is loaded for real."
  (let* ((directory (context-directory context))
         (previous (enchiridion.supervisor:supervisor-generation supervisor))
         (generation (1+ previous))
         (sources (handler-case (enchiridion.plugin:agent-source-files directory)
                    (error () '()))))
    (if (null sources)
        (progn
          (enchiridion.plugin:discard-generation previous)
          (setf (context-generation context) generation)
          (list :ok-p t :generation generation :report "no agent files to load"))
        (multiple-value-bind (ok-p output)
            (enchiridion.tools.broker:broker-verify-plugin
             (uiop:ensure-directory-pathname directory)
             :uid (agent-uid (context-config context)))
          (if (not ok-p)
              (list :ok-p nil :generation previous :report output)
              (progn
                (install-agent-proxies context sources generation)
                (let ((reply (enchiridion.tools.broker:broker-load-generation
                              (context-broker context) directory
                              :generation generation)))
                  (list :ok-p (not (null (gethash "ok" reply)))
                        :generation generation
                        :report (or (gethash "report" reply) "")))))))))

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
          (let ((completion (enchiridion.kernel:run-turn
                             (context-agent context) text
                             :session (context-session context)
                             :store (context-store context)
                             :channel channel
                             :cancel-p (lambda () (car cancelled)))))
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

(declaim (ftype (function (t) string) condition-line))

(defun condition-line (condition)
  "Return CONDITION as one line: its report, then its detail when it has one."
  (let ((detail (and (typep condition 'enchiridion.errors:enchiridion-error)
                     (enchiridion.errors:error-detail condition))))
    (if (stringp detail)
        (format nil "~A ~A" condition detail)
        (princ-to-string condition))))

(declaim (ftype (function (t) function) make-channel-turn))

(defun make-channel-turn (context)
  "Return the function a channel calls to run one turn.

The result is a plist, because every channel formats its own answer and none
of them should have to know what a completion is: :ok-p says whether the turn
ran, :reply is the text to send, :error is one line when it did not, :reason
separates a busy agent from a failure, and :usage sums what the turn cost.

The turn takes the agent lock without waiting. A webhook client is better
served by a 503 and a retry than by a connection held open behind somebody
else's turn, and the reply is scrubbed here as well as in the kernel: the
model can echo a secret back, and the outbound path is the last gate."
  (lambda (message)
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
                 (before (length (enchiridion.kernel:spend agent)))
                 (completion (enchiridion.kernel:run-turn
                              agent text
                              :session (context-session context)
                              :store (context-store context)
                              :channel channel
                              :block-p nil)))
            (list :ok-p t
                  :reply (enchiridion.llm.secrets:scrub
                          (enchiridion.llm:completion-text completion))
                  :error ""
                  :reason nil
                  :usage (enchiridion.kernel:spend-summary
                          (enchiridion.kernel:spend-since agent before)))))
      (enchiridion.errors:turn-busy (condition)
        (channel-failure :busy (condition-line condition)))
      (enchiridion.errors:turn-cancelled (condition)
        (channel-failure :cancelled (condition-line condition)))
      (enchiridion.errors:enchiridion-error (condition)
        (channel-failure :failed (condition-line condition)))
      (error (condition)
        (channel-failure :failed (condition-line condition))))))

(declaim (ftype (function (t) t) make-http-health))

(defun make-http-health (supervisor)
  "Return the function GET /health reads.
The answer comes from the live supervisor rather than from the status file: a
file left by a process that stopped reports an uptime that grows forever."
  (lambda ()
    (when (enchiridion.supervisor:supervisor-running-p supervisor)
      (list :ok-p t
            :uptime (max 0 (- (get-universal-time)
                              (enchiridion.supervisor:supervisor-started supervisor)))
            :channels (mapcar #'enchiridion.supervisor:channel-row
                              (enchiridion.supervisor:supervisor-channels supervisor))))))

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

(declaim (ftype (function (t t t list string) list) build-channels))

(defun build-channels (context supervisor command-context options command)
  "Return the channels this process supervises.

Every channel the process can run is built, not only the enabled ones: the
control file's `channels enable http` has to be able to start a channel that
was disabled at startup, and an object that does not exist cannot be started.
Building one binds no port and opens no socket.

CHAT and SERVE differ by one channel. The REPL is the command's own foreground
surface, so the cli channel is a supervised channel only under `serve`; giving
it to chat as well would run a second REPL on a thread."
  (let* ((config (context-config context))
         (requested (getf options :channel))
         (http-p (or (and (stringp requested) (string-equal requested "http"))
                     (enchiridion:channel-enabled-p :http)))
         (fluxer-p (or (and (stringp requested) (string-equal requested "fluxer"))
                       (enchiridion:channel-enabled-p :fluxer)))
         (channels '()))
    (when (string= command "serve")
      (push (enchiridion.channel.cli:make-cli-channel :context command-context)
            channels))
    (when http-p
      (let* ((entry (http-entry config options))
             (bind (or (getf entry :bind) "127.0.0.1"))
             (port (or (getf entry :port) 8787)))
        (push (enchiridion.channel.http:make-http-channel
               :service (enchiridion.channel.http:make-http-service
                         :turn (make-channel-turn context)
                         :health (make-http-health supervisor)
                         :usage (make-ledger-reader (context-store context))
                         :token (http-token entry)
                         :bind bind
                         :port port
                         :body-limit (or (getf entry :max-body-bytes)
                                         enchiridion.channel.http:+http-body-limit+)))
              channels)))
    (when fluxer-p
      ;; The channel resolves its own allowlist and token from the
      ;; configuration it is handed, so a test and the supervisor use the same
      ;; reader and a short :fluxer entry cannot lose the operator's allowlist.
      (push (enchiridion.channel.fluxer:make-fluxer-channel
             :turn (make-channel-turn context)
             :config config)
            channels))
    (nreverse channels)))

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
     :heartbeat-p (enchiridion:config-section-value config :sleep :enabled t)
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

(defun run-command (name arguments)
  "Run NAME with ARGUMENTS through the shared command table.
Return an exit status."
  (let ((context (make-context)))
    (unwind-protect
         (let* ((cancelled (list nil))
                (enchiridion.channel.cli:*command-context*
                  (command-context-for
                   context
                   :respond (make-respond context cancelled)
                   :cancel (lambda () (setf (car cancelled) t)))))
           (enchiridion.channel.cli:run-command name arguments))
      (close-context context))))

(declaim (ftype (function (string) boolean) supervisor-command-p))

(defun supervisor-command-p (name)
  "Return T for the two commands that own a supervisor process."
  (not (null (member name '("chat" "serve") :test #'string=))))

(declaim (ftype (function (string list &optional list) integer) run-supervised-command))

(defun run-supervised-command (name arguments &optional options)
  "Run chat or serve with a supervisor this process owns.

CHAT runs the REPL in the foreground with the control poll on a thread beside
it, so a reload typed at the REPL reaches a supervisor that answers. SERVE
hands the supervisor to the command, which starts it and polls in the
foreground itself.

The channels are built and handed over before the supervisor starts. It starts
whatever is in its list, and an empty list is why `serve` used to come up with
no channels at all."
  (let ((context (make-context)))
    (unwind-protect
         (progn
           (ensure-started context)
           (let* ((supervisor (make-application-supervisor context))
                  (cancelled (list nil))
                  (poll nil)
                  (command-context
                    (command-context-for
                     context
                     :supervisor supervisor
                     :respond (make-respond context cancelled)
                     :cancel (lambda () (setf (car cancelled) t)))))
             (setf (enchiridion.supervisor:supervisor-channels supervisor)
                   (build-channels context supervisor command-context options name))
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
               (when poll
                 (ignore-errors (bordeaux-threads:destroy-thread poll)))
               (ignore-errors
                 (enchiridion.supervisor:supervisor-stop supervisor)))))
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

(declaim (ftype (function (&rest t) integer) main))

(defun main (&rest argv)
  "Read ARGV, everything after the script name, and run the named command.
Return an exit status.

A bad flag, an unknown channel and a refused configuration are exit 2, the
status the command table already uses for a call it could not use. A first
launch is checked before the channel flags, because nothing may start before
the operator has had a chance to edit the seed files."
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
               (verify-plugin-directory directory)))
            ((plusp (length command))
             (if (supervisor-command-p command)
                 (run-supervised-command command (rest arguments) options)
                 (run-command command (rest arguments))))
            ((first-launch-p) (print-first-launch))
            ;; The plan prints `enchiridion --channel http --bind 127.0.0.1
            ;; --port 8787` with no subcommand, so a channel flag with no
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
          (format t "~&Bootstrap has not started. Edit SOUL.md, OPERATOR.md, and WORLD.md first,~%")
          (format t "then run `enchiridion chat`. See agents/default/GUIDE.md for the walkthrough.~%")
          (finish-output)
          0))))

;;;; Entry.

(load-config)
;; apply, not a plain call: MAIN is &rest over the arguments, so passing the
;; list as one argument would nest it and every command would look absent.
(enchiridion.compat:exit-with
 (apply #'main (enchiridion.compat:script-arguments)))