;;;; shell.cl --- Run a command with a time limit and a capped result.
;;;;
;;;; The shell tool is the broker's most direct escape hatch, which is why the
;;;; broker, not the supervisor, runs it. This file does only three things:
;;;; run the command, stop it at the deadline, and keep the result small.

(in-package #:enchiridion.tools.builtin)

(defparameter +shell-timeout+ 30
  "Default seconds before a shell command is stopped.")

(defparameter +shell-max-timeout+ 600
  "The most seconds a shell command may ask for. The model chooses the timeout,
and a turn holds the agent for as long as its command runs, so the choice is
bounded here rather than trusted.")

(declaim (ftype (function (t) (integer 1 *)) shell-timeout))

(defun shell-timeout (requested)
  "Return REQUESTED as a whole number of seconds between 1 and the maximum, or
the default when it is not a number at all."
  (if (realp requested)
      (max 1 (min +shell-max-timeout+ (ceiling requested)))
      +shell-timeout+))

(declaim (ftype (function (t) string) shell-run))

(defun shell-run (args)
  "Run COMMAND through /bin/sh and return combined output and exit status.
A timeout ends the child and everything it started, and the result says so."
  (let* ((command (argument args "command"))
         (timeout (shell-timeout (argument args "timeout"))))
    (unless (stringp command)
      (error 'enchiridion.errors:schema-error :detail "command must be a string."))
    (multiple-value-bind (output status)
        (enchiridion.compat:run-program-capture "/bin/sh" (list "-c" command)
                                                :timeout timeout)
      (cap-result
       (if (eq status :timeout)
           (format nil "~A~%[timed out after ~A seconds]" output timeout)
           (format nil "~A~%[exit ~A]" output status))))))

(defparameter +shell-tools+
  (list
   (enchiridion.tools:make-tool
    :name "shell"
    :description "Run a shell command and return its output, with a time limit."
    :schema '(:object :required (:command)
              :properties ((:command :string) (:timeout :integer)))
    :handler #'shell-run)))

(defun register-shell-tools ()
  "Register the shell tool. Idempotent."
  (dolist (tool +shell-tools+)
    (enchiridion.tools:register-tool tool))
  (length +shell-tools+))
