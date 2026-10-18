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

;; The same warning muffling as the supervisor, for the same reason: DBI's
;; macros redefine each DEFTYPE <NAME> as a class, and the child should not
;; print nineteen warnings before it serves its first request. The predicate
;; matches one message and lets every other warning through.
(defun broker-exec-muffled-warning-p (condition)
  "Return T for the one library warning the child does not print.

The test is on the report, for the reason given in src/main.cl: SBCL keeps the
format control of a SIMPLE-WARNING in its own representation."
  (let ((report (princ-to-string condition)))
    (and (>= (length report) 40)
         (eql 0 (search "redefining DEFTYPE type to be a class" report)))))

(handler-bind ((warning (lambda (condition)
                          (when (broker-exec-muffled-warning-p condition)
                            (muffle-warning condition)))))
  (asdf:load-system "enchiridion" :verbose nil))

(defun broker-exec-argument (arguments name)
  "Return the value after NAME in ARGUMENTS, or NIL."
  (let ((tail (member name arguments :test #'string=)))
    (when tail (second tail))))

(defun broker-exec-drop-uid (uid)
  "Drop to UID when this process is root and UID is a real user.
A non-root process stays where it is: dropping to a uid it does not own would
only fail, and the tests run as an ordinary user."
  (when (and uid (plusp uid) (zerop (enchiridion.compat:process-uid)))
    (enchiridion.compat:set-process-uid uid)))

(defun broker-exec-verify (directory uid)
  "Compile and self-test every agent file in DIRECTORY and report.
Return 0 when the generation is good and 1 when it is not. The uid is dropped
before a single agent file is read, so a verification that runs away runs away
as the agent and not as the process that holds the secrets."
  (broker-exec-drop-uid uid)
  (handler-case
      (let ((result (enchiridion.plugin:verify-directory (pathname directory))))
        (format t "~A~%" (enchiridion.plugin:verify-report result))
        (finish-output)
        (if (enchiridion.plugin:verify-ok-p result) 0 1))
    (enchiridion.errors:enchiridion-error (condition)
      (format *error-output* "~&verify: ~A~%" condition)
      (let ((detail (enchiridion.errors:error-detail condition)))
        (when (stringp detail)
          (format *error-output* "~A~%" detail)))
      1)
    (error (condition)
      (format *error-output* "~&verify: ~A~%" condition)
      1)))

(defun broker-exec-load-generation (directory generation)
  "Load a generation through the plugin loader.
Return two values, the ok flag and the report, which is the shape
*LOAD-GENERATION-FUNCTION* promises the broker."
  (let ((result (enchiridion.plugin:load-generation
                 directory
                 :generation (or generation
                                 (1+ (enchiridion.plugin:current-generation))))))
    (values (enchiridion.plugin:generation-result-ok-p result)
            (enchiridion.plugin:generation-result-report result))))

(defun broker-exec-main ()
  "Parse the small command line and serve until killed, or verify and exit."
  (let* ((arguments (enchiridion.compat:script-arguments))
         (verify (broker-exec-argument arguments "--verify-plugin"))
         (socket (broker-exec-argument arguments "--socket"))
         (uid-text (broker-exec-argument arguments "--uid"))
         (uid (and uid-text (parse-integer uid-text :junk-allowed t))))
    (when verify
      (return-from broker-exec-main (broker-exec-verify verify uid)))
    (unless socket
      (format *error-output* "broker-exec: --socket PATH is required.~%")
      (return-from broker-exec-main 2))
    (handler-case
        (progn
          (enchiridion.tools.builtin:register-builtin-tools)
          (setf enchiridion.tools.broker:*load-generation-function*
                #'broker-exec-load-generation)
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
        1))))

(enchiridion.compat:exit-with (broker-exec-main))
