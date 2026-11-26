;;;; shell.lsp --- Run shell commands with a bounded timeout and capped output.

(in-package #:enchiridion.tools.builtin)

(defparameter +shell-timeout+ 30
  "Default seconds before a shell command is stopped.")

(defparameter +shell-max-timeout+ 600
  "Maximum allowed shell command timeout in seconds.")

(declaim (ftype (function (t) (integer 1 *)) shell-timeout))

(defun shell-timeout (requested)
  "Clamp REQUESTED to [1, +SHELL-MAX-TIMEOUT+], or return +SHELL-TIMEOUT+ if non-numeric."
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
