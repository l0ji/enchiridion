;;;; broker-exec.cl --- The child process on the other side of the boundary.
;;;;
;;;; The supervisor starts this script, then talks to it over the Unix socket.
;;;; It runs as uid 1000 before any agent file is loaded. It holds no secret:
;;;; its environment is built by the supervisor and contains only paths and the
;;;; SBCL source registry.
;;;;
;;;; Run it by hand for a smoke test:
;;;;
;;;;   sbcl --script src/broker-exec.cl --socket /tmp/enchiridion-broker.sock

(require :asdf)

;; The same duplicate-contrib warning the supervisor suppresses. The child
;; runs the same source registry and the same ASDF.
(let ((package (find-package "ASDF/SOURCE-REGISTRY")))
  (when package
    (let ((symbol (find-symbol "*VERBOSE-OUT*" package)))
      (when symbol
        (setf (symbol-value symbol) nil)))))

(asdf:load-system "enchiridion" :verbose nil)

(defun broker-exec-argument (arguments name)
  "Return the value after NAME in ARGUMENTS, or NIL."
  (let ((tail (member name arguments :test #'string=)))
    (when tail (second tail))))

(defun broker-exec-main ()
  "Parse the small command line and serve until killed."
  (let* ((arguments (enchiridion.compat:script-arguments))
         (socket (broker-exec-argument arguments "--socket"))
         (uid-text (broker-exec-argument arguments "--uid")))
    (unless socket
      (format *error-output* "broker-exec: --socket PATH is required.~%")
      (return-from broker-exec-main 2))
    (let ((uid (and uid-text (parse-integer uid-text :junk-allowed t))))
      (handler-case
          (progn
            (enchiridion.tools.builtin:register-builtin-tools)
            (enchiridion.tools.broker:serve-broker (pathname socket) :uid uid)
            0)
        (enchiridion.errors:enchiridion-error (condition)
          (format *error-output* "~&~A~%" condition)
          (let ((detail (enchiridion.errors:error-detail condition)))
            (when (stringp detail)
              (format *error-output* "~A~%" detail)))
          1)
        (error (condition)
          (format *error-output* "~&broker-exec: ~A~%" condition)
          1)))))

(enchiridion.compat:exit-with (broker-exec-main))
