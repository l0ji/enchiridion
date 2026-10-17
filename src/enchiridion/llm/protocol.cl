;;;; protocol.cl --- The backend protocol and the shapes every backend returns.
;;;;
;;;; Every LLM backend implements BACKEND and nothing above it ever asks which
;;;; one it has. The kernel calls COMPLETE and reads a COMPLETION; it does not
;;;; know that HTTP, JSON, or a cache breakpoint exist. That is the whole
;;;; reason a second provider is an afternoon rather than a rewrite.
;;;;
;;;; Messages are stored as plain text. Tool call arguments are stored as JSON
;;;; text rather than as parsed objects, because the model that wrote them
;;;; owns their shape and the tool that will run them owns their meaning;
;;;; nothing in between needs to understand either.

(in-package #:enchiridion.llm)

;;;; Messages.

;; defstruct slots take :type and :read-only, and a defstruct takes no
;; :documentation option at all: a trailing :documentation is read as a slot
;; named DOCUMENTATION, and a slot's meaning is carried in a comment here
;; rather than in a field the reader would trip over.
;;
;; role is user, assistant, system, or tool. content is the body text.
;; tool-call-id names the call a tool message answers, and is empty for every
;; other role: the id is carried rather than looked up so a result cannot be
;; reordered against its call and read as an answer to a different call.
(defstruct (message (:constructor %make-message))
  (:role "" :type string)
  (:content "" :type string)
  (:tool-call-id "" :type string))

(defun system-message (text)
  "Return a message carrying instructions, which the model never replies to."
  (%make-message :role "system" :content text))

(defun user-message (text)
  "Return a message carrying what the operator or an agent asked."
  (%make-message :role "user" :content text))

(defun assistant-message (text)
  "Return a message carrying what the model said."
  (%make-message :role "assistant" :content text))

(defun tool-message (text id)
  "Return a message carrying the result of tool call ID."
  (%make-message :role "tool" :content text :tool-call-id id))

;;;; Tool calls.

;; id is the call's id as the model gave it. name is which tool to run.
;; arguments is the arguments as JSON text, exactly as the model wrote them,
;; because that is how they were sent and how the tool layer validates them.
(defstruct (tool-call (:constructor %make-tool-call))
  (:id "" :type string)
  (:name "" :type string)
  (:arguments "" :type string))

;;;; Usage.
;;;;
;;;; Cache read and cache write are tracked apart from input and output
;;;; because they are what the prefix cache costs and saves. A ledger that only
;;;; counted input would show a cached turn costing the same as a cold one,
;;;; which is exactly the number that has to stay visible.
;;;;
;;;; text is the reply as text. tool-calls are the calls it asked for, in the
;;;; order it asked for them. model is which model actually answered, which is
;;;; not always the one that was asked for. stop-reason is why it stopped: stop,
;;;; length, tool_calls.

(defstruct (completion (:constructor %make-completion))
  (:text "" :type string)
  (:tool-calls '() :type list)
  (:model "" :type string)
  (:stop-reason "" :type string)
  (:input-tokens 0 :type (integer 0 *))
  (:output-tokens 0 :type (integer 0 *))
  (:cache-read-tokens 0 :type (integer 0 *))
  (:cache-write-tokens 0 :type (integer 0 *)))

(defun completion-total-tokens (completion)
  "Return the tokens COMPLETION was billed for in total. A cache read is not
added twice: it is already part of the prompt the provider counted."
  (+ (completion-input-tokens completion)
     (completion-output-tokens completion)))

;;;; Tiers.
;;;;
;;;; Three models, not one. Reasoning turns go to primary, memory digests and
;;;; compaction go to cheap, and the sleep agent goes to sleep, which defaults
;;;; to cheap because nothing is waiting on it.
;;;;
;;;; The names are PRIMARY-MODEL, CHEAP-MODEL and SLEEP-MODEL and not the bare
;;;; words primary, cheap and sleep because SLEEP is CL:SLEEP. A function
;;;; named sleep in a package that uses CL is a package lock error, and a
;;;; warning here is an error.

(defparameter *model-primary*
  "kimi-k3"
  "The model that handles reasoning turns.")

(defparameter *model-cheap*
  "space-bunny"
  "The model that handles memory digests and compaction.")

(defparameter *model-sleep*
  nil
  "The model the sleep agent uses. NIL means *MODEL-CHEAP*, which is the
default, and the default is the point: the sleep agent has no deadline.")

;; The argument is T and not KEYWORD, because TIER normalises and NIL is a
;; documented input: it means "no tier named", and it becomes :PRIMARY.
;; Declaring the argument as KEYWORD made (tier nil) a type error at the safety
;; check on entry, which is the opposite of what the docstring promises.
(declaim (ftype (function (t) keyword) tier))

(defun tier (name)
  "Return NAME as a tier keyword: :PRIMARY, :CHEAP, or :SLEEP.

Unknown names become :PRIMARY rather than signalling. A typo in a config key
should cost a cheap turn on a strong model, not stop the agent from starting,
and a tier is never a security decision."
  (case (or name :primary)
    ((:primary :primary) :primary)
    ((:cheap :cheap) :cheap)
    ((:sleep :sleep) :sleep)
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
;;;;
;;;; Three generic functions rather than DEFPROTOCOL, and that is the one
;;;; deliberate departure from the shape section 16.3 of the plan draws. SBCL
;;;; 2.5.4 does not have defprotocol: the symbol is not in the CL package and
;;;; not in SB-MOP or SB-EXT either, so (defprotocol backend ...) reads as an
;;;; ordinary call to a function that does not exist and dies with
;;;; UNDEFINED-FUNCTION. Writing the three generics by hand is the whole
;;;; substitution. The names, the argument lists and every call site are the
;;;; ones the plan fixes, so nothing above this line has to know.
;;;;
;;;; TOOLS and BUDGET are in the signature now and are ignored by the only
;;;; backend written so far. They are here because adding a parameter later
;;;; changes every DEF-METHOD at once, and the plan fixes this signature.

(defgeneric complete (this messages &key model tools budget)
  (:documentation
   "Ask this backend to continue MESSAGES. MODEL names the model to use and NIL
means the backend's own default. Return a COMPLETION."))

(defgeneric model-capabilities (this)
  (:documentation
   "Return a plist describing what this backend's models support: :TOOLS,
:CACHE, :STREAMING, :CACHE-BREAKPOINTS."))

(defgeneric backend-name (this)
  (:documentation
   "Return a short name for this backend, for logs and for `enchiridion doctor'."))

(declaim (ftype (function (t) boolean) backendp))

(defun backendp (object)
  "Return T when OBJECT answers every operation the kernel calls on a backend.

This is what satisfies was for. Without a protocol there is no type to check
against, so the check is written out: one method specialised on OBJECT's
class, for each of the three operations. A backend that grows a fourth
operation later has to add its method here too, and that is the point of
listing them.

Two things about the calls below, both of which cost a debugging session to
find and neither of which is visible from the error.

The specializer list is spelled out per operation and not built by counting,
because COMPLETE takes MESSAGES as well as the backend, and FIND-METHOD
refuses to match a method against the wrong number of specializers.

The NIL before each list is a METHOD QUALIFIER list, not an empty
specializer list, and the NIL after each list is an ERRORP argument, not a
third specializer. SBCL 2.5.4 spells the parameters QUALIFIERS, SPECIALIZERS
and ERRORP where ANSI spells the first two SPECIALIZERS and GENERIC-ARGS.
Written the ANSI way, SBCL reads a list of classes as a list of qualifiers and
answers FIND-METHOD-LENGTH-MISMATCH, which names neither the class nor the
argument that is wrong. Left out, ERRORP defaults to signalling, so checking
whether a method exists for a class that has none is a SIMPLE-ERROR rather
than the NIL the question asks for."
  (and (not (null object))
       (let ((class (class-of object)))
         (not (null (and (find-method #'complete nil (list class t) nil)
                         (find-method #'model-capabilities nil (list class) nil)
                         (find-method #'backend-name nil (list class) nil)))))))
