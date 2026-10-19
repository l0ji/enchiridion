;;;; anthropic-test.cl --- The Anthropic Messages API wire format.
;;;;
;;;; Every test here runs with no network, no key, and no provider. The
;;;; request and the reply are pure functions over text and data, and they are
;;;; the part that decides whether a turn works at all. The one function that
;;;; touches a socket is replaced through a special, which is also the only way
;;;; to test a retry: a retry is about what happens between two calls.
;;;;
;;;; The request side is read back with jzon rather than with PARSE-JSON,
;;;; because several of these tests are about the difference between an
;;;; object, an empty array and null, and PARSE-JSON is the one conversion
;;;; that erases exactly that difference. The fixtures are shaped like real
;;;; replies, including the fields that are optional.

(defpackage #:enchiridion-anthropic-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-anthropic-test)

;;;; Fixtures.

(defparameter *text-reply*
  "{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\
\"model\":\"claude-sonnet-5-5\",\
\"content\":[{\"type\":\"text\",\"text\":\"hello \"},\
{\"type\":\"text\",\"text\":\"there\"}],\
\"stop_reason\":\"end_turn\",\
\"usage\":{\"input_tokens\":11,\"output_tokens\":3,\
\"cache_read_input_tokens\":100,\"cache_creation_input_tokens\":7}}"
  "A successful reply with two text blocks and a warm cache.")

(defparameter *tool-reply*
  "{\"id\":\"msg_2\",\"model\":\"claude-sonnet-5-5\",\
\"content\":[{\"type\":\"text\",\"text\":\"reading\"},\
{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"file-read\",\
\"input\":{\"path\":\"SOUL.md\"}}],\
\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":20,\"output_tokens\":8}}"
  "A reply that asks for a tool rather than answering.")

;;;; Helpers.

(defun wire (text)
  "Return TEXT as jzon data: objects are hash tables and arrays are vectors."
  (com.inuoe.jzon:parse text))

(defun request-body (messages &key tools (backend nil) (model nil))
  "Return the Messages request text for MESSAGES, as the backend would send it."
  (enchiridion.llm:anthropic-completion-request
   (or backend (enchiridion.llm:anthropic-backend :api-key "k"))
   messages
   :tools tools
   :model model))

(defun tool-definition (name)
  "Return one tool definition shaped the way the registry builds it."
  (let ((entry (make-hash-table :test #'equal)))
    (setf (gethash "name" entry) name)
    (setf (gethash "description" entry) (format nil "The ~A tool." name))
    (setf (gethash "parameters" entry)
          (enchiridion.llm::json-object :type "object"))
    entry))

(defun call (id name arguments)
  (enchiridion.llm::%make-tool-call :id id :name name :arguments arguments))

(defun cache-breakpoints (text)
  "Return how many cache_control markers TEXT carries."
  (loop with start = 0
        for position = (search "cache_control" text :start2 start)
        while position
        do (setf start (+ position (length "cache_control")))
        count 1))

;;;; The backend.

(deftest an-anthropic-backend-satisfies-every-operation-the-kernel-calls ()
  (let ((backend (enchiridion.llm:anthropic-backend :api-key "k")))
    (ok (enchiridion.llm:backendp backend))
    (ok (search "anthropic" (enchiridion.llm:backend-name backend)))))

(deftest an-anthropic-base-url-gains-a-trailing-slash ()
  (ok (search "/v1/"
              (enchiridion.llm:backend-name
               (enchiridion.llm:anthropic-backend
                :base-url "https://example.test/v1" :api-key "k"))))
  (testing "and one that already has it is left alone"
    (ng (search "v1//"
                (enchiridion.llm:backend-name
                 (enchiridion.llm:anthropic-backend
                  :base-url "https://example.test/v1/" :api-key "k"))))))

(deftest anthropic-capabilities-claim-the-breakpoints-it-really-sends ()
  (let ((capabilities (enchiridion.llm:model-capabilities
                       (enchiridion.llm:anthropic-backend :api-key "k"))))
    (ok (getf capabilities :tools))
    (ok (getf capabilities :streaming))
    (ok (getf capabilities :cache))
    (testing "unlike the OpenAI backend, which places none"
      (ok (getf capabilities :cache-breakpoints)))))

;;;; The request.

(deftest a-messages-request-carries-the-required-max-tokens ()
  (let ((data (wire (request-body (list (enchiridion.llm:user-message "hi"))
                                  :model "a-model"))))
    (ok (string= "a-model" (gethash "model" data)))
    (ok (eql 4096 (gethash "max_tokens" data))))
  (testing "and a connection cap is what is sent, with its own model"
    (let ((data (wire (request-body
                       (list (enchiridion.llm:user-message "hi"))
                       :backend (enchiridion.llm:anthropic-backend
                                 :api-key "k" :model "wire-model"
                                 :max-tokens 512)))))
      (ok (string= "wire-model" (gethash "model" data)))
      (ok (eql 512 (gethash "max_tokens" data))))))

(deftest instructions-are-hoisted-out-of-the-message-array ()
  (let* ((data (wire (request-body
                      (list (enchiridion.llm:system-message "be brief")
                            (enchiridion.llm:user-message "hi")))))
         (system (gethash "system" data))
         (messages (gethash "messages" data)))
    (ok (vectorp system))
    (ok (= 1 (length system)))
    (ok (string= "be brief" (gethash "text" (aref system 0))))
    (testing "and no message carries a system role"
      (ok (= 1 (length messages)))
      (ok (string= "user" (gethash "role" (aref messages 0)))))))

(deftest several-system-messages-become-one-instruction-block ()
  (let* ((data (wire (request-body
                      (list (enchiridion.llm:system-message "one")
                            (enchiridion.llm:system-message "two")
                            (enchiridion.llm:user-message "hi")))))
         (system (gethash "system" data))
         (text (gethash "text" (aref system 0))))
    (ok (= 1 (length system)))
    (ok (search "one" text))
    (ok (search "two" text))
    (testing "in the order the operator wrote them"
      (ok (< (search "one" text) (search "two" text))))))

(deftest absent-request-fields-are-omitted-and-not-sent-as-false ()
  (let ((data (wire (request-body (list (enchiridion.llm:user-message "hi"))))))
    (testing "a conversation with no instructions has no system field"
      (multiple-value-bind (value present) (gethash "system" data)
        (declare (ignore value))
        (ng present)))
    (testing "and no tools means neither tools nor tool_choice"
      (multiple-value-bind (value present) (gethash "tools" data)
        (declare (ignore value))
        (ng present))
      (multiple-value-bind (value present) (gethash "tool_choice" data)
        (declare (ignore value))
        (ng present))))
  (testing "an empty message list is an array, not false"
    (let* ((data (wire (request-body '())))
           (messages (gethash "messages" data)))
      (ok (vectorp messages))
      (ok (zerop (length messages))))))

(deftest an-assistant-tool-call-becomes-a-tool-use-block-with-an-object-input ()
  (let* ((data (wire (request-body
                      (list (enchiridion.llm:assistant-message
                             "reading"
                             (list (call "toolu_1" "file-read"
                                         "{\"path\":\"SOUL.md\"}")))))))
         (message (aref (gethash "messages" data) 0))
         (content (gethash "content" message))
         (use (aref content 1)))
    (ok (string= "assistant" (gethash "role" message)))
    (ok (string= "text" (gethash "type" (aref content 0))))
    (ok (string= "tool_use" (gethash "type" use)))
    (ok (string= "toolu_1" (gethash "id" use)))
    (ok (string= "file-read" (gethash "name" use)))
    (testing "the input is an object and not a plist written as an array"
      (ok (hash-table-p (gethash "input" use)))
      (ok (string= "SOUL.md" (gethash "path" (gethash "input" use)))))))

(deftest a-tool-call-with-no-arguments-sends-an-empty-object ()
  (let* ((body (request-body
                (list (enchiridion.llm:assistant-message
                       "" (list (call "toolu_1" "clock" ""))))))
         (data (wire body))
         (content (gethash "content" (aref (gethash "messages" data) 0)))
         (use (aref content 0)))
    (testing "an assistant turn that only called a tool has no text block"
      (ok (string= "tool_use" (gethash "type" use))))
    (ok (hash-table-p (gethash "input" use)))
    (ok (zerop (hash-table-count (gethash "input" use))))
    (testing "and on the wire the input is {} and not false"
      (ok (search "\"input\":{}" body)))))

(deftest a-tool-result-becomes-a-user-message-with-a-tool-result-block ()
  (let* ((data (wire (request-body
                      (list (enchiridion.llm:tool-message "42" "toolu_1")))))
         (messages (gethash "messages" data))
         (message (aref messages 0))
         (block (aref (gethash "content" message) 0)))
    (ok (= 1 (length messages)))
    (ok (string= "user" (gethash "role" message)))
    (ok (string= "tool_result" (gethash "type" block)))
    (ok (string= "toolu_1" (gethash "tool_use_id" block)))
    (ok (string= "42" (gethash "content" block)))))

(deftest consecutive-tool-results-merge-into-one-user-message ()
  (let* ((data (wire (request-body
                      (list (enchiridion.llm:tool-message "one" "toolu_1")
                            (enchiridion.llm:tool-message "two" "toolu_2")))))
         (messages (gethash "messages" data))
         (content (gethash "content" (aref messages 0))))
    (ok (= 1 (length messages)))
    (ok (= 2 (length content)))
    (testing "in the order the tools ran"
      (ok (string= "toolu_1" (gethash "tool_use_id" (aref content 0))))
      (ok (string= "one" (gethash "content" (aref content 0))))
      (ok (string= "toolu_2" (gethash "tool_use_id" (aref content 1))))
      (ok (string= "two" (gethash "content" (aref content 1)))))))

(deftest text-after-tool-results-stays-in-the-message-and-comes-last ()
  (let* ((data (wire (request-body
                      (list (enchiridion.llm:tool-message "42" "toolu_1")
                            (enchiridion.llm:user-message "and now?")))))
         (messages (gethash "messages" data))
         (content (gethash "content" (aref messages 0))))
    (ok (= 1 (length messages)))
    (ok (= 2 (length content)))
    (testing "a tool_result block has to be the first block in its message"
      (ok (string= "tool_result" (gethash "type" (aref content 0)))))
    (ok (string= "text" (gethash "type" (aref content 1))))
    (ok (string= "and now?" (gethash "text" (aref content 1))))))

(deftest no-message-on-the-wire-carries-a-tool-role ()
  (let* ((data (wire (request-body
                      (list (enchiridion.llm:user-message "hi")
                            (enchiridion.llm:assistant-message "ok")
                            (enchiridion.llm:tool-message "r" "toolu_1")))))
         (messages (gethash "messages" data)))
    (ok (every (lambda (message)
                 (member (gethash "role" message) '("user" "assistant")
                         :test #'string=))
               messages))))

(deftest tools-are-flat-and-the-schema-key-is-renamed ()
  (let* ((data (wire (request-body
                      (list (enchiridion.llm:user-message "hi"))
                      :tools (list (tool-definition "file-read")))))
         (tools (gethash "tools" data))
         (tool (aref tools 0))
         (choice (gethash "tool_choice" data)))
    (ok (= 1 (length tools)))
    (ok (string= "file-read" (gethash "name" tool)))
    (ok (stringp (gethash "description" tool)))
    (testing "the schema keeps its object and gains the API's key name"
      (ok (hash-table-p (gethash "input_schema" tool)))
      (multiple-value-bind (value present) (gethash "parameters" tool)
        (declare (ignore value))
        (ng present)))
    (testing "with no function wrapper around the three keys"
      (multiple-value-bind (value present) (gethash "function" tool)
        (declare (ignore value))
        (ng present)))
    (testing "and tool_choice is auto whenever there are tools"
      (ok (string= "auto" (gethash "type" choice))))))

(deftest the-last-system-block-and-last-tool-definition-carry-the-breakpoints ()
  (let* ((body (request-body (list (enchiridion.llm:system-message "sys")
                                   (enchiridion.llm:user-message "hi"))
                             :tools (list (tool-definition "one")
                                          (tool-definition "two"))))
         (data (wire body))
         (system (gethash "system" data))
         (tools (gethash "tools" data))
         (messages (gethash "messages" data)))
    (ok (string= "ephemeral"
                 (gethash "type" (gethash "cache_control" (aref system 0)))))
    (testing "only the last tool definition, because the rest is one prefix"
      (multiple-value-bind (value present)
          (gethash "cache_control" (aref tools 0))
        (declare (ignore value))
        (ng present))
      (ok (hash-table-p (gethash "cache_control" (aref tools 1)))))
    (testing "never on the incoming user message"
      (multiple-value-bind (value present)
          (gethash "cache_control"
                   (aref (gethash "content" (aref messages 0)) 0))
        (declare (ignore value))
        (ng present)))
    (testing "and the request stays under the API's cap of four"
      (ok (= 2 (cache-breakpoints body))))))

(deftest a-connection-that-does-not-ask-for-caching-sends-no-breakpoints ()
  (let ((body (request-body (list (enchiridion.llm:system-message "sys")
                                  (enchiridion.llm:user-message "hi"))
                            :backend (enchiridion.llm:anthropic-backend
                                      :api-key "k" :cache-p nil)
                            :tools (list (tool-definition "one")))))
    (ok (zerop (cache-breakpoints body)))))

(deftest a-configured-cache-ttl-rides-on-the-breakpoint ()
  (let* ((body (request-body (list (enchiridion.llm:system-message "sys")
                                   (enchiridion.llm:user-message "hi"))
                             :backend (enchiridion.llm:anthropic-backend
                                       :api-key "k" :cache-ttl "1h")))
         (block (aref (gethash "system" (wire body)) 0)))
    (ok (string= "1h" (gethash "ttl" (gethash "cache_control" block))))))

;;;; The reply.

(deftest a-text-reply-parses-into-a-completion-with-a-folded-input-count ()
  (let ((completion (enchiridion.llm:anthropic-parse-completion *text-reply*)))
    (testing "every text block is concatenated"
      (ok (string= "hello there" (enchiridion.llm:completion-text completion))))
    (ok (string= "claude-sonnet-5-5"
                 (enchiridion.llm:completion-model completion)))
    (ok (string= "stop" (enchiridion.llm:completion-stop-reason completion)))
    (testing "input_tokens excludes the cache, so the three are added"
      (ok (= 118 (enchiridion.llm:completion-input-tokens completion))))
    (ok (= 3 (enchiridion.llm:completion-output-tokens completion)))
    (ok (= 100 (enchiridion.llm:completion-cache-read-tokens completion)))
    (ok (= 7 (enchiridion.llm:completion-cache-write-tokens completion)))
    (testing "and the total still counts the prompt once"
      (ok (= 121 (enchiridion.llm:completion-total-tokens completion))))))

(deftest a-tool-use-reply-parses-into-a-tool-call ()
  (let* ((completion (enchiridion.llm:anthropic-parse-completion *tool-reply*))
         (calls (enchiridion.llm:completion-tool-calls completion)))
    (ok (string= "reading" (enchiridion.llm:completion-text completion)))
    (ok (string= "tool_calls"
                 (enchiridion.llm:completion-stop-reason completion)))
    (ok (= 1 (length calls)))
    (ok (string= "toolu_1" (enchiridion.llm:tool-call-id (first calls))))
    (ok (string= "file-read" (enchiridion.llm:tool-call-name (first calls))))
    (testing "arguments are the JSON text of the object the wire sent"
      (let ((arguments (enchiridion.llm:tool-call-arguments (first calls))))
        (ok (char= #\{ (char arguments 0)))
        (ok (string= "SOUL.md"
                     (getf (enchiridion.llm:parse-json arguments) :path)))))))

(deftest a-tool-use-with-no-input-becomes-an-empty-argument-object ()
  (testing "an absent input"
    (let* ((completion (enchiridion.llm:anthropic-parse-completion
                        "{\"content\":[{\"type\":\"tool_use\",\"id\":\"t\",\
\"name\":\"clock\"}],\"stop_reason\":\"tool_use\"}"))
           (arguments (enchiridion.llm:tool-call-arguments
                       (first (enchiridion.llm:completion-tool-calls
                               completion)))))
      (ok (string= "{}" arguments))))
  (testing "and a null input"
    (let* ((completion (enchiridion.llm:anthropic-parse-completion
                        "{\"content\":[{\"type\":\"tool_use\",\"id\":\"t\",\
\"name\":\"clock\",\"input\":null}],\"stop_reason\":\"tool_use\"}"))
           (arguments (enchiridion.llm:tool-call-arguments
                       (first (enchiridion.llm:completion-tool-calls
                               completion)))))
      (ok (string= "{}" arguments)))))

(deftest an-empty-content-array-is-a-legal-empty-completion ()
  (let ((completion (enchiridion.llm:anthropic-parse-completion
                     "{\"content\":[],\"stop_reason\":\"end_turn\",\
\"usage\":{}}")))
    (ok (zerop (length (enchiridion.llm:completion-text completion))))
    (ok (string= "stop" (enchiridion.llm:completion-stop-reason completion)))
    (ok (= 0 (enchiridion.llm:completion-input-tokens completion)))))

(deftest a-reply-with-no-content-field-signals-as-a-backend-error ()
  (testing "an absent field is a provider failure"
    (ok (signals (enchiridion.llm:anthropic-parse-completion
                  "{\"error\":{\"type\":\"overloaded_error\",\
\"message\":\"Overloaded\"}}")
                 'enchiridion.errors:backend-error)))
  (testing "and a null content is the same failure"
    (ok (signals (enchiridion.llm:anthropic-parse-completion
                  "{\"content\":null}")
                 'enchiridion.errors:backend-error)))
  (testing "the condition names the backend"
    (handler-case
        (progn (enchiridion.llm:anthropic-parse-completion "{\"content\":null}")
               (ok nil "the reply should have signalled"))
      (enchiridion.errors:backend-error (condition)
        (ok (string= "anthropic"
                     (enchiridion.errors::error-backend condition)))))))

(deftest every-wire-stop-reason-gets-this-systems-name ()
  (flet ((reason (wire-reason)
           (enchiridion.llm:completion-stop-reason
            (enchiridion.llm:anthropic-parse-completion
             (format nil "{\"content\":[],\"stop_reason\":\"~A\"}"
                     wire-reason)))))
    (ok (string= "stop" (reason "end_turn")))
    (ok (string= "stop" (reason "stop_sequence")))
    (ok (string= "length" (reason "max_tokens")))
    (ok (string= "tool_calls" (reason "tool_use")))
    (testing "an unknown reason is recorded rather than renamed"
      (ok (string= "pause_turn" (reason "pause_turn"))))
    (testing "and an absent reason is empty, not a guess"
      (ok (string= "" (enchiridion.llm:completion-stop-reason
                       (enchiridion.llm:anthropic-parse-completion
                        "{\"content\":[]}")))))))

;;;; The transport.

(deftest the-messages-transport-sends-the-headers-this-api-requires ()
  (let ((headers (enchiridion.llm::anthropic-headers "sk-ant-test" "2023-06-01")))
    (ok (string= "application/json" (cdr (assoc :content-type headers))))
    (ok (string= "sk-ant-test" (cdr (assoc :x-api-key headers))))
    (ok (string= "2023-06-01" (cdr (assoc :anthropic-version headers))))
    (testing "the key is not carried in an Authorization or bearer-auth header"
      (ok (null (assoc :authorization headers)))
      (ok (null (assoc :bearer-auth headers))))
    (testing "and the OpenCode routing header is not sent to it"
      (ok (null (assoc :x-opencode-session headers))))))

(deftest the-version-header-is-the-date-the-service-requires ()
  (ok (string= "2023-06-01" enchiridion.llm::+anthropic-version+)))

(deftest a-429-is-retried-and-the-loop-ends ()
  (let* ((calls 0)
         (paths '())
         (enchiridion.llm::*retry-delay* 0)
         (enchiridion.llm::*http-post-function*
           (lambda (request)
             (incf calls)
             (push (enchiridion.llm::http-request-url request) paths)
             (if (< calls 3)
                 (error 'dexador.error:http-request-failed
                        :status 429 :body "slow down"
                        :headers nil :uri nil :method :post)
                 *text-reply*))))
    (let ((completion (enchiridion.llm:complete
                       (enchiridion.llm:anthropic-backend :api-key "k"
                                                          :retries 2)
                       (list (enchiridion.llm:user-message "hi")))))
      (ok (string= "hello there" (enchiridion.llm:completion-text completion)))
      (ok (= 3 calls) "two 429 responses and one success")
      (testing "and every attempt went to the Messages endpoint"
        (ok (= 3 (length paths)))
        (ok (every (lambda (url) (search "v1/messages" url)) paths))))))

(deftest a-529-overload-is-retried-too ()
  (let* ((calls 0)
         (enchiridion.llm::*retry-delay* 0)
         (enchiridion.llm::*http-post-function*
           (lambda (request)
             (declare (ignore request))
             (incf calls)
             (if (< calls 2)
                 (error 'dexador.error:http-request-failed
                        :status 529 :body "overloaded"
                        :headers nil :uri nil :method :post)
                 *text-reply*))))
    (let ((completion (enchiridion.llm:complete
                       (enchiridion.llm:anthropic-backend :api-key "k"
                                                          :retries 2)
                       (list (enchiridion.llm:user-message "hi")))))
      (ok (string= "hello there" (enchiridion.llm:completion-text completion)))
      (ok (= 2 calls)))))

(deftest a-401-is-reported-at-once ()
  (let* ((calls 0)
         (enchiridion.llm::*retry-delay* 0)
         (enchiridion.llm::*http-post-function*
           (lambda (request)
             (declare (ignore request))
             (incf calls)
             (error 'dexador.error:http-request-failed
                    :status 401 :body "bad key"
                    :headers nil :uri nil :method :post))))
    (ok (signals (enchiridion.llm:complete
                  (enchiridion.llm:anthropic-backend :api-key "k" :retries 2)
                  (list (enchiridion.llm:user-message "hi")))
                 'enchiridion.errors:transport-error))
    (ok (= 1 calls))))

(deftest a-complete-call-sends-the-turn-model-and-the-tools ()
  (let* ((seen nil)
         (enchiridion.llm::*http-post-function*
           (lambda (request)
             (setf seen (enchiridion.llm::http-request-body request))
             *text-reply*))
         (completion (enchiridion.llm:complete
                      (enchiridion.llm:anthropic-backend
                       :api-key "k" :model "connection-model")
                      (list (enchiridion.llm:user-message "hi"))
                      :model "turn-model"
                      :tools (list (tool-definition "file-read")))))
    (let ((data (wire seen)))
      (ok (string= "turn-model" (gethash "model" data)))
      (ok (eql 4096 (gethash "max_tokens" data)))
      (ok (= 1 (length (gethash "tools" data)))))
    (ok (string= "hello there" (enchiridion.llm:completion-text completion)))))

;;;; Provider selection.

(deftest an-anthropic-backend-is-the-one-the-config-selects ()
  (enchiridion.llm.secrets:clear-secrets)
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:backend :anthropic) :api-key "k")))
    (ok (enchiridion.llm:backendp backend))
    (ok (search "api.anthropic.com" (enchiridion.llm:backend-name backend)))
    (testing "from the anthropic row in the provider table"
      (ok (string= "claude-sonnet-5-5"
                   (enchiridion.llm::anthropic-connection-model backend))))))

(deftest provider-anthropic-implies-the-anthropic-backend ()
  (enchiridion.llm.secrets:clear-secrets)
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:llm (:provider :anthropic)) :api-key "k")))
    (ok (search "api.anthropic.com" (enchiridion.llm:backend-name backend)))
    (ok (string= "claude-sonnet-5-5"
                 (enchiridion.llm::anthropic-connection-model backend)))))

(deftest a-key-for-another-provider-does-not-change-the-backend ()
  ;; :BACKEND :ANTHROPIC chooses the row and the request shape together, so an
  ;; OpenAI key lying in the environment cannot pair the Messages request with
  ;; the OpenAI endpoint.
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "OPENAI_API_KEY"
                                           "fake-openai-key-123456")
  (unwind-protect
       (let ((backend (enchiridion.llm:resolve-backend
                       :config '(:backend :anthropic) :api-key "k")))
         (ok (search "api.anthropic.com"
                     (enchiridion.llm:backend-name backend))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest an-explicit-base-url-still-wins-for-anthropic ()
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:llm (:backend :anthropic)
                            (:base-url "https://proxy.test/v1/"))
                  :api-key "k")))
    (ok (search "proxy.test" (enchiridion.llm:backend-name backend)))))

(deftest an-explicit-model-still-wins-for-anthropic ()
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:llm (:backend :anthropic)
                            (:model-primary "a-chosen-model"))
                  :api-key "k")))
    (ok (string= "a-chosen-model"
                 (enchiridion.llm::anthropic-connection-model backend)))))

(deftest an-anthropic-base-url-selects-the-anthropic-wire ()
  (enchiridion.llm.secrets:clear-secrets)
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:llm (:base-url "https://api.anthropic.com/"))
                  :api-key "k")))
    (ok (search "api.anthropic.com" (enchiridion.llm:backend-name backend)))))

