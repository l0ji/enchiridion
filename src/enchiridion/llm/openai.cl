;;;; openai.cl --- The OpenAI-compatible backend.
;;;;
;;;; One adapter covers OpenCode Go, OpenAI, and anything that speaks the chat
;;;; completions shape, which is what the config's :BACKEND :OPENAI means.
;;;; Anthropic's cache_control is a different wire shape and gets its own file
;;;; when it gets written.
;;;;
;;;; The request and the response are separated from the transport on purpose:
;;;; COMPLETION-REQUEST and PARSE-COMPLETION are pure functions over text and
;;;; data, so the whole wire format is testable without a network, a key, or a
;;;; provider. The only part that needs any of those is the transport, and it is
;;;; one function long.
;;;;
;;;; Nothing in this file branches on which provider it is talking to. That is
;;;; what makes "fall back to a local OpenAI-compatible server" a config change
;;;; and not a code change.
;;;;
;;;; The file is in dependency order, bottom to top, and it has to be. A name
;;;; used before it is defined is not a forward declaration in Lisp: the
;;;; compiler reads a symbol it has never seen as a variable, and the failure
;;;; surfaces at run time as UNBOUND-VARIABLE from a function that plainly
;;;; exists. The same trap closed in on the backend's own DEFMETHOD, which is
;;;; why COMPLETE is defined after SEND-COMPLETION rather than with the other
;;;; methods at the top.

