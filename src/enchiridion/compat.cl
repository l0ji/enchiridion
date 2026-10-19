;;;; compat.cl --- The only file with implementation extensions.
;;;;
;;;; Every implementation extension in this project lives here: sb-ext:run-program,
;;;; sb-ext:posix-getenv, and the reader conditionals that choose between
;;;; them. Nothing above this file is non standard, which is what lets the
;;;; agent rewrite its own tools without rewriting the porting layer along
;;;; with them.
;;;;
;;;; If you find yourself typing sb-ext: or #+sbcl anywhere else in the tree,
;;;; the answer belongs in this file instead.

(in-package #:enchiridion.compat)

;; The package is declared in packages.cl, and only there. A second defpackage
;; for a package that already exists re-uses the package but leaves two export
;; lists to drift, and the one in the second file silently wins.

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; SB-POSIX is a contributed package, not part of the core, so the package
  ;; does not exist until it is required. Every reference below is inside a
  ;; #+sbcl form, which means the reader accepts it either way but the
  ;; compiler needs the package to exist while it compiles the caller.
  #+sbcl (require :sb-posix))

;; A constant and not a variable. Nothing in this system rebinds the running
;; implementation, and a variable here has to be proclaimed SPECIAL for every
;; file that reads it; a proclaim that does not reach the file doing the
;; reading turns the name into an undefined function call at run time, two
;; files from the one that defined it. A constant is visible everywhere it is
;; read, with nothing to declare.
;;
;; The value is INTERNed rather than left as whatever LISP-IMPLEMENTATION-TYPE
;; returned, because that is not the same answer on every SBCL: it is the
;; string "SBCL" on 2.5.4 and a keyword on older ones. Comparing the raw value
;; against :sbcl silently answers nil on a perfectly good SBCL, and every
;; feature check that depends on it answers nil too. The call is written out
;; rather than hidden in a helper because DEF-CONSTANT evaluates it while the
;; file is still being compiled, and a function defined in the same file is not
;; defined yet at that point.
(defconstant +implementation+
  (intern (string-upcase (lisp-implementation-type)) :keyword)
  "Which implementation is running, as a keyword: :SBCL, :CCL, :CLISP, and so
on. Read at compile time so that the rest of the file can branch on a name
rather than on a reader conditional.")

(declaim (ftype (function (keyword) boolean) implementation-dependency-p))

(defun implementation-dependency-p (feature)
  "Return T when FEATURE, a keyword, names a feature the running SBCL has."
  (and (eq +implementation+ :sbcl)
       (not (null (member feature *features*)))))

;;;; Environment.
;;;;
;;;; The supervisor reads .env once, holds the values in memory, and unsets
;;;; them from its own environment. Everything else in the system reads
;;;; secrets through these two functions, so there is exactly one place where
;;;; a secret is read and exactly one place to audit.

#+sbcl
(defun environment-value (name)
  "Return the value of environment variable NAME, or NIL when it is unset."
  (sb-ext:posix-getenv name))

#-sbcl
(defun environment-value (name)
  "Return the value of environment variable NAME, or NIL when it is unset."
  (declare (ignore name))
  (error "No environment reader is available in ~A." +implementation+))

#+sbcl
(defun environment-bound-p (name)
  "Return T when environment variable NAME is set, even to the empty string."
  (not (null (sb-ext:posix-getenv name))))

#-sbcl
(defun environment-bound-p (name)
  "Return T when environment variable NAME is set, even to the empty string."
  (declare (ignore name))
  (error "No environment reader is available in ~A." +implementation+))

(declaim (ftype (function (string string) string) set-environment-variable))

#+sbcl
(defun set-environment-variable (name value)
  "Set environment variable NAME to VALUE and return VALUE.

The pair with UNSET-ENVIRONMENT-VARIABLE exists so that the unset can be
proved. An absent name is the ordinary case here, and a test that only checks
an absent name proves nothing about the writer."
  (sb-posix:setenv name value 1)
  value)

#-sbcl
(defun set-environment-variable (name value)
  "Set environment variable NAME to VALUE and return VALUE."
  (declare (ignore name value))
  (error "No environment writer is available in ~A." +implementation+))

(declaim (ftype (function (string) boolean) unset-environment-variable))

#+sbcl
(defun unset-environment-variable (name)
  "Remove environment variable NAME from this process and return T.

PLAN.md section 5.2: the supervisor reads its secrets once, holds the values
in memory, and then removes them from its own environment, so a child cannot
inherit a key and a later /proc read finds nothing. SB-POSIX:UNSETENV reports
no status and a name that was never set is not an error, so T is the honest
answer to the only question that is left: the name is gone from this process."
  (sb-posix:unsetenv name)
  t)

#-sbcl
(defun unset-environment-variable (name)
  "Remove environment variable NAME from this process and return T."
  (declare (ignore name))
  (error "No environment writer is available in ~A." +implementation+))

(declaim (ftype (function () list) environment))

#+sbcl
(defun environment ()
  "Return the environment as an alist of strings.

SB-EXT:POSIX-ENVIRON hands back a list of \"NAME=VALUE\" strings on SBCL 2.5.4,
and a list of pairs on older ones. Which of the two arrives is an SBCL
implementation detail, and the supervisor builds the broker's whole environment
from this list, so the shape is fixed here rather than left to be discovered
inside a container."
  (mapcar (lambda (entry)
            (let ((split (position #\= entry)))
              (if split
                  (cons (subseq entry 0 split) (subseq entry (1+ split)))
                  (cons entry ""))))
          (sb-ext:posix-environ)))

#-sbcl
(defun environment ()
  "Return the environment as an alist of strings."
  (error "No environment reader is available in ~A." +implementation+))

;;;; Processes.

(defun run-program (program arguments &key input (output :stream)
                                (error-output :stream) directory search wait
                                environment)
  "Start PROGRAM with ARGUMENTS and wait for it when WAIT. OUTPUT defaults to
:stream, which means the child inherits this process's streams and a shell
command writes where the operator is looking. Return the exit status.
SBCL spells the stderr keyword :error, not :error-output; this function keeps
the longer name and translates."
  #+sbcl
  (apply #'sb-ext:run-program program arguments
         :input input
         :output output
         :error error-output
         :directory directory
         :search search
         :wait wait
         (when environment (list :environment environment)))
  ;; One form, not a declare followed by an error. A reader conditional covers
  ;; exactly the next form, so #-sbcl on the DECLARE would leave the ERROR
  ;; unconditional and every SBCL call would run it after doing the work.
  #-sbcl
  (progn
    (declare (ignore program arguments input output error-output directory
                     search wait environment))
    (error "No process launcher is available in ~A." +implementation+)))

(defun run-program-blocking (program arguments &key input)
  "Run PROGRAM and return its standard output as a string. The exit status is
the second value: an integer, or NIL when the child was killed by a signal.

The output goes to a string stream, and not to the keyword :STRING. On SBCL
2.5.4 :STRING is a pathname, not a request to hand back a string, so asking
for it fails at run time with an invalid option error. A string stream says
what is meant and works on every SBCL.

finish-output comes before the read, not after: the stream is buffered, and a
half read buffer is a truncated program result.

PROCESS-EXIT-CODE, and not a second value from RUN-PROGRAM: with :WAIT T on
this SBCL, RUN-PROGRAM returns the process object and nothing else. Treating
the process object as the status hands the caller a #<PROCESS ...> where it
expects a number, and every exit code check after that is quietly wrong."
  #+sbcl
  (let ((stream (make-string-output-stream)))
    (let ((process (sb-ext:run-program program arguments
                                        :search t
                                        :input input
                                        :output stream
                                        :wait t)))
      (finish-output stream)
      (values (get-output-stream-string stream)
              (sb-ext:process-exit-code process))))
  #-sbcl
  (progn
    (declare (ignore program arguments input))
    (error "No process launcher is available in ~A." +implementation+)))

(declaim (ftype (function (string) vector) encode-utf8))

(defun encode-utf8 (text)
  "Return TEXT as UTF-8 octets. One implementation-specific encoder in the
tree, so the broker framing and anything else that writes bytes agree."
  #+sbcl (sb-ext:string-to-octets text :external-format :utf-8)
  #-sbcl (progn (declare (ignore text))
                (error "No UTF-8 encoder is available in ~A." +implementation+)))

(declaim (ftype (function (vector) string) decode-utf8))

(defun decode-utf8 (octets)
  "Return OCTETS decoded as UTF-8 text."
  #+sbcl (sb-ext:octets-to-string octets :external-format :utf-8)
  #-sbcl (progn (declare (ignore octets))
                (error "No UTF-8 decoder is available in ~A." +implementation+)))

(declaim (ftype (function () pathname) temp-directory))

(defun temp-directory ()
  "Return a directory the agent can write.

Inside the container /tmp is root owned and mode 755, so a tool that writes
there fails for uid 1000. ENCHIRIDION_HOME is the agent's writable state, and
the host keeps using /tmp."
  (if (uiop:getenv "ENCHIRIDION_HOME")
      (merge-pathnames "tmp/"
                       (uiop:ensure-directory-pathname
                        (uiop:getenv "ENCHIRIDION_HOME")))
      #p"/tmp/"))

(defparameter +signal-numbers+
  '((:sigterm . 15) (:sigkill . 9) (:sigint . 2) (:sighup . 1) (:sigtstp . 20))
  "The signals this tree sends, as numbers.

SBCL's PROCESS-KILL wants a signal number and a keyword is a type error, which
an IGNORE-ERRORS then hides: the process is never killed and nothing says so.
The mapping lives here because it is an implementation detail.")

(declaim (ftype (function (t t) t) process-kill))

(defun process-kill (process signal)
  "Send SIGNAL to PROCESS. SIGNAL is a keyword or a number.

On the pinned SBCL, (SB-EXT:PROCESS-KILL p :SIGTERM) signals a type error and
(SB-EXT:PROCESS-KILL p 15) works. Every caller writes the keyword, so the
translation has to be here rather than at five call sites."
  #+sbcl (sb-ext:process-kill
          process
          (if (integerp signal)
              signal
              (or (cdr (assoc signal +signal-numbers+)) 15)))
  #-sbcl (progn
           (declare (ignore process signal))
           (error "No process signal sender is available in ~A." +implementation+)))

(defun run-program-capture (program arguments &key (timeout nil) (environment nil))
  "Run PROGRAM with ARGUMENTS and return its combined output and exit status.

TIMEOUT is seconds, or NIL for no limit. On expiry the child gets SIGTERM,
then SIGKILL after a short grace period, and the second value is :TIMEOUT.
Standard error goes to the same string stream as standard output: a shell
command that fails usually explains why on stderr, and a caller that sees only
stdout sees an empty string and no reason.

ENVIRONMENT is a list of NAME=VALUE strings that replaces the child environment
when it is given, or NIL to inherit. The git tests use it to supply an author
and to switch signing off without writing any configuration file."
  #+sbcl
  (let* ((directory (temp-directory))
         (path (merge-pathnames
                (format nil "enchiridion-capture-~D.txt" (random most-positive-fixnum))
                directory))
         (process nil)
         (deadline (and timeout
                        (+ (get-internal-real-time)
                           (* timeout internal-time-units-per-second)))))
    (unwind-protect
         (progn
           (ensure-directories-exist path)
           (ignore-errors (delete-file path))
           ;; A file, not a pipe. With :WAIT NIL SBCL's string stream is not
           ;; flushed by the child's exit, and :PIPE is not an accepted
           ;; :OUTPUT value. A pathname is the one output sink that works for
           ;; a short lived child and keeps stderr on the same text.
           (setf process (apply #'sb-ext:run-program program arguments
                                             :search t
                                             :output path
                                             :error :output
                                             :if-output-exists :supersede
                                             :wait nil
                                             (when environment
                                               (list :environment environment))))
           (loop
             (let ((code (sb-ext:process-exit-code process)))
               (when code
                 (return (values (if (probe-file path)
                                     (uiop:read-file-string path)
                                     "")
                                 code))))
             (when (and deadline (> (get-internal-real-time) deadline))
               (ignore-errors (process-kill process :sigterm))
               (sleep 0.1)
               (ignore-errors (process-kill process :sigkill))
               (return (values (if (probe-file path)
                                   (uiop:read-file-string path)
                                   "")
                               :timeout)))
             (sleep 0.01)))
      (ignore-errors (delete-file path))))
  #-sbcl
  (progn
    (declare (ignore program arguments timeout environment))
    (error "No process launcher is available in ~A." +implementation+)))

;;;; Process identity.
;;;;
;;;; The broker runs as uid 1000 and the supervisor as uid 0. These two pairs
;;;; are how the supervisor drops privilege and how a test proves the drop
;;;; happened, and they are the only reason the secret isolation is a
;;;; property rather than an intention.

(declaim (ftype (function () (integer 0 *)) process-id))

(defun process-id ()
  "Return this process's id. The status file carries it so a reader can tell a
stale file left by a dead supervisor from a live one."
  #+sbcl (sb-posix:getpid)
  #-sbcl (error "No process id reader is available in ~A." +implementation+))

(defun process-uid ()
  "Return the effective user id of this process as an integer."
  #+sbcl (sb-posix:geteuid)
  #-sbcl (error "No uid reader is available in ~A." +implementation+))

(defun set-process-uid (uid)
  "Set the effective user id of this process to UID. There is no way back, and
that is deliberate: the broker never becomes the supervisor."
  #+sbcl (progn (sb-posix:seteuid uid) uid)
  #-sbcl (progn (declare (ignore uid))
                (error "No uid writer is available in ~A." +implementation+)))

(defun process-user ()
  "Return the name of the user this process runs as, or NIL when it cannot be
read.

SB-POSIX has no username call at all, so this shells out to id. That is one
subprocess for a question asked rarely, at startup and in isolation tests,
and it is better than a uid the operator cannot read.

id is named without a path so that PATH decides, not this file: /usr/bin/id is
a Debian and Alpine convention, and a Nix build sandbox has the program on PATH
and not at that address. NIL rather than an error, because a caller that wants
the name can carry on without it and a caller that cannot have to be told."
  (let ((text (run-program-blocking "id" '("-un"))))
    (when (plusp (length text))
      (string-trim '(#\Space #\Tab #\Newline) text))))

(defun set-process-user (name)
  "Set the user of this process to NAME, which must already exist. Resolves the
name to a uid first, because SB-POSIX setuid takes a number."
  (let ((resolved (string-trim '(#\Space #\Tab #\Newline)
             (or (run-program-blocking "id" (list "-u" name)) ""))))
    (when (zerop (length resolved))
      (error "No such user: ~A." name))
    (set-process-uid (parse-integer resolved))))

;;;; File modes.
;;;;
;;;; The supervisor creates the memory store as root and the broker searches it
;;;; as uid 1000. SQLite cannot lock a file its user cannot write, so whoever
;;;; creates the file has to set the mode. chmod is an extension and lives
;;;; here for the same reason geteuid does.

(declaim (ftype (function (t (or null integer)) (or null integer)) set-file-mode))

#+sbcl
(defun set-file-mode (path mode)
  "Set the permission bits of PATH to MODE, an integer such as #o666, and
return MODE. NIL means leave the mode alone, which is the host case, and the
return is MODE rather than the call's own value so that a caller can chain."
  (when mode
    (sb-posix:chmod (pathname path) mode)
    mode))

#-sbcl
(defun set-file-mode (path mode)
  "Set the permission bits of PATH. There is no portable spelling, so this
implementation leaves the file with whatever the umask gave it."
  (declare (ignore path mode))
  nil)

(declaim (ftype (function (t) (or null (integer 0 #o777))) file-mode))

#+sbcl
(defun file-mode (path)
  "Return the nine permission bits of PATH as an integer, or NIL when PATH does
not exist.

SB-POSIX STAT signals for a file that is not there instead of answering, and
every caller here asks a question with two answers: may this file be read, and
is it still there. Catching the condition here keeps the answer NIL and saves
each caller from writing the same handler. The mask drops the file type bits,
which sit above the permission bits, because a caller compares the result
against #o600 or #o004 and a type bit would make every comparison lie."
  (let ((info (ignore-errors (sb-posix:stat path))))
    (when info
      (logand (sb-posix:stat-mode info) #o777))))

#-sbcl
(defun file-mode (path)
  "Return the permission bits of PATH, which is always NIL here: there is no
portable spelling of stat. The secret file check reads NIL as a mode it cannot
refuse on, which is the same answer it gives for a file that is absent, so no
implementation other than SBCL loses a check it was able to make."
  (declare (ignore path))
  nil)

;;;; Backtraces.
;;;;
;;;; A long running server without a trace on crash is a server the operator
;;;; cannot report a bug about. The trace is implementation specific, so it is
;;;; read here and returned as a string; the caller prints it and knows nothing
;;;; about SB-DEBUG.

(declaim (ftype (function (&optional integer) string) backtrace-string))

#+sbcl
(defun backtrace-string (&optional (count 12))
  "Return up to COUNT frames of the current call stack as text."
  (with-output-to-string (stream)
    (sb-debug:backtrace count stream)))

#-sbcl
(defun backtrace-string (&optional (count 12))
  "Return a note that this implementation has no backtrace reader."
  (declare (ignore count))
  (format nil "No backtrace is available in ~A." +implementation+))

;;;; Interrupts.
;;;;
;;;; Ctrl-C is SIGINT, and SBCL turns it into SB-SYS:INTERACTIVE-INTERRUPT in
;;;; the main thread even when other threads are running. A --script process
;;;; runs with the debugger disabled, so an interrupt nobody handles prints a
;;;; forty frame backtrace and exits 1: the REPL dies at the prompt and serve
;;;; dies in the middle of its poll. The condition's name is the one
;;;; implementation extension in that story, so it stays here and every file
;;;; above answers an interrupt through this macro.

(defmacro with-interrupt-handler ((handler) &body body)
  "Run BODY; when an interactive interrupt arrives, call HANDLER with it.

HANDLER has to leave the interrupted code by a non-local exit, usually a THROW
to a CATCH outside this form. A handler that returns lets the interrupt keep
unwinding, and nothing above this frame answers it, so the process still dies
with a backtrace."
  #+sbcl `(handler-bind ((sb-sys:interactive-interrupt
                           (lambda (condition)
                             (funcall ,handler condition))))
            ,@body)
  ;; The handler is evaluated only to keep a non SBCL call from looking like it
  ;; silently drops the form; there is no interrupt condition to bind.
  #-sbcl `(let ((ignored ,handler))
            (declare (ignore ignored))
            ,@body))

(declaim (ftype (function () t) signal-interactive-interrupt))

#+sbcl
(defun signal-interactive-interrupt ()
  "Signal the condition a Ctrl-C produces.

SIGNAL and not ERROR: a caller that has installed the handler through
WITH-INTERRUPT-HANDLER sees it, and a test that runs without one does not kill
the suite."
  (signal 'sb-sys:interactive-interrupt))

#-sbcl
(defun signal-interactive-interrupt ()
  "Signal an ordinary error: this implementation has no interrupt condition."
  (error "No interactive interrupt is available in ~A." +implementation+))

#+sbcl
(define-condition shutdown-interrupt (sb-sys:interactive-interrupt) ()
  (:documentation
   "A SIGTERM or SIGHUP raised as an interrupt, so one handler answers both.

The process has to tell a Ctrl-C, which belongs to the line or the turn in
front of the operator, from a request to stop. This subtype is how the REPL
declines the second and lets the top level answer it."))

(declaim (ftype (function (t) boolean) shutdown-interrupt-p))

#+sbcl
(defun shutdown-interrupt-p (condition)
  "Return T when CONDITION is a SIGTERM or SIGHUP and not a Ctrl-C."
  (typep condition 'shutdown-interrupt))

#-sbcl
(defun shutdown-interrupt-p (condition)
  "Return NIL: this implementation has no shutdown interrupt."
  (declare (ignore condition))
  nil)

(declaim (ftype (function () t) signal-shutdown-interrupt))

#+sbcl
(defun signal-shutdown-interrupt ()
  "Signal the shutdown condition a SIGTERM raises, for a test.

SIGNAL and not ERROR, for the reason SIGNAL-INTERACTIVE-INTERRUPT gives."
  (signal 'shutdown-interrupt))

#-sbcl
(defun signal-shutdown-interrupt ()
  "Signal an ordinary error: this implementation has no shutdown interrupt."
  (error "No shutdown interrupt is available in ~A." +implementation+))

(declaim (ftype (function () boolean) install-shutdown-signals))

#+sbcl
(defun install-shutdown-signals ()
  "Make SIGTERM and SIGHUP raise a shutdown interrupt in the main thread.

`docker stop` and a closed terminal end the process with SIGTERM and SIGHUP,
not SIGINT, and the default action kills it where it stands. Raising the
condition in the main thread instead is what lets the handler installed by
WITH-INTERRUPT-HANDLER answer them the way it answers Ctrl-C: every
UNWIND-PROTECT runs, the channels stop, and the process leaves with 130.

The main thread is the one that installed the handler, so it is the one to
interrupt. Return T when the handlers are installed."
  (let ((main sb-thread:*current-thread*))
    (flet ((raise-shutdown (signal info context)
             (declare (ignore signal info context))
             (sb-thread:interrupt-thread
              main
              (lambda () (error 'shutdown-interrupt)))))
      (sb-sys:enable-interrupt sb-unix:sigterm #'raise-shutdown)
      (sb-sys:enable-interrupt sb-unix:sighup #'raise-shutdown))
    t))

#-sbcl
(defun install-shutdown-signals ()
  "Return NIL: this implementation has no signal interface to install."
  nil)

;;;; The command line.
;;;;
;;;; sb-ext:*posix-argv* is the one piece of the script interface that no
;;;; other file is allowed to touch, because it does not mean the same thing
;;;; on every implementation. Here it means one thing.

(defun script-arguments ()
  "Return the arguments given on the command line.

Under --script, SBCL replaces *posix-argv* with the executable followed by
the arguments after the script name. The script name is gone, so the
executable is the only thing to drop, and dropping one more loses the first
real argument."
  #+sbcl (rest sb-ext:*posix-argv*)
  #-sbcl (error "No command line reader is available in ~A." +implementation+))

(defun exit-with (status)
  "Leave the process with STATUS as its exit code. A script that returns a
value does not set one, so a command that failed would otherwise report
success to whatever ran it."
  #+sbcl (sb-ext:exit :code status)
  #-sbcl (progn (declare (ignore status))
                (error "No exit is available in ~A." +implementation+)))