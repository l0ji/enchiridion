;;;; broker-exec.lsp --- The child process on the other side of the boundary.
;;;;
;;;; The supervisor starts this script, then talks to it over the Unix socket.
;;;; It runs as uid 1000 before any agent file is loaded. It holds no secret:
;;;; its environment is built by the supervisor and contains only paths and the
;;;; SBCL source registry.
;;;;
;;;; Run it by hand for a smoke test:
;;;;
;;;;   sbcl --script src/broker-exec.lsp --socket /tmp/enchiridion-broker.sock

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
  "Drop root privileges before ASDF can read configuration or cached code."
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

The test is on the report, for the reason given in src/main.lsp: SBCL keeps the
format control of a SIMPLE-WARNING in its own representation."
  (let ((report (princ-to-string condition)))
    (and (>= (length report) 40)
         (eql 0 (search "redefining DEFTYPE type to be a class" report)))))

(handler-bind ((warning (lambda (condition)
                          (when (broker-exec-muffled-warning-p condition)
                            (muffle-warning condition)))))
  (asdf:load-system "enchiridion" :verbose nil))

(defun broker-exec-verify (directory &optional digests)
  "Compile and self-test every agent file in DIRECTORY and report.
Return 0 when the generation is good and 1 when it is not. The uid is dropped
before a single agent file is read, so a verification that runs away runs away
as the agent and not as the process that holds the secrets.

DIGESTS is the digest string the supervisor read, and a directory that no longer
matches it is refused without compiling a file."
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
  "Load a generation through the plugin loader.
Return four values: the ok flag, the report, the digest string of the source that
was published, and the generation that is live after the call. The last two are
what the broker puts in its reply, and the supervisor compares them with the
digest it verified and the generation it asked for.

VERIFY is NIL: a separate one-shot child already compiled and self-tested these
files before the supervisor asked for this load. Verifying here as well would
load every file twice in one process, and the second load redefines each
function, which verification counts as a warning and therefore as a failure.

The digest the supervisor verified arrives in *LOAD-SOURCE-DIGESTS*, which the
broker binds around this call, and the loader refuses a tree that no longer
matches it."
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
  ;; The same seed as the supervisor otherwise, and so the same temporary file
  ;; names in the same shared directory.
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

;; The child is in the terminal's process group, so a Ctrl-C at the supervising
;; terminal reaches it as well. It answers the interrupt the same way the
;; supervisor does, with a quiet exit and no backtrace: the supervisor is about
;; to stop the child anyway, and a trace from the sandbox side reads as the
;; agent crashing.
(enchiridion.compat:exit-with
 (catch 'broker-exec-interrupt
   (enchiridion.compat:with-interrupt-handler
       ((lambda (condition)
          (declare (ignore condition))
          (throw 'broker-exec-interrupt 130)))
     (broker-exec-main))))
