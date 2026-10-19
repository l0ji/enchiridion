;;;; anthropic.cl --- The Anthropic Messages API backend.
;;;;
;;;; A second wire shape, not a second transport. The request and the reply are
;;;; pure functions over text and data, exactly as in openai.cl, so the whole
;;;; format is testable without a network, a key, or a provider; the only part
;;;; that needs any of those is one function long.
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
;;;; The file is in dependency order, bottom to top, and it has to be. A name
;;;; used before it is defined is not a forward declaration in Lisp: the
;;;; compiler reads a symbol it has never seen as a variable, and the failure
;;;; surfaces at run time as UNBOUND-VARIABLE from a function that plainly
;;;; exists. COMPLETE is written last for that reason, after the sender and the
;;;; parser it calls.
;;;;
;;;; Every name here is new to package ENCHIRIDION.LLM. OPENAI.CL already owns
;;;; %MAKE-CONNECTION, COMPLETION-REQUEST, PARSE-COMPLETION,
;;;; MESSAGE->REQUEST-MESSAGE, TOOL-CALL->REQUEST, TOOL-DEFINITION->REQUEST,
;;;; PARSE-TOOL-CALLS, SEND-COMPLETION and HTTP-POST, and a second definition
;;;; of one of those names is a redefinition warning, which this system makes
;;;; an error rather than a note.

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
  (:timeout 60 :type (integer 1 *))
  (:retries 2 :type (integer 0 *)))

(defun anthropic-backend (&key (base-url "https://api.anthropic.com/")
                                api-key
                                (model nil)
                                (max-tokens 4096)
                                (cache-ttl nil)
                                (cache-p t)
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
   :timeout timeout
   :retries retries))

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

(defun anthropic-completion-request (connection messages &key tools model)
  "Return the request body for MESSAGES, as JSON text.

MODEL overrides the connection's model; an absent model means the connection's
own. The messages array is coerced to a vector even when it is empty, because
STRINGIFY writes an empty list as false and the API wants [] there: the key is
required, so omitting it is not an option.

SYSTEM, TOOLS and TOOL_CHOICE are added only when there is something to say.
An absent field is not the same fact as a present but empty one, and the
provider refuses several of the empty spellings."
  (let* ((cache-p (anthropic-connection-cache-p connection))
         (cache-ttl (anthropic-connection-cache-ttl connection))
         (body (json-object
                :model (or model (anthropic-connection-model connection))
                :max_tokens (anthropic-connection-max-tokens connection)
                :messages (coerce (anthropic-request-messages messages)
                                  'vector)))
         (system (anthropic-system-blocks messages cache-p cache-ttl)))
    (when system
      (setf (gethash "system" body) system))
    (when tools
      (setf (gethash "tools" body)
            (anthropic-tool-definitions tools cache-p cache-ttl))
      (setf (gethash "tool_choice" body) (json-object :type "auto")))
    (stringify body)))

;;;; The reply.
;;;;
;;;; A Messages reply is read with jzon's own object type and not through
;;;; PARSE-JSON, and that is a deliberate difference from the OpenAI parser.
;;;; PARSE-JSON turns every object into a plist and every array into a list,
;;;; which loses the two distinctions this parser needs: [] and null both
;;;; become NIL, and a tool_use input has to stay an object so STRINGIFY can
;;;; write it back as one. Reading the wire's types as they are keeps both.

(declaim (ftype (function (t string &optional t) t) anthropic-json-value))

(defun anthropic-json-value (object key &optional default)
  "Return KEY from OBJECT, a jzon object, or DEFAULT.

Keys are compared with STRING-EQUAL and not by identity, because jzon pools
object keys: a table just parsed holds the pooled string, and a GETHASH against
a fresh literal of the same characters is the kind of code that works until the
pool grows. A value that is not an object, an absent key and a JSON null all
answer DEFAULT rather than signalling, because a provider that omits a field
and one that sends it as null are the same fact to every caller here."
  (if (hash-table-p object)
      (let ((name (loop for candidate being the hash-keys of object
                        when (string-equal (string candidate) key)
                          return candidate)))
        (if name (gethash name object) default))
      default))

(declaim (ftype (function (t) string) anthropic-json-string))

(defun anthropic-json-string (value)
  "Return VALUE as a string, or the empty string when it is absent or null.

jzon spells JSON null as a symbol, so a field the provider sent as null
reaches this function as something that is neither a string nor NIL, and every
completion slot it is stored in is typed STRING."
  (if (stringp value) value ""))

(declaim (ftype (function (t) (integer 0 *)) anthropic-json-count))

(defun anthropic-json-count (value)
  "Return VALUE as a token count, and zero for anything else.

A missing usage field, a null and a value that is not a whole number are all an
unknown cost, and zero is the honest answer for an unknown cost. The completion
slots are typed (INTEGER 0 *), so jzon's null symbol would be a type error at
the constructor rather than the number nobody asked for."
  (if (and (integerp value) (not (minusp value))) value 0))

(declaim (ftype (function (t) string) anthropic-error-message))

(defun anthropic-error-message (data)
  "Return the provider's own error text from DATA, or the empty string.

The error is an object with a message in it, and a proxy in front of the
provider may answer with something else entirely, so anything that is not the
object is put through ANTHROPIC-JSON-STRING rather than assumed to be a
string."
  (let ((error-object (anthropic-json-value data "error")))
    (if (hash-table-p error-object)
        (anthropic-json-string (anthropic-json-value error-object "message"))
        (anthropic-json-string error-object))))

(declaim (ftype (function (t) string) anthropic-tool-arguments))

(defun anthropic-tool-arguments (input)
  "Return INPUT, a tool_use block's input, as JSON text.

STRINGIFY writes a jzon object as an object and an empty one as {}, which is
what the tool layer wants. An absent input and a null become {} rather than
\"null\": a call with no arguments is a call with an empty argument object, and
every reader downstream can index that without a special case."
  (if (or (null input) (eq input +json-null+))
      "{}"
      (stringify input)))

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
                   for type = (anthropic-json-value block "type")
                   when (and (stringp type) (string= type "text"))
                     collect (anthropic-json-string
                              (anthropic-json-value block "text")))))
    (t "")))

