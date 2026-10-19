;;;; openai.cl --- The OpenAI chat completions handler.
;;;;
;;;; One adapter covers OpenAI, OpenCode Go, Azure, OpenRouter, Groq and the
;;;; long tail that speaks the chat completions shape. What differs between
;;;; them is a DIALECT --- an auth header, a base path, a body field name ---
;;;; and a dialect is data (see dialects.cl), not a branch in this file.
;;;;
;;;; The request and the response are separated from the transport on purpose:
;;;; COMPLETION-REQUEST and PARSE-COMPLETION are pure functions over text and
;;;; data, so the whole wire format is testable without a network, a key, or a
;;;; provider. The only part that needs any of those is the transport, and it
;;;; lives in http.cl now, not here.
;;;;
;;;; The handler registers itself as :OPENAI-CHAT at the bottom of the file.
;;;; The provider table resolves a provider to this file through the registry
;;;; and never names OpenAI: BUILD-OPENAI-PROVIDER receives an already resolved
;;;; PROVIDER record (endpoint, key, model, profile, headers, options) and
;;;; returns a BACKEND.
;;;;
;;;; The file is in dependency order, bottom to top, and it has to be. A name
;;;; used before it is defined is not a forward declaration in Lisp: the
;;;; compiler reads a symbol it has never seen as a variable, and the failure
;;;; surfaces at run time as UNBOUND-VARIABLE from a function that plainly
;;;; exists. The same trap closed in on the backend's own DEFMETHOD, which is
;;;; why COMPLETE is defined after SEND-COMPLETION rather than with the other
;;;; methods at the top, and it is why the registration is the last form here.

