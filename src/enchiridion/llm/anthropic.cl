;;;; anthropic.cl --- The Anthropic Messages API handler.
;;;;
;;;; A second wire shape, not a second transport. The request and the reply are
;;;; pure functions over text and data, so the whole format is testable without
;;;; a network, a key, or a provider; the only part that needs any of those is
;;;; the transport, and it lives in http.cl.
;;;;
;;;; Everything that is genuinely different about this API is in the mapping:
;;;;
;;;;   * instructions live in a top level SYSTEM field, and there is no system
;;;;     role inside the conversation;
;;;;   * a tool call is a tool_use block inside an assistant message, and its
;;;;     input is a JSON object, not the JSON text the call stores;
;;;;   * a tool result is a tool_result block inside a USER message, because
;;;;     this wire has no tool role at all, and consecutive results merge into
;;;;     one user message;
;;;;   * max_tokens is required on every request and the provider has no
;;;;     default for it;
;;;;   * prompt caching is a cache_control breakpoint on the blocks that end
;;;;     the reusable prefix, not a request level flag.
;;;;
;;;; The schema half of this file is shared. Anthropic's own endpoint, an
;;;; Anthropic-shaped gateway, Amazon Bedrock's InvokeModel path and Google
;;;; Vertex's :rawPredict path all carry this body; they differ in transport,
;;;; path, auth and where the version string goes. Those differences live in
;;;; bedrock.cl and vertex.cl, and both call ANTHROPIC-REQUEST-BODY and
;;;; ANTHROPIC-PARSE-COMPLETION from here rather than copying them.
;;;;
;;;; Every name here is new to package ENCHIRIDION.LLM. OPENAI.CL already owns
;;;; OPENAI-BACKEND and the OpenAI request builders, and a second definition of
;;;; one of those names is a redefinition warning, which this system makes an
;;;; error rather than a note.

(in-package #:enchiridion.llm)

;;;; The connection.
;;;;
;;;; The struct is ANTHROPIC-CONNECTION and the constructor is
;;;; ANTHROPIC-BACKEND, the same split as the OpenAI file and for the same
;;;; reason: the exported name is a function, and the type stays an internal
;;;; detail.
;;;;
;;;; max-tokens is a slot because the Messages API requires the field on every
;;;; request. cache-p is on by default: a breakpoint on the last system block
;;;; and on the last tool definition is the prefix that does not change between
;;;; turns, and the API caps one request at four. cache-ttl is the optional
;;;; lifetime of a breakpoint, "5m" or "1h"; NIL takes the provider's default.
;;
;; base-url always ends in a slash, so paths can be appended to it. api-key is
;; never logged and never put in an error report. model is the default for this
;; backend. timeout is seconds to wait for a reply, and retries is how many
;; extra attempts a 429 or a 5xx earns. There is no session-id slot: the
;; Messages API has no routing header, so there is nothing to carry.
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
  (:retries 2 :type (integer 0 *)))

(defun anthropic-backend (&key (base-url "https://api.anthropic.com/")
                                api-key
                                (model nil)
                                (max-tokens 4096)
                                (cache-ttl nil)
                                (cache-p t)
                                (headers '())
                                (dialect nil)
                                (timeout 60)
                                (retries 2))
  "Return a BACKEND that speaks the Anthropic Messages API.

BASE-URL gains a trailing slash when it lacks one, because every path is
appended to it and a missing slash silently turns /v1 into a host named v1.
MODEL defaults to the primary tier when it is absent.

MAX-TOKENS is required by the API and NIL is not an acceptable value for it, so
the default is a whole reply rather than an omission. CACHE-P places the two
cache breakpoints this backend knows about, on the blocks that end the prefix
every turn shares.

No F-TYPE, for the reason RESOLVE-BACKEND has none: SBCL wants every keyword in
an F-TYPE lambda list to have been declared in one already, and a dummy
declaration per keyword costs more than the annotation would catch."
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
   :retries retries))

