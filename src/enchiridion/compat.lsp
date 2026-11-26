;;;; compat.lsp --- Implementation-specific extensions (SBCL / POSIX).
;;;;
;;;; All sb-ext:, sb-posix:, sb-sys:, sb-thread:, and #+sbcl conditionals live here.

(in-package #:enchiridion.compat)

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; Require sb-posix at compile time so the compiler sees the package.
  #+sbcl (require :sb-posix))

;; Interned inline at compile time: LISP-IMPLEMENTATION-TYPE returns a string on newer SBCLs.
(defconstant +implementation+
  (intern (string-upcase (lisp-implementation-type)) :keyword)
  "Running Lisp implementation as a keyword (e.g. :SBCL).")

(declaim (ftype (function (keyword) boolean) implementation-dependency-p))

(defun implementation-dependency-p (feature)
  "Return T when FEATURE, a keyword, names a feature the running SBCL has."
  (and (eq +implementation+ :sbcl)
       (not (null (member feature *features*)))))

;;;; Environment.

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
  "Set environment variable NAME to VALUE and return VALUE."
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
  "Remove environment variable NAME from this process and return T."
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
  "Return the process environment as an alist of (NAME . VALUE) strings.
Normalizes SB-EXT:POSIX-ENVIRON \"NAME=VALUE\" entries."
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
                                environment (if-output-exists :error))
  "Start PROGRAM with ARGUMENTS and return the process object (or wait if WAIT).
Translates :ERROR-OUTPUT to SBCL's :ERROR keyword; IF-OUTPUT-EXISTS applies to pathname OUTPUT."
  #+sbcl
  (apply #'sb-ext:run-program program arguments
         :input input
         :output output
         :error error-output
         :if-output-exists if-output-exists
         :directory directory
         :search search
         :wait wait
         (when environment (list :environment environment)))
  ;; Wrap in PROGN so #-sbcl covers both DECLARE and ERROR.
  #-sbcl
  (progn
    (declare (ignore program arguments input output error-output directory
                     search wait environment if-output-exists))
    (error "No process launcher is available in ~A." +implementation+)))

(defun run-program-blocking (program arguments &key input)
  "Run PROGRAM synchronously and return (values stdout exit-code).
Uses a string stream (SBCL rejects :OUTPUT :STRING), flushes before reading, and reads SB-EXT:PROCESS-EXIT-CODE."
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
  "Return TEXT encoded as UTF-8 octets."
  #+sbcl (sb-ext:string-to-octets text :external-format :utf-8)
  #-sbcl (progn (declare (ignore text))
                (error "No UTF-8 encoder is available in ~A." +implementation+)))

(declaim (ftype (function (vector) string) decode-utf8))

(defun decode-utf8 (octets)
  "Return OCTETS decoded as UTF-8 text."
  #+sbcl (sb-ext:octets-to-string octets :external-format :utf-8)
  #-sbcl (progn (declare (ignore octets))
                (error "No UTF-8 decoder is available in ~A." +implementation+)))

(declaim (ftype (function (vector) string) decode-utf8-lenient))

(defun decode-utf8-lenient (octets)
  "Return OCTETS decoded as UTF-8, replacing malformed sequences with '?'."
  #+sbcl (sb-ext:octets-to-string octets :external-format '(:utf-8 :replacement #\?))
  #-sbcl (progn (declare (ignore octets))
                (error "No UTF-8 decoder is available in ~A." +implementation+)))

(declaim (ftype (function () pathname) temp-directory))