(in-package #:enchiridion.llm)

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
;;
;; headers are the operator's extra headers and dialect is the resolved quirk
;; record; both are already merged by the provider table, so this handler never
;; reads the configuration. A connection with a NIL dialect behaves exactly
;; like the generic OpenAI wire, which is what every existing test relies on.
;;
;; max-tokens is the reply cap. NIL omits the field, which is what the generic
;; wire did before this slot existed and what a provider with no configured cap
;; still does; when it is set, the dialect decides which of the two spellings
;; the provider accepts.
(defstruct (openai-connection (:constructor %make-connection))
  (:base-url "https://api.openai.com/v1/" :type string)
  (:api-key "" :type string)
  (:model "" :type string)
  (:session-id "" :type string)
  (:headers '() :type list)
  (:dialect nil :type t)
  (:max-tokens nil :type (or null (integer 1 *)))
  (:timeout 60 :type (integer 1 *))
  (:retries 2 :type (integer 0 *)))

(defun openai-backend (&key (base-url "https://api.openai.com/v1/")
                             api-key
                             (model nil)
                             (session-id nil)
                             (headers '())
                             (dialect nil)
                             (max-tokens nil)
                             (timeout 60)
                             (retries 2))
  "Return a BACKEND that speaks the OpenAI chat completions shape.

BASE-URL gains a trailing slash when it lacks one, because every path is
appended to it and a missing slash silently turns /v1 into a host named v1.
SESSION-ID is generated when it is absent; one backend is one conversation.
DIALECT is the resolved quirk record from dialects.cl; NIL means the generic
wire, which is what a provider with no profile gets. MAX-TOKENS is the reply
cap the dialect names the field for; NIL sends no cap."
  (%make-connection
   :base-url (ensure-trailing-slash base-url)
   :api-key (or api-key "")
   :model (or model (primary-model))
   :session-id (or session-id (new-session-id))
   :headers headers
   :dialect dialect
   :max-tokens max-tokens
   :timeout timeout
   :retries retries))

;;;; Shared dialect helpers.
;;;;
;;;; A dialect is a record of overrides on top of the generic wire, and the
;;;; generic wire is a NIL dialect. DIALECT-FIELD cannot be asked for a boolean
;;;; with a T default: it answers its default for a slot that holds NIL, and
;;;; NIL is exactly what a profile writes to switch a switch off
;;;; (:openai-local has no tool_choice to send). So the helpers below read the
;;;; slot with a NIL default whenever a dialect exists and fall back to the
;;;; generic truth when there is none.

(declaim (ftype (function (t t) string) dialect-path-with-model))

(defun dialect-path-with-model (path model)
  "Return PATH with every {model} replaced by MODEL.

Azure's deployment path names the model inside the path, and a proxy's prefix
may do the same, so the substitution belongs to the path and not to a branch in
a handler. A path that does not carry the placeholder comes back unchanged."
  (loop with result = (make-string-output-stream)
        with start = 0
        for position = (search "{model}" path :start2 start)
        while position
        do (write-string path result :start start :end position)
           (write-string model result)
           (setf start (+ position (length "{model}")))
        finally (write-string path result :start start)
                (return (get-output-stream-string result))))

(declaim (ftype (function (t) t) plist-as-json-object))

(defun plist-as-json-object (value)
  "Return VALUE with every plist in it turned into a JSON object.

STRINGIFY writes a plist as an ARRAY of alternating keys and values, which is
the wrong shape for a vendor's extra request field and for tool arguments that
arrived as a JSON object and were read back as a plist. Hash tables, strings,
numbers and T are already what the writer wants and are returned untouched.
A plist is the only nested shape a dialect carries, and it is either a field
list or an argument object; an array would have arrived as a JSON array, which
PARSE-JSON also turns into a list, so this function treats a bare list as the
key/value pair list the writer is about to be handed."
  (cond
    ((hash-table-p value) value)
    ((consp value)
     (apply #'json-object
            (loop for (key item) on value by #'cddr
                  append (list key (plist-as-json-object item)))))
    (t value)))

(declaim (ftype (function (t) string) openai-max-tokens-key))

(defun openai-max-tokens-key (dialect)
  "Return the body key DIALECT wants the reply cap written under.

The two spellings are not interchangeable: a provider that wants
max_completion_tokens rejects max_tokens, and the other way round. Only the
named one is written, and no cap writes neither."
  (if (eq (dialect-field dialect :max-tokens-field :max-tokens)
          :max-completion-tokens)
      "max_completion_tokens"
      "max_tokens"))

;; The name is not DIALECT-EXTRA-BODY: that is the accessor the EXTRA-BODY slot
;; already generates in dialects.cl, and a function that takes it over is a
;; redefinition warning, which this system makes an error.
(declaim (ftype (function (t) list) dialect-extra-body-fields))

(defun dialect-extra-body-fields (dialect)
  "Return DIALECT's extra request fields as (NAME . VALUE) pairs.

The profile carries them as a plist of keywords and the wire wants JSON names,
so the key is downcased here. A nested plist becomes an object rather than the
array of alternating keys the JSON writer would otherwise produce for it."
  (let ((fields (dialect-field dialect :extra-body '())))
    (loop for (key value) on fields by #'cddr
          collect (cons (string-downcase (string key))
                        (plist-as-json-object value)))))

(declaim (ftype (function (list) list) dialect-query-param-pairs))

(defun dialect-query-param-pairs (parameters)
  "Return PARAMETERS as proper (NAME . VALUE) pairs.

A profile spells a parameter as a two element list --- (\"api-version\"
\"2024-06-01\") --- and URL-WITH-QUERY walks its list with (LOOP FOR (NAME .
VALUE) IN ...), which reads the second element of a two element list as a one
element list and writes the query string as api-version=(2024-06-01). One
function turns every spelling into the cons that walker wants, and it is called
where the dialect is built so no handler has to remember to."
  (loop for entry in parameters
        collect (cond ((not (consp entry)) entry)
                      ((consp (cdr entry)) (cons (car entry) (cadr entry)))
                      (t entry))))

(declaim (ftype (function (t) t) normalize-dialect-query-params))

(defun normalize-dialect-query-params (dialect)
  "Return DIALECT with every query parameter a proper (NAME . VALUE) pair.

This is called wherever a dialect is about to be handed to AUTH-APPLY, because
a profile spells a parameter as a two element list and the one appender reads a
parameter as a cons. It is idempotent, so a dialect a provider builder already
normalised costs nothing here, and a NIL dialect --- the generic wire --- is
returned untouched."
  (when dialect
    (setf (dialect-query-params dialect)
          (dialect-query-param-pairs (dialect-query-params dialect))))
  dialect)

(declaim (ftype (function (t t) t) openai-field-value))

(defun openai-field-value (data path)
  "Return the value PATH names inside DATA, or NIL when it is absent.

PATH is a field name or several of them joined with dots, because one provider
reports a cached token count inside a nested object
(prompt_tokens_details.cached_tokens) and another reports the same number at
the top level under a name of its own (prompt_cache_hit_tokens). DATA is the
plist shape PARSE-JSON produces; a hash table, as jzon produced it, is accepted
too, so a caller that reads a reply with either parser can share this."
  (when (and data path (stringp path) (plusp (length path)))
    (let ((node data)
          (start 0))
      (loop
        (let* ((dot (position #\. path :start start))
               (name (subseq path start dot)))
          (setf node (if (hash-table-p node)
                         (json-value node name)
                         (and (listp node) (getf node (json-key name)))))
          (unless dot (return node))
          (setf start (1+ dot)))))))

;;;; Headers.
;;;;
;;;; The credential is not built here. AUTH-APPLY writes it, so a bearer token,
;;;; Azure's api-key header, a query parameter and a signature all take one
;;;; path, and a provider that replaces a header does so through one merge.

(declaim (ftype (function (&optional list) list) openai-static-headers))

(defun openai-static-headers (&optional extra)
  "Return the chat completions headers that are not the credential.

The content type and the user agent are the same on every provider, and they
live here so the chat request and the model lister cannot disagree about them.
EXTRA is merged last, which is what lets a provider replace either one."
  (merge-headers
   (list (cons :content-type "application/json")
         (cons :user-agent "enchiridion/0.1.0"))
   extra))

(declaim (ftype (function (string &optional list) list) openai-headers))

(defun openai-headers (session-id &optional extra)
  "Return the headers one chat completions request carries.

X-OPENCODE-SESSION is the one header OpenCode Go needs that a generic OpenAI
client does not send: it is the routing key and the prompt cache key, and a
generic server ignores it. The credential is added by AUTH-APPLY after this
list exists, because where it belongs depends on the scheme."
  (merge-headers
   (openai-static-headers)
   (cons (cons :x-opencode-session session-id) extra)))

;;;; The request.
;;;;
;;;; The shape is the one every OpenAI-compatible server accepts:
;;;;
;;;;   {"model": "...", "messages": [{"role": "user", "content": "hi"}]}
;;;;
;;;; A tool call id rides along on a tool message because the provider matches
;;;; results to calls by id, and a result whose id is missing or wrong is
;;;; answered with an error rather than with a guess.

(declaim (ftype (function (t) hash-table) tool-call->request))

(defun tool-call->request (call)
  "Return CALL as the assistant tool_calls object a provider accepts."
  (json-object :id (tool-call-id call)
               :type "function"
               :function (json-object :name (tool-call-name call)
                                      :arguments (tool-call-arguments call))))

(declaim (ftype (function (t) t) normalize-tool-arguments))

(defun normalize-tool-arguments (arguments)
  "Return a tool call's arguments as the JSON text the tool layer validates.

Three shapes arrive in practice and all three become text. A provider that
follows the specification sends a JSON string and it is passed through
unchanged, because parsing and re-writing it could only change it. A provider
that sends the arguments as an object arrives here either as a plist (this
tree's PARSE-JSON turned the object into one) or as a jzon hash table, and
either is written back as the object it was. An absent field and the empty
string become an empty object: a tool that takes no arguments is a real thing,
and the tool layer can index {} without a special case."
  (cond
    ((null arguments) "{}")
    ((eq arguments +json-null+) "{}")
    ((stringp arguments) (if (plusp (length arguments)) arguments "{}"))
    ((hash-table-p arguments) (stringify arguments))
    ((consp arguments) (stringify (plist-as-json-object arguments)))
    (t (stringify arguments))))

(declaim (ftype (function (message &optional t) hash-table)
                message->request-message))

(defun message->request-message (message &optional dialect)
  "Return MESSAGE as the request object.

A tool message carries its call id; an assistant message carries its tool calls
when it asked for any. Every other message does not carry either key, because
some servers reject an unexpected field rather than ignoring it.

DIALECT may rename the system role: OpenAI's reasoning models took the
developer role where the system role used to be, and the profile that serves
them says so."
  (let ((pairs (list :role (if (string= "system" (message-role message))
                               (dialect-field dialect :system-role "system")
                               (message-role message))
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

(declaim (ftype (function (hash-table) hash-table) tool-definition->request))

(defun tool-definition->request (definition)
  "Wrap one registry function object as an OpenAI tool definition."
  (json-object :type "function" :function definition))

(defun openai-request-body (model messages &key tools dialect max-tokens stream)
  "Return the request body for MODEL continuing MESSAGES as data.

The data shape and not text, because a dialect may need to rewrite a field
before the body is written, and because the Bedrock and Vertex paths that share
this builder stringify once at the end.

DIALECT decides the system role, the name of the reply cap, which of the three
optional fields are sent at all, and which extra fields are merged in. STREAM
is NIL for every request this tree makes today: it exists so that a caller that
does ask for a stream gets the stream_options field, which is legal only beside
\"stream\": true, and only from a provider whose profile accepts it."
  (flet ((flag (key)
           ;; The raw slot answers a boolean, and the generic wire answers T
           ;; when there is no dialect at all. See the note above the shared
           ;; helpers for why the default cannot be passed to DIALECT-FIELD.
           (if dialect (dialect-field dialect key nil) t)))
    (let ((body (json-object
                 :model model
                 :stream (if stream t nil)
                 :messages (map 'list
                                (lambda (message)
                                  (message->request-message message dialect))
                                messages))))
      (when (and max-tokens (integerp max-tokens) (plusp max-tokens))
        (setf (gethash (openai-max-tokens-key dialect) body) max-tokens))
      (when tools
        (setf (gethash "tools" body)
              (map 'list #'tool-definition->request tools))
        (when (flag :send-tool-choice-p)
          (setf (gethash "tool_choice" body) "auto"))
        (when (flag :send-parallel-tool-calls-p)
          (setf (gethash "parallel_tool_calls" body) t)))
      (when (and stream (flag :send-stream-options-p))
        (setf (gethash "stream_options" body) (json-object :include_usage t)))
      (loop for (name . value) in (dialect-extra-body-fields dialect)
            do (setf (gethash name body) value))
      body)))

(defun completion-request (model messages &key tools dialect max-tokens stream)
  "Return the request body for MODEL continuing MESSAGES, as JSON text.

#'MESSAGE->REQUEST-MESSAGE is reached through the LAMBDA above and not by a
bare symbol: MAP evaluates its function argument as a value, so a bare symbol
there is a variable reference and the failure arrives at run time as
UNBOUND-VARIABLE from a function that is plainly defined."
  (stringify (openai-request-body model messages
                                  :tools tools
                                  :dialect dialect
                                  :max-tokens max-tokens
                                  :stream stream)))

;;;; The reply.

(declaim (ftype (function (t) list) parse-tool-calls))

(defun parse-tool-calls (reply)
  "Return the tool calls in REPLY, a request message read from the wire.

Arguments are normalised to JSON text whichever of the three shapes the
provider sent, because the tool layer and the TOOL-CALL store hold text and
nothing above them wants to know that some servers send an object."
  (loop for call in (getf reply :tool_calls)
        when call
        collect (%make-tool-call
                 :id (or (getf call :id) "")
                 :name (or (getf (getf call :function) :name) "")
                 :arguments (normalize-tool-arguments
                             (getf (getf call :function) :arguments)))))

(defun parse-completion (data &key dialect)
  "Return the COMPLETION described by DATA, which is the parsed JSON object a
chat completions reply carries.

Signals rather than returning an empty completion when the reply has no
choices. An empty completion is indistinguishable from a model that said
nothing, and that is the one failure the agent cannot recover from on its own.

DIALECT decides where the chain of thought is read from and which fields carry
the token counts. Reasoning is stored apart from the reply text and is never
concatenated into it: a caller that showed TEXT to the operator would be
showing the model's private notes as its answer."
  (let ((choices (getf data :choices)))
    (unless (and (listp choices) (plusp (length choices)))
      (error 'enchiridion.errors:backend-error
             :backend "openai"
             :detail (format nil "The reply carried no choices: ~S"
                             (getf data :error))))
    (let* ((choice (first choices))
           (reply (getf choice :message))
           (usage (getf data :usage))
           (reasoning-field (dialect-field dialect :reasoning-field nil))
           (reasoning (and reasoning-field
                           (or (openai-field-value reply reasoning-field)
                               (openai-field-value data reasoning-field)))))
      (%make-completion
       :text (or (getf reply :content) "")
       :reasoning-text (if (stringp reasoning) reasoning "")
       :tool-calls (parse-tool-calls reply)
       :model (or (getf data :model) "")
       :stop-reason (or (getf choice :finish_reason) "")
       :input-tokens (json-count
                      (openai-field-value
                       usage
                       (dialect-field dialect :input-tokens-field
                                      "prompt_tokens")))
       :output-tokens (json-count
                       (openai-field-value
                        usage
                        (dialect-field dialect :output-tokens-field
                                       "completion_tokens")))
       ;; A provider that reports cached tokens as a field of its own rather
       ;; than inside prompt_tokens_details still has to be counted, or the
       ;; ledger says every turn cost full price.
       :cache-read-tokens (json-count
                           (openai-field-value
                            usage
                            (dialect-field dialect :cache-read-tokens-field
                                           "prompt_tokens_details.cached_tokens")))
       :cache-write-tokens (json-count
                            (openai-field-value
                             usage
                             (dialect-field dialect :cache-write-tokens-field
                                            "cache_creation_input_tokens")))))))

;;;; The transport.

(defun send-completion (connection messages model &key tools)
  "Return the COMPLETION for MESSAGES from CONNECTION using MODEL.

The URL is the connection's base URL and the dialect's chat path, with {model}
replaced by MODEL: Azure's deployment path and a proxy's prefix are data and
not a branch. The credential is applied last, to the finished request, because
a signed scheme has to see the body and the URL before it can sign them, and
because that is the one call every scheme shares.

The reply is parsed after POST-WITH-RETRIES returns, not inside it: a 200 that
carries something PARSE-JSON cannot read is not a transport failure and is not
retried, and the retry loop stays a loop over one HTTP call."
  (let* ((dialect (normalize-dialect-query-params
                   (openai-connection-dialect connection)))
         (url (concatenate 'string
                           (openai-connection-base-url connection)
                           (dialect-path-with-model
                            (dialect-field dialect :chat-path
                                           "chat/completions")
                            model)))
         (body (completion-request model messages
                                   :tools tools
                                   :dialect dialect
                                   :max-tokens (openai-connection-max-tokens
                                                connection)))
         (request (make-http-request
                   :url url
                   :body body
                   :timeout (openai-connection-timeout connection))))
    (parse-completion
     (parse-json
      (post-with-retries
       *http-post-function*
       (auth-apply dialect
                   (openai-connection-api-key connection)
                   request
                   :extra (openai-headers
                           (openai-connection-session-id connection)
                           (openai-connection-headers connection)))
       (openai-connection-retries connection)))
     :dialect dialect)))

;;;; The operations.
;;;;
;;;; Last of the operations, because COMPLETE is a call into SEND-COMPLETION
;;;; and a DEFMETHOD that calls a name the compiler has not seen yet compiles
;;;; into a variable reference and fails at run time.

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

BUDGET is ignored: the budget decides whether a turn starts, not how long a
reply may be, and the reply cap comes from the provider's own option."
  (declare (ignore budget))
  (send-completion connection messages
                   (or model (openai-connection-model connection))
                   :tools tools))

;;;; The adapter.
;;;;
;;;; The provider table hands over an already resolved PROVIDER: endpoint, key,
;;;; model, profile, headers and options. Everything vendor specific is either
;;;; in the row or in the dialect, and this section is the only place that
;;;; knows both a PROVIDER and this wire.

(declaim (ftype (function (provider) t) openai-dialect-for))

(defun openai-dialect-for (provider)
  "Return the resolved dialect for PROVIDER.

The provider's profile names the quirks and the row's :dialect-overrides
replaces any single field. The row's own :query-params are appended to the
profile's and every parameter is turned into a proper pair, because
AUTH-APPLY is the one place that appends a query string and a second appender
would drift from it."
  (let ((dialect (make-dialect-for
                  (provider-profile provider)
                  :protocol :openai
                  :overrides (provider-option provider :dialect-overrides))))
    (setf (dialect-query-params dialect)
          (dialect-query-param-pairs
           (append (dialect-query-params dialect)
                   (provider-query-params provider))))
    dialect))
(declaim (ftype (function (provider) t) build-openai-provider))

(defun build-openai-provider (provider)
  "Return the :OPENAI-CHAT backend PROVIDER describes.

The key is the resolved value and never the name of the variable that holds it,
so this function cannot print or re-read one. The model is the provider's
chosen one and falls back to its default; the backend replaces a missing one
with the primary tier."
  (openai-backend
   :base-url (provider-base-url provider)
   :api-key (provider-key provider)
   :model (or (provider-model provider) (provider-default-model provider))
   :headers (merge-headers (openai-static-headers) (provider-headers provider))
   :dialect (openai-dialect-for provider)
   :max-tokens (provider-option provider :max-tokens)))

;;;; The model list.

(declaim (ftype (function (t) string) openai-model-text))

(defun openai-model-text (value)
  "Return VALUE as a string, or the empty string when it is not one."
  (if (stringp value) value ""))

(declaim (ftype (function (t) (or null integer)) openai-model-count))

(defun openai-model-count (value)
  "Return VALUE as a positive count, or NIL when the source did not say.
NIL is not zero: a source that states no context window has not stated that the
window is empty."
  (if (and (integerp value) (plusp value)) value nil))

(declaim (ftype (function (t) (or null number)) openai-model-price))

(defun openai-model-price (value)
  "Return VALUE, a price models.dev already states per million tokens."
  (if (numberp value) value nil))

(declaim (ftype (function (t) (or null number)) openai-token-price))

(defun openai-token-price (value)
  "Return VALUE, a price stated per token, as USD per million tokens.

OpenRouter states its prices as strings of USD per token. The ledger keeps the
per-million figure and this is the one place the unit is converted. A string
that is not a number is an unknown price and not a zero one. READ is performed
with *READ-EVAL* bound to NIL, because the string comes from a provider and a
provider must not be able to run code in this process."
  (let ((number (typecase value
                  (number value)
                  (string (let ((*read-eval* nil))
                            (ignore-errors (read-from-string value))))
                  (t nil))))
    (if (numberp number) (* number 1000000) nil)))

(declaim (ftype (function (t t) model-info) openai-model-row))

(defun openai-model-row (entry shape)
  "Return ENTRY, one model of a listed provider, as a MODEL-INFO row.

The three list shapes carry different facts. :DATA is the generic list, whose
entries may add a context window and models.dev style flags. :OLLAMA names the
model under NAME. :OPENROUTER is the rich one: it states the context window,
the prices as USD-per-token strings, and which parameters --- tools, reasoning
--- the model accepts.

An entry that carries a pricing object or a supported_parameters array is read
as the rich shape even when the profile left the shape at its default, because
those two fields are what decide how the numbers and the flags are read, and a
profile that forgets to name the shape should not silently turn prices into
NIL."
  (let* ((ollama (eq shape :ollama))
         (rich (or (eq shape :openrouter)
                   (not (null (getf entry :supported_parameters)))
                   (not (null (getf entry :pricing)))))
         (parameters (getf entry :supported_parameters))
         (pricing (getf entry :pricing))
         (cost (getf entry :cost))
         (id (openai-model-text
              (if ollama
                  (or (getf entry :name) (getf entry :model))
                  (or (getf entry :id) (getf entry :name)))))
         (name (openai-model-text (getf entry :name))))
    (flet ((parameter-p (wanted)
             (and (listp parameters)
                  (member wanted parameters :test #'string=)
                  t)))
      (%make-model-info
       :id id
       :name (if (plusp (length name)) name id)
       :tool-call-p (if rich
                        (parameter-p "tools")
                        (not (null (or (getf entry :tool_call)
                                       (getf entry :supports_tools)))))
       :reasoning-p (if rich
                        (parameter-p "reasoning")
                        (not (null (getf entry :reasoning))))
       :context (openai-model-count (or (getf entry :context_length)
                                        (getf entry :context_window)
                                        (getf entry :context)))
       :output (openai-model-count (or (getf entry :max_output_tokens)
                                       (getf entry :output)))
       :cost-input (if rich
                       (openai-token-price (getf pricing :prompt))
                       (openai-model-price (getf cost :input)))
       :cost-output (if rich
                        (openai-token-price (getf pricing :completion))
                        (openai-model-price (getf cost :output)))
       :cost-cache-read (if rich
                            (openai-token-price
                             (getf pricing :input_cache_read))
                            (openai-model-price (getf cost :cache_read)))
       :cost-cache-write (if rich
                             (openai-token-price
                              (getf pricing :input_cache_write))
                             (openai-model-price (getf cost :cache_write)))
       :source :provider))))

(declaim (ftype (function (t t) t) openai-model-entries))

(defun openai-model-entries (payload shape)
  "Return the model entries PAYLOAD carries for SHAPE.

Ollama lists them under models, every other compatible endpoint under data.
Both keys are read here so a caller never has to branch on a vendor."
  (case shape
    (:ollama (getf payload :models))
    (t (getf payload :data))))

(declaim (ftype (function (t t) list) openai-model-infos))

(defun openai-model-infos (payload shape)
  "Return every model PAYLOAD lists, as MODEL-INFO rows.

An entry that is not an object is skipped rather than turned into a row of
empty strings: a malformed reply should cost the models it could not describe
and not the whole list."
  (let ((entries (openai-model-entries payload shape)))
    (if (and (listp entries) (every #'consp entries))
        (loop for entry in entries collect (openai-model-row entry shape))
        '())))

(declaim (ftype (function (provider) t) list-openai-models))

(defun list-openai-models (provider)
  "Return the MODEL-INFO rows PROVIDER's own endpoint reports.

The path and the shape are the dialect's. A profile that says it has no list
(a NIL shape) answers NIL rather than sending a request that can only fail.
The credential is applied with AUTH-APPLY for the same reason a chat request
is: a header, a query parameter and a signature are one code path, and the
model list must not be the one caller that forgets one of them."
  (let* ((dialect (openai-dialect-for provider))
         (shape (if dialect
                    (dialect-field dialect :models-list-shape nil)
                    :data))
         (path (dialect-field dialect :models-path "models")))
    (when (and shape path)
      (let* ((request (make-http-request
                       :url (concatenate
                             'string
                             (ensure-trailing-slash (provider-base-url provider))
                             path)))
             (authorized (auth-apply dialect (provider-key provider) request
                                     :extra (openai-static-headers))))
        (openai-model-infos
         (parse-json (funcall *http-get-function*
                              (http-request-url authorized)
                              :headers (http-request-headers authorized)))
         shape)))))

;;;; Registration.
;;;;
;;;; Last form in the file, and it has to be: it names the two functions above
;;;; with #', and a #' of a name the compiler has not seen is a warning.

(register-api-handler
 :openai-chat
 :schema :openai
 :build #'build-openai-provider
 :list-models #'list-openai-models
 :documentation
 "The OpenAI chat completions wire, dialect by dialect: OpenAI, OpenCode Go,
Azure, OpenRouter, Groq, Qwen, DeepSeek and any local server that speaks it.")
