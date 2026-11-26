;;;; openai.lsp --- OpenAI chat completions API handler.
;;;;
;;;; Pure request/response builders live separately from HTTP transport (http.lsp).
;;;; Provider differences are encoded as DIALECT data (dialects.lsp).
;;;; Registered as :OPENAI-CHAT at EOF.

(in-package #:enchiridion.llm)

;;;; The connection.

;; base-url always has a trailing slash. api-key is never logged.
;; session-id routes and caches conversations on OpenCode Go.
;; dialect NIL uses generic OpenAI wire defaults; max-tokens NIL omits the cap.
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
  "Return a BACKEND for the OpenAI chat completions API.
Ensures BASE-URL has a trailing slash, generates SESSION-ID if absent, and
uses generic OpenAI wire defaults when DIALECT is NIL."
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
;;;; For boolean switches where a dialect can explicitly set NIL (e.g. disabling
;;;; tool_choice), read with a NIL default when a dialect is present and fall
;;;; back to T only when DIALECT is NIL.

(declaim (ftype (function (t t) string) dialect-path-with-model))

(defun dialect-path-with-model (path model)
  "Return PATH with every {model} placeholder replaced by MODEL."
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
  "Recursively convert plists in VALUE to JSON hash tables.
Required because STRINGIFY serializes plists as JSON arrays, not objects."
  (cond
    ((hash-table-p value) value)
    ((consp value)
     (apply #'json-object
            (loop for (key item) on value by #'cddr
                  append (list key (plist-as-json-object item)))))
    (t value)))

(declaim (ftype (function (t) string) openai-max-tokens-key))

(defun openai-max-tokens-key (dialect)
  "Return the max-tokens body key for DIALECT (\"max_completion_tokens\" or \"max_tokens\")."
  (if (eq (dialect-field dialect :max-tokens-field :max-tokens)
          :max-completion-tokens)
      "max_completion_tokens"
      "max_tokens"))

;; Distinct from the DIALECT-EXTRA-BODY struct accessor in dialects.lsp.
(declaim (ftype (function (t) list) dialect-extra-body-fields))

(defun dialect-extra-body-fields (dialect)
  "Return DIALECT's extra request fields as (NAME . VALUE) pairs with downcased
JSON keys and nested plists converted to JSON objects."
  (let ((fields (dialect-field dialect :extra-body '())))
    (loop for (key value) on fields by #'cddr
          collect (cons (string-downcase (string key))
                        (plist-as-json-object value)))))

(declaim (ftype (function (list) list) dialect-query-param-pairs))

(defun dialect-query-param-pairs (parameters)
  "Normalize PARAMETERS from two-element lists into (NAME . VALUE) cons pairs
as expected by URL-WITH-QUERY."
  (loop for entry in parameters
        collect (cond ((not (consp entry)) entry)
                      ((consp (cdr entry)) (cons (car entry) (cadr entry)))
                      (t entry))))

(declaim (ftype (function (t) t) normalize-dialect-query-params))

(defun normalize-dialect-query-params (dialect)
  "Idempotently normalize DIALECT's query-params to (NAME . VALUE) cons pairs."
  (when dialect
    (setf (dialect-query-params dialect)
          (dialect-query-param-pairs (dialect-query-params dialect))))
  dialect)

(declaim (ftype (function (t t) t) openai-field-value))

(defun openai-field-value (data path)
  "Look up dot-separated PATH in plist or hash-table DATA, or return NIL.
Supports both nested fields (prompt_tokens_details.cached_tokens) and flat ones."
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

;;;; Headers. Credentials are applied later by AUTH-APPLY.

(declaim (ftype (function (&optional list) list) openai-static-headers))

(defun openai-static-headers (&optional extra)
  "Return non-credential OpenAI headers (Content-Type, User-Agent), with EXTRA merged last."
  (merge-headers
   (list (cons :content-type "application/json")
         (cons :user-agent "enchiridion/0.1.0"))
   extra))

(declaim (ftype (function (string &optional list) list) openai-headers))

(defun openai-headers (session-id &optional extra)
  "Return chat request headers including x-opencode-session, with EXTRA merged last."
  (merge-headers
   (openai-static-headers)
   (cons (cons :x-opencode-session session-id) extra)))

;;;; The request.

(declaim (ftype (function (t) hash-table) tool-call->request))

(defun tool-call->request (call)
  "Return CALL as the assistant tool_calls object a provider accepts."
  (json-object :id (tool-call-id call)
               :type "function"
               :function (json-object :name (tool-call-name call)
                                      :arguments (tool-call-arguments call))))

(declaim (ftype (function (t) t) normalize-tool-arguments))

(defun normalize-tool-arguments (arguments)
  "Normalize tool-call ARGUMENTS to a JSON string.
Passes non-empty strings through, serializes hash tables/plists as JSON objects,
and turns NIL, +JSON-NULL+, or empty strings into \"{}\"."
  (cond
    ((null arguments) "{}")
    ((eq arguments +json-null+) "{}")
    ((stringp arguments) (if (plusp (length arguments)) arguments "{}"))
    ((hash-table-p arguments) (stringify arguments))
    ((consp arguments) (stringify (plist-as-json-object arguments)))
    (t (stringify arguments))))

(declaim (ftype (function (message &optional t t) hash-table)
                message->request-message))

(defun message->request-message (message &optional dialect replay-p)
  "Return MESSAGE encoded for DIALECT. When REPLAY-P is true, replays
reasoning_content on assistant messages and sets empty tool-call content to null."
  (let* ((role (message-role message))
         (body (json-object :role (if (string= "system" role)
                                      (dialect-field dialect :system-role "system")
                                      role)
                            :content (message-content message))))
    (when (plusp (length (message-tool-call-id message)))
      (setf (gethash "tool_call_id" body) (message-tool-call-id message)))
    (when (message-tool-calls message)
      (setf (gethash "tool_calls" body)
            (mapcar #'tool-call->request (message-tool-calls message))))
    (when (and replay-p (string= "assistant" role))
      (setf (gethash "reasoning_content" body) (or (message-tool-reasoning message) ""))
      (when (and (message-tool-calls message) (zerop (length (message-content message))))
        (setf (gethash "content" body) +json-null+)))
    body))

(declaim (ftype (function (hash-table) hash-table) tool-definition->request))

(defun tool-definition->request (definition)
  "Wrap one registry function object as an OpenAI tool definition."
  (json-object :type "function" :function definition))

(defun openai-request-body (model messages &key tools dialect max-tokens stream replay-p)
  "Return the chat completions request body for MODEL and MESSAGES as a hash table.
Applies DIALECT overrides (system role, max-tokens key, tool/stream flags, extra
body fields) and reasoning replay when REPLAY-P is true."
  (flet ((flag (key)
           ;; Explicit NIL on a dialect overrides the generic T default.
           (if dialect (dialect-field dialect key nil) t)))
    (let ((body (json-object
                 :model model
                 :stream (if stream t nil)
                 :messages (map 'list
                                (lambda (message)
                                  (message->request-message message dialect replay-p))
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

(defun completion-request (model messages &key tools dialect max-tokens stream replay-p)
  "Return the request body for MODEL continuing MESSAGES, as JSON text."
  (stringify (openai-request-body model messages
                                  :tools tools
                                  :dialect dialect
                                  :max-tokens max-tokens
                                  :stream stream :replay-p replay-p)))

;;;; The reply.

(declaim (ftype (function (t) list) parse-tool-calls))

(defun parse-tool-calls (reply)
  "Parse tool_calls from REPLY, normalizing each call's arguments to a JSON string."
  (loop for call in (getf reply :tool_calls)
        when call
        collect (%make-tool-call
                 :id (or (getf call :id) "")
                 :name (or (getf (getf call :function) :name) "")
                 :arguments (normalize-tool-arguments
                             (getf (getf call :function) :arguments)))))

(defun parse-completion (data &key dialect replay-p)
  "Parse a chat completions JSON plist DATA into a COMPLETION.
Signals BACKEND-ERROR when choices are missing or when a thinking tool call
cannot be replayed. Keeps reasoning-text separate from reply text."
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
                               (openai-field-value data reasoning-field))))
           (wire-reasoning (getf reply :reasoning_content))
           (calls (getf reply :tool_calls))
           (tool-reasoning (and replay-p calls (stringp wire-reasoning) wire-reasoning)))
      (when (and calls (not tool-reasoning)
                 (or (and (stringp reasoning) (plusp (length reasoning)))
                     (and (stringp wire-reasoning) (plusp (length wire-reasoning)))))
        (error 'enchiridion.errors:backend-error
               :backend "openai"
               :detail "Thinking tool calls require reasoning replay. This OpenAI-compatible backend only replays reasoning for deepseek-v4.1-flash on OpenCode Go. Disable thinking or choose a nonthinking model."))
      (%make-completion
       :text (or (getf reply :content) "")
       :reasoning-text (if (and (not tool-reasoning) (stringp reasoning)) reasoning "")
       :tool-reasoning tool-reasoning
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
  "Send a chat completion request for MESSAGES to CONNECTION using MODEL.
Applies AUTH-APPLY last so signed schemes see the final URL and body.
Reasoning replay is enabled only for deepseek-v4.1-flash on OpenCode Go."
  (let* ((dialect (normalize-dialect-query-params
                   (openai-connection-dialect connection)))
         (replay-p (and (string= model "deepseek-v4.1-flash")
                        (member (openai-connection-base-url connection)
                                '("https://opencode.ai/zen/go/v1/"
                                  "https://opencode.ai/inference/go/v1/"
                                  "https://opencode.ai/inference/go/openai/v1/")
                                :test #'string=)))
         (url (concatenate 'string
                           (openai-connection-base-url connection)
                           (dialect-path-with-model
                            (dialect-field dialect :chat-path
                                           "chat/completions")
                            model)))
         (body (completion-request model messages
                                   :tools tools
                                   :dialect dialect
                                   :replay-p replay-p
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
     :dialect dialect :replay-p replay-p)))

;;;; The operations.

(defmethod backend-name ((connection openai-connection))
  "Return a short name for this backend."
  (format nil "openai (~A)" (openai-connection-base-url connection)))

(defmethod model-capabilities ((connection openai-connection))
  "Return capabilities plist for this backend (:cache-breakpoints is NIL because
OpenAI requests do not send explicit cache breakpoints)."
  (declare (ignore connection))
  '(:tools t :streaming t :cache t :cache-breakpoints nil))

(defmethod complete ((connection openai-connection) messages
                     &key model tools budget)
  "Continue MESSAGES and return a COMPLETION. BUDGET is ignored; max tokens comes
from the connection."
  (declare (ignore budget))
  (send-completion connection messages
                   (or model (openai-connection-model connection))
                   :tools tools))

;;;; Embeddings.

(defun embedding-request (model texts dimensions)
  "Return the JSON body of one embeddings request."
  (let ((body (make-hash-table :test #'equal)))
    (setf (gethash "model" body) model
          (gethash "input" body) (coerce texts 'vector))
    (when (integerp dimensions)
      (setf (gethash "dimensions" body) dimensions))
    (com.inuoe.jzon:stringify body)))

(defun parse-embeddings (data count)
  "Return the COUNT vectors in DATA, an embeddings reply, ordered by index."
  (let ((out (make-array count :initial-element nil)))
    (dolist (entry (getf data :data))
      (let ((index (getf entry :index))
            (values (getf entry :embedding)))
        (when (and (integerp index) (< -1 index count))
          (setf (aref out index)
                (map '(simple-array single-float (*))
                     (lambda (x) (coerce x 'single-float))
                     values)))))
    (when (some #'null out)
      (error 'enchiridion.errors:backend-error
             :backend "openai"
             :detail (format nil "The embeddings reply returned ~D of ~D vectors."
                             (count-if-not #'null out) count)))
    (coerce out 'list)))

(defmethod embed ((connection openai-connection) texts &key model dimensions)
  "Embed TEXTS through the connection's embeddings endpoint."
  (if (null texts)
      '()
      (let* ((dialect (openai-connection-dialect connection))
             (request (make-http-request
                       :url (concatenate 'string
                                         (openai-connection-base-url connection)
                                         "embeddings")
                       :body (embedding-request model texts dimensions)
                       :timeout (openai-connection-timeout connection))))
        (parse-embeddings
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
         (length texts)))))

;;;; The adapter.

(declaim (ftype (function (provider) t) openai-dialect-for))

(defun openai-dialect-for (provider)
  "Resolve PROVIDER's dialect with :dialect-overrides and normalized query params."
  (let ((dialect (make-dialect-for
                  (provider-profile provider)
                  :protocol :openai
                  :overrides (provider-option provider :dialect-overrides))))
    (setf (dialect-query-params dialect)
          (dialect-query-param-pairs
           (merge-query-params (dialect-query-params dialect)
                               (provider-query-params provider))))
    dialect))
(declaim (ftype (function (provider) t) build-openai-provider))

(defun build-openai-provider (provider)
  "Construct an :OPENAI-CHAT backend from resolved PROVIDER."
  (openai-backend
   :base-url (provider-base-url provider)
   :api-key (provider-key provider)
   :model (or (provider-model provider) (provider-default-model provider))
   :headers (merge-headers (openai-static-headers) (provider-headers provider))
   :dialect (openai-dialect-for provider)
   :max-tokens (provider-option provider :max-tokens)
   :timeout (provider-option provider :timeout 60)
   :retries (provider-option provider :retries 2)))

;;;; The model list.

(declaim (ftype (function (t) string) openai-model-text))

(defun openai-model-text (value)
  "Return VALUE as a string, or the empty string when it is not one."
  (if (stringp value) value ""))

(declaim (ftype (function (t) (or null integer)) openai-model-count))

(defun openai-model-count (value)
  "Return VALUE if it is a positive integer, else NIL (unknown, not zero)."
  (if (and (integerp value) (plusp value)) value nil))

(declaim (ftype (function (t) (or null number)) openai-model-price))

(defun openai-model-price (value)
  "Return VALUE, a price models.dev already states per million tokens."
  (if (numberp value) value nil))

(declaim (ftype (function (t) (or null number)) openai-token-price))

(defun openai-token-price (value)
  "Convert per-token USD price VALUE (number or numeric string) to USD per
million tokens, or NIL if unparseable. Parses strings with *READ-EVAL* NIL."
  (let ((number (typecase value
                  (number value)
                  (string (let ((*read-eval* nil))
                            (ignore-errors (read-from-string value))))
                  (t nil))))
    (if (numberp number) (* number 1000000) nil)))

(declaim (ftype (function (t t) model-info) openai-model-row))

(defun openai-model-row (entry shape)
  "Convert one model list ENTRY into a MODEL-INFO for SHAPE (:DATA, :OLLAMA, :OPENROUTER).
Entries carrying :pricing or :supported_parameters use rich OpenRouter parsing."
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
  "Extract model entries from PAYLOAD (:models for :OLLAMA, :data otherwise)."
  (case shape
    (:ollama (getf payload :models))
    (t (getf payload :data))))

(declaim (ftype (function (t t) list) openai-model-infos))

(defun openai-model-infos (payload shape)
  "Convert model entries in PAYLOAD to MODEL-INFO rows, skipping malformed entries."
  (let ((entries (openai-model-entries payload shape)))
    (if (and (listp entries) (every #'consp entries))
        (loop for entry in entries collect (openai-model-row entry shape))
        '())))

(declaim (ftype (function (provider) t) list-openai-models))

(defun list-openai-models (provider)
  "Fetch MODEL-INFO rows from PROVIDER's models endpoint using its dialect path,
shape, and AUTH-APPLY. Returns NIL when the dialect has no models listing."
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
                             path)
                       :timeout (provider-option provider :timeout +http-get-timeout+)))
             (authorized (auth-apply dialect (provider-key provider) request
                                     :extra (merge-headers (openai-static-headers)
                                                            (provider-headers provider)))))
        (openai-model-infos
         (parse-json (get-with-retries
                      authorized (provider-option provider :retries 2)))
         shape)))))

;;;; Registration.

(register-api-handler
 :openai-chat
 :schema :openai
 :build #'build-openai-provider
 :list-models #'list-openai-models
 :documentation
 "The OpenAI chat completions wire, dialect by dialect: OpenAI, OpenCode Go,
Azure, OpenRouter, Groq, Qwen, DeepSeek and any local server that speaks it.")