;; DEFPARAMETER and not DEFCONSTANT, which is deliberate. SBCL evaluates a
;; DEFCONSTANT's init form at compile time and again when the fasl loads, and
;; two strings with the same characters are not EQL, so the second evaluation
;; is a redefinition warning; this system makes a warning an error, and the
;; report names a value that never changed. Nothing rebinds this.
;;
;; It is defined here, above the request builder, because that builder is what
;; writes the revision into a body when the profile puts it there, and a
;; variable used above its DEFPARAMETER is an undefined-variable warning.
(defparameter +anthropic-version+ "2023-06-01"
  "The anthropic-version header every Messages API request carries. The value
is the revision of the API, not a build of it, and the service refuses a
request that omits the header. A profile that carries the revision in the body
names its own value instead.")

;;;; The request.
;;;;
;;;; The shape is the one the Messages API accepts:
;;;;
;;;;   {"model": "m", "max_tokens": 4096,
;;;;    "system": [{"type": "text", "text": "..."}],
;;;;    "messages": [{"role": "user",
;;;;                  "content": [{"type": "text", "text": "hi"}]}]}
;;;;
;;;; Every field this request does not need is absent rather than NIL.
;;;; STRINGIFY writes NIL as false, so an omitted key and a false one are two
;;;; different things on the wire and only one of them is accepted.

(declaim (ftype (function (&optional t) hash-table) anthropic-cache-control))

(defun anthropic-cache-control (&optional ttl)
  "Return an ephemeral cache breakpoint, with TTL when one is configured.

The Messages API accepts {\"type\": \"ephemeral\"} and optionally a lifetime of
\"5m\" or \"1h\". NIL leaves the lifetime to the provider's default. The object
is built through JSON-OBJECT so its keys are the wire's spelling and not this
package's."
  (if (and (stringp ttl) (plusp (length ttl)))
      (json-object :type "ephemeral" :ttl ttl)
      (json-object :type "ephemeral")))

(declaim (ftype (function (t) t) anthropic-tool-input))

(defun anthropic-tool-input (arguments)
  "Return ARGUMENTS, the JSON text the model wrote for one tool, as an object.

COM.INUOE.JZON:PARSE directly, never PARSE-JSON. PARSE-JSON turns every JSON
object into a plist so that the rest of this system can read a reply with GETF,
and jzon writes a plist back as an ARRAY of alternating keys and values. A
tool_use input has to be an object, so the conversion would turn every tool
call into one the API rejects, and the report would name the input's type
rather than the conversion that produced it.

An empty or absent argument string becomes an empty object rather than an
error: a tool with no arguments is a real thing, and (jzon:parse \"\") signals."
  (if (and (stringp arguments)
           (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                       arguments))))
      (com.inuoe.jzon:parse arguments)
      (make-hash-table :test #'equal)))

(declaim (ftype (function (string) hash-table) anthropic-text-block))

(defun anthropic-text-block (text)
  "Return TEXT as a text block.

The block shape and not a bare string, because a bare string cannot carry
cache_control, and the two shapes are not interchangeable once one block in
the array is an object."
  (json-object :type "text" :text text))

(declaim (ftype (function (tool-call) hash-table) anthropic-tool-use-block))

(defun anthropic-tool-use-block (call)
  "Return CALL as the tool_use block an assistant message carries.

The input is an object and not the JSON text the call stores: this wire wants
the arguments as data, and the stored text was always a serialization of
exactly that data. ANTHROPIC-TOOL-INPUT is the one place that decides how it is
read back."
  (json-object :type "tool_use"
               :id (tool-call-id call)
               :name (tool-call-name call)
               :input (anthropic-tool-input (tool-call-arguments call))))

(declaim (ftype (function (message) hash-table) anthropic-tool-result-block))

(defun anthropic-tool-result-block (message)
  "Return MESSAGE as the tool_result block a user message carries.

TOOL_USE_ID is the call's id, which is what the API matches the result to; a
missing or wrong id is answered with an error rather than with a guess. The
content is the result text as a string, which is the short form of the block.
None of these blocks carries cache_control: a tool result is the part of the
conversation that changes every turn, so a breakpoint there would end a prefix
no later turn can reuse."
  (json-object :type "tool_result"
               :tool_use_id (message-tool-call-id message)
               :content (message-content message)))

(declaim (ftype (function (message) list) anthropic-message-blocks))

(defun anthropic-message-blocks (message)
  "Return MESSAGE as the content blocks of one wire entry.

An assistant message carries its text and then one tool_use block per call, in
the order the model asked for them. A turn that only called tools has no text
block, and a turn with neither text nor calls gets an empty text block: the API
refuses a message whose content array is empty, and this system records an
empty completion as a legal reply."
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
  "Return MESSAGES as the wire's array, without the system messages.

The wire has no system role and no tool role. A system message is hoisted to
the top level by ANTHROPIC-SYSTEM-BLOCKS and is skipped here. A tool message
becomes a USER message whose content is a tool_result block: the result is
something the operator's side of the conversation says, and the API matches it
to the call by tool_use_id rather than by a role of its own.

Adjacent entries with the same role are merged, and merging is the function's
whole second half. Two tool messages in a row are two results for one assistant
turn, and the API wants the conversation to alternate, so the results are
concatenated into one user message in the order the tools ran. A text message
that follows tool results is appended to the same message, after the
tool_result blocks, because a tool_result block has to be the first block in
its message."
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
  "Return the top level system array for MESSAGES, or NIL when there is none.

The Messages API takes instructions in a field of its own and has no system
role inside the conversation. Every system message is concatenated into the one
text block: they are all instructions, the model reads them in order, and
separate blocks would put a cache breakpoint in the middle of what is
conceptually one paragraph. The block is an element of an array and not a bare
string because that is the only shape that can carry cache_control, which marks
the end of the prefix that does not change between turns."
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
  "Return TOOLS, the registry's definition objects, as this wire's flat list.

The registry builds {\"name\", \"description\", \"parameters\"} for the OpenAI
shape, where a tool is wrapped in a function object and the schema key is
called parameters. The Messages API wants the three keys flat and calls the
schema input_schema.

Only the last definition carries the second cache breakpoint: everything before
it is part of the same cached prefix, and the API caps one request at four
breakpoints."
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
  "Return the Messages request for MESSAGES as data.

MODEL is written into the body unless MODEL-IN-BODY-P is NIL, which is what
Amazon Bedrock and Google Vertex need: both carry the model in the URL path and
reject a body that names it twice. DIALECT answers that question when the
caller does not, so a profile cannot be applied and then ignored.

CACHE-P and CACHE-TTL are explicit arguments rather than slots of a connection,
because the cloud endpoints are stricter than Anthropic's own: Bedrock has no
top level cache_control and no 1h TTL, and the caller is the one that knows
which endpoint it is building for. A profile whose CACHE-TTL-SUPPORTED-P is NIL
drops the TTL and keeps the breakpoint.

DIALECT also decides where the revision goes. A profile with a :BODY version
location gets anthropic_version in the body and no header; the header case is
the caller's, because only the caller knows what the transport sends.
BETAS is the beta feature list. A profile whose beta channel is the body gets
it as an anthropic_beta array; the header case is written by the caller."
  (flet ((flag (key)
           ;; The raw slot answers a switch, and the generic wire answers T
           ;; when there is no dialect. A T default cannot be passed to
           ;; DIALECT-FIELD: it answers its default for a slot that holds NIL,
           ;; and NIL is exactly what a profile writes to switch a switch off.
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
  "Return the request body for MESSAGES, as JSON text.

The messages array is coerced to a vector even when it is empty, because
STRINGIFY writes an empty list as false and the API wants [] there: the key is
required, so omitting it is not an option.

SYSTEM, TOOLS and TOOL_CHOICE are added only when there is something to say.
An absent field is not the same fact as a present but empty one, and the
provider refuses several of the empty spellings. The connection's dialect is
passed through so the body is built for the endpoint this connection talks to."
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
;;;; A Messages reply is read with jzon's own object type and not through
;;;; PARSE-JSON, and that is a deliberate difference from the OpenAI parser.
;;;; PARSE-JSON turns every object into a plist and every array into a list,
;;;; which loses the two distinctions this parser needs: [] and null both
;;;; become NIL, and a tool_use input has to stay an object so STRINGIFY can
;;;; write it back as one. Reading the wire's types as they are keeps both.

(declaim (ftype (function (t) string) anthropic-error-message))

(defun anthropic-error-message (data)
  "Return the provider's own error text from DATA, or the empty string.

The error is an object with a message in it, and a proxy in front of the
provider may answer with something else entirely, so anything that is not the
object is put through JSON-STRING rather than assumed to be a string."
  (let ((error-object (json-value data "error")))
    (if (hash-table-p error-object)
        (json-string (json-value error-object "message"))
        (json-string error-object))))

(declaim (ftype (function (t) string) anthropic-tool-arguments))

(defun anthropic-tool-arguments (input)
  "Return INPUT, a tool_use block's input, as JSON text.

STRINGIFY writes a jzon object as an object and an empty one as {}, which is
what the tool layer wants. An absent input and a null become {} rather than
\"null\": a call with no arguments is a call with an empty argument object, and
every reader downstream can index that without a special case.

An input that arrived as a string is passed through as it is: a handful of
Anthropic-shaped gateways emit the arguments already serialized, and parsing
text only to re-serialize it would change nothing and could fail."
  (cond
    ((or (null input) (eq input +json-null+)) "{}")
    ((stringp input) (if (plusp (length input)) input "{}"))
    (t (stringify input))))

(declaim (ftype (function (t) string) anthropic-content-text))

(defun anthropic-content-text (content)
  "Return every text block in CONTENT, concatenated in order.

A reply may carry several text blocks around a tool_use block, and this system
stores one text string, so the blocks are joined with nothing between them:
each block carries its own whitespace, and a separator inserted here would be
characters the model never wrote. A bare string is legal content on this
wire's request side and is passed through as it is."
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
  "Return every thinking block in CONTENT, concatenated.

Extended thinking arrives as its own block type. It is not the answer and must
not be concatenated into the reply text, but it is worth keeping apart so a
caller that wants to show its work can. The blocks are joined like the text
blocks, with nothing inserted between them."
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
  "Return the tool calls in CONTENT, the reply's content array.

Arguments are stored as JSON text and not as a parsed object, because that is
how the model wrote them and how the tool layer validates them. STRINGIFY
writes a jzon object back as an object, so an input that arrived as data leaves
as the text of exactly that data."
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
  "Return REASON, the wire's stop_reason, as this system's stop reason.

The two vocabularies are close and not identical. end_turn and stop_sequence
both mean the model finished its answer, so both become stop. max_tokens
becomes length, which is the name the rest of this system already uses for a
reply cut off by the cap. tool_use becomes tool_calls. Anything else, including
an absent field, passes through as it came: a provider that adds a reason
should have it recorded and not silently renamed."
  (let ((reason (if (stringp reason) reason "")))
    (cond
      ((string= reason "end_turn") "stop")
      ((string= reason "stop_sequence") "stop")
      ((string= reason "max_tokens") "length")
      ((string= reason "tool_use") "tool_calls")
      (t reason))))

(declaim (ftype (function (string) completion) anthropic-parse-completion))

(defun anthropic-parse-completion (payload)
  "Return the COMPLETION described by PAYLOAD, the reply text.

Signals BACKEND-ERROR when the reply carries no content field at all. A reply
whose content array is empty is legal and becomes an empty completion: the
model may end a turn without saying anything, and only a reply with no content
block at all is a provider failure. The empty array and the absent field are
told apart here and nowhere else, which is the other reason this parser reads
jzon's types directly.

TOKEN ACCOUNTING. The Messages API reports input_tokens with the cache reads
and the cache writes taken out of it, unlike the OpenAI shape, where the prompt
count already includes the cached part. This system's input count is
provider-normalised, so the three are added together here and the cache slots
are still filled: the ledger keeps the split, and COMPLETION-TOTAL-TOKENS stays
input plus output on both wires."
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
;;;;
;;;; x-api-key is what every documented Messages request sends, so it is the
;;;; spelling this backend standardises on. anthropic-version is required on
;;;; every request to Anthropic's own endpoint. A dialect changes both facts
;;;; for a gateway or a cloud endpoint --- a bearer token instead of the key, a
;;;; revision in the body instead of a header, a beta list in the body --- and
;;;; AUTH-APPLY is the one call that puts the credential wherever the profile
;;;; says it goes.

(declaim (ftype (function (&optional list) list) anthropic-static-headers))

(defun anthropic-static-headers (&optional extra)
  "Return the Messages headers that are not the credential.

The content type and the user agent are the same on every Anthropic-shaped
endpoint, and they live here so the chat request, the model list and a cloud
handler cannot disagree about them. EXTRA is merged last, which is what lets a
provider replace either one."
  (merge-headers
   (list (cons :content-type "application/json")
         (cons :user-agent "enchiridion/0.1.0"))
   extra))

(declaim (ftype (function (string (or null string) &optional list) list)
                anthropic-headers))

(defun anthropic-headers (api-key version &optional extra)
  "Return the headers a Messages API request carries.

An alist of CONSES and not a list of two element lists: dexador walks the
header list with (LOOP FOR (NAME . VALUE) IN HEADERS), so a two element list
leaves VALUE bound to a list of one string and the header goes on the wire as
a parenthesised list.

These four headers are the whole set. There is no Authorization header and no
x-opencode-session: the key travels in x-api-key, which every documented example
sends, and not in the header generic proxies are built to log and forward. The
user agent names this project rather than dexador, as a validated client does.

VERSION NIL omits anthropic-version entirely, which is what a profile that
carries the revision in the request body needs: Bedrock's InvokeModel path
refuses the header, and a header with a NIL value is worse than no header."
  (merge-headers
   (append (anthropic-static-headers)
           (list (cons :x-api-key api-key))
           (when version (list (cons :anthropic-version version))))
   extra))

(declaim (ftype (function (t) (or null string)) anthropic-version-header-value))

(defun anthropic-version-header-value (dialect)
  "Return the anthropic-version header for DIALECT, or NIL when the version
travels in the body.

A profile that carries the revision in the body (Bedrock, Vertex) must not send
the header as well, and one that names a revision of its own gets that
revision. The generic wire sends the constant this service requires."
  (when (eq (dialect-field dialect :version-location :header) :header)
    (or (dialect-field dialect :version-value nil) +anthropic-version+)))

(declaim (ftype (function (t t) list) anthropic-beta-headers))

(defun anthropic-beta-headers (dialect betas)
  "Return the anthropic-beta header for DIALECT, or NIL.

A profile whose beta channel is the body writes the list into the request as
anthropic_beta and gets no header at all, so this function answers NIL for it.
Several betas travel as one comma separated header, which is the spelling the
service documents."
  (when (and betas
             (plusp (length betas))
             (eq (dialect-field dialect :beta-channel :header) :header))
    (list (cons :anthropic-beta (format nil "~{~A~^,~}" betas)))))

(declaim (ftype (function (t) t) anthropic-auth-scheme))

(defun anthropic-auth-scheme (dialect)
  "Return the credential scheme this Messages request uses.

ANTHROPIC's own endpoint authenticates with x-api-key, and so does every
Anthropic-shaped endpoint that does not say otherwise. The DIALECT struct's
generic default is :bearer and the :anthropic profile overrides no field, so
the scheme is read from the provider's profile when that profile names one and
is :x-api-key otherwise. A gateway profile names :bearer, which is what turns
x-api-key into Authorization: Bearer on the same wire."
  (if (and dialect
           (getf (dialect-profile-plist (dialect-profile dialect)) :auth-scheme))
      (dialect-field dialect :auth-scheme)
      :x-api-key))

(declaim (ftype (function (t t (or null string) list http-request) http-request)
                anthropic-authorize))

(defun anthropic-authorize (dialect api-key version extra request)
  "Return REQUEST with DIALECT's credential applied to it.

VERSION is the anthropic-version header value, or NIL when the profile carries
the revision in the body. EXTRA is the connection's own header list, which
already carries the beta header when the profile wants one in a header.

The Messages API's own wire authenticates with x-api-key, so that branch writes
the header directly. A profile that names another scheme --- a bearer gateway,
Amazon SigV4, Google OAuth --- goes through AUTH-APPLY, which is the only code
that knows where a signed credential goes."
  (let ((headers (append (anthropic-static-headers)
                         (when version (list (cons :anthropic-version version)))
                         (dialect-field dialect :extra-headers '())
                         extra)))
    (if (eq (anthropic-auth-scheme dialect) :x-api-key)
        (progn
          ;; ANTHROPIC-HEADERS adds the credential and the version. The version
          ;; is already in HEADERS, and MERGE-HEADERS keeps one of each name,
          ;; so the merge is a no-op for it and the credential lands in the
          ;; one place this wire puts it.
          (setf (http-request-headers request)
                (anthropic-headers api-key version headers))
          request)
        (auth-apply dialect api-key request :extra headers))))

(defun send-anthropic-completion (connection messages model &key tools betas)
  "Return the COMPLETION for MESSAGES from CONNECTION using MODEL.

The URL is the connection's base URL and the dialect's chat path, with {model}
replaced by MODEL. The credential is applied last, to the finished request,
because a signed scheme has to see the body before it can sign it.

The reply is parsed by ANTHROPIC-PARSE-COMPLETION, which reads the JSON itself
rather than receiving the plist shape PARSE-JSON would produce, for the reasons
written at that function."
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
;;;;
;;;; Last, because COMPLETE is a call into SEND-ANTHROPIC-COMPLETION and a
;;;; DEFMETHOD that calls a name the compiler has not seen yet compiles into a
;;;; variable reference and fails at run time.

(defmethod backend-name ((connection anthropic-connection))
  "Return a short name for this backend."
  (format nil "anthropic (~A)" (anthropic-connection-base-url connection)))

(defmethod model-capabilities ((connection anthropic-connection))
  "Return what this backend's models support.

  :cache             the provider reports cached prompt tokens
  :cache-breakpoints an explicit cache breakpoint is accepted in the request
  :tools             tool calling is available
  :streaming         a stream can be requested, and is not used here

:CACHE-BREAKPOINTS is true here and NIL on the OpenAI backend, because this
backend really does place breakpoints and that one really does not. Reported as
present only when the feature is real, so nothing above has to guess."
  (declare (ignore connection))
  '(:tools t :streaming t :cache t :cache-breakpoints t))

(defmethod complete ((connection anthropic-connection) messages
                     &key model tools budget)
  "Continue MESSAGES and return the COMPLETION.

TOOLS is the registry's definition objects and is passed through to the
request, which flattens them and renames the schema key. BUDGET is ignored: the
budget decides whether a turn starts, not how long a reply may be, and
max_tokens comes from the connection."
  (declare (ignore budget))
  (send-anthropic-completion connection messages
                             (or model (anthropic-connection-model connection))
                             :tools tools))

;;;; The adapter.
;;;;
;;;; The provider table hands over an already resolved PROVIDER: endpoint, key,
;;;; model, profile, headers and options. Everything vendor specific is either
;;;; in the row or in the dialect, and this section is the only place that
;;;; knows both a PROVIDER and this wire.

(declaim (ftype (function (provider) t) anthropic-dialect-for))

(defun anthropic-dialect-for (provider)
  "Return the resolved dialect for PROVIDER.

The provider's profile names the quirks and the row's :dialect-overrides
replaces any single field. The row's own :query-params are appended to the
profile's and every parameter is turned into a proper pair, because
AUTH-APPLY is the one place that appends a query string and a second appender
would drift from it."
  (let ((dialect (make-dialect-for
                  (provider-profile provider)
                  :protocol :anthropic
                  :overrides (provider-option provider :dialect-overrides))))
    (setf (dialect-query-params dialect)
          (dialect-query-param-pairs
           (append (dialect-query-params dialect)
                   (provider-query-params provider))))
    dialect))

(declaim (ftype (function (provider) t) build-anthropic-provider))

(defun build-anthropic-provider (provider)
  "Return the :ANTHROPIC-MESSAGES backend PROVIDER describes.

MAX-TOKENS is required on this wire, so a row that names no cap gets the whole
reply rather than an omission. CACHE-P is on unless the row turns it off: the
two breakpoints are what make a repeated prefix cheap."
  (anthropic-backend
   :base-url (provider-base-url provider)
   :api-key (provider-key provider)
   :model (or (provider-model provider) (provider-default-model provider))
   :max-tokens (or (provider-option provider :max-tokens) 4096)
   :cache-ttl (provider-option provider :cache-ttl)
   :cache-p (provider-option provider :cache-p t)
   :headers (merge-headers (anthropic-static-headers)
                           (provider-headers provider))
   :dialect (anthropic-dialect-for provider)))

;;;; The model list.

;; The list is paginated, and a has_more that never clears is a provider bug.
;; The cap turns it into a bounded number of requests rather than a loop that
;; runs until the process is killed.
(defparameter +anthropic-model-pages+ 64
  "The most pages the model lister follows before it stops asking.")

(defparameter +anthropic-model-page-size+ 1000
  "How many models one models request asks for; the API's own maximum.")

(declaim (ftype (function (string (or null string)) string)
                anthropic-models-url))

(defun anthropic-models-url (base after)
  "Return the models URL for BASE, asking for the page that follows AFTER.

AFTER is the id of the last model of the previous page, which is the cursor the
API documents, or NIL for the first page. The page size is always asked for, so
the endpoint does not fall back to a default this tree does not know."
  (url-with-query base nil
                  (append (list (cons "limit"
                                      (princ-to-string
                                       +anthropic-model-page-size+)))
                          (when after (list (cons "after_id" after))))))

(declaim (ftype (function (t) model-info) anthropic-model-row))

(defun anthropic-model-row (entry)
  "Return ENTRY, one model of a Messages model list, as a MODEL-INFO row.

The endpoint reports an id, a display name and a creation time and little else.
Tool calling is not a per-model fact on this wire: every model the Messages API
serves can be given tools, so the row says so rather than leaving the catalog
to guess."
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
  "Return the MODEL-INFO rows the Messages endpoint reports.

The list is paginated: a reply carries a page, HAS_MORE says whether another
one exists, and AFTER_ID asks for the models that follow the last one seen. The
cursor is the id of the last row rather than a count, because the API's
ordering is its own and a caller that assumed the number of models it had seen
was the offset would skip or repeat rows."
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
    ;; Every repeated page goes through AUTH-APPLY, so a gateway's token and a
    ;; signed request are built exactly as the chat request is. The version's
    ;; header placement is shared with it for the same reason.
    (loop repeat +anthropic-model-pages+
          while more
          do (let* ((request (anthropic-authorize
                              dialect (provider-key provider) version extra
                              (make-http-request
                               :url (anthropic-models-url base after))))
                    (payload (parse-json
                              (funcall *http-get-function*
                                       (http-request-url request)
                                       :headers (http-request-headers request))))
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
;;;;
;;;; Last form in the file, and it has to be: it names the two functions above
;;;; with #', and a #' of a name the compiler has not seen is a warning.

(register-api-handler
 :anthropic-messages
 :schema :anthropic
 :build #'build-anthropic-provider
 :list-models #'list-anthropic-models
 :documentation
 "The Anthropic Messages API, and every Anthropic-shaped gateway that speaks
it: Anthropic's own endpoint, an OpenRouter-style bearer gateway, and an
Anthropic-compatible proxy.")