(declaim (ftype (function (t) list) anthropic-parse-tool-calls))

(defun anthropic-parse-tool-calls (content)
  "Return the tool calls in CONTENT, the reply's content array.

Arguments are stored as JSON text and not as a parsed object, because that is
how the model wrote them and how the tool layer validates them. STRINGIFY
writes a jzon object back as an object, so an input that arrived as data leaves
as the text of exactly that data."
  (if (vectorp content)
      (loop for block across content
            for type = (anthropic-json-value block "type")
            when (and (stringp type) (string= type "tool_use"))
              collect (%make-tool-call
                       :id (anthropic-json-string
                            (anthropic-json-value block "id"))
                       :name (anthropic-json-string
                              (anthropic-json-value block "name"))
                       :arguments (anthropic-tool-arguments
                                   (anthropic-json-value block "input"))))
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

(declaim (ftype (function (string)) anthropic-parse-completion))

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
         (content (anthropic-json-value data "content")))
    (unless (or (vectorp content) (stringp content))
      (let ((message (anthropic-error-message data)))
        (error 'enchiridion.errors:backend-error
               :backend "anthropic"
               :detail (if (zerop (length message))
                           "The reply carried no content blocks at all."
                           (format nil "The reply carried no content blocks: ~A"
                                   message)))))
    (let ((usage (anthropic-json-value data "usage")))
      (%make-completion
       :text (anthropic-content-text content)
       :tool-calls (anthropic-parse-tool-calls content)
       :model (anthropic-json-string (anthropic-json-value data "model"))
       :stop-reason (anthropic-stop-reason
                     (anthropic-json-value data "stop_reason"))
       :input-tokens (+ (anthropic-json-count
                         (anthropic-json-value usage "input_tokens"))
                        (anthropic-json-count
                         (anthropic-json-value usage "cache_read_input_tokens"))
                        (anthropic-json-count
                         (anthropic-json-value usage
                                               "cache_creation_input_tokens")))
       :output-tokens (anthropic-json-count
                       (anthropic-json-value usage "output_tokens"))
       :cache-read-tokens (anthropic-json-count
                           (anthropic-json-value usage
                                                 "cache_read_input_tokens"))
       :cache-write-tokens (anthropic-json-count
                            (anthropic-json-value usage
                                                  "cache_creation_input_tokens"))))))

