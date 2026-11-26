;;;; protocol.lsp --- Backend protocol and normalized completion/message types.
;;;;
;;;; Messages hold plain text; tool-call arguments are stored verbatim as JSON
;;;; strings so the tool layer owns parsing and validation.

(in-package #:enchiridion.llm)

;;;; Messages.

;; role is "user", "assistant", "system", or "tool".
;; tool-call-id links a tool message to its originating tool call.
(defstruct (message (:constructor %make-message))
  (:role "" :type string)
  (:content "" :type string)
  (:tool-call-id "" :type string)
  (:tool-calls '() :type list)
  ;; Provider reasoning for the current tool round
  (:tool-reasoning nil :type (or null string)))

(defun system-message (text)
  "Return a message carrying instructions, which the model never replies to."
  (%make-message :role "system" :content text))

(defun user-message (text)
  "Return a message carrying what the operator or an agent asked."
  (%make-message :role "user" :content text))

(defun assistant-message (text &optional tool-calls)
  "Return a message carrying what the model said and the calls it asked for."
  (%make-message :role "assistant" :content text :tool-calls tool-calls))

(defun tool-message (text id)
  "Return a message carrying the result of tool call ID."
  (%make-message :role "tool" :content text :tool-call-id id))

;;;; Tool calls.

;; arguments is raw JSON text as emitted by the model.
(defstruct (tool-call (:constructor %make-tool-call))
  (:id "" :type string)
  (:name "" :type string)
  (:arguments "" :type string))

;;;; Usage.
;;;;
;;;; Cache read/write counts are tracked separately for cost accounting.
;;;; reasoning-text holds chain-of-thought apart from text so private reasoning
;;;; is not mixed into user-facing output.

(defstruct (completion (:constructor %make-completion))
  (:text "" :type string)
  (:reasoning-text "" :type string)
  ;; Moved to the tool-call message before the completion enters session history
  (:tool-reasoning nil :type (or null string))
  (:tool-calls '() :type list)
  (:model "" :type string)
  (:stop-reason "" :type string)
  (:input-tokens 0 :type (integer 0 *))
  (:output-tokens 0 :type (integer 0 *))
  (:cache-read-tokens 0 :type (integer 0 *))
  (:cache-write-tokens 0 :type (integer 0 *)))

(defun take-completion-tool-message (completion)
  "Move the current tool round's replay data out of COMPLETION."
  (when (completion-tool-calls completion)
    (%make-message :role "assistant"
                   :content (completion-text completion)
                   :tool-calls (completion-tool-calls completion)
                   :tool-reasoning (shiftf (completion-tool-reasoning completion) nil))))

(defun completion-total-tokens (completion)
  "Return total billed tokens (input + output). Backends normalize input-tokens
to include cache reads and writes, so cached tokens are not double-counted."
  (+ (completion-input-tokens completion)
     (completion-output-tokens completion)))

;;;; Tiers.
;;;;
;;;; Prefixed names (PRIMARY-MODEL, CHEAP-MODEL, SLEEP-MODEL) avoid colliding
;;;; with CL:SLEEP.

(defparameter *model-primary*
  "deepseek-v4.1-flash"
  "Default model for reasoning turns.")

(defparameter *model-cheap*
  "deepseek-v4.1-flash"
  "The model that handles memory digests and compaction.")

(defparameter *model-sleep*
  nil
  "Model for the sleep agent; NIL falls back to *MODEL-CHEAP*.")

;; Argument type is T because NIL is a valid input (defaults to :PRIMARY).
(declaim (ftype (function (t) keyword) tier))

(defun tier (name)
  "Return NAME as a tier keyword (:PRIMARY, :CHEAP, or :SLEEP), defaulting
NIL or unknown values to :PRIMARY."
  ;; Distinct keys only to avoid SBCL duplicate-case warnings.
  (case (or name :primary)
    (:primary :primary)
    (:cheap :cheap)
    (:sleep :sleep)
    (t :primary)))

(declaim (ftype (function () string) primary-model cheap-model sleep-model))
(declaim (ftype (function (keyword) string) model-for-tier))

(defun primary-model ()
  "Return the model that handles reasoning turns."
  *model-primary*)

(defun cheap-model ()
  "Return the model that handles memory digests and compaction."
  *model-cheap*)

(defun sleep-model ()
  "Return the model the sleep agent uses, falling back to the cheap one."
  (or *model-sleep* *model-cheap*))

(defun model-for-tier (name)
  "Return the model name for tier NAME."
  (ecase (tier name)
    (:primary (primary-model))
    (:cheap (cheap-model))
    (:sleep (sleep-model))))

;;;; The protocol.

(defgeneric complete (this messages &key model tools budget)
  (:documentation
   "Ask this backend to continue MESSAGES. MODEL names the model to use and NIL
means the backend's own default. Return a COMPLETION."))

(defgeneric embed (this texts &key model dimensions)
  (:documentation
   "Return one embedding per string in TEXTS, in order, each a vector of
SINGLE-FLOAT. MODEL names the embedding model. DIMENSIONS, when an integer,
asks a model that supports truncation for that many components. A backend
whose wire has no embeddings endpoint signals."))

(defgeneric model-capabilities (this)
  (:documentation
   "Return a plist describing what this backend's models support: :TOOLS,
:CACHE, :STREAMING, :CACHE-BREAKPOINTS."))

(defgeneric backend-name (this)
  (:documentation
   "Return a short name for this backend, for logs and for `enchiridion doctor'."))

(declaim (ftype (function (t) boolean) backendp))

(defun backendp (object)
  "Return T when OBJECT implements COMPLETE, MODEL-CAPABILITIES, and BACKEND-NAME.
FIND-METHOD takes (gf qualifiers specializers errorp): NIL qualifiers, exact
specializer arity per generic, and ERRORP NIL to return NIL instead of signalling."
  (and (not (null object))
       (let ((class (class-of object)))
         (not (null (and (find-method #'complete nil (list class t) nil)
                         (find-method #'model-capabilities nil (list class) nil)
                         (find-method #'backend-name nil (list class) nil)))))))