(in-package #:enchiridion.llm)

;;;; JSON.
;;;;
;;;; Called from several places, and :PARSE and :STRINGIFY belong to nobody in
;;;; particular, so they are wrapped rather than used raw.

;; jzon spells JSON null as an unexported symbol rather than as NIL, and its
;; own JSON-ATOM type says so: T is true, NIL is false, REAL is a number and
;; this symbol is null. PARSE hands the symbol back, so a provider that omits a
;; field and a provider that sends the field as null arrive as two different
;; values and would reach two different code paths if it were passed through as
;; it came.
;;
;; Naming it here is why this file has an internal reference to a dependency at
;; all. There is no exported name to ask for, and PARSE-COMPLETION has to be
;; able to recognise the value once it is in hand.
;;
;; The QUOTE is not decoration. DEFCONSTANT evaluates its value form, and a bare
;; symbol in an evaluated position is a variable reference, so writing the name
;; unqualified here reads as a lookup of a variable called null and fails during
;; the compile of this file with an unbound variable whose name gives nothing
;; away. The backtrace prints CL:NULL as bare NULL because *PRINT-ESCAPE* is off,
;; so the reported name looks like the standard Lisp one it is not.
(defconstant +json-null+ 'com.inuoe.jzon::null)

(defun json-key (name)
  "Return NAME as a keyword, interned in KEYWORD.

NAME is an OR a CHARACTER, not only a string. jzon pools short object keys
and pools a one character key as the character itself, so a reply with a key
called \"id\" arrives here as #\\I rather than as \"id\". STRING on either turns
that back into a name, and without it the first short key in a reply is a type
error.

The DECLARE is inline and not a F-TYPE because an F-TYPE lambda list whose one
argument spec is itself a compound type has to be written ((TYPE)), and a
reader error in a declaim costs a whole build to find.

Interning in KEYWORD rather than in this package means a provider that invents
a key cannot intern a symbol into enchiridion.llm and make it look like part
of this system's own API."
  (declare (type (or string character) name))
  (intern (string-upcase (string name)) :keyword))

(declaim (ftype (function (hash-table) list) json-object->plist))

(defun json-object->plist (table)
  "Return TABLE, a jzon object, as a plist with keyword keys.

jzon represents a JSON object as a hash table keyed by strings, measured
against com.inuoe.jzon 1.1.4, and has no option to change that. GETF on a
hash table is a malformed property list error, so every accessor in
PARSE-COMPLETION would fail on the first reply. Converting here means one
place owns the translation and every caller above it speaks the plist shape the
rest of this system already uses."
  (loop for key being the hash-keys of table
        append (list (json-key key) (json->lisp (gethash key table)))))

(declaim (ftype (function (t)) json->lisp))

(defun json->lisp (node)
  "Return NODE, as jzon produced it, in this system's shape.

An object arrives as a hash table and becomes a plist. An array arrives as a
vector and becomes a list. A cons is mapped over for the benefit of any future
jzon that changes its mind about arrays. Numbers, booleans and NIL are already
what they are and are returned untouched.

STRINGP is tested before VECTORP, and the order is the whole function. jzon
returns a JSON string whose characters are all base characters as a
SIMPLE-BASE-STRING, and SBCL reports that as a vector as well as a string. A
branch that tests VECTORP first therefore turns every string in a reply into a
list of characters, and the symptom is a STRING= against a list of CHAR, which
says nothing at all about where it came from.

JSON null becomes NIL. jzon's JSON-ATOM type says so outright: T is true, NIL
is false, REAL is a number and the symbol NULL is null. A provider that omits
a field and a provider that sends it as null are the same fact to every caller
here, and leaving NULL in place means it reaches a string slot and fails as a
type error about a word nobody wrote."
  (cond
    ((hash-table-p node) (json-object->plist node))
    ((stringp node) node)
    ((vectorp node) (map 'list #'json->lisp node))
    ((consp node) (map 'list #'json->lisp node))
    ((eq node +json-null+) nil)
    (t node)))

(declaim (ftype (function (string) t) parse-json))

(defun parse-json (text)
  "Return TEXT as JSON data: objects as alists keyed by keyword, arrays as
lists, strings as strings, numbers as numbers.

Signals JSON-PARSE-ERROR on malformed input rather than returning NIL, because
a provider that answered with an error page and a provider that answered with
an empty object are different problems and the message has to say which."
  (json->lisp (com.inuoe.jzon:parse text)))

(declaim (ftype (function (t)) stringify))

(defun stringify (object)
  "Return OBJECT as JSON text."
  (com.inuoe.jzon:stringify object))

;;;; The connection.
;;;;
;;;; The struct is OPENAI-CONNECTION and the constructor is OPENAI-BACKEND, so
;;;; that the exported name is a function and the type stays an internal
;;;; detail. A struct and a function cannot share one name here without the
;;;; export list meaning two different things depending on how it is read.

;; base-url always ends in a slash, so paths can be appended to it. api-key is
;; never logged and never put in an error report. model is the default for
;; this backend. timeout is seconds to wait for a reply, and retries is how
;; many extra attempts a 429 or a 5xx earns. session-id identifies one
;; conversation to OpenCode Go, which uses it for routing and prompt caching.
(defstruct (openai-connection (:constructor %make-connection))
  (:base-url "https://api.openai.com/v1/" :type string)
  (:api-key "" :type string)
  (:model "" :type string)
  (:session-id "" :type string)
  (:timeout 60 :type (integer 1 *))
  (:retries 2 :type (integer 0 *)))

(declaim (ftype (function () string) new-session-id))

(defun new-session-id ()
  "Return a 32 character hexadecimal session id. OpenCode Go asks for one on
every request so that it can route a conversation and keep its prompt cache
warm. A backend generates one when it is built and reuses it for every turn."
  (format nil "~32,'0X" (random (expt 2 128))))

(defun openai-backend (&key (base-url "https://api.openai.com/v1/")
                             api-key
                             (model nil)
                             (session-id nil)
                             (timeout 60)
                             (retries 2))
  "Return a BACKEND that speaks the OpenAI chat completions shape.

BASE-URL gains a trailing slash when it lacks one, because every path is
appended to it and a missing slash silently turns /v1 into a host named v1.
SESSION-ID is generated when it is absent; one backend is one conversation."
  (%make-connection
   :base-url (if (and (plusp (length base-url))
                      (char= (char base-url (1- (length base-url))) #\/))
                 base-url
                 (concatenate 'string base-url "/"))
   :api-key (or api-key "")
   :model (or model (primary-model))
   :session-id (or session-id (new-session-id))
   :timeout timeout
   :retries retries))

;;;; The request.
;;;;
;;;; The shape is the one every OpenAI-compatible server accepts:
;;;;
;;;;   {"model": "...", "messages": [{"role": "user", "content": "hi"}]}
;;;;
;;;; A tool call id rides along on a tool message because the provider matches
;;;; results to calls by id, and a result whose id is missing or wrong is
;;;; answered with an error rather than with a guess.

(declaim (ftype (function (&rest t) hash-table) json-object))

(defun json-object (&rest pairs)
  "Return PAIRS, alternating keys and values, as the object STRINGIFY writes as
a JSON object.

STRINGIFY takes the same shape PARSE produces, and that shape is a hash table
keyed by strings. Handed a plist it writes an ARRAY of alternating elements
instead, so the provider receives [\"model\",\"m\",...] rather than {...} and
answers with an error about a malformed request. Keys are downcased because
that is what a JSON object conventionally looks like on the wire; the reading
side upcases whatever it gets, so the case is only ever cosmetic here.

One constructor for this, so the mistake above is made in one place rather
than in every object the tree builds."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash (string-downcase (string key)) table) value))
    table))

(declaim (ftype (function (message) hash-table) message->request-message))

(defun tool-call->request (call)
  "Return CALL as the assistant tool_calls object a provider accepts."
  (json-object :id (tool-call-id call)
               :type "function"
               :function (json-object :name (tool-call-name call)
                                      :arguments (tool-call-arguments call))))

(defun message->request-message (message)
  "Return MESSAGE as the request object. A tool message carries its call id;
an assistant message carries its tool calls when it asked for any. Every other
message does not carry either key, because some servers reject an unexpected
field rather than ignoring it."
  (let ((pairs (list :role (message-role message)
                     :content (message-content message))))
    (cond
      ((plusp (length (message-tool-call-id message)))
       (apply #'json-object
              (append pairs (list :tool_call_id (message-tool-call-id message)))))
      ((message-tool-calls message)
       (apply #'json-object
              (append pairs (list :tool_calls
                                  (map 'list #'tool-call->request
                                       (message-tool-calls message))))))
      (t (apply #'json-object pairs)))))

(defun tool-definition->request (definition)
  "Wrap one registry function object as an OpenAI tool definition."
  (json-object :type "function" :function definition))

(defun completion-request (model messages &key tools)
  "Return the request body for MODEL continuing MESSAGES, as JSON text.

#'MESSAGE->REQUEST-MESSAGE and not the bare name: MAP evaluates its function
argument as a value, so a bare symbol there is a variable reference and the
failure arrives at run time as UNBOUND-VARIABLE from a function that is
plainly defined."
  (let ((body (json-object :model model
                           :stream nil
                           :messages (map 'list #'message->request-message messages))))
    (when tools
      (setf (gethash "tools" body)
            (map 'list #'tool-definition->request tools))
      (setf (gethash "tool_choice" body) "auto"))
    (stringify body)))

;;;; The reply.

(declaim (ftype (function (t) list) parse-tool-calls))

(defun parse-tool-calls (reply)
  "Return the tool calls in REPLY, a request message read from the wire.

Arguments come back as JSON text, not as a parsed object, because that is how
they were sent and how the tool layer validates them."
  (loop for call in (getf reply :tool_calls)
        when call
        collect (%make-tool-call
                 :id (or (getf call :id) "")
                 :name (or (getf (getf call :function) :name) "")
                 :arguments (or (getf (getf call :function) :arguments) ""))))

(declaim (ftype (function (t)) parse-completion))

(defun parse-completion (data)
  "Return the COMPLETION described by DATA, which is the parsed JSON object a
chat completions reply carries.

Signals rather than returning an empty completion when the reply has no
choices. An empty completion is indistinguishable from a model that said
nothing, and that is the one failure the agent cannot recover from on its own."
  (let ((choices (getf data :choices)))
    (unless (and (listp choices) (plusp (length choices)))
      (error 'enchiridion.errors:backend-error
             :backend "openai"
             :detail (format nil "The reply carried no choices: ~S" (getf data :error))))
    (let* ((choice (first choices))
           (reply (getf choice :message))
           (usage (getf data :usage))
           (details (getf usage :prompt_tokens_details))
           (cached (or (getf details :cached_tokens) 0)))
      (%make-completion
       :text (or (getf reply :content) "")
       :tool-calls (parse-tool-calls reply)
       :model (or (getf data :model) "")
       :stop-reason (or (getf choice :finish_reason) "")
       :input-tokens (or (getf usage :prompt_tokens) 0)
       :output-tokens (or (getf usage :completion_tokens) 0)
       ;; A provider that reports cached tokens as a field of its own rather
       ;; than inside prompt_tokens_details still has to be counted, or the
       ;; ledger says every turn cost full price.
       :cache-read-tokens cached
       :cache-write-tokens (or (getf usage :cache_creation_input_tokens) 0)))))

(declaim (ftype (function (string)) provider-error-message))

(defun provider-error-message (payload)
  "Return the provider's own error text from PAYLOAD, or a short note when
there is none. A reply that is not JSON at all is not a crash: a proxy in
front of the provider answers HTML."
  (handler-case
      (let* ((parsed (parse-json payload))
             (error-object (getf parsed :error)))
        (cond
          ((and (listp error-object) (stringp (getf error-object :message)))
           (getf error-object :message))
          ((stringp error-object) error-object)
          (t (string-right-trim '(#\Space #\Newline #\Return) (or payload "")))))
    (error () "the provider replied with something that is not JSON")))

;;;; The transport.
;;;;
;;;; dexador signals HTTP-REQUEST-FAILED on any 4xx or 5xx and returns the body
;;;; on a 2xx, so the status is read off the condition rather than off a return
;;;; value. RESPONSE-STATUS is that condition's reader; it is not a way to ask
;;;; "what did the last call return", and calling it with no arguments is a
;;;; style warning about arity.

(declaim (ftype (function (string string string string integer string) string)
                http-post))

(defun http-post (base-url path body api-key timeout session-id)
  "POST BODY to PATH under BASE-URL and return the reply text.

The argument names are dexador's, not guesses. It spells the payload :CONTENT
and not :DATA, spells the content type as a header and not as a :CONTENT-TYPE
argument, and spells both halves of a deadline :READ-TIMEOUT and
:CONNECT-TIMEOUT with no :TIMEOUT at all. Passing the names that read well
instead of the names it accepts is a style warning about unknown argument
keywords, and a warning here is an error.

The header list is an alist of CONSES. dexador walks it with (LOOP FOR (NAME .
VALUE) IN HEADERS), so a list of two element lists leaves VALUE bound to a
list of one string, and the header goes on the wire as a parenthesised list.

X-OPENCODE-SESSION is the one header OpenCode Go needs that a generic OpenAI
client does not send. It is the routing key and the prompt cache key; without
it the service answers MissingSessionID and a turn costs a full cold prompt.
A generic OpenAI server ignores it. The user agent names this project rather
than dexador, which is what the service asks validated clients to do.

No :FORCE-BINARY. A chat completions reply is JSON text and dexador decodes it
using the charset the reply names, which is the only decoding that is correct
for a reply that is not ASCII. Forcing binary returns a vector of octets
instead, and the first thing that touches the reply is PARSE-JSON, which wants
a string: the error path fails while reporting the error, and the report is a
vector of numbers.

:BEARER-AUTH rather than a hand built header, so that the one place a key is
read and the one place it is formatted are not two different places."
  (dexador:request
   (concatenate 'string base-url path)
   :method :post
   :bearer-auth api-key
   :headers (list (cons :content-type "application/json")
                  (cons :user-agent "enchiridion/0.1.0")
                  (cons :x-opencode-session session-id))
   :content body
   :read-timeout timeout
   :connect-timeout timeout))

;; The transport is a special so a test can replace it without a network. That
;; is also the only way to test the retry path, because the retry path is about
;; what happens between two calls and not about what a provider says.
(defparameter *http-post-function* #'http-post
  "The function SEND-COMPLETION uses to make one HTTP request. Bound in tests.")

(defparameter *retry-delay* 2
  "The base delay in seconds for a retry. Attempt N waits N times this. Bound
to 0 in tests so a retry test does not spend six seconds asleep.")

(defun send-completion (connection messages model &key tools)
  "Return the COMPLETION for MESSAGES from CONNECTION using MODEL.

429 and 5xx are repeated with a growing gap, because they are the two the same
request is worth sending again. Everything else in the 4xx range is reported
at once: a wrong key or a wrong model does not become right by being
repeated.

There is no loop inside the handler. The handler returns after it sleeps, the
body of the outer loop ends, and the outer loop runs again. An inner (loop)
would be a new infinite loop and a 429 would hang the process instead of
retrying the request."
  (let ((body (completion-request model messages :tools tools))
        (attempt 0))
    (loop
      (handler-case
          (return (parse-completion
                   (parse-json (funcall *http-post-function*
                                        (openai-connection-base-url connection)
                                        "chat/completions"
                                        body
                                        (openai-connection-api-key connection)
                                        (openai-connection-timeout connection)
                                        (openai-connection-session-id connection)))))
        (dexador.error:http-request-failed (failure)
          (let ((status (dexador.error:response-status failure)))
            (if (and (integerp status)
                     (or (= status 429) (>= status 500))
                     (< attempt (openai-connection-retries connection)))
                (progn (incf attempt)
                       (sleep (* *retry-delay* attempt)))
                (error 'enchiridion.errors:transport-error
                       :status status
                       :detail (format nil "~D after ~D attempt~:P: ~A"
                                       status
                                       (1+ attempt)
                                       (provider-error-message
                                        (dexador.error:response-body failure)))))))))))

;;;; The operations.
;;;;
;;;; Last, because COMPLETE is a call into SEND-COMPLETION and a DEFMETHOD that
;;;; calls a name the compiler has not seen yet compiles into a variable
;;;; reference and fails at run time.

(defmethod backend-name ((connection openai-connection))
  "Return a short name for this backend."
  (format nil "openai (~A)" (openai-connection-base-url connection)))

(defmethod model-capabilities ((connection openai-connection))
  "Return what this backend's models support.

  :cache             the provider reports cached prompt tokens
  :cache-breakpoints an explicit cache breakpoint is accepted in the request
  :tools             tool calling is available
  :streaming         a stream can be requested, and is not used here

:CACHE-BREAKPOINTS is nil because nothing in this milestone sends one. It is
reported as absent rather than as present-and-ignored so that nothing above
has to guess whether the feature is real."
  (declare (ignore connection))
  '(:tools t :streaming t :cache t :cache-breakpoints nil))

(defmethod complete ((connection openai-connection) messages
                     &key model tools budget)
  "Continue MESSAGES and return the COMPLETION.

TOOLS is ignored: this milestone has no tool registry and the OpenAI request
shape is built without it. That is recorded by ignoring the argument out loud
rather than by omitting it from the signature, because omitting it would mean a
signature change the moment tools arrive."
  (declare (ignore budget))
  (send-completion connection messages (or model (openai-connection-model connection))
                   :tools tools))

;;;; Providers.
;;;;
;;;; The wire protocol is :OPENAI for both providers. The provider chooses the
;;;; endpoint, the default reasoning model, and the name of the key variable.
;;;; OpenAI is the default. A key that the environment or .env supplies selects
;;;; the other provider. An explicit :PROVIDER or a recognized :BASE-URL in
;;;; config.cl wins over both.

(defparameter +provider-defaults+
  '(:openai
    (:base-url "https://api.openai.com/v1/"
     :model "gpt-5.6-luna"
     :api-key-env "OPENAI_API_KEY")
    :opencode
    (:base-url "https://opencode.ai/zen/go/v1"
     :model "space-bunny"
     :api-key-env "OPENCODE_API_KEY"))
  "Provider name to the endpoint, default model, and key variable it uses.
Both speak the OpenAI chat completions shape; only these three facts differ.")

(declaim (ftype (function (t) list) provider-properties))

(defun provider-properties (provider)
  "Return the plist for PROVIDER, falling back to the OpenAI entry."
  (or (getf +provider-defaults+ provider)
      (getf +provider-defaults+ :openai)))

(declaim (ftype (function (t) (or null keyword)) normalize-provider))

(defun normalize-provider (name)
  "Return NAME as :OPENAI or :OPENCODE, or NIL when it is neither."
  (when name
    (let ((keyword (intern (string-upcase (string name)) :keyword)))
      (when (member keyword '(:openai :opencode))
        keyword))))

(declaim (ftype (function (t) (or null keyword)) provider-from-base-url))

(defun provider-from-base-url (url)
  "Return the provider URL names, or NIL for a server that is neither.
A local OpenAI-compatible server is neither, and its config still works: the
base URL is used as written and the key variable comes from detection."
  (when (stringp url)
    (cond
      ((search "opencode.ai" url) :opencode)
      ((search "api.openai.com" url) :openai)
      (t nil))))

(declaim (ftype (function (string) boolean) provider-key-present-p))

(defun provider-key-present-p (name)
  "Return T when NAME is in the environment or the secret loader holds it.
The loader runs before this in the CLI, so a key in .env selects a provider
the same way an exported variable does."
  (or (enchiridion.compat:environment-bound-p name)
      (enchiridion.llm.secrets:secret-present-p name)))

(declaim (ftype (function (&optional t) keyword) detect-provider))

(defun detect-provider (&optional config)
  "Return the provider CONFIG asks for, or the one the keys select.
The order is explicit config, a recognized base URL, an OpenAI key, an
OpenCode key, then OpenAI. OpenAI wins a tie because it is the default."
  (or (normalize-provider (enchiridion:config-value config :provider))
      (provider-from-base-url (enchiridion:config-value config :base-url))
      (and (provider-key-present-p "OPENAI_API_KEY") :openai)
      (and (provider-key-present-p "OPENCODE_API_KEY") :opencode)
      :openai))

(declaim (ftype (function (&optional t) string) default-api-key-env))

(defun default-api-key-env (&optional config)
  "Return the name of the variable that holds the key for the active provider.
An explicit :API-KEY-ENV in config wins; otherwise the provider decides."
  (or (enchiridion:config-value config :api-key-env)
      (getf (provider-properties (detect-provider config)) :api-key-env)))

;;;; Resolution.

;; No F-TYPE on RESOLVE-BACKEND, which is a choice rather than an oversight.
;; It is the one function here with &KEY arguments, and SBCL wants every keyword
;; used in an F-TYPE lambda list to have been declared in one already, which
;; means a dummy declaration per keyword for a function that is three lines
;; long. The cost of the annotation is larger than what it would catch.

(defun resolve-backend (&key (config nil) (api-key nil) (base-url nil))
  "Return the BACKEND that CONFIG asks for.

CONFIG is a plist as config.cl holds it. An explicit :BASE-URL, :MODEL-PRIMARY,
or :API-KEY-ENV wins. When one is absent, DETECT-PROVIDER chooses between
OpenAI and OpenCode Go from the config, a recognized base URL, or the keys the
environment and .env supplied.

CASE and not ECASE. ECASE is the better construct here in principle, because it
refuses to run if a backend is added without a clause here, but SBCL 2.5.4
gives ECASE no default clause: a clause headed by T is a clause about the
symbol T, so an unknown backend comes back as CASE-FAILURE listing (:OPENAI T)
rather than as the configuration error the operator needs. TIER has the same
shape for the same reason.

The T clause exists so that a typo in a config key is named rather than
reported as a missing function."
  (let* ((config (or config '()))
         (provider (detect-provider config))
         (properties (provider-properties provider))
         (backend (enchiridion:config-value config :backend :openai))
         (url (or base-url
                  (enchiridion:config-value config :base-url)
                  (getf properties :base-url)))
         (model (or (enchiridion:config-value config :model-primary)
                    (getf properties :model)))
         (key (or api-key (backend-api-key config backend))))
    (case backend
      (:openai (openai-backend :base-url url
                               :api-key key
                               :model model))
      (t
       (error 'enchiridion.errors:configuration-error
              :key :backend
              :detail (format nil "No backend for ~S. Only :OPENAI is written."
                              backend))))))

(defun backend-api-key (config backend)
  "Return the API key for BACKEND, from CONFIG, .env, or the environment.

The name of the variable comes from the active provider. The value is looked up
in the secret loader first, because .env is not the process environment and
the provider detection already saw the registered keys there."
  (declare (ignore backend))
  (let ((variable (default-api-key-env config)))
    (or (enchiridion.llm.secrets:secret-value variable)
        (enchiridion.compat:environment-value variable))))