(deftest only-an-anthropic-key-selects-anthropic ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "ANTHROPIC_API_KEY"
                                           "fake-anthropic-key-123456")
  (unwind-protect
       (let ((backend (enchiridion.llm:resolve-backend :api-key "k")))
         (ok (search "api.anthropic.com"
                     (enchiridion.llm:backend-name backend)))
         (ok (string= "ANTHROPIC_API_KEY"
                      (enchiridion.llm:default-api-key-env))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest the-configured-key-variable-still-wins-for-anthropic ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "MY_ANTHROPIC_KEY"
                                           "fake-anthropic-key-123456")
  (unwind-protect
       (let* ((config '(:llm (:backend :anthropic)
                         (:api-key-env "MY_ANTHROPIC_KEY")))
              (backend (enchiridion.llm:resolve-backend :config config)))
         (ok (search "api.anthropic.com"
                     (enchiridion.llm:backend-name backend)))
         (ok (string= "MY_ANTHROPIC_KEY"
                      (enchiridion.llm:default-api-key-env config))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest the-configured-max-tokens-reaches-the-connection ()
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:llm (:backend :anthropic) (:max-tokens 1234))
                  :api-key "k")))
    (ok (eql 1234
            (enchiridion.llm::anthropic-connection-max-tokens backend)))))

