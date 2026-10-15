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
   #:getenv
   #:pathname-directory-pathname)
  (:export
   #:main #:project-root #:resolve-project-root #:agent-directory
   #:environment-value #:load-config #:first-launch-p #:run-command
   #:*commands*)
  (:documentation
   "Process entry: roots, configuration, argument handling, and first launch."))

(in-package #:enchiridion.main)

(require :enchiridion)

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
source is read only and the agent directory has to be on the volume."
  (format nil "~A/agents/default/" (or (environment-value "ENCHIRIDION_HOME")
                                       (resolve-project-root))))

;;;; Configuration.
;;;;
;;;; An absent config.cl is not an error. It means defaults, which is how a
;;;; first time user writes nothing at all. Env vars override the file. The
;;;; file never holds a secret, because a file in the repository is a file
;;;; that ends up in a store path.

(defun load-config ()
  "Load config.cl when it is there and return the configuration plist, or NIL
for the defaults."
  (let ((path (merge-pathnames "config.cl" (resolve-project-root))))
    (when (probe-file path)
      ;; Deliberate. config.cl is operator written Lisp that lives outside
      ;; version control, and loading it is the only way to honour it.
      (load path :verbose nil :print nil))
    (when (boundp 'enchiridion.user::*enchiridion-config*)
      (symbol-value 'enchiridion.user::*enchiridion-config*))))

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
    0))

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
          (format t "~A~%    ~A~%    arguments ~D to ~D~%"
                  name summary minimum maximum)))
      (progn
        (format t "~&Commands:~%")
        (dolist (entry *commands*)
          (destructuring-bind (name minimum maximum handler summary) entry
            (declare (ignore handler))
            (format t "  ~A~%    ~A~%    arguments ~D to ~D~%"
                    name summary minimum maximum)))))
  (finish-output)
  0)

(defparameter *commands*
  ;; Built with LIST rather than quoted. Under a quote the reader turns #'X
  ;; into the list (FUNCTION X), so HANDLER would hold a cons and FUNCALL
  ;; would refuse it. The table is static either way; only the quoting lies.
  (list (list "init" 0 0 #'command-init "Create the agent directory and seed files")
        (list "version" 0 0 #'command-version "Version and build provenance")
        (list "help" 0 1 #'command-help "This list, or detail for one command"))
  "Every command: name, minimum and maximum argument count, handler, and the
one line that help prints beside it.")

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
      (unless (<= minimum (length arguments) maximum)
        (format *error-output* "~A takes between ~D and ~D arguments.~%"
                name minimum maximum)
        (finish-output *error-output*)
        (return-from run-command 2))
      (funcall handler arguments))))

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
    (when (enchiridion.memory:init-problems result)
      (format t "~&Could not write:~%")
      (dolist (problem (enchiridion.memory:init-problems result))
        (format t "  ~A: ~A~%" (car problem) (cdr problem))))
    (format t "~&Bootstrap has not started. Edit SOUL.md, OPERATOR.md, and WORLD.md first,~%")
    (format t "then run `enchiridion chat`. See agents/default/GUIDE.md for the walkthrough.~%")
    (finish-output)
    0))

;;;; Entry.

(declaim (ftype (function (&rest t) integer) main))

(defun main (&rest argv)
  "Read ARGV, everything after the script name, and run the named command.
Return an exit status."
  (handler-case
      (let ((command (or (first argv) "")))
        (when (and (stringp command) (plusp (length command)))
          (return-from main (run-command command (rest argv))))
        (if (first-launch-p)
            (print-first-launch)
            (progn
              (format t "~&Agent directory is ready. Run `enchiridion chat`, or `enchiridion help`.~%")
              (finish-output)
              0)))
    (error (condition)
      (format *error-output* "~&~A~%" condition)
      ;; A command line tool that dies with no trace is a tool the operator
      ;; cannot report a bug about.
      (format *error-output* "~A~%"
              (with-output-to-string (s)
                (finish-output s)
                (sb-debug:backtrace 12 s)))
      (finish-output *error-output*)
      1)))

(load-config)
;; apply, not a plain call: MAIN is &rest over the arguments, so passing the
;; list as one argument would nest it and every command would look absent.
(enchiridion.compat:exit-with
 (apply #'main (enchiridion.compat:script-arguments)))