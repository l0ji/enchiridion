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
   #:join-arguments #:secrets-api-key
   #:*commands*)
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

;; The table is defined after the handlers it names, and two of the
;; handlers read the table, so the forward reference is real. Proclaiming
;; it here is what keeps the compiler from warning about it.
(declaim (special *commands*))

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

(declaim (ftype (function () string) secrets-api-key))

(defun secrets-api-key ()
  "Return the API key, loading .env first if there is one.

The key comes from the loader rather than from getenv so that there is one
path to a secret. .env is read here, held in memory by the loader, and not
written anywhere; the process is short lived and nothing is logged.

The loader registers every value it reads, so the scrubber knows the key even
when the provider quotes it back. A value that came from the environment is
registered here for the same reason; otherwise the one path that did not pass
through .env would be the one that leaks."
  (let* ((config (load-config))
         (path (secrets-path)))
    ;; Load .env before choosing the provider. A key in the file is a key the
    ;; provider detection can see, and the file is not the process environment.
    (when (probe-file path)
      (enchiridion.llm.secrets:load-secrets :path path))
    (let* ((variable (enchiridion.llm:default-api-key-env config))
           (value (or (enchiridion.llm.secrets:secret-value variable)
                      (enchiridion.compat:environment-value variable))))
      (when (and value
                 (plusp (length value))
                 (not (enchiridion.llm.secrets:secret-present-p variable)))
        (enchiridion.llm.secrets:register-secret variable value :env))
      (or value ""))))

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

