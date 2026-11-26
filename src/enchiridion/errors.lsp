;;;; errors.lsp --- Condition hierarchy.

(in-package #:enchiridion.errors)

(declaim (ftype function condition-report-line))

(defun condition-report-line (condition)
  "Return a single-line summary of CONDITION."
  (with-output-to-string (stream)
    (princ condition stream)))

;;;; Root.

(define-condition enchiridion-error (error)
  ((detail :initarg :detail :initform nil :reader error-detail
           :documentation "Optional detail string."))
  (:report (lambda (condition stream)
             (if (error-detail condition)
                 (format stream "~A: ~A" (type-of condition) (error-detail condition))
                 (format stream "~A" (type-of condition)))))
  (:documentation "Base condition for all application errors."))

;;;; Configuration and invocation.

(define-condition configuration-error (enchiridion-error)
  ((key :initarg :key :initform nil :reader configuration-key
        :documentation "The offending configuration key."))
  (:report (lambda (condition stream)
             (format stream "Configuration is wrong at ~A."
                     (or (configuration-key condition) "the root"))))
  (:documentation "Invalid or refused configuration."))

(define-condition usage-error (enchiridion-error)
  ((argument :initarg :argument :reader usage-argument))
  (:report (lambda (condition stream)
             (format stream "Invalid argument ~S." (usage-argument condition))))
  (:documentation "Invalid CLI or function argument."))

(define-condition missing-command (enchiridion-error)
  ((name :initarg :name :reader missing-command-name)
   (known :initarg :known :initform nil :reader missing-command-known
          :documentation "List of known command names."))
  (:report (lambda (condition stream)
             (format stream "There is no command called ~A."
                     (missing-command-name condition))))
  (:documentation "Unknown command name."))

;;;; Backends.

(define-condition backend-error (enchiridion-error)
  ((backend :initarg :backend :initform nil :reader error-backend))
  (:report (lambda (condition stream)
             (if (error-backend condition)
                 (format stream "The ~A backend refused the request."
                         (error-backend condition))
                 (format stream "The backend refused the request."))))
  (:documentation "Unimplemented backend feature or unparseable response."))

(define-condition transport-error (enchiridion-error)
  ((status :initarg :status :initform nil :reader transport-status))
  (:report (lambda (condition stream)
             (if (transport-status condition)
                 (format stream "The transport failed with status ~D."
                         (transport-status condition))
                 (format stream "The transport failed."))))
  (:documentation "Transient network, HTTP, or gateway failure."))

;;;; Tools.

(define-condition tool-error (enchiridion-error)
  ((tool :initarg :tool :initform nil :reader error-tool))
  (:report (lambda (condition stream)
             (format stream "Tool ~A failed."
                     (or (error-tool condition) "of unknown name"))))
  (:documentation "Runtime error inside a tool handler."))

(define-condition schema-error (enchiridion-error)
  ((tool :initarg :tool :initform nil :reader schema-tool)
   (path :initarg :path :initform nil :reader schema-path
         :documentation "Path to the invalid argument."))
  (:report (lambda (condition stream)
             (format stream "~@[Tool ~A: ~]~A"
                     (schema-tool condition)
                     (or (schema-path condition)
                         (error-detail condition)
                         "the arguments do not match the schema"))))
  (:documentation "Tool arguments failed schema validation."))

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
  (:documentation "Memory block write exceeds its character limit."))

(define-condition block-frozen (enchiridion-error)
  ((label :initarg :label :reader frozen-label))
  (:report (lambda (condition stream)
             (format stream "Block ~A is frozen for this session."
                     (frozen-label condition))))
  (:documentation "Attempted write to the compiled prompt snapshot."))

(define-condition bootstrap-pending (enchiridion-error)
  ((label :initarg :label :reader pending-label))
  (:report (lambda (condition stream)
             (format stream "Block ~A is the operator's until bootstrap hands over."
                     (pending-label condition))))
  (:documentation "Agent attempted to edit a seed file before bootstrap handover."))

(define-condition duplicate-message (enchiridion-error)
  ((id :initarg :id :reader duplicate-id))
  (:report (lambda (condition stream)
             (format stream "Message ~A has already been handled."
                     (duplicate-id condition))))
  (:documentation "Duplicate gateway message delivery."))

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
  (:documentation "Background work reached its token budget."))

(define-condition not-found (enchiridion-error)
  ((kind :initarg :kind :reader not-found-kind)
   (name :initarg :name :reader not-found-name))
  (:report (lambda (condition stream)
             (format stream "No ~A called ~A."
                     (not-found-kind condition) (not-found-name condition))))
  (:documentation "Named resource lookup failed."))

(define-condition turn-cancelled (enchiridion-error)
  ((turn :initarg :turn :initform 0 :reader cancelled-turn))
  (:report (lambda (condition stream)
             (format stream "The turn was cancelled after ~D round~:P."
                     (cancelled-turn condition))))
  (:documentation "Operator cancelled a turn in progress."))

(define-condition unauthorized (enchiridion-error)
  ((channel :initarg :channel :initform nil :reader unauthorized-channel))
  (:report (lambda (condition stream)
             (if (unauthorized-channel condition)
                 (format stream "~A is not allowed to talk to this agent."
                         (unauthorized-channel condition))
                 (format stream "That caller is not allowed to talk to this agent."))))
  (:documentation "Caller rejected by channel allowlist."))

(define-condition turn-busy (enchiridion-error)
  ((agent :initarg :agent :initform nil :reader busy-agent))
  (:report (lambda (condition stream)
             (let ((agent (busy-agent condition)))
               (if agent
                   (format stream "~A is already answering a turn." agent)
                   (format stream "This agent is already answering a turn.")))))
  (:documentation "Agent is already processing another turn."))
