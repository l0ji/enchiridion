;;;; llm-test.cl --- The protocol shapes and the OpenAI wire format.
;;;;
;;;; Every test here runs with no network, no key, and no provider. The request
;;;; and the reply are pure functions over text and data, and they are the
;;;; parts that decide whether a turn works at all. The one function that
;;;; touches a socket is four lines long and is covered by the live call.
;;;;
;;;; The fixtures are shaped like real replies, including the fields that are
;;;; optional and the ones that only one provider sends, because those are
;;;; exactly the shapes that break a parser.

(defpackage #:enchiridion-llm-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-llm-test)

(defmacro with-shipped-providers (&body body)
  "Run BODY with no provider key in the environment and no cached catalog.

These tests are about which key selects which provider and which model a
shipped row names. The gate can run on a machine that has ANTHROPIC_API_KEY
exported, and a cached run/providers.json changes step five of detection, so
without this wrapper the suite reports on the shell that started it. The
previous values are always put back."
  (let ((names '("OPENAI_API_KEY" "OPENCODE_API_KEY" "ANTHROPIC_API_KEY")))
    `(let ((previous (loop for name in ',names
                           collect (cons name (enchiridion.compat:environment-value name))))
           (enchiridion.llm::*catalog* nil)
           (enchiridion.llm::*catalog-path* #p"/nonexistent/enchiridion-providers.json"))
       (unwind-protect
            (progn
              (dolist (name ',names)
                (enchiridion.compat:unset-environment-variable name))
              ,@body)
         (dolist (pair previous)
           (if (cdr pair)
               (enchiridion.compat:set-environment-variable (car pair) (cdr pair))
               (enchiridion.compat:unset-environment-variable (car pair))))))))


;;;; Messages.

(deftest a-message-carries-a-role-and-a-body ()
  (ok (string= "user" (enchiridion.llm:message-role
                        (enchiridion.llm:user-message "hi"))))
  (ok (string= "hi" (enchiridion.llm:message-content
                       (enchiridion.llm:user-message "hi")))))

(deftest every-role-is-built-the-one-way-it-should-be ()
  (ok (string= "system" (enchiridion.llm:message-role
                         (enchiridion.llm:system-message "be brief"))))
  (ok (string= "assistant" (enchiridion.llm:message-role
                            (enchiridion.llm:assistant-message "sure"))))
  (ok (string= "tool" (enchiridion.llm:message-role
                       (enchiridion.llm:tool-message "42" "call-1")))))

(deftest a-tool-message-carries-the-call-it-answers ()
  ;; The id is carried rather than looked up so a result cannot be reordered
  ;; against its call and read as an answer to a different call.
  (ok (string= "call-1"
               (enchiridion.llm:message-tool-call-id
                (enchiridion.llm:tool-message "42" "call-1"))))
  (testing "and every other message carries none"
    (ok (zerop (length (enchiridion.llm:message-tool-call-id
                        (enchiridion.llm:user-message "hi")))))))

;;;; Tiers.

(deftest a-tier-is-one-of-three-and-a-nonsense-tier-is-the-strong-one ()
  (ok (eql :primary (enchiridion.llm:tier :primary)))
  (ok (eql :cheap (enchiridion.llm:tier :cheap)))
  (ok (eql :sleep (enchiridion.llm:tier :sleep)))
  (testing "a typo costs a cheap turn on a strong model, not a stopped agent"
    (ok (eql :primary (enchiridion.llm:tier :primry)))
    (ok (eql :primary (enchiridion.llm:tier nil)))))

(deftest each-tier-names-a-model ()
  (ok (stringp (enchiridion.llm:model-for-tier :primary)))
  (ok (stringp (enchiridion.llm:model-for-tier :cheap)))
  (testing "sleep falls back to cheap, because nothing is waiting on it"
    (let ((enchiridion.llm:*model-sleep* nil))
      (ok (string= (enchiridion.llm:cheap-model) (enchiridion.llm:sleep-model))))
    (let ((enchiridion.llm:*model-sleep* "stronger"))
      (ok (string= "stronger" (enchiridion.llm:sleep-model))))))

(deftest the-default-primary-model-is-the-cheap-one ()
  (testing "a default that spends more per turn is a default nobody chose"
    (ok (string= (enchiridion.llm:cheap-model)
                 (enchiridion.llm:primary-model)))))

;;;; The request.

(deftest a-request-is-the-shape-every-openai-compatible-server-accepts ()
  (let* ((body (enchiridion.llm:completion-request
                "a-model" (list (enchiridion.llm:user-message "hi"))))
         (parsed (enchiridion.llm:parse-json body)))
    (ok (string= "a-model" (getf parsed :model)))
    (ok (null (getf parsed :stream)))
    (testing "one message, in order, with the role and the body"
      (let ((messages (getf parsed :messages)))
        (ok (= 1 (length messages)))
        (ok (string= "user" (getf (first messages) :role)))
        (ok (string= "hi" (getf (first messages) :content)))))))

(deftest messages-keep-their-order ()
  ;; Order is the whole conversation. A request that reorders them is a request
  ;; to a model that has been told the opposite of what was said.
  (let* ((body (enchiridion.llm:completion-request
                "m" (list (enchiridion.llm:system-message "one")
                          (enchiridion.llm:user-message "two")
                          (enchiridion.llm:assistant-message "three"))))
         (messages (getf (enchiridion.llm:parse-json body) :messages)))
    (ok (string= "one" (getf (nth 0 messages) :content)))
    (ok (string= "two" (getf (nth 1 messages) :content)))
    (ok (string= "three" (getf (nth 2 messages) :content)))))

(deftest a-tool-message-carries-its-call-id-and-others-do-not ()
  ;; Some servers reject an unexpected field rather than ignoring it, so the
  ;; key appears only on the messages that are allowed to have it.
  (let* ((body (enchiridion.llm:completion-request
                "m" (list (enchiridion.llm:tool-message "42" "call-7")
                          (enchiridion.llm:user-message "hi"))))
         (messages (getf (enchiridion.llm:parse-json body) :messages)))
    (ok (string= "call-7" (getf (nth 0 messages) :tool_call_id)))
    (ok (null (getf (nth 1 messages) :tool_call_id)))))

(deftest a-request-with-unusual-text-survives-the-round-trip ()
  ;; Quotes, newlines and a non-ASCII character. A hand rolled JSON writer
  ;; breaks here and nowhere else that is easy to see.
  ;; LIST and not a quoted literal, because a quoted list holds the FORMAT
  ;; form rather than the string it returns.
  (dolist (text (list "a \"quoted\" word"
                      (format nil "two~%lines")
                      "unicode: héllo ☃"
                      "back\\slash"
                      "{braces} and [brackets]"))
    (testing (format nil "~S" text)
      (let* ((body (enchiridion.llm:completion-request
                    "m" (list (enchiridion.llm:user-message text))))
             (messages (getf (enchiridion.llm:parse-json body) :messages)))
        (ok (string= text (getf (first messages) :content)))))))

;;;; The reply.

(defparameter *text-reply*
  "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"model\":\"a-model\",\
\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hello there\"},\
\"finish_reason\":\"stop\"}],\
\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":3,\"total_tokens\":14}}"
  "A minimal successful reply.")

(defparameter *cached-reply*
  "{\"model\":\"a-model\",\"choices\":[{\"index\":0,\
\"message\":{\"role\":\"assistant\",\"content\":\"cached\"},\"finish_reason\":\"stop\"}],\
\"usage\":{\"prompt_tokens\":1200,\"completion_tokens\":20,\"total_tokens\":1220,\
\"prompt_tokens_details\":{\"cached_tokens\":1100}}}"
  "A reply from a provider that reports a warm prefix cache.")

(defparameter *tool-reply*
  "{\"model\":\"a-model\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\
\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\
\"function\":{\"name\":\"file-read\",\"arguments\":\"{\\\"path\\\":\\\"SOUL.md\\\"}\"}}]},\
\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":8}}"
  "A reply that asks for a tool rather than answering.")

(deftest a-text-reply-parses-into-a-completion ()
  (let ((completion (enchiridion.llm:parse-completion
                     (enchiridion.llm:parse-json *text-reply*))))
    (ok (string= "hello there" (enchiridion.llm:completion-text completion)))
    (ok (string= "a-model" (enchiridion.llm:completion-model completion)))
    (ok (string= "stop" (enchiridion.llm:completion-stop-reason completion)))
    (ok (= 11 (enchiridion.llm:completion-input-tokens completion)))
    (ok (= 3 (enchiridion.llm:completion-output-tokens completion)))
    (ok (= 0 (enchiridion.llm:completion-cache-read-tokens completion)))
    (testing "and no tool calls were asked for"
      (ok (null (enchiridion.llm:completion-tool-calls completion))))))

(deftest a-cached-reply-is-counted-as-a-cache-read ()
  ;; This is the number that says whether the prefix cache is working. If a
  ;; provider reports it somewhere other than the obvious place and the ledger
  ;; misses it, every cached turn looks like it cost full price.
  (let ((completion (enchiridion.llm:parse-completion
                     (enchiridion.llm:parse-json *cached-reply*))))
    (ok (= 1100 (enchiridion.llm:completion-cache-read-tokens completion)))
    (testing "and the total counts the prompt once, not twice"
      (ok (= 1220 (enchiridion.llm:completion-total-tokens completion))))))

(deftest a-tool-reply-parses-into-tool-calls ()
  (let* ((completion (enchiridion.llm:parse-completion
                      (enchiridion.llm:parse-json *tool-reply*)))
         (calls (enchiridion.llm:completion-tool-calls completion)))
    (ok (= 1 (length calls)))
    (ok (string= "call_1" (enchiridion.llm:tool-call-id (first calls))))
    (ok (string= "file-read" (enchiridion.llm:tool-call-name (first calls))))
    (testing "arguments come back as the JSON text the model wrote"
      (ok (string= "{\"path\":\"SOUL.md\"}"
                   (enchiridion.llm:tool-call-arguments (first calls)))))
    (testing "and a reply that is only a tool call has no text"
      (ok (zerop (length (enchiridion.llm:completion-text completion)))))
    (ok (string= "tool_calls" (enchiridion.llm:completion-stop-reason completion)))))

(deftest a-reply-with-no-choices-signals-rather-than-looking-empty ()
  ;; An empty completion is indistinguishable from a model that said nothing,
  ;; and that is the one failure the agent cannot recover from on its own.
  ;; ROVE takes the FORM first and the condition type second, which is the
  ;; opposite of the order the Common Lisp EXPECT-ERROR uses. With the two the
  ;; other way round the form is never evaluated inside the handler, and the
  ;; condition the code under test raises is then reported as an unexpected
  ;; error, which reads as though the assertion itself is what failed.
  (ok (signals (enchiridion.llm:parse-completion
                (enchiridion.llm:parse-json "{\"error\":{\"message\":\"no\"}}"))
               'enchiridion.errors:backend-error))
  (ok (signals (enchiridion.llm:parse-completion
                (enchiridion.llm:parse-json "{\"choices\":[]}"))
               'enchiridion.errors:backend-error)))

(deftest a-reply-with-missing-usage-still-parses ()
  ;; Not every compatible server sends usage. Zero is the honest answer for an
  ;; unknown cost, and refusing to parse would lose the text as well.
  (let ((completion (enchiridion.llm:parse-completion
                     (enchiridion.llm:parse-json
                      "{\"model\":\"m\",\"choices\":[{\"index\":0,\
\"message\":{\"role\":\"assistant\",\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}"))))
    (ok (string= "hi" (enchiridion.llm:completion-text completion)))
    (ok (= 0 (enchiridion.llm:completion-input-tokens completion)))))

;;;; The backend.

(deftest an-openai-backend-satisfies-every-operation-the-kernel-calls ()
  (let ((backend (enchiridion.llm:openai-backend :api-key "k")))
    (ok (enchiridion.llm:backendp backend))
    (ok (search "openai" (enchiridion.llm:backend-name backend)))))

(deftest every-backend-carries-a-session-id ()
  ;; OpenCode Go asks for x-opencode-session on every request. It is the
  ;; routing key and the prompt cache key, so one backend must keep one id for
  ;; its whole life.
  (let ((one (enchiridion.llm:openai-backend :api-key "k"))
        (two (enchiridion.llm:openai-backend :api-key "k"))
        (fixed (enchiridion.llm:openai-backend :api-key "k"
                                               :session-id "fixed-session")))
    (ok (stringp (enchiridion.llm::openai-connection-session-id one)))
    (ok (= 32 (length (enchiridion.llm::openai-connection-session-id one))))
    (testing "two backends do not share one"
      (ng (string= (enchiridion.llm::openai-connection-session-id one)
                   (enchiridion.llm::openai-connection-session-id two))))
    (testing "and an explicit id is kept"
      (ok (string= "fixed-session"
                   (enchiridion.llm::openai-connection-session-id fixed))))))

(deftest a-base-url-gains-a-trailing-slash ()
  ;; Without it a path is appended to a host name: api.openai.com/v1/chat
  ;; becomes a request to a host called v1, which fails with a name error
  ;; rather than a useful message.
  (ok (search "/v1/"
              (enchiridion.llm:backend-name
               (enchiridion.llm:openai-backend
                :base-url "https://example.test/v1" :api-key "k"))))
  (testing "and one that already has it is left alone"
    (ng (search "v1//" (enchiridion.llm:backend-name
                        (enchiridion.llm:openai-backend
                         :base-url "https://example.test/v1/" :api-key "k"))))))

(deftest something-that-is-not-a-backend-is-not-a-backend ()
  ;; Stands in for satisfies, which SBCL has no defprotocol to provide.
  (ng (enchiridion.llm:backendp 42))
  (ng (enchiridion.llm:backendp nil)))

(deftest capabilities-report-what-is-real-and-what-is-not ()
  ;; Cache breakpoints are reported absent rather than present-and-ignored, so
  ;; that nothing above has to guess whether the feature works.
  (let ((capabilities (enchiridion.llm:model-capabilities
                      (enchiridion.llm:openai-backend :api-key "k"))))
    (ok (getf capabilities :tools))
    (ng (getf capabilities :cache-breakpoints))
    (testing "tool calling is not claimed before the registry exists"
      (ng (getf capabilities :tool-registration)))))

(deftest an-unknown-backend-name-is-a-configuration-error ()
  ;; Named rather than signalled as "no such function", so the operator is
  ;; told which key in which file is wrong.
  (ok (signals (enchiridion.llm:resolve-backend :config '(:backend :nonesuch))
               'enchiridion.errors:configuration-error)))

(deftest the-configured-backend-is-the-one-that-comes-back ()
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:backend :openai
                            :base-url "https://example.test/v1"
                            :model-primary "a-model")
                  :api-key "k")))
    (ok (enchiridion.llm:backendp backend))
    (ok (search "example.test" (enchiridion.llm:backend-name backend)))))

(deftest a-sectioned-config-reaches-the-backend ()
  ;; config.example.cl puts the LLM keys under :LLM. A flat GETF reads the
  ;; section name and its first entry and then treats every later entry as a
  ;; key, so the endpoint and the model fall back to defaults.
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:llm
                            (:backend :openai)
                            (:base-url "https://example.test/v1")
                            (:model-primary "section-model"))
                  :api-key "k")))
    (ok (search "example.test" (enchiridion.llm:backend-name backend)))
    (ok (string= "section-model"
                 (enchiridion.llm::openai-connection-model backend)))))

(deftest the-default-provider-is-openai ()
  ;; No config and no provider key means OpenAI. The key name follows the
  ;; provider, so a missing key is reported as OPENAI_API_KEY.
  (with-shipped-providers
    (enchiridion.llm.secrets:clear-secrets)
    (let ((backend (enchiridion.llm:resolve-backend :api-key "k")))
      (ok (search "api.openai.com" (enchiridion.llm:backend-name backend)))
      (ok (string= "gpt-5.6-luna"
                   (enchiridion.llm::openai-connection-model backend))))))

(deftest an-openai-key-selects-openai ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "OPENAI_API_KEY" "fake-openai-key-123456")
  (unwind-protect
       (let ((backend (enchiridion.llm:resolve-backend :api-key "k")))
         (ok (search "api.openai.com"
                     (enchiridion.llm:backend-name backend)))
         (ok (string= "OPENAI_API_KEY"
                      (enchiridion.llm:default-api-key-env))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest an-opencode-key-selects-opencode-go ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY"
                                           "fake-opencode-key-123456")
  (unwind-protect
       (let ((backend (enchiridion.llm:resolve-backend :api-key "k")))
         (ok (search "opencode.ai/zen/go/v1"
                     (enchiridion.llm:backend-name backend)))
         (ok (string= "deepseek-v4.1-flash"
                      (enchiridion.llm::openai-connection-model backend)))
         (ok (string= "OPENCODE_API_KEY"
                      (enchiridion.llm:default-api-key-env))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest openai-wins-when-both-provider-keys-are-present ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "OPENAI_API_KEY" "fake-openai-key-123456")
  (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY"
                                           "fake-opencode-key-123456")
  (unwind-protect
       (ok (search "api.openai.com"
                   (enchiridion.llm:backend-name
                    (enchiridion.llm:resolve-backend :api-key "k"))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest an-explicit-provider-overrides-the-keys ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "OPENAI_API_KEY" "fake-openai-key-123456")
  (unwind-protect
       (let ((backend (enchiridion.llm:resolve-backend
                       :config '(:llm
                                 (:provider :opencode)
                                 (:model-primary "chosen-model"))
                       :api-key "k")))
         (ok (search "opencode.ai/zen/go/v1"
                     (enchiridion.llm:backend-name backend)))
         (ok (string= "chosen-model"
                      (enchiridion.llm::openai-connection-model backend))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest the-configured-model-reaches-the-backend ()
  ;; The config names a model string, not a tier. Passing it through
  ;; MODEL-FOR-TIER replaced it with the global default, so the operator's
  ;; choice was silently ignored while the backend still looked configured.
  (let ((backend (enchiridion.llm:resolve-backend
                  :config '(:backend :openai
                            :base-url "https://example.test/v1"
                            :model-primary "configured-model")
                  :api-key "k")))
    (ok (string= "configured-model"
                 (enchiridion.llm::openai-connection-model backend)))))

;;;; Retries and the transport.
;;;;
;;;; The transport is a special variable, so these tests replace it and never
;;;; touch a socket. A retry test with a real provider would need a key, a
;;;; network, and a server that fails on purpose.

(deftest a-429-is-retried-and-the-loop-ends ()
  ;; The outer LOOP is the retry. An inner (loop) in the handler was an
  ;; infinite loop, so a 429 hung the process instead of sending the request
  ;; again. Count the calls: two failures then one success is three.
  (let* ((calls 0)
        (enchiridion.llm::*retry-delay* 0)
        (enchiridion.llm::*http-post-function*
          (lambda (request)
            (declare (ignore request))
            (incf calls)
            (if (< calls 3)
                (error 'dexador.error:http-request-failed
                       :status 429
                       :body "slow down"
                       :headers nil
                       :uri nil
                       :method :post)
                *text-reply*))))
    (let ((completion (enchiridion.llm:complete
                       (enchiridion.llm:openai-backend :api-key "k" :retries 2)
                       (list (enchiridion.llm:user-message "hi")))))
      (ok (string= "hello there" (enchiridion.llm:completion-text completion)))
      (ok (= 3 calls)
          "two 429 responses and one success"))))

(deftest a-401-is-reported-at-once ()
  ;; A wrong key does not become right by being repeated. The condition is a
  ;; transport error with the provider's own text, and the call count is one.
  (let* ((calls 0)
        (enchiridion.llm::*retry-delay* 0)
        (enchiridion.llm::*http-post-function*
          (lambda (request)
            (declare (ignore request))
            (incf calls)
            (error 'dexador.error:http-request-failed
                   :status 401
                   :body "bad key"
                   :headers nil
                   :uri nil
                   :method :post))))
    (ok (signals (enchiridion.llm:complete
                  (enchiridion.llm:openai-backend :api-key "k" :retries 2)
                  (list (enchiridion.llm:user-message "hi")))
                 'enchiridion.errors:transport-error))
    (ok (= 1 calls))))
