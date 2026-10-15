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
                                (error-output :stream) directory search wait)
  "Start PROGRAM with ARGUMENTS and wait for it when WAIT. OUTPUT defaults to
:stream, which means the child inherits this process's streams and a shell
command writes where the operator is looking. Return the exit status.
SBCL spells the stderr keyword :error, not :error-output; this function keeps
the longer name and translates."
  #+sbcl
  (sb-ext:run-program program arguments
                      :input input
                      :output output
                      :error error-output
                      :directory directory
                      :search search
                      :wait wait)
  ;; One form, not a declare followed by an error. A reader conditional covers
  ;; exactly the next form, so #-sbcl on the DECLARE would leave the ERROR
  ;; unconditional and every SBCL call would run it after doing the work.
  #-sbcl
  (progn
    (declare (ignore program arguments input output error-output directory
                     search wait))
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

;;;; Process identity.
;;;;
;;;; The broker runs as uid 1000 and the supervisor as uid 0. These two pairs
;;;; are how the supervisor drops privilege and how a test proves the drop
;;;; happened, and they are the only reason the secret isolation is a
;;;; property rather than an intention.

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