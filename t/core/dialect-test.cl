;;;; dialect-test.cl --- The two generic handlers under a provider's dialect.
;;;;
;;;; Every test here is offline. *HTTP-POST-FUNCTION* and *HTTP-GET-FUNCTION*
;;;; are bound to stubs, so what is asserted is the http-request a handler
;;;; built --- its URL, its headers, its body --- and never a socket.
;;;;
;;;; The wires are driven through the same entry points a provider uses: the
;;;; handler's builder turns a PROVIDER into a backend, and COMPLETE runs the
;;;; whole path from the dialect to the request. A test that called the request
;;;; builder directly would pass while the transport dropped the credential,
;;;; the deployment path or the version, and those are exactly the mistakes a
;;;; dialect is supposed to make impossible.
;;;;
;;;; A dialect is data, so most of these tests differ by one profile keyword
;;;; and assert one difference on the wire.

(defpackage #:enchiridion-dialect-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-dialect-test)

;;;; Fixtures.

(defparameter *text-reply*
  "{\"model\":\"a-model\",\"choices\":[{\"index\":0,\
\"message\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":\"stop\"}],\
\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":3,\
\"prompt_tokens_details\":{\"cached_tokens\":7}}}"
  "A minimal reply, with a warm prefix cache in the generic field.")

(defparameter *deepseek-reply*
  "{\"model\":\"deepseek-chat\",\"choices\":[{\"index\":0,\
\"message\":{\"role\":\"assistant\",\"content\":\"the answer\",\
\"reasoning_content\":\"the notes\"},\"finish_reason\":\"stop\"}],\
\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5,\
\"prompt_cache_hit_tokens\":80}}"
  "A reply in DeepSeek's shape: reasoning beside the answer, cache hits under
a name of its own.")

(defparameter *reasoning-only-reply*
  "{\"model\":\"deepseek-reasoner\",\"choices\":[{\"index\":0,\
\"message\":{\"role\":\"assistant\",\"content\":null,\
\"reasoning_content\":\"the notes\"},\"finish_reason\":\"stop\"}],\
\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":5}}"
  "A reasoning reply with no answer text at all.")

(defparameter *openrouter-reply*
  "{\"model\":\"vendor/model\",\"choices\":[{\"index\":0,\
\"message\":{\"role\":\"assistant\",\"content\":\"hello\",\"reasoning\":\"the notes\"},\
\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":50,\"completion_tokens\":4,\
\"prompt_tokens_details\":{\"cached_tokens\":30,\"cache_write_tokens\":10}}}"
  "A reply in OpenRouter's shape: reasoning, and both cache counts nested.")

(defparameter *anthropic-reply*
  "{\"id\":\"msg_1\",\"model\":\"claude\",\
\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"stop_reason\":\"end_turn\",\
\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}"
  "A minimal Messages reply.")

(defparameter *ollama-models*
  "{\"models\":[{\"name\":\"llama3.2:latest\",\"model\":\"llama3.2:latest\",\
\"modified_at\":\"2026-01-01T00:00:00Z\"}]}"
  "Ollama's model list, which names the model under NAME.")

(defparameter *openrouter-models*
  "{\"data\":[{\"id\":\"vendor/model-1\",\"name\":\"Model One\",\
\"context_length\":128000,\"pricing\":{\"prompt\":\"0.000001\",\
\"completion\":\"0.000002\"},\"supported_parameters\":[\"tools\",\"reasoning\"]}]}"
  "OpenRouter's rich model list: prices as USD-per-token strings.")

(defparameter *anthropic-models-page-1*
  "{\"data\":[{\"id\":\"claude-a\",\"display_name\":\"Claude A\"},\
{\"id\":\"claude-b\",\"display_name\":\"Claude B\"}],\"has_more\":true,\
\"first_id\":\"claude-a\",\"last_id\":\"claude-b\"}"
  "The first page of a Messages model list.")

(defparameter *anthropic-models-page-2*
  "{\"data\":[{\"id\":\"claude-c\",\"display_name\":\"Claude C\"}],\
\"has_more\":false}"
  "The page that follows it.")

(defparameter *string-arguments-reply*
  "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\
\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\
\"function\":{\"name\":\"file-read\",\"arguments\":\"{\\\"path\\\":\\\"SOUL.md\\\"}\"}}]},\
\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"
  "A tool call whose arguments are the JSON string the specification wants.")

