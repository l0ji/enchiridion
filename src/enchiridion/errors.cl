;;;; errors.cl --- The condition hierarchy.
;;;;
;;;; Every failure in this system is a condition, never a formatted string.
;;;; The difference is recoverable: a caller can ask a block-overflow how many
;;;; characters it needs to free, and it cannot ask a string anything at all.

;; The package is declared in packages.cl, and only there. A second defpackage
;; for the same name leaves two export lists to drift, and the one in the
;; second file silently wins.

(in-package #:enchiridion.errors)

(declaim (ftype function condition-report-line))

(defun condition-report-line (condition)
  "Return a one line human summary of CONDITION, for a status file or a log."
  (with-output-to-string (stream)
    (princ condition stream)))

;;;; Root.

(define-condition enchiridion-error (error)
  ((detail :initarg :detail :initform nil :reader error-detail
          :documentation "A free form note, or NIL."))
  (:report (lambda (condition stream)
             (if (error-detail condition)
                 (format stream "~A: ~A" (type-of condition) (error-detail condition))
                 (format stream "~A" (type-of condition)))))
  (:documentation
   "Parent of every condition this system signals. Catching this one catches
the system's own failures without also catching, say, a file error from the
host filesystem."))

;;;; Configuration and invocation.

(define-condition configuration-error (enchiridion-error)
  ((key :initarg :key :initform nil :reader configuration-key
        :documentation "The configuration key at fault."))
  (:report (lambda (condition stream)
             (format stream "Configuration is wrong at ~A." (or (configuration-key condition) "the root"))))
  (:documentation
   "A configuration file is absent, unreadable, or holds a value of the wrong
shape. An absent file is never this: absence means defaults."))

(define-condition usage-error (enchiridion-error)
  ((argument :initarg :argument :reader usage-argument))
  (:report (lambda (condition stream)
             (format stream "Argument ~S is not usable here." (usage-argument condition))))
  (:documentation "A command or function was called with something it cannot use."))

(define-condition missing-command (enchiridion-error)
  ((name :initarg :name :reader missing-command-name)
   (known :initarg :known :initform nil :reader missing-command-known
         :documentation "Every command name that does exist."))
  (:report (lambda (condition stream)
             (format stream "There is no command called ~A." (missing-command-name condition))))
  (:documentation "An unknown command name. The report names the command rather
than listing thirty of them into a terminal; a caller that wants the list asks
the condition for it."))

;;;; Backends.

(define-condition backend-error (enchiridion-error)
  ((backend :initarg :backend :initform nil :reader error-backend))
  (:report (lambda (condition stream)
             (if (error-backend condition)
                 (format stream "The ~A backend refused the request." (error-backend condition))
                 (format stream "The backend refused the request."))))
  (:documentation "A backend was asked for something it does not implement, or
answered with something that does not parse."))

(define-condition transport-error (enchiridion-error)
  ((status :initarg :status :initform nil :reader transport-status))
  (:report (lambda (condition stream)
             (if (transport-status condition)
                 (format stream "The transport failed with status ~D." (transport-status condition))
                 (format stream "The transport failed."))))
  (:documentation
   "The socket, the HTTP call, or the gateway went away. Distinct from
backend-error because the right response is to retry, not to change the code."))

;;;; Tools.

(define-condition tool-error (enchiridion-error)
  ((tool :initarg :tool :initform nil :reader error-tool))
  (:report (lambda (condition stream)
             (format stream "Tool ~A failed." (or (error-tool condition) "of unknown name"))))
  (:documentation "A tool raised while running. The agent sees the report and
can try something else, because the report is a sentence rather than a
backtrace."))

(define-condition schema-error (enchiridion-error)
  ((tool :initarg :tool :initform nil :reader schema-tool)
   (path :initarg :path :initform nil :reader schema-path
         :documentation "Where in the arguments the failure is."))
  (:report (lambda (condition stream)
             (format stream "~@[Tool ~A: ~]~A"
                     (schema-tool condition)
                     (or (schema-path condition)
                         (error-detail condition)
                         "the arguments do not match the schema"))))
  (:documentation
   "A tool call did not match its schema. It fails at the boundary with a
readable message, before the handler ever runs."))

;;;; Memory.

(define-condition block-overflow (enchiridion-error)
  ((label :initarg :label :reader overflow-label)
   (current :initarg :current :reader overflow-current)
   (wanted :initarg :wanted :reader overflow-wanted))
  (:report (lambda (condition stream)
             (format stream "Block ~A is at ~D characters and needs ~D, so ~D must go."
                     (overflow-label condition)
                     (overflow-current condition)
                     (overflow-wanted condition)
                     (max 0 (- (overflow-wanted condition) (overflow-current condition))))))
  (:documentation
   "A block write that would exceed the character limit. The report carries the
exact shortfall, because the agent has to be able to consolidate in the same
batched call and a vague failure makes that impossible. Nothing is ever
truncated silently."))

(define-condition block-frozen (enchiridion-error)
  ((label :initarg :label :reader frozen-label))
  (:report (lambda (condition stream)
             (format stream "Block ~A is frozen for this session." (frozen-label condition))))
  (:documentation
   "A write to the compiled prompt after the snapshot was taken. Disk changes
without changing the live prompt: that is the whole reason the prefix cache
stays warm."))

(define-condition bootstrap-pending (enchiridion-error)
  ((label :initarg :label :reader pending-label))
  (:report (lambda (condition stream)
             (format stream "Block ~A is the operator's until bootstrap hands over." (pending-label condition))))
  (:documentation
   "An agent write to a seed file before handover. The operator's guidance must
survive the first minutes of the agent's life."))

(define-condition duplicate-message (enchiridion-error)
  ((id :initarg :id :reader duplicate-id))
  (:report (lambda (condition stream)
             (format stream "Message ~A has already been handled." (duplicate-id condition))))
  (:documentation
   "A gateway redelivered a message. Retrying a turn twice is worse than
dropping it, so the second copy is dropped and said so."))

(define-condition budget-exceeded (enchiridion-error)
  ((spent :initarg :spent :reader budget-spent)
   (cap :initarg :cap :reader budget-cap)
   (window :initarg :window :initform :tick :reader budget-window
           :type keyword))
  (:report (lambda (condition stream)
             (format stream "The ~A budget is spent: ~D of ~D tokens."
                     (budget-window condition)
                     (budget-spent condition)
                     (budget-cap condition))))
  (:documentation
   "Unattended work stopped rather than exceeding its cap. A tick that cannot
finish is a tick that does not start."))

(define-condition not-found (enchiridion-error)
  ((kind :initarg :kind :reader not-found-kind)
   (name :initarg :name :reader not-found-name))
  (:report (lambda (condition stream)
             (format stream "No ~A called ~A." (not-found-kind condition) (not-found-name condition))))
  (:documentation "A lookup by name failed. Named separately so that a missing
skill is not reported as a crash."))

(define-condition turn-cancelled (enchiridion-error)
  ((turn :initarg :turn :initform 0 :reader cancelled-turn))
  (:report (lambda (condition stream)
             (format stream "The turn was cancelled after ~D round~:P."
                     (cancelled-turn condition))))
  (:documentation
   "The operator stopped a turn in progress. Distinct from a failure: nothing
went wrong, and the reply that would have been printed will not arrive."))

(define-condition unauthorized (enchiridion-error)
  ((channel :initarg :channel :initform nil :reader unauthorized-channel))
  (:report (lambda (condition stream)
             (if (unauthorized-channel condition)
                 (format stream "~A is not allowed to talk to this agent." (unauthorized-channel condition))
                 (format stream "That caller is not allowed to talk to this agent."))))
  (:documentation
   "An allowlist said no. Deny by default: an empty allowlist means nobody may
talk to the agent, and that case is tested."))