(defun temp-directory ()
  "Return a writable temp directory: ENCHIRIDION_HOME/tmp/ if ENCHIRIDION_HOME exists, else /tmp/.
Does not create ENCHIRIDION_HOME if absent."
  (let ((state (uiop:getenv "ENCHIRIDION_HOME")))
    (if (and state (plusp (length state)) (probe-file state))
        (merge-pathnames "tmp/" (uiop:ensure-directory-pathname state))
        #p"/tmp/")))

(defparameter +signal-numbers+
  '((:sigterm . 15) (:sigkill . 9) (:sigint . 2) (:sighup . 1) (:sigtstp . 20))
  "Keyword-to-number signal map (SBCL's PROCESS-KILL requires integer signals).")

(declaim (ftype (function (t t &optional t) t) process-kill))

(defun process-kill (process signal &optional (whom :pid))
  "Send SIGNAL (keyword or integer) to PROCESS; WHOM is :PID or :PROCESS-GROUP."
  #+sbcl (sb-ext:process-kill
          process
          (if (integerp signal)
              signal
              (or (cdr (assoc signal +signal-numbers+)) 15))
          whom)
  #-sbcl (progn
           (declare (ignore process signal whom))
           (error "No process signal sender is available in ~A." +implementation+)))

(declaim (ftype (function (t) t) process-reap))

(defun process-reap (process)
  "Wait (bounded ~2s) for PROCESS to exit and close its SBCL process handle."
  #+sbcl
  (progn
    (loop repeat 200
          until (sb-ext:process-exit-code process)
          do (sleep 0.01))
    (when (sb-ext:process-exit-code process)
      (ignore-errors (sb-ext:process-close process)))
    process)
  #-sbcl
  (progn
    (declare (ignore process))
    (error "No process reaper is available in ~A." +implementation+)))

(declaim (ftype (function (t) integer) process-pid))

(defun process-pid (process)
  "Return PROCESS's pid. PROCESS is a process object or a pid."
  #+sbcl (if (integerp process) process (sb-ext:process-pid process))
  #-sbcl (progn
           (declare (ignore process))
           (error "No process id is available in ~A." +implementation+)))

(declaim (ftype (function (integer t) boolean) signal-process))

(defun signal-process (pid signal)
  "Send SIGNAL (keyword or integer) to PID (negative for process group); return T on success."
  #+sbcl
  (let ((number (if (integerp signal)
                    signal
                    (or (cdr (assoc signal +signal-numbers+)) 15))))
    (handler-case (progn (sb-posix:kill pid number) t)
      (error () nil)))
  #-sbcl
  (progn
    (declare (ignore pid signal))
    (error "No process signal sender is available in ~A." +implementation+)))

(declaim (ftype (function (integer) boolean) process-alive-p))

(defun process-alive-p (pid)
  "Return T when PID can be signalled (zombies return T until reaped)."
  (signal-process pid 0))

(declaim (ftype (function (string) (or null integer)) proc-stat-parent))