;;;; The transport.
;;;;
;;;; dexador signals HTTP-REQUEST-FAILED on any 4xx or 5xx and returns the body
;;;; on a 2xx, so the status is read off the condition rather than off a return
;;;; value. RESPONSE-STATUS is that condition's reader; it is not a way to ask
;;;; "what did the last call return".
;;;;
;;;; x-api-key is what every documented Messages request sends, so it is the
;;;; spelling this backend standardises on. Authorization: Bearer is accepted as
;;;; well and is deliberately not used, so the key stays out of the header a
;;;; proxy is built to log. anthropic-version is required on every request.

;; DEFPARAMETER and not DEFCONSTANT, which is deliberate. SBCL evaluates a
;; DEFCONSTANT's init form at compile time and again when the fasl loads, and
;; two strings with the same characters are not EQL, so the second evaluation
;; is a redefinition warning; this system makes a warning an error, and the
;; report names a value that never changed. Nothing rebinds this.
(defparameter +anthropic-version+ "2023-06-01"
  "The anthropic-version header every Messages API request carries. The value
is the revision of the API, not a build of it, and the service refuses a
request that omits the header.")

(declaim (ftype (function (string string) list) anthropic-headers))

(defun anthropic-headers (api-key version)
  "Return the headers a Messages API request carries.

An alist of CONSES and not a list of two element lists: dexador walks the
header list with (LOOP FOR (NAME . VALUE) IN HEADERS), so a two element list
leaves VALUE bound to a list of one string and the header goes on the wire as
a parenthesised list.

These four headers are the whole set. There is no Authorization header and no
x-opencode-session: the key travels in x-api-key, which every documented example
sends, and not in the header generic proxies are built to log and forward. The
user agent names this project rather than dexador, as a validated client does."
  (list (cons :content-type "application/json")
        (cons :x-api-key api-key)
        (cons :anthropic-version version)
        (cons :user-agent "enchiridion/0.1.0")))

(declaim (ftype (function (string string string string integer string) string)
                anthropic-http-post))

(defun anthropic-http-post (base-url path body api-key timeout version)
  "POST BODY to PATH under BASE-URL and return the reply text.

The argument names are dexador's, not guesses. It spells the payload :CONTENT
and not :DATA, spells the content type as a header and not as a :CONTENT-TYPE
argument, and spells both halves of a deadline :READ-TIMEOUT and
:CONNECT-TIMEOUT with no :TIMEOUT at all. Passing the names that read well
instead of the names it accepts is a style warning about unknown argument
keywords, and a warning here is an error.

No :FORCE-BINARY. A Messages reply is JSON text and dexador decodes it using
the charset the reply names, which is the only decoding that is correct for a
reply that is not ASCII. Forcing binary returns a vector of octets instead, and
the first thing that touches the reply is the parser, which wants a string.

VERSION is a parameter and not a constant read inside this function, because
POST-WITH-RETRIES hands both wire transports one six argument call: the last
argument is the one field each wire carries outside the body and outside the
common headers, and on this wire it is the anthropic-version value."
  (dexador:request
   (concatenate 'string base-url path)
   :method :post
   :headers (anthropic-headers api-key version)
   :content body
   :read-timeout timeout
   :connect-timeout timeout))

;; The transport is a special so a test can replace it without a network, and
;; so the retry path is testable at all: the retry path is about what happens
;; between two calls and not about what a provider says.
(defparameter *anthropic-http-post-function* #'anthropic-http-post
  "The function SEND-ANTHROPIC-COMPLETION uses to make one HTTP request.
Bound in tests.")

(defun send-anthropic-completion (connection messages model &key tools)
  "Return the COMPLETION for MESSAGES from CONNECTION using MODEL.

The reply is parsed by ANTHROPIC-PARSE-COMPLETION, which reads the JSON itself
rather than receiving the plist shape PARSE-JSON would produce, for the reasons
written at that function."
  (let ((body (anthropic-completion-request connection messages
                                            :model model
                                            :tools tools)))
    (anthropic-parse-completion
     (post-with-retries *anthropic-http-post-function*
                        (anthropic-connection-base-url connection)
                        "v1/messages"
                        body
                        (anthropic-connection-api-key connection)
                        (anthropic-connection-timeout connection)
                        +anthropic-version+
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