(defun make-context ()
  "Build the context for one command. Start nothing and open no socket."
  (let* ((config (load-config))
         (directory (agent-directory))
         (key (secrets-api-key))
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
                 :broker broker)))
    (enchiridion.tools.builtin:register-builtin-tools)
    (%make-context :directory directory
                   :config config
                   :store (open-agent-store config)
                   :backend backend
                   :broker broker
                   :agent agent
                   :generation (handler-case
                                   (enchiridion.memory:state-generation directory)
                                 (error () 0)))))

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
        (enchiridion.plugin:discard-generation (context-generation context))
        (dolist (manifest (enchiridion.plugin:plugin-manifests sources))
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

(defun ensure-agent-repository (directory)
  "Make DIRECTORY a git repository when it is not one, and commit what is
there. Return the commit hash, or NIL when there was nothing to commit.

The repository is nested: the agent's history is its own, so `enchiridion
undo` rolls back an agent change and never a change to the harness."
  (if (enchiridion.git:repository-p directory)
      (enchiridion.git:git-commit-all directory "Record the agent directory")
      (progn
        (enchiridion.git:git-init directory)
        (enchiridion.git:git-commit-all directory "Create the agent directory"))))

(defun commit-agent-turn (context label)
  "Commit whatever the turn changed in the agent directory.

Every change the agent makes lands in git under the operator's key. A turn
with nothing to commit, and a host with no git, both leave the turn alone."
  (handler-case
      (enchiridion.git:git-commit-all
       (context-directory context)
       (format nil "Turn ~D via ~A"
               (enchiridion.kernel:agent-turn (context-agent context))
               label))
    (error () nil)))

(defun verify-plugin-directory (directory)
  "Verify DIRECTORY in a child process and print its report. Return an exit
status. The child drops to the agent uid before it reads a single agent file."
  (multiple-value-bind (ok-p output)
      (enchiridion.tools.broker:broker-verify-plugin
       (uiop:ensure-directory-pathname directory) :uid 1000)
    (write-string output)
    (finish-output)
    (if ok-p 0 1)))

;;;; The command table.
;;;;
;;;; One table backs both the shell and the REPL, so the two surfaces cannot
;;;; drift apart. Milestone 6 moves this table into the channel package; it is
;;;; here now because the first launch needs something to call.

(defun command-init (arguments)
  "Create the agent directory, writing only the files that are missing."
  (declare (ignore arguments))
  (let ((result (enchiridion.memory:init-agent (agent-directory))))
    (format t "~A~%" (enchiridion.memory:init-status-line result))
    (dolist (name (enchiridion.memory:init-created result))
      (format t "  created  ~A~%" name))
    (dolist (name (enchiridion.memory:init-existing result))
      (format t "  kept     ~A~%" name))
    (when (enchiridion.memory:init-problems result)
      (format t "~&Could not write:~%")
      (dolist (problem (enchiridion.memory:init-problems result))
        (format t "  ~A: ~A~%" (car problem) (cdr problem))))
    (finish-output)
    (unless (enchiridion.memory:init-problems result)
      (ensure-agent-repository (agent-directory)))
    (if (enchiridion.memory:init-problems result) 1 0)))

(defun command-version (arguments)
  "Print the version and where the binary was installed."
  (declare (ignore arguments))
  (format t "enchiridion ~A~%"
          (asdf:component-version (asdf:find-system "enchiridion" nil)))
  (format t "~A ~A~%" (lisp-implementation-type) (lisp-implementation-version))
  (format t "source   ~A~%" (or (environment-value "ENCHIRIDION_SOURCE")
                                 (resolve-project-root)))
  (format t "agent    ~A~%" (agent-directory))
  (finish-output)
  0)

(declaim (ftype (function (integer (or null integer)) string) argument-range))

(defun argument-range (minimum maximum)
  "Return the arity MINIMUM to MAXIMUM as a phrase. A NIL MAXIMUM means no
upper bound, so the phrase says so instead of reading NIL as a number."
  (if maximum
      (format nil "between ~D and ~D" minimum maximum)
      (format nil "at least ~D" minimum)))

(defun command-help (arguments)
  "Print the command list, or the detail for one command."
  (if (first arguments)
      (let ((entry (assoc (first arguments) *commands* :test #'string=)))
        (unless entry
          (format t "There is no command called ~A.~%" (first arguments))
          (finish-output)
          (return-from command-help 2))
        (destructuring-bind (name minimum maximum handler summary) entry
          (declare (ignore handler))
          (format t "~A~%    ~A~%    arguments ~A~%"
                  name summary (argument-range minimum maximum))))
      (progn
        (format t "~&Commands:~%")
        (dolist (entry *commands*)
          (destructuring-bind (name minimum maximum handler summary) entry
            (declare (ignore handler))
            (format t "  ~A~%    ~A~%    arguments ~A~%"
                    name summary (argument-range minimum maximum))))))
  (finish-output)
  0)

;;;; One turn.
;;;;
;;;; `ask` is the smallest thing that proves the whole outbound path: the key
;;;; is read, the request is built, it goes out, the reply comes back parsed,
;;;; and the tokens are on a record. Everything above it is an assembly of this.

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

(defun command-ask (arguments)
  "Send one turn to the configured backend and print the reply. Returns an
exit status.

The key is read here and nowhere else in the command path, and it is never
printed. The scrubber runs over the reply on the way to the terminal as well
as on the way to a provider, because a model that quotes a key back at you has
already had it and showing it is what turns that into a screenshot.

The turn is also written to the memory store, so that a later search can find
what was asked and what was answered. A store that cannot be opened costs the
transcript and not the turn: the reply prints either way. Whatever the turn
wrote under the agent directory is committed when it lands."
  ;; A provider that refuses the request is an expected outcome and is reported
  ;; as the operator's problem to fix. MAIN prints a backtrace for everything
  ;; else, and MAIN's backtrace stops at MAIN itself because the compiler
  ;; inlines this function into it, so a missing key arrives as a stack of
  ;; frames that name no library, no request and no reply.
  (handler-case
      (let ((question (join-arguments arguments)))
        (unless (plusp (length question))
          (format *error-output* "ask takes the question as its argument.~%")
          (finish-output *error-output*)
          (return-from command-ask 2))
        (let ((context (make-context)))
          (unwind-protect
               (progn
                 (unless (context-backend context)
                   (error 'enchiridion.errors:configuration-error
                          :key :api-key
                          :detail (format nil "No API key. Put ~A in .env or the environment."
                                          (enchiridion.llm:default-api-key-env
                                           (context-config context)))))
                 (ensure-started context)
                 (let ((completion (enchiridion.kernel:run-turn
                                    (context-agent context) question
                                    :session (context-session context)
                                    :store (context-store context))))
                   (print-completion completion (context-config context))
                   (commit-agent-turn context :cli)
                   0))
            (close-context context))))
    (enchiridion.errors:enchiridion-error (condition)
      (format *error-output* "~&~A~%" condition)
      ;; The report line is one line so that it can go in a log. The detail is
      ;; the part that says what to do, and for a provider that refuses the
      ;; request it is the provider's own words, including the URL for the key.
      (let ((detail (enchiridion.errors:error-detail condition)))
        (when (stringp detail)
          (format *error-output* "~A~%" detail)))
      (finish-output *error-output*)
      1)))

(defun join-arguments (arguments)
  "Return ARGUMENTS as one string, so that an unquoted question still reads
the way the operator typed it."
  (with-output-to-string (stream)
    (loop for argument in arguments
          for first = t then nil
          do (unless first (write-char #\Space stream))
             (write-string argument stream))))

(defun main (&rest argv)
  "Read ARGV, everything after the script name, and run the named command.
Return an exit status."
  (handler-case
      (let ((command (or (first argv) "")))
        (cond
          ((string= command "--verify-plugin")
           (let ((directory (second argv)))
             (unless directory
               (format *error-output* "--verify-plugin takes a directory.~%")
               (finish-output *error-output*)
               (return-from main 2))
             (verify-plugin-directory directory)))
          ((stringp command)
           (if (plusp (length command))
               (run-command command (rest argv))
               (if (first-launch-p)
                   (print-first-launch)
                   (progn
                     (format t "~&Agent directory is ready. Run `enchiridion chat`, or `enchiridion help`.~%")
                     (finish-output)
                     0))))
          (t 2)))
    (error (condition)
      (format *error-output* "~&~A~%" condition)
      ;; A command line tool that dies with no trace is a tool the operator
      ;; cannot report a bug about.
      (format *error-output* "~A~%" (enchiridion.compat:backtrace-string 12))
      (finish-output *error-output*)
      1)))

(defparameter *commands*
  ;; Built with LIST rather than quoted. Under a quote the reader turns #'X
  ;; into the list (FUNCTION X), so HANDLER would hold a cons and FUNCALL
  ;; would refuse it. The table is static either way; only the quoting lies.
  (list (list "init" 0 0 #'command-init "Create the agent directory and seed files")
        (list "ask" 1 nil #'command-ask "One turn, print the reply, exit")
        (list "version" 0 0 #'command-version "Version and build provenance")
        (list "help" 0 1 #'command-help "This list, or detail for one command"))
  "Every command: name, minimum and maximum argument count, handler, and the
one line that help prints beside it. NIL for the maximum means no upper
bound.")

(declaim (ftype (function (string list) integer) run-command))

(defun run-command (name arguments)
  "Call the command NAME with ARGUMENTS. Return an exit status."
  (let ((entry (assoc name *commands* :test #'string=)))
    (unless entry
      (format *error-output* "There is no command called ~A.~%" name)
      (finish-output *error-output*)
      (return-from run-command 2))
    (destructuring-bind (key minimum maximum handler summary) entry
      (declare (ignore key summary))
      (let ((count (length arguments)))
        ;; Two comparisons and not (<= MINIMUM COUNT MAXIMUM).
        ;;
        ;; MAXIMUM is NIL for a command that takes any number of arguments, and
        ;; <= on NIL is a type error about REAL. It arrives from inside MAIN,
        ;; because the compiler inlines RUN-COMMAND into it, so the trace names
        ;; neither the command nor the argument list and the backtrace stops at
        ;; MAIN itself. The only symptom the operator sees is a crash on a
        ;; command that is written down as working.
        (unless (and (<= minimum count)
                     (or (null maximum) (<= count maximum)))
          ;; The range is built as a string and not written with ~[:...~;...~].
          ;; A conditional reads one argument and its two branches then read
          ;; different numbers of the rest, so the second ~D of the short
          ;; branch is fed MAXIMUM, which is NIL, and the operator is told it
          ;; got NIL arguments.
          (format *error-output* "~A takes ~A arguments; got ~D.~%"
                  name (argument-range minimum maximum) count)
          (finish-output *error-output*)
          (return-from run-command 2))
        (funcall handler arguments)))))

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
          (ensure-agent-repository (agent-directory))
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