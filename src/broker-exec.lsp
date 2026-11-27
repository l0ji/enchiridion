;;;; broker-exec.lsp --- Unprivileged child entry point for the tool broker.
;;;;
;;;; Usage: sbcl --script src/broker-exec.lsp --socket PATH [--uid N --gid N] | --verify-plugin DIR

(require :sb-posix)

(defun broker-exec-argument (arguments name)
  "Return the value after NAME in ARGUMENTS, or NIL."
  (let ((tail (member name arguments :test #'string=)))
    (when tail (second tail))))

;; This bootstrap cannot depend on the system it must drop privileges to load
(sb-alien:define-alien-routine ("setgroups" broker-exec-setgroups) sb-alien:int
  (size sb-alien:unsigned-int)
  (list sb-alien:system-area-pointer))

(defun broker-exec-drop-privileges (arguments)
  "Drop root privileges (setgroups, setgid, setuid) before ASDF reads config or cached code."
  (when (zerop (sb-posix:geteuid))
    (let ((uid (parse-integer
                (or (broker-exec-argument arguments "--uid") "")))
          (gid (parse-integer
                (or (broker-exec-argument arguments "--gid") ""))))
      (unless (and (plusp uid) (plusp gid))
        (error "Root broker requires positive --uid and --gid values."))
      (when (minusp (broker-exec-setgroups 0 (sb-sys:int-sap 0)))
        (error "Could not clear the supplementary groups."))
      (sb-posix:setgid gid)
      (sb-posix:setuid uid)
      (unless (and (= uid (sb-posix:getuid) (sb-posix:geteuid))
                   (= gid (sb-posix:getgid) (sb-posix:getegid)))
        (error "Broker privilege drop did not take effect.")))))

(handler-case
    (broker-exec-drop-privileges (rest sb-ext:*posix-argv*))
  (error (condition)
    (format *error-output* "broker-exec: privilege drop failed: ~A~%"
            condition)
    (sb-ext:exit :code 1)))

(require :asdf)

;; Suppress ASDF duplicate-contrib output as in the supervisor.
(let ((package (find-package "ASDF/SOURCE-REGISTRY")))
  (when package
    (let ((symbol (find-symbol "*VERBOSE-OUT*" package)))
      (when symbol
        (setf (symbol-value symbol) nil)))))

(defun broker-exec-muffled-warning-p (condition)
  "Return T for the DBI DEFTYPE-to-class redefinition warning muffled during system load.
Matches on the printed report because SBCL stores SIMPLE-WARNING format controls specially."
  (let ((report (princ-to-string condition)))
    (and (>= (length report) 40)
         (eql 0 (search "redefining DEFTYPE type to be a class" report)))))

(handler-bind ((warning (lambda (condition)
                          (when (broker-exec-muffled-warning-p condition)
                            (muffle-warning condition)))))
  (asdf:load-system "enchiridion" :verbose nil))

(defun broker-exec-verify (directory &optional digests)
  "Compile and self-test agent files in DIRECTORY (after privilege drop); return exit code 0 or 1.
If DIGESTS is provided, refuses a directory whose snapshot digest does not match."
  (handler-case
      (let ((result (enchiridion.plugin:verify-directory (pathname directory)
                                                        :source-digests digests)))
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
  "Load GENERATION from DIRECTORY via the plugin loader, returning (values ok-p report digest live-gen).
Passes :VERIFY NIL because a one-shot child already verified the files (re-verifying in-process
would trigger redefinition warnings). Reads the expected digest from *LOAD-SOURCE-DIGESTS*."
  (let* ((digests enchiridion.tools.broker::*load-source-digests*)
         (result (enchiridion.plugin:load-generation
                  directory
                  :generation (or generation
                                  (1+ (enchiridion.plugin:current-generation)))
                  :verify nil
                  :source-digests digests))
         (snapshot (enchiridion.plugin:generation-result-digests result)))
    (values (enchiridion.plugin:generation-result-ok-p result)
            (enchiridion.plugin:generation-result-report result)
            (and snapshot
                 (enchiridion.plugin:source-snapshot-digest snapshot))
            (enchiridion.plugin:generation-result-generation result))))

(defun broker-exec-main ()
  "Parse the small command line and serve until killed, or verify and exit."
  ;; Reseed RNG so child temp names do not collide with the supervisor.
  (setf *random-state* (make-random-state t))
  (let* ((arguments (enchiridion.compat:script-arguments))
         (verify (broker-exec-argument arguments "--verify-plugin"))
         (digests (broker-exec-argument arguments "--digests"))
         (socket (broker-exec-argument arguments "--socket"))
         (uid-text (broker-exec-argument arguments "--uid"))
         (gid-text (broker-exec-argument arguments "--gid"))
         (uid (and uid-text (parse-integer uid-text)))
         (gid (and gid-text (parse-integer gid-text))))
    (when verify
      (return-from broker-exec-main (broker-exec-verify verify digests)))
    (unless socket
      (format *error-output* "broker-exec: --socket PATH is required.~%")
      (return-from broker-exec-main 2))
    (handler-case
        (progn
          (enchiridion.log:configure-logging)
          (enchiridion.tools.builtin:register-builtin-tools)
          (setf enchiridion.tools.broker:*load-generation-function*
                #'broker-exec-load-generation)
          (enchiridion.tools.broker:serve-broker (pathname socket) :uid uid :gid gid)
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

;; Exit quietly (130) on terminal SIGINT instead of printing a backtrace.
(enchiridion.compat:exit-with
 (catch 'broker-exec-interrupt
   (enchiridion.compat:with-interrupt-handler
       ((lambda (condition)
          (declare (ignore condition))
          (throw 'broker-exec-interrupt 130)))
     (broker-exec-main))))