(deftest the-max-tokens-default-is-a-whole-reply ()
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:backend :anthropic) :api-key "k")))
    (ok (eql 4096
            (enchiridion.llm::anthropic-connection-max-tokens backend)))))

(deftest every-provider-key-variable-is-named ()
  ;; The catalog cache is a run-time artefact: an operator who has refreshed it
  ;; holds hundreds of provider key names, and this test is about the shipped
  ;; configuration alone. Binding the path to somewhere that cannot exist keeps
  ;; the assertion the same whether run/ holds a cache or not, which is the
  ;; difference between a test and a report on the machine it ran on.
  (let ((enchiridion.llm::*catalog* nil)
        (enchiridion.llm::*catalog-path*
          #p"/nonexistent/enchiridion-providers.json"))
    (let ((names (enchiridion.llm:provider-key-names
                  '(:llm (:api-key-env "MY_LLM_KEY")))))
      (ok (member "OPENAI_API_KEY" names :test #'string=))
      (ok (member "OPENCODE_API_KEY" names :test #'string=))
      (ok (member "ANTHROPIC_API_KEY" names :test #'string=))
      (ok (member "MY_LLM_KEY" names :test #'string=))
      (testing "and no name is repeated"
        (ok (= (length names)
               (length (remove-duplicates names :test #'string=))))))
    (testing "the active configuration supplies the configured name"
      (let ((enchiridion:*config* '(:llm (:api-key-env "ACTIVE_KEY"))))
        (ok (member "ACTIVE_KEY" (enchiridion.llm:provider-key-names)
                    :test #'string=))))
    (testing "and the shipped configuration names no LLM key at all"
      (ok (equal '("OPENAI_API_KEY" "OPENCODE_API_KEY" "ANTHROPIC_API_KEY")
                 (enchiridion.llm:provider-key-names '()))))))