(defun proc-stat-parent (text)
  "Return the parent PID from /proc/PID/stat TEXT, or NIL.
Parses from the last ')' so spaces/parens in comm cannot shift fields."
  (let ((close (position #\) text :from-end t)))
    (when close
      (let* ((fields (remove-if (lambda (part) (zerop (length part)))
                                (uiop:split-string (subseq text (1+ close))
                                                   :separator '(#\Space #\Newline))))
             (parent (second fields)))
        (and parent (parse-integer parent :junk-allowed t))))))

(declaim (ftype (function () list) process-table-from-proc))

(defun process-table-from-proc ()
  "Return /proc as (PID . PPID) pairs, or NIL."
  (let ((entries '()))
    (dolist (directory (uiop:subdirectories #p"/proc/") entries)
      (let ((name (car (last (pathname-directory directory)))))
        (when (and name (every #'digit-char-p name))
          (let ((parent (ignore-errors
                          (proc-stat-parent
                           (uiop:read-file-string (merge-pathnames "stat" directory))))))
            (when parent (push (cons (parse-integer name) parent) entries))))))))

(defparameter +ps-programs+ '("ps" "/bin/ps" "/usr/bin/ps")
  "Candidate ps paths (bare name for PATH, absolute paths for minimal sandboxes).")

(declaim (ftype (function (string) list) process-table-from-program))

(defun process-table-from-program (program)
  "Return (PID . PPID) pairs from `ps -axo pid=,ppid=`, or NIL."
  (handler-case
      (multiple-value-bind (output status)
          (run-program-blocking program '("-axo" "pid=,ppid="))
        (when (eql 0 status)
          (loop for line in (uiop:split-string output :separator '(#\Newline))
                for fields = (remove-if (lambda (part) (zerop (length part)))
                                        (uiop:split-string line
                                                           :separator '(#\Space #\Tab)))
                for pid = (and fields (parse-integer (first fields) :junk-allowed t))
                for parent = (and pid (second fields)
                                  (parse-integer (second fields) :junk-allowed t))
                when (and pid parent) collect (cons pid parent))))
    (error () nil)))

(declaim (ftype (function () list) process-table-from-ps))

(defun process-table-from-ps ()
  "Return (PID . PPID) pairs by trying +PS-PROGRAMS+ in order, or NIL."
  (loop for program in +ps-programs+
        for table = (process-table-from-program program)
        when table return table))

(declaim (ftype (function () list) process-table))

(defun process-table ()
  "Return all processes as (PID . PPID) pairs (/proc first, then ps), or NIL."
  (or (and (probe-file #p"/proc/self/stat") (process-table-from-proc))
      (process-table-from-ps)))

(declaim (ftype (function (t) list) process-descendants))

(defun process-descendants (process)
  "Return descendant PIDs of PROCESS (deepest first) via parent links, or NIL.
Follows PPIDs rather than process groups so nested sub-process groups are included."
  (let ((root (process-pid process))
        (children (make-hash-table :test #'eql)))
    (dolist (entry (process-table))
      (push (car entry) (gethash (cdr entry) children)))
    (let ((found '())
          (stack (list root))
          (mine (process-id)))
      (loop while stack
            do (let ((pid (pop stack)))
                 (dolist (child (gethash pid children))
                   (push child found)
                   (push child stack))))
      ;; Reverse preorder puts leaves before parents for bottom-up signalling.
      (remove-if (lambda (pid) (or (= pid mine) (= pid root) (<= pid 1))) found))))

(defmacro with-deadline ((seconds &key on-timeout) &body body)
  "Run BODY with a SECONDS timeout, returning ON-TIMEOUT if exceeded (NIL disables).
SBCL's timeout is a SERIOUS-CONDITION (not ERROR), so UNWIND-PROTECT runs and error handlers don't catch it."
  (let ((limit (gensym "LIMIT")))
    #+sbcl
    `(let ((,limit ,seconds))
       (if ,limit
           (handler-case (sb-ext:with-timeout ,limit ,@body)
             (sb-ext:timeout () ,on-timeout))
           (progn ,@body)))
    #-sbcl
    `(let ((,limit ,seconds))
       (declare (ignore ,limit))
       ,@body)))

(declaim (ftype (function () string) lisp-runtime-path))

(defun lisp-runtime-path ()
  "Return the native path of the running Lisp executable."
  #+sbcl (uiop:native-namestring sb-ext:*runtime-pathname*)
  #-sbcl (error "No runtime path is available in ~A." +implementation+))

(declaim (ftype (function (t) t) process-exit-code))

(defun process-exit-code (process)
  "Return PROCESS's exit status, or NIL while it is still running."
  #+sbcl (sb-ext:process-exit-code process)
  #-sbcl (progn
           (declare (ignore process))
           (error "No process status reader is available in ~A." +implementation+)))

(defun run-program-capture (program arguments &key (timeout nil) (environment nil))
  "Run PROGRAM with ARGUMENTS and return (values combined-output exit-status-or-:TIMEOUT).
Merges stderr into stdout; TIMEOUT (seconds or NIL) sends SIGTERM then SIGKILL to the process group.
ENVIRONMENT is a list of \"NAME=VALUE\" strings, or NIL to inherit."
  #+sbcl
  (let* ((directory (temp-directory))
         (stream nil)
         (process nil)
         (deadline (and timeout
                        (+ (get-internal-real-time)
                           (* timeout internal-time-units-per-second)))))
    (unwind-protect
         (progn
           (ensure-directories-exist directory)
           ;; Use an immediately-unlinked mkstemp file (not a pipe/string-stream): :WAIT NIL
           ;; doesn't flush string streams on exit, and unlinking prevents symlink/TOCTOU races.
           (multiple-value-bind (fd name)
               (sb-posix:mkstemp
                (uiop:native-namestring
                 (merge-pathnames "enchiridion-capture-XXXXXX" directory)))
             (ignore-errors (sb-posix:unlink name))
             (setf stream (sb-sys:make-fd-stream
                           fd :input t :output t
                              :external-format '(:utf-8 :replacement #\?)
                              :buffering :full
                              :auto-close t)))
           (setf process (apply #'sb-ext:run-program program arguments
                                             :search t
                                             :output stream
                                             :error :output
                                             :wait nil
                                             (when environment
                                               (list :environment environment))))
           ;; Read to EOF because SBCL refuses FILE-LENGTH on an unlinked fd stream.
           (flet ((captured ()
                    (file-position stream 0)
                    (with-output-to-string (text)
                      (let ((buffer (make-string 4096)))
                        (loop for count = (read-sequence buffer stream)
                              while (plusp count)
                              do (write-string buffer text :end count))))))
             (loop
               (let ((code (sb-ext:process-exit-code process)))
                 (when code
                   (return (values (captured) code))))
               (when (and deadline (> (get-internal-real-time) deadline))
                 ;; Signal the process group so /bin/sh -c children don't outlive the shell.
                 (ignore-errors (process-kill process :sigterm :process-group))
                 (sleep 0.1)
                 (ignore-errors (process-kill process :sigkill :process-group))
                 (process-reap process)
                 (return (values (captured) :timeout)))
               (sleep 0.01))))
      (when process
        ;; Kill and reap the process group on non-local exit.
        (unless (sb-ext:process-exit-code process)
          (ignore-errors (process-kill process :sigterm :process-group))
          (loop repeat 20
                until (sb-ext:process-exit-code process)
                do (sleep 0.01))
          (unless (sb-ext:process-exit-code process)
            (ignore-errors (process-kill process :sigkill :process-group))))
        (ignore-errors (process-reap process)))
      (when stream
        (ignore-errors (close stream)))))
  #-sbcl
  (progn
    (declare (ignore program arguments timeout environment))
    (error "No process launcher is available in ~A." +implementation+)))

;;;; Process identity.

(declaim (ftype (function () (integer 0 *)) process-id))

(defun process-id ()
  "Return this process's PID."
  #+sbcl (sb-posix:getpid)
  #-sbcl (error "No process id reader is available in ~A." +implementation+))

(defun process-uid ()
  "Return the effective user id of this process as an integer."
  #+sbcl (sb-posix:geteuid)
  #-sbcl (error "No uid reader is available in ~A." +implementation+))

(defun set-process-uid (uid)
  "Irreversibly set real, effective, and saved UID to UID (uses setuid, not seteuid)."
  #+sbcl (progn (sb-posix:setuid uid) uid)
  #-sbcl (progn (declare (ignore uid))
                (error "No uid writer is available in ~A." +implementation+)))

(declaim (ftype (function () (integer 0 *)) process-gid))

#+sbcl
(defun process-gid ()
  "Return the effective group id of this process as an integer."
  (sb-posix:getegid))

#-sbcl
(defun process-gid ()
  "Return the effective group id, which is unavailable in ~A."
  (error "No gid reader is available in ~A." +implementation+))

(declaim (ftype (function (integer) integer) set-process-gid))

#+sbcl
(defun set-process-gid (gid)
  "Set the real, effective, and saved group id of this process to GID."
  (sb-posix:setgid gid)
  gid)

#-sbcl
(defun set-process-gid (gid)
  "Set the process group id, which is unavailable in ~A."
  (declare (ignore gid))
  (error "No gid writer is available in ~A." +implementation+))

#+sbcl
(sb-alien:define-alien-routine ("setgroups" %setgroups) sb-alien:int
  (size sb-alien:unsigned-int)
  (list sb-alien:system-area-pointer))

(declaim (ftype (function () t) clear-supplementary-groups))

#+sbcl
(defun clear-supplementary-groups ()
  "Clear all supplementary groups before dropping UID; signals on failure."
  (when (minusp (%setgroups 0 (sb-sys:int-sap 0)))
    (error "Could not clear the supplementary groups."))
  t)

#-sbcl
(defun clear-supplementary-groups ()
  "Clear supplementary groups, which is unavailable in ~A."
  (error "No group writer is available in ~A." +implementation+))

(defun process-user ()
  "Return the current username via `id -un` (SB-POSIX has no getpwuid), or NIL."
  (let ((text (run-program-blocking "id" '("-un"))))
    (when (plusp (length text))
      (string-trim '(#\Space #\Tab #\Newline) text))))

(defun set-process-user (name)
  "Resolve NAME via `id -u` and drop to that UID; signals if user does not exist."
  (let ((resolved (string-trim '(#\Space #\Tab #\Newline)
             (or (run-program-blocking "id" (list "-u" name)) ""))))
    (when (zerop (length resolved))
      (error "No such user: ~A." name))
    (set-process-uid (parse-integer resolved))))

;;;; File modes.

(declaim (ftype (function (t (or null integer)) (or null integer)) set-file-mode))

#+sbcl
(defun set-file-mode (path mode)
  "Set permission bits of PATH to MODE (e.g. #o666) and return MODE, or NIL to leave unchanged."
  (when mode
    (sb-posix:chmod (pathname path) mode)
    mode))

#-sbcl
(defun set-file-mode (path mode)
  "No-op on non-SBCL implementations; returns NIL."
  (declare (ignore path mode))
  nil)

(declaim (ftype (function (t) (or null (integer 0 #o777))) file-mode))

#+sbcl
(defun file-mode (path)
  "Return the permission bits (#o777 mask) of PATH as an integer, or NIL if absent."
  (let ((info (ignore-errors (sb-posix:stat path))))
    (when info
      (logand (sb-posix:stat-mode info) #o777))))

#-sbcl
(defun file-mode (path)
  "Return NIL (no portable stat)."
  (declare (ignore path))
  nil)

(declaim (ftype (function (t) (or null string)) symlink-target))

#+sbcl
(defun symlink-target (path)
  "Return the symlink target of PATH via lstat/readlink, or NIL if not a symlink."
  (let ((info (ignore-errors (sb-posix:lstat (pathname path)))))
    (when (and info
               (eql (logand (sb-posix:stat-mode info) #o170000) #o120000))
      (sb-posix:readlink (pathname path)))))

#-sbcl
(defun symlink-target (path)
  "Return the link target of PATH, which is unavailable in ~A."
  (declare (ignore path))
  nil)

;;;; Backtraces.

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

(defmacro with-interrupt-handler ((handler) &body body)
  "Run BODY, invoking HANDLER on interactive interrupts (SIGINT/SIGTERM/SIGHUP).
HANDLER must perform a non-local exit (e.g. THROW) to prevent unwinding."
  #+sbcl `(handler-bind ((sb-sys:interactive-interrupt
                           (lambda (condition)
                             (funcall ,handler condition))))
            ,@body)
  ;; Evaluate HANDLER for parity even though no interrupt condition exists.
  #-sbcl `(let ((ignored ,handler))
            (declare (ignore ignored))
            ,@body))

(declaim (ftype (function () t) signal-interactive-interrupt))

#+sbcl
(defun signal-interactive-interrupt ()
  "Signal SB-SYS:INTERACTIVE-INTERRUPT (uses SIGNAL so unhandled tests don't abort)."
  (signal 'sb-sys:interactive-interrupt))

#-sbcl
(defun signal-interactive-interrupt ()
  "Signal an ordinary error: this implementation has no interrupt condition."
  (error "No interactive interrupt is available in ~A." +implementation+))

#+sbcl
(define-condition shutdown-interrupt (sb-sys:interactive-interrupt) ()
  (:documentation
   "Subtype of INTERACTIVE-INTERRUPT for SIGTERM/SIGHUP so callers can distinguish them from Ctrl-C."))

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
  "Signal SHUTDOWN-INTERRUPT for tests (uses SIGNAL, not ERROR)."
  (signal 'shutdown-interrupt))

#-sbcl
(defun signal-shutdown-interrupt ()
  "Signal an ordinary error: this implementation has no shutdown interrupt."
  (error "No shutdown interrupt is available in ~A." +implementation+))

(declaim (ftype (function () boolean) install-shutdown-signals))

#+sbcl
(defun install-shutdown-signals ()
  "Route SIGTERM and SIGHUP to raise SHUTDOWN-INTERRUPT in the main thread; return T."
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

;;;; Command line.

(defun script-arguments ()
  "Return command-line arguments (under --script, SBCL drops the script name from *POSIX-ARGV*)."
  #+sbcl (rest sb-ext:*posix-argv*)
  #-sbcl (error "No command line reader is available in ~A." +implementation+))

(defun exit-with (status)
  "Exit the process with integer STATUS."
  #+sbcl (sb-ext:exit :code status)
  #-sbcl (progn (declare (ignore status))
                (error "No exit is available in ~A." +implementation+)))

;;;; IEEE 754 float32 bit conversion.

(defun single-float-bits (float)
  "Return FLOAT's IEEE 754 single bits as an unsigned 32-bit integer."
  #+sbcl (ldb (byte 32 0) (sb-kernel:single-float-bits (coerce float 'single-float)))
  #-sbcl (error "single-float-bits is not implemented for ~A." +implementation+))

(defun bits-single-float (bits)
  "Return the single float whose IEEE 754 bits are the 32-bit integer BITS."
  #+sbcl (sb-kernel:make-single-float (if (logbitp 31 bits) (- bits (ash 1 32)) bits))
  #-sbcl (error "bits-single-float is not implemented for ~A." +implementation+))
