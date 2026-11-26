;;;; anthropic.lsp --- Anthropic Messages API handler.
;;;;
;;;; Pure request/response builders (shared by bedrock.lsp and vertex.lsp) live
;;;; separately from HTTP transport (http.lsp). Key wire differences from OpenAI:
;;;; top-level system array, tool_use input as JSON object, tool_result blocks
;;;; merged into user messages, required max_tokens, and block cache_control.

(in-package #:enchiridion.llm)

;;;; The connection.

;; base-url always has a trailing slash. api-key is never logged.
;; max-tokens is required by the Messages API. cache-p enables prefix breakpoints
;; on the last system and tool blocks; cache-ttl is "5m", "1h", or NIL (default).
(defstruct (anthropic-connection (:constructor %make-anthropic-connection))
  (:base-url "https://api.anthropic.com/" :type string)
  (:api-key "" :type string)
  (:model "" :type string)
  (:max-tokens 4096 :type (integer 1 *))
  (:cache-p t :type boolean)
  (:cache-ttl nil :type (or null string))
  (:headers '() :type list)
  (:dialect nil :type t)
  (:timeout 60 :type (integer 1 *))
  (:retries 2 :type (integer 0 *))
  (:betas '() :type list))

(defun anthropic-backend (&key (base-url "https://api.anthropic.com/")
                                api-key
                                (model nil)
                                (max-tokens 4096)
                                (cache-ttl nil)
                                (cache-p t)
                                (headers '())
                                (dialect nil)
                                (timeout 60)
                                (retries 2)
                                (betas '()))
  "Return a BACKEND for the Anthropic Messages API.
Ensures BASE-URL has a trailing slash, defaults MODEL to the primary tier,
and enables prompt-cache breakpoints when CACHE-P is true."
  (%make-anthropic-connection
   :base-url (ensure-trailing-slash base-url)
   :api-key (or api-key "")
   :model (or model (primary-model))
   :max-tokens max-tokens
   :cache-ttl cache-ttl
   :cache-p (not (null cache-p))
   :headers headers
   :dialect dialect
   :timeout timeout
   :retries retries
   :betas (beta-list betas)))

;; DEFPARAMETER avoids SBCL DEFCONSTANT string redefinition warnings.
(defparameter +anthropic-version+ "2023-06-01"
  "Default anthropic-version header value required by the Messages API.")

;;;; The request.
;;;;
;;;; Omit unused fields rather than setting NIL (STRINGIFY encodes NIL as false).

(declaim (ftype (function (&optional t) hash-table) anthropic-cache-control))

(defun anthropic-cache-control (&optional ttl)
  "Return an ephemeral cache_control object, with optional TTL (\"5m\" or \"1h\")."
  (if (and (stringp ttl) (plusp (length ttl)))
      (json-object :type "ephemeral" :ttl ttl)
      (json-object :type "ephemeral")))

(declaim (ftype (function (t) t) anthropic-tool-input))

(defun anthropic-tool-input (arguments)
  "Parse tool ARGUMENTS JSON string into a jzon hash table, or an empty object.
Uses COM.INUOE.JZON:PARSE directly (not PARSE-JSON) so tool_use input stays a
JSON object rather than a plist that STRINGIFY would emit as an array."
  (if (and (stringp arguments)
           (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                       arguments))))
      (com.inuoe.jzon:parse arguments)
      (make-hash-table :test #'equal)))

(declaim (ftype (function (string) hash-table) anthropic-text-block))

(defun anthropic-text-block (text)
  "Wrap TEXT as a {\"type\":\"text\"} block so it can carry cache_control."
  (json-object :type "text" :text text))

(declaim (ftype (function (tool-call) hash-table) anthropic-tool-use-block))

(defun anthropic-tool-use-block (call)
  "Return CALL as a tool_use content block with parsed JSON object input."
  (json-object :type "tool_use"
               :id (tool-call-id call)
               :name (tool-call-name call)
               :input (anthropic-tool-input (tool-call-arguments call))))

(declaim (ftype (function (message) hash-table) anthropic-tool-result-block))

(defun anthropic-tool-result-block (message)
  "Return tool MESSAGE as a tool_result content block matched by tool_use_id."
  (json-object :type "tool_result"
               :tool_use_id (message-tool-call-id message)
               :content (message-content message)))

(declaim (ftype (function (message) list) anthropic-message-blocks))

(defun anthropic-message-blocks (message)
  "Convert MESSAGE into content blocks. Assistant messages emit text then tool_use
blocks, falling back to an empty text block since the API rejects empty content."
  (let ((role (message-role message)))
    (cond
      ((string= role "tool")
       (list (anthropic-tool-result-block message)))
      ((string= role "assistant")
       (let ((blocks '()))
         (unless (zerop (length (message-content message)))
           (push (anthropic-text-block (message-content message)) blocks))
         (dolist (call (message-tool-calls message))
           (push (anthropic-tool-use-block call) blocks))
         (or (nreverse blocks)
             (list (anthropic-text-block "")))))
      (t (list (anthropic-text-block (message-content message)))))))

(declaim (ftype (function (list) list) anthropic-request-messages))

(defun anthropic-request-messages (messages)
  "Convert non-system MESSAGES into alternating wire messages.
Maps tool messages to user tool_result blocks and merges adjacent same-role
entries so consecutive tool results and follow-up text share one user message."
  (let ((entries '()))
    (dolist (message messages)
      (unless (string= "system" (message-role message))
        (let* ((role (if (string= "tool" (message-role message))
                         "user"
                         (message-role message)))
               (blocks (anthropic-message-blocks message))
               (current (first entries)))
          (if (and current (string= (car current) role))
              (setf (cdr current) (append (reverse blocks) (cdr current)))
              (push (cons role (reverse blocks)) entries)))))
    (loop for (role . blocks) in (nreverse entries)
          collect (json-object :role role :content (nreverse blocks)))))

(declaim (ftype (function (list boolean (or null string)) list)
                anthropic-system-blocks))

(defun anthropic-system-blocks (messages cache-p cache-ttl)
  "Join system MESSAGES into a single top-level system text block, or return NIL.
Uses an array block (not a bare string) so it can carry cache_control."
  (let ((text (format nil "~{~A~^~%~%~}"
                      (loop for message in messages
                            when (string= "system" (message-role message))
                            collect (message-content message)))))
    (when (plusp (length text))
      (let ((block (anthropic-text-block text)))
        (when cache-p
          (setf (gethash "cache_control" block)
                (anthropic-cache-control cache-ttl)))
        (list block)))))

(declaim (ftype (function (list boolean (or null string)) list)
                anthropic-tool-definitions))

(defun anthropic-tool-definitions (tools cache-p cache-ttl)
  "Convert registry tool definitions to Anthropic's flat shape (input_schema).
When CACHE-P is true, attaches cache_control to the final tool definition."
  (let ((last (1- (length tools))))
    (loop for tool in tools
          for index from 0
          for entry = (json-object :name (gethash "name" tool)
                                   :description (gethash "description" tool)
                                   :input_schema (gethash "parameters" tool))
          when (and cache-p (= index last))
            do (setf (gethash "cache_control" entry)
                     (anthropic-cache-control cache-ttl))
          collect entry)))

(defun anthropic-request-body (messages &key model tools max-tokens
                                            (cache-p t) cache-ttl
                                            (model-in-body-p t model-in-body-p-p)
                                            dialect betas)
  "Return the Messages API request body for MESSAGES as a hash table.
DIALECT controls whether model, anthropic_version, and anthropic_beta go in
the body (e.g. Bedrock/Vertex) and whether cache_control TTL is supported."
  (flet ((flag (key)
           ;; Explicit NIL on a dialect overrides the generic T default.
           (if dialect (dialect-field dialect key nil) t)))
    (let* ((model-in-body-p (if model-in-body-p-p
                                model-in-body-p
                                (flag :model-in-body-p)))
           (cache-ttl (if (flag :cache-ttl-supported-p) cache-ttl nil))
           (body (json-object
                  :max_tokens (or max-tokens 4096)
                  :messages (coerce (anthropic-request-messages messages)
                                    'vector)))
           (system (anthropic-system-blocks messages cache-p cache-ttl)))
      (when (eq (dialect-field dialect :version-location :header) :body)
        (setf (gethash "anthropic_version" body)
              (or (dialect-field dialect :version-value nil)
                  +anthropic-version+)))
      (when (and betas
                 (plusp (length betas))
                 (eq (dialect-field dialect :beta-channel :header) :body))
        (setf (gethash "anthropic_beta" body) (coerce betas 'vector)))
      (when model-in-body-p
        (setf (gethash "model" body) (or model "")))
      (when system
        (setf (gethash "system" body) system))
      (when tools
        (setf (gethash "tools" body)
              (anthropic-tool-definitions tools cache-p cache-ttl))
        (setf (gethash "tool_choice" body) (json-object :type "auto")))
      body)))

(defun anthropic-completion-request (connection messages &key tools model betas)
  "Serialize the Messages API request body for MESSAGES to JSON text.
Coerces messages to a vector so an empty list serializes as [] rather than false."
  (stringify (anthropic-request-body
              messages
              :model (or model (anthropic-connection-model connection))
              :tools tools
              :max-tokens (anthropic-connection-max-tokens connection)
              :cache-p (anthropic-connection-cache-p connection)
              :cache-ttl (anthropic-connection-cache-ttl connection)
              :dialect (anthropic-connection-dialect connection)
              :betas betas)))

;;;; The reply.
;;;;
;;;; Parses with jzon directly (not PARSE-JSON) to distinguish [] from null
;;;; and keep tool_use inputs as hash tables for re-serialization.

(declaim (ftype (function (t) string) anthropic-error-message))

(defun anthropic-error-message (data)
  "Extract error.message from reply DATA, or return the empty string."
  (let ((error-object (json-value data "error")))
    (if (hash-table-p error-object)
        (json-string (json-value error-object "message"))
        (json-string error-object))))

(declaim (ftype (function (t) string) anthropic-tool-arguments))

(defun anthropic-tool-arguments (input)
  "Serialize tool_use INPUT to JSON text.
Passes non-empty strings through and normalizes NIL, +JSON-NULL+, or \"\" to \"{}\"."
  (cond
    ((or (null input) (eq input +json-null+)) "{}")
    ((stringp input) (if (plusp (length input)) input "{}"))
    (t (stringify input))))

(declaim (ftype (function (t) string) anthropic-content-text))

(defun anthropic-content-text (content)
  "Concatenate all \"text\" blocks in CONTENT in order (or pass through a bare string)."
  (cond
    ((stringp content) content)
    ((vectorp content)
     (format nil "~{~A~}"
             (loop for block across content
                   for type = (json-value block "type")
                   when (and (stringp type) (string= type "text"))
                     collect (json-string (json-value block "text")))))
    (t "")))

(declaim (ftype (function (t) string) anthropic-reasoning-text))

(defun anthropic-reasoning-text (content)
  "Concatenate all \"thinking\" and \"redacted_thinking\" blocks in CONTENT."
  (if (vectorp content)
      (format nil "~{~A~}"
              (loop for block across content
                    for type = (json-value block "type")
                    when (and (stringp type)
                              (member type '("thinking" "redacted_thinking")
                                      :test #'string=))
                      collect (json-string (json-value block "thinking"))))
      ""))

(declaim (ftype (function (t) list) anthropic-parse-tool-calls))

(defun anthropic-parse-tool-calls (content)
  "Extract tool_use blocks from CONTENT, storing each input serialized as JSON text."
  (if (vectorp content)
      (loop for block across content
            for type = (json-value block "type")
            when (and (stringp type) (string= type "tool_use"))
              collect (%make-tool-call
                       :id (json-string (json-value block "id"))
                       :name (json-string (json-value block "name"))
                       :arguments (anthropic-tool-arguments
                                   (json-value block "input"))))
      '()))

(declaim (ftype (function (t) string) anthropic-stop-reason))

(defun anthropic-stop-reason (reason)
  "Map Anthropic stop_reason to normalized stop reasons: end_turn/stop_sequence ->
\"stop\", max_tokens -> \"length\", tool_use -> \"tool_calls\", else pass through."
  (let ((reason (if (stringp reason) reason "")))
    (cond
      ((string= reason "end_turn") "stop")
      ((string= reason "stop_sequence") "stop")
      ((string= reason "max_tokens") "length")
      ((string= reason "tool_use") "tool_calls")
      (t reason))))

(declaim (ftype (function (string) completion) anthropic-parse-completion))

(defun anthropic-parse-completion (payload)
  "Parse a Messages API JSON reply PAYLOAD into a COMPLETION.
Signals BACKEND-ERROR if content is missing or if thinking blocks accompany tool
calls. Folds cache read/write tokens into input-tokens to match OpenAI accounting."
  (let* ((data (com.inuoe.jzon:parse payload))
         (content (json-value data "content")))
    (unless (or (vectorp content) (stringp content))
      (let ((message (anthropic-error-message data)))
        (error 'enchiridion.errors:backend-error
               :backend "anthropic"
               :detail (if (zerop (length message))
                           "The reply carried no content blocks at all."
                           (format nil "The reply carried no content blocks: ~A"
                                   message)))))
    (when (and (anthropic-parse-tool-calls content)
               (vectorp content)
               (find-if (lambda (block)
                          (member (json-value block "type")
                                  '("thinking" "redacted_thinking") :test #'equal))
                        content))
      (error 'enchiridion.errors:backend-error
             :backend "anthropic"
             :detail "Thinking tool calls require signed thinking-block replay, which this message protocol does not support. Disable thinking or choose a nonthinking model."))
    (let ((usage (json-value data "usage")))
      (%make-completion
       :text (anthropic-content-text content)
       :reasoning-text (anthropic-reasoning-text content)
       :tool-calls (anthropic-parse-tool-calls content)
       :model (json-string (json-value data "model"))
       :stop-reason (anthropic-stop-reason
                     (json-value data "stop_reason"))
       :input-tokens (+ (json-count (json-value usage "input_tokens"))
                        (json-count
                         (json-value usage "cache_read_input_tokens"))
                        (json-count
                         (json-value usage "cache_creation_input_tokens")))
       :output-tokens (json-count (json-value usage "output_tokens"))
       :cache-read-tokens (json-count
                           (json-value usage "cache_read_input_tokens"))
       :cache-write-tokens (json-count
                            (json-value usage
                                        "cache_creation_input_tokens"))))))

;;;; The transport.

(declaim (ftype (function (&optional list) list) anthropic-static-headers))

(defun anthropic-static-headers (&optional extra)
  "Return non-credential Messages API headers (Content-Type, User-Agent), with EXTRA merged last."
  (merge-headers
   (list (cons :content-type "application/json")
         (cons :user-agent "enchiridion/0.1.0"))
   extra))

(declaim (ftype (function (string (or null string) &optional list) list)
                anthropic-headers))

(defun anthropic-headers (api-key version &optional extra)
  "Return Messages API headers as a (NAME . VALUE) cons alist for dexador.
Sends x-api-key; omits anthropic-version when VERSION is NIL (body-version dialects)."
  (merge-headers
   (append (anthropic-static-headers)
           (list (cons :x-api-key api-key))
           (when version (list (cons :anthropic-version version))))
   extra))

(declaim (ftype (function (t) (or null string)) anthropic-version-header-value))

(defun anthropic-version-header-value (dialect)
  "Return the anthropic-version header value for DIALECT, or NIL if sent in the body."
  (when (eq (dialect-field dialect :version-location :header) :header)
    (or (dialect-field dialect :version-value nil) +anthropic-version+)))

(declaim (ftype (function (t t) list) anthropic-beta-headers))

(defun anthropic-beta-headers (dialect betas)
  "Return a comma-joined anthropic-beta header for DIALECT, or NIL if sent in the body."
  (when (and betas
             (plusp (length betas))
             (eq (dialect-field dialect :beta-channel :header) :header))
    (list (cons :anthropic-beta (format nil "~{~A~^,~}" betas)))))

(declaim (ftype (function (t) t) anthropic-auth-scheme))

(defun anthropic-auth-scheme (dialect)
  "Return the effective credential scheme, defaulting to x-api-key."
  (or (dialect-field dialect :auth-scheme :x-api-key) :x-api-key))

(declaim (ftype (function (t t (or null string) list http-request) http-request)
                anthropic-authorize))

(defun anthropic-authorize (dialect api-key version extra request)
  "Apply DIALECT auth, static/version/extra headers, and query params to REQUEST."
  (let ((headers (append (anthropic-static-headers)
                         (when version (list (cons :anthropic-version version)))
                         (dialect-field dialect :extra-headers '())
                         extra)))
    (auth-apply (or dialect (make-dialect-for :anthropic))
                api-key request :extra headers)))

(defun send-anthropic-completion (connection messages model &key tools betas)
  "Send a Messages API completion request for MESSAGES using MODEL.
Applies AUTH-APPLY last so signed schemes see the final URL and body."
  (let* ((dialect (normalize-dialect-query-params
                   (anthropic-connection-dialect connection)))
         (version (anthropic-version-header-value dialect))
         (extra (append (anthropic-beta-headers dialect betas)
                        (anthropic-connection-headers connection)))
         (body (anthropic-completion-request connection messages
                                             :model model
                                             :tools tools
                                             :betas betas))
         (request (make-http-request
                   :url (concatenate
                         'string
                         (anthropic-connection-base-url connection)
                         (dialect-path-with-model
                          (dialect-field dialect :chat-path "v1/messages")
                          model))
                   :body body
                   :timeout (anthropic-connection-timeout connection))))
    (anthropic-parse-completion
     (post-with-retries *http-post-function*
                        (anthropic-authorize dialect
                                             (anthropic-connection-api-key
                                              connection)
                                             version extra request)
                        (anthropic-connection-retries connection)))))

;;;; The operations.

(defmethod backend-name ((connection anthropic-connection))
  "Return a short name for this backend."
  (format nil "anthropic (~A)" (anthropic-connection-base-url connection)))

(defmethod model-capabilities ((connection anthropic-connection))
  "Return capabilities plist for this backend (:cache-breakpoints is T)."
  (declare (ignore connection))
  '(:tools t :streaming t :cache t :cache-breakpoints t))

(defmethod complete ((connection anthropic-connection) messages
                     &key model tools budget)
  "Continue MESSAGES and return a COMPLETION. BUDGET is ignored; max_tokens comes
from the connection."
  (declare (ignore budget))
  (send-anthropic-completion connection messages
                             (or model (anthropic-connection-model connection))
                             :tools tools
                             :betas (anthropic-connection-betas connection)))

;;;; The adapter.

(declaim (ftype (function (provider) t) anthropic-dialect-for))

(defun anthropic-dialect-for (provider)
  "Resolve PROVIDER's dialect with :dialect-overrides and normalized query params."
  (let ((dialect (make-dialect-for
                  (provider-profile provider)
                  :protocol :anthropic
                  :overrides (provider-option provider :dialect-overrides))))
    (setf (dialect-query-params dialect)
          (dialect-query-param-pairs
           (merge-query-params (dialect-query-params dialect)
                               (provider-query-params provider))))
    dialect))

(declaim (ftype (function (provider) t) build-anthropic-provider))

(defun build-anthropic-provider (provider)
  "Construct an :ANTHROPIC-MESSAGES backend from resolved PROVIDER."
  (anthropic-backend
   :base-url (provider-base-url provider)
   :api-key (provider-key provider)
   :model (or (provider-model provider) (provider-default-model provider))
   :max-tokens (or (provider-option provider :max-tokens) 4096)
   :cache-ttl (provider-option provider :cache-ttl)
   :cache-p (provider-option provider :cache-p t)
   :headers (merge-headers (anthropic-static-headers)
                           (provider-headers provider))
   :dialect (anthropic-dialect-for provider)
   :betas (provider-option provider :betas)
   :timeout (provider-option provider :timeout 60)
   :retries (provider-option provider :retries 2)))

;;;; The model list.

;; Caps pagination against misbehaving has_more responses.
(defparameter +anthropic-model-pages+ 64
  "The most pages the model lister follows before it stops asking.")

(defparameter +anthropic-model-page-size+ 1000
  "How many models one models request asks for; the API's own maximum.")

(declaim (ftype (function (string (or null string)) string)
                anthropic-models-url))

(defun anthropic-models-url (base after)
  "Return the paginated models URL for BASE with limit and optional after_id cursor AFTER."
  (url-with-query base nil
                  (append (list (cons "limit"
                                      (princ-to-string
                                       +anthropic-model-page-size+)))
                          (when after (list (cons "after_id" after))))))

(declaim (ftype (function (t) model-info) anthropic-model-row))

(defun anthropic-model-row (entry)
  "Convert one Messages models-list ENTRY into a MODEL-INFO (all Messages models support tools)."
  (let* ((id (json-string (getf entry :id)))
         (name (json-string (getf entry :display_name))))
    (%make-model-info
     :id id
     :name (if (plusp (length name)) name id)
     :tool-call-p t
     :reasoning-p nil
     :source :provider)))

(declaim (ftype (function (provider) t) list-anthropic-models))

(defun list-anthropic-models (provider)
  "Fetch all paginated MODEL-INFO rows from PROVIDER's models endpoint using after_id cursors."
  (let* ((dialect (anthropic-dialect-for provider))
         (path (dialect-field dialect :models-path "v1/models"))
         (base (concatenate 'string
                            (ensure-trailing-slash (provider-base-url provider))
                            path))
         (version (anthropic-version-header-value dialect))
         (extra (append (anthropic-beta-headers dialect nil)
                        (merge-headers (anthropic-static-headers)
                                       (provider-headers provider))))
         (rows '())
         (after nil)
         (more t))
    ;; Re-authorize each page so signed schemes sign the paginated URL.
    (loop repeat +anthropic-model-pages+
          while more
          do (let* ((request (anthropic-authorize
                              dialect (provider-key provider) version extra
                              (make-http-request
                               :url (anthropic-models-url base after)
                               :timeout (provider-option provider :timeout +http-get-timeout+))))
                    (payload (parse-json
                              (get-with-retries request (provider-option provider :retries 2))))
                    (entries (getf payload :data)))
               (when (and (listp entries) (every #'consp entries))
                 (dolist (entry entries)
                   (push (anthropic-model-row entry) rows)))
               (setf after (and (listp entries)
                                (consp entries)
                                (getf (car (last entries)) :id))
                     more (and after (getf payload :has_more)))))
    (nreverse rows)))

;;;; Registration.

(register-api-handler
 :anthropic-messages
 :schema :anthropic
 :build #'build-anthropic-provider
 :list-models #'list-anthropic-models
 :documentation
 "The Anthropic Messages API, and every Anthropic-shaped gateway that speaks
it: Anthropic's own endpoint, an OpenRouter-style bearer gateway, and an
Anthropic-compatible proxy.")