(defparameter *object-arguments-reply*
  "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\
\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\
\"function\":{\"name\":\"file-read\",\"arguments\":{\"path\":\"SOUL.md\"}}}]},\
\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"
  "A tool call whose arguments are an object, which some servers send.")

(defparameter *empty-arguments-reply*
  "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\
\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\
\"function\":{\"name\":\"clock\",\"arguments\":\"\"}}]},\
\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"
  "A tool call whose arguments are the empty string.")

(defparameter *absent-arguments-reply*
  "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\
\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\
\"function\":{\"name\":\"clock\"}}]},\"finish_reason\":\"tool_calls\"}],\
\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"
  "A tool call with no arguments field at all.")

;;;; Helpers.

(defun dialect (profile &rest overrides)
  "Return a resolved OpenAI-protocol dialect for PROFILE with OVERRIDES."
  (apply #'enchiridion.llm:make-dialect-for profile
         :protocol :openai overrides))

(defun messages-dialect (profile &rest overrides)
  "Return a resolved Anthropic-protocol dialect for PROFILE with OVERRIDES."
  (apply #'enchiridion.llm:make-dialect-for profile
         :protocol :anthropic overrides))

(defun header (name headers)
  "Return the value the header NAME carries in HEADERS, or NIL.

The names are compared as strings because HTTP header names are compared that
way, and because a profile spells its header as a string while this tree spells
the ones it builds as keywords."
  (let ((cell (assoc name headers :test #'string-equal)))
    (and cell (cdr cell))))

(defun capture-post (reply seen)
  "Return a POST stub that stores the request in the first cell of SEEN."
  (lambda (request)
    (setf (car seen) request)
    reply))

(defun capture-get (reply seen)
  "Return a GET stub that stores (URL HEADERS) in the first cell of SEEN."
  (lambda (url &key headers timeout)
    (declare (ignore timeout))
    (setf (car seen) (list url headers))
    reply))

(defun wire (text)
  "Return TEXT as jzon data: objects are hash tables and arrays are vectors."
  (com.inuoe.jzon:parse text))

(defun tool-definition (name)
  "Return one tool definition shaped the way the registry builds it."
  (let ((entry (make-hash-table :test #'equal)))
    (setf (gethash "name" entry) name)
    (setf (gethash "description" entry) (format nil "The ~A tool." name))
    (setf (gethash "parameters" entry)
          (enchiridion.llm::json-object :type "object"))
    entry))

(defun handler (id)
  "Return the registered adapter ID names."
  (enchiridion.llm:find-api-handler id))

(defun provider (&rest options)
  "Return a resolved PROVIDER shaped the way the provider table builds one.

OPTIONS come first in the constructor's keyword list because Common Lisp reads
the leftmost of a repeated keyword: a caller that names :base-url or :key
overrides the default here rather than losing to it."
  (apply #'enchiridion.llm::%make-provider
         (append options
                 (list :id :test :name "Test provider" :api :openai-chat
                       :base-url "https://api.openai.com/v1/"
                       :key "test-key"))))

(defun arguments-text (reply)
  "Return the arguments of the first tool call in REPLY, as text."
  (let* ((completion (enchiridion.llm:parse-completion
                      (enchiridion.llm:parse-json reply)))
         (call (first (enchiridion.llm:completion-tool-calls completion))))
    (enchiridion.llm:tool-call-arguments call)))

;;;; The generic wire.

(deftest the-generic-wire-is-what-it-always-was ()
  (let* ((seen (list nil))
         (enchiridion.llm::*http-post-function* (capture-post *text-reply* seen))
         (completion (enchiridion.llm:complete
                      (enchiridion.llm:openai-backend :api-key "k"
                                                      :model "a-model")
                      (list (enchiridion.llm:system-message "be brief")
                            (enchiridion.llm:user-message "hi"))
                      :tools (list (tool-definition "echo")))))
    (let* ((request (car seen))
           (headers (enchiridion.llm::http-request-headers request))
           (body (enchiridion.llm:parse-json
                  (enchiridion.llm::http-request-body request))))
      (testing "the path, the bearer token and the session header are unchanged"
        (ok (string= "https://api.openai.com/v1/chat/completions"
                     (enchiridion.llm::http-request-url request)))
        (ok (string= "Bearer k" (header :authorization headers)))
        (ok (= 32 (length (header :x-opencode-session headers)))))
      (testing "and the body is the generic chat completions shape"
        (ok (string= "a-model" (getf body :model)))
        (ok (null (getf body :stream)))
        (ok (string= "system" (getf (first (getf body :messages)) :role)))
        (ok (string= "auto" (getf body :tool_choice)))
        (ok (null (getf body :max_tokens))
            "no cap is configured, so neither spelling is written"))
      (testing "with no reasoning dialect, no reasoning is invented"
        (ok (string= "hello" (enchiridion.llm:completion-text completion)))
        (ok (string= "" (enchiridion.llm:completion-reasoning-text completion)))
        (ok (= 11 (enchiridion.llm:completion-input-tokens completion)))
        (testing "and the generic cached-token path is still read"
          (ok (= 7 (enchiridion.llm:completion-cache-read-tokens completion))))))))

;;;; Azure.

(deftest azure-uses-its-deployment-path-and-its-own-cap-field ()
  (let* ((seen (list nil))
         (enchiridion.llm::*http-post-function* (capture-post *text-reply* seen))
         (backend (enchiridion.llm:openai-backend
                   :base-url "https://acme.openai.azure.com/"
                   :api-key "az-key" :model "gpt-4o" :max-tokens 256
                   :dialect (dialect :azure))))
    (enchiridion.llm:complete backend
                              (list (enchiridion.llm:system-message "be brief")
                                    (enchiridion.llm:user-message "hi")))
    (let* ((request (car seen))
           (headers (enchiridion.llm::http-request-headers request))
           (body (enchiridion.llm:parse-json
                  (enchiridion.llm::http-request-body request))))
      (testing "the deployment is in the path and api-version is in the query"
        (ok (string= (concatenate 'string
                                  "https://acme.openai.azure.com/"
                                  "openai/deployments/gpt-4o/chat/completions"
                                  "?api-version=2024-06-01")
                     (enchiridion.llm::http-request-url request))))
      (testing "the key travels in api-key and not in an Authorization header"
        (ok (string= "az-key" (header "api-key" headers)))
        (ok (null (header :authorization headers))))
      (testing "only max_completion_tokens is written"
        (ok (eql 256 (getf body :max_completion_tokens)))
        (ok (null (getf body :max_tokens))))
      (testing "and the system role is the developer role on this wire"
        (ok (string= "developer" (getf (first (getf body :messages)) :role)))))))

;;;; A local server.

(deftest a-local-server-gets-no-credential-and-no-tool-choice ()
  (let* ((seen (list nil))
         (enchiridion.llm::*http-post-function* (capture-post *text-reply* seen))
         (backend (enchiridion.llm:openai-backend
                   :base-url "http://localhost:11434/v1/"
                   :api-key "unused" :model "llama3.2"
                   :dialect (dialect :openai-local))))
    (enchiridion.llm:complete backend (list (enchiridion.llm:user-message "hi"))
                              :tools (list (tool-definition "echo")))
    (let* ((request (car seen))
           (headers (enchiridion.llm::http-request-headers request))
           (body (enchiridion.llm:parse-json
                  (enchiridion.llm::http-request-body request))))
      (testing "no credential header at all, in either spelling"
        (ng (header :authorization headers))
        (ng (header "api-key" headers)))
      (testing "and no tool_choice, because this server ignores it"
        (ng (getf body :tool_choice)))
      (testing "but the tools themselves are still offered"
        (ok (= 1 (length (getf body :tools))))))))

;;;; Providers that report their reasoning beside the answer.

(deftest deepseek-reads-its-own-reasoning-and-cache-fields ()
  (let* ((seen (list nil))
         (enchiridion.llm::*http-post-function* (capture-post *deepseek-reply* seen))
         (completion (enchiridion.llm:complete
                      (enchiridion.llm:openai-backend
                       :api-key "k" :model "deepseek-chat"
                       :dialect (dialect :deepseek))
                      (list (enchiridion.llm:user-message "hi")))))
    (testing "the answer is the answer"
      (ok (string= "the answer" (enchiridion.llm:completion-text completion))))
    (testing "and the chain of thought is kept apart from it"
      (ok (string= "the notes"
                   (enchiridion.llm:completion-reasoning-text completion))))
    (testing "the cache hit is read under DeepSeek's own field name"
      (ok (= 80 (enchiridion.llm:completion-cache-read-tokens completion)))
      (ok (= 100 (enchiridion.llm:completion-input-tokens completion))))
    (testing "a reply that carries only the notes has no answer text"
      (let ((only-notes (enchiridion.llm:parse-completion
                         (enchiridion.llm:parse-json *reasoning-only-reply*)
                         :dialect (dialect :deepseek))))
        (ok (string= "" (enchiridion.llm:completion-text only-notes)))
        (ok (string= "the notes"
                     (enchiridion.llm:completion-reasoning-text only-notes)))))))

(deftest openrouter-reads-its-own-reasoning-and-both-cache-counts ()
  (let ((completion (enchiridion.llm:parse-completion
                     (enchiridion.llm:parse-json *openrouter-reply*)
                     :dialect (dialect :openrouter))))
    (ok (string= "hello" (enchiridion.llm:completion-text completion)))
    (ok (string= "the notes"
                 (enchiridion.llm:completion-reasoning-text completion)))
    (ok (= 30 (enchiridion.llm:completion-cache-read-tokens completion)))
    (testing "the nested cache write is read from the nested path"
      (ok (= 10 (enchiridion.llm:completion-cache-write-tokens completion))))))

;;;; A provider whose profile turns one field off and merges one in.

(defun openai-body (dialect &key tools (stream nil))
  "Return the parsed request body OPENAI-REQUEST-BODY builds for DIALECT."
  (enchiridion.llm:parse-json
   (enchiridion.llm:stringify
    (enchiridion.llm::openai-request-body
     "m" (list (enchiridion.llm:user-message "hi"))
     :tools tools :stream stream :dialect dialect))))

(deftest qwen-drops-parallel-tool-calls-and-merges-enable-thinking ()
  (let ((body (openai-body (dialect :qwen)
                           :tools (list (tool-definition "echo")))))
    (testing "tool_choice is still sent"
      (ok (string= "auto" (getf body :tool_choice))))
    (testing "parallel_tool_calls is not, because this provider defaults it off"
      (ng (getf body :parallel_tool_calls)))
    (testing "and the thinking switch is merged in from the profile"
      (ok (eq t (getf body :enable_thinking))))))

(deftest a-nested-extra-body-field-is-an-object-and-not-an-array ()
  (let* ((body (openai-body (dialect :zai)))
         (thinking (getf body :thinking)))
    (testing "the profile's plist for the thinking switch is written as an object"
      (ok (string= "enabled" (getf thinking :type))))))

(deftest stream-options-follow-the-profile-and-only-ride-a-stream ()
  (testing "a dialect that accepts the field gets it when a stream is asked for"
    (let ((body (openai-body (dialect :openai) :stream t)))
      (ok (eq t (getf body :stream)))
      (ok (eq t (getf (getf body :stream_options) :include_usage)))))
  (testing "Groq rejects the field, so its profile keeps it off the wire"
    (ng (getf (openai-body (dialect :groq) :stream t) :stream_options)))
  (testing "and a plain request never carries it"
    ;; The API accepts stream_options only beside "stream": true, so a
    ;; non-streaming request must not gain a field that makes it a 400.
    (ng (getf (openai-body (dialect :openai)) :stream_options))))

;;;; Tool arguments.

(deftest tool-arguments-normalise-from-all-three-shapes ()
  (testing "a JSON string is kept exactly as the model wrote it"
    (ok (string= "{\"path\":\"SOUL.md\"}" (arguments-text *string-arguments-reply*))))
  (testing "an object is written back as an object and not as an array"
    (ok (string= "{\"path\":\"SOUL.md\"}" (arguments-text *object-arguments-reply*))))
  (testing "an empty string becomes an empty object"
    (ok (string= "{}" (arguments-text *empty-arguments-reply*))))
  (testing "and so does an absent field"
    (ok (string= "{}" (arguments-text *absent-arguments-reply*)))))

;;;; Anthropic-shaped endpoints.

(deftest anthropics-own-wire-still-uses-x-api-key ()
  (let* ((seen (list nil))
         (enchiridion.llm::*http-post-function* (capture-post *anthropic-reply* seen))
         (backend (enchiridion.llm:anthropic-backend
                   :api-key "sk-ant" :model "claude"
                   :dialect (messages-dialect :anthropic))))
    (enchiridion.llm:complete backend (list (enchiridion.llm:user-message "hi")))
    (let* ((request (car seen))
           (headers (enchiridion.llm::http-request-headers request)))
      (ok (string= "sk-ant" (header :x-api-key headers)))
      (ng (header :authorization headers))
      (testing "and the required version header is still sent"
        (ok (string= "2023-06-01" (header :anthropic-version headers)))))))

(deftest an-anthropic-gateway-uses-a-bearer-token-instead ()
  (let* ((seen (list nil))
         (enchiridion.llm::*http-post-function* (capture-post *anthropic-reply* seen))
         (backend (enchiridion.llm:anthropic-backend
                   :base-url "https://gateway.test/"
                   :api-key "gw-key" :model "claude"
                   :dialect (messages-dialect :anthropic-gateway))))
    (enchiridion.llm:complete backend (list (enchiridion.llm:user-message "hi")))
    (let* ((request (car seen))
           (headers (enchiridion.llm::http-request-headers request)))
      (testing "the credential is a bearer token and x-api-key is gone"
        (ok (string= "Bearer gw-key" (header :authorization headers)))
        (ng (header :x-api-key headers)))
      (testing "the version header survives the credential path"
        (ok (string= "2023-06-01" (header :anthropic-version headers))))
      (testing "and so does the content type"
        (ok (string= "application/json" (header :content-type headers)))))))

(deftest a-body-version-profile-puts-the-revision-in-the-body ()
  (let* ((seen (list nil))
         (enchiridion.llm::*http-post-function* (capture-post *anthropic-reply* seen))
         (backend (enchiridion.llm:anthropic-backend
                   :api-key "k" :model "claude"
                   :dialect (messages-dialect
                             :anthropic
                             :overrides '(:version-location :body
                                          :version-value "test-2026-01-01")))))
    (enchiridion.llm:complete backend (list (enchiridion.llm:user-message "hi")))
    (let* ((request (car seen))
           (headers (enchiridion.llm::http-request-headers request))
           (body (wire (enchiridion.llm::http-request-body request))))
      (testing "the revision travels in the body"
        (ok (string= "test-2026-01-01" (gethash "anthropic_version" body))))
      (testing "and the header is not sent at all"
        (ng (header :anthropic-version headers))))))

(deftest a-body-beta-channel-puts-the-betas-in-the-body-array ()
  (let ((body (enchiridion.llm::anthropic-request-body
               (list (enchiridion.llm:user-message "hi"))
               :model "claude"
               :dialect (messages-dialect :bedrock-invoke)
               :betas '("prompt-caching-2024-07-31" "computer-use-2025-01-24"))))
    (let ((betas (gethash "anthropic_beta" body)))
      (ok (vectorp betas))
      (ok (= 2 (length betas)))
      (testing "in the order the provider asked for them"
        (ok (string= "prompt-caching-2024-07-31" (aref betas 0)))
        (ok (string= "computer-use-2025-01-24" (aref betas 1)))))
    (testing "and the revision of a body-version profile rides along"
      (ok (string= "bedrock-2023-05-31" (gethash "anthropic_version" body))))))

;;;; The registry.

(deftest both-generic-handlers-register-themselves ()
  (let ((openai (handler :openai-chat))
        (anthropic (handler :anthropic-messages)))
    (ok openai)
    (ok anthropic)
    (testing "each names the schema it speaks"
      (ok (eq :openai (enchiridion.llm::api-handler-schema openai)))
      (ok (eq :anthropic (enchiridion.llm::api-handler-schema anthropic))))
    (testing "and both halves of the adapter are functions of one provider"
      (ok (functionp (enchiridion.llm::api-handler-build openai)))
      (ok (functionp (enchiridion.llm::api-handler-list-models openai)))
      (ok (functionp (enchiridion.llm::api-handler-build anthropic)))
      (ok (functionp (enchiridion.llm::api-handler-list-models anthropic))))))

;;;; Building a backend from a provider row.

(deftest a-provider-builds-the-backend-its-row-describes ()
  (let* ((row (provider :profile :azure
                        :base-url "https://acme.openai.azure.com/"
                        :model "gpt-4o" :default-model "gpt-4o"
                        :headers '(("X-Tenant" . "acme"))))
         (backend (funcall (enchiridion.llm::api-handler-build
                            (handler :openai-chat))
                           row)))
    (ok (search "acme.openai.azure.com"
                (enchiridion.llm:backend-name backend)))
    (testing "the row's model and headers reach the connection"
      (ok (string= "gpt-4o"
                   (enchiridion.llm::openai-connection-model backend)))
      (ok (string= "acme"
                   (header "X-Tenant"
                           (enchiridion.llm::openai-connection-headers backend)))))
    (testing "and the row's profile became the dialect"
      (ok (eq :azure
              (enchiridion.llm::dialect-profile
               (enchiridion.llm::openai-connection-dialect backend)))))))

(deftest a-rows-overrides-and-query-parameters-reach-the-wire ()
  (let* ((row (provider :profile :openai
                        :base-url "https://llm.internal/v1/"
                        :model "m" :default-model "m"
                        :query-params '(("tenant" "acme"))
                        :options '(:dialect-overrides (:send-tool-choice-p nil))))
         (backend (funcall (enchiridion.llm::api-handler-build
                            (handler :openai-chat))
                           row))
         (seen (list nil))
         (enchiridion.llm::*http-post-function* (capture-post *text-reply* seen)))
    (enchiridion.llm:complete backend (list (enchiridion.llm:user-message "hi"))
                              :tools (list (tool-definition "echo")))
    (let ((request (car seen)))
      (testing "the row's query parameter is appended, not dropped"
        (ok (search "tenant=acme" (enchiridion.llm::http-request-url request))))
      (testing "and the row's dialect override really removed tool_choice"
        (ng (getf (enchiridion.llm:parse-json
                   (enchiridion.llm::http-request-body request))
                  :tool_choice))))))

;;;; Model lists.

(deftest a-model-list-is-read-in-the-shape-the-profile-names ()
  (let* ((seen (list nil))
         (enchiridion.llm::*http-get-function* (capture-get *ollama-models* seen))
         (models (funcall (enchiridion.llm::api-handler-list-models
                           (handler :openai-chat))
                          (provider :profile :ollama
                                    :base-url "http://localhost:11434/"
                                    :key ""))))
    (testing "the profile's path, not the default one"
      (ok (search "api/tags" (first (car seen)))))
    (ok (= 1 (length models)))
    (testing "Ollama names its models under NAME"
      (ok (string= "llama3.2:latest"
                   (enchiridion.llm:model-info-id (first models)))))))

(deftest the-rich-openrouter-list-carries-flags-and-prices ()
  (let* ((seen (list nil))
         (enchiridion.llm::*http-get-function* (capture-get *openrouter-models* seen))
         (models (funcall (enchiridion.llm::api-handler-list-models
                           (handler :openai-chat))
                          (provider :profile :openrouter
                                    :base-url "https://openrouter.ai/api/v1/"))))
    (ok (= 1 (length models)))
    (let ((model (first models)))
      (ok (string= "vendor/model-1" (enchiridion.llm:model-info-id model)))
      (ok (string= "Model One" (enchiridion.llm:model-info-name model)))
      (testing "the supported parameters become the flags"
        (ok (enchiridion.llm:model-info-tool-call-p model))
        (ok (enchiridion.llm:model-info-reasoning-p model)))
      (ok (= 128000 (enchiridion.llm:model-info-context model)))
      (testing "and the prices are converted from per token to per million"
        (ok (< (abs (- (enchiridion.llm:model-info-cost-input model) 1)) 0.000001))
        (ok (< (abs (- (enchiridion.llm:model-info-cost-output model) 2)) 0.000001))))))

(deftest the-anthropic-model-list-follows-its-cursor ()
  (let* ((pages (list *anthropic-models-page-1* *anthropic-models-page-2*))
         (urls '())
         (enchiridion.llm::*http-get-function*
           (lambda (url &key headers timeout)
             (declare (ignore headers timeout))
             (push url urls)
             (pop pages)))
         (models (funcall (enchiridion.llm::api-handler-list-models
                           (handler :anthropic-messages))
                          (provider :api :anthropic-messages
                                    :profile :anthropic
                                    :base-url "https://api.anthropic.com/"))))
    (testing "both pages are read, in order"
      (ok (equal '("claude-a" "claude-b" "claude-c")
                 (mapcar #'enchiridion.llm:model-info-id models))))
    (testing "the second request asks for what follows the last id of the first"
      (ok (= 2 (length urls)))
      (ok (search "after_id=claude-b" (first urls)))
      (ok (search "v1/models" (second urls))))
    (testing "and the display name is the name when there is one"
      (ok (string= "Claude A"
                   (enchiridion.llm:model-info-name (first models)))))))
