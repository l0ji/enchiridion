;;;; bedrock-test.cl --- Bedrock's two Anthropic shapes and its control plane.
;;;;
;;;; Every test here runs with no network and no credential. The transport is a
;;;; function in a special, so a test reads the request that would have gone on
;;;; the wire and answers with a fixture instead. That is the only way to assert
;;;; a path, a body field or a signed header at all: a live call asserts that
;;;; something answered, not that the right thing was sent.
;;;;
;;;; The two shapes are tested side by side on purpose. Almost every assertion
;;;; below is the difference between them: where the model goes, where the
;;;; revision goes, where the betas go, and which service name is in the
;;;; signature's scope.

(defpackage #:enchiridion-bedrock-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-bedrock-test)

;;;; Helpers.

(defun header (headers name)
  "Return the value of header NAME in HEADERS, or NIL, ignoring name case."
  (cdr (assoc name headers :test #'string-equal)))

(defmacro with-environment ((name value) &body body)
  "Run BODY with environment variable NAME set to VALUE, then restore it.

A VALUE of NIL removes the variable; the previous value is always put back, so a
test cannot leak an AWS_REGION or a bearer token into the next one."
  `(let ((previous (enchiridion.compat:environment-value ,name)))
     (unwind-protect
          (progn
            (if ,value
                (enchiridion.compat:set-environment-variable ,name ,value)
                (enchiridion.compat:unset-environment-variable ,name))
            ,@body)
       (if previous
           (enchiridion.compat:set-environment-variable ,name previous)
           (enchiridion.compat:unset-environment-variable ,name)))))

(defmacro signaled-key (form)
  "Return the :key of the CONFIGURATION-ERROR FORM signals, or NIL."
  `(handler-case (progn ,form nil)
     (enchiridion.errors:configuration-error (condition)
       (enchiridion.errors::configuration-key condition))))

;;;; Fixtures.

(defparameter *invoke-model* "anthropic.claude-sonnet-4-5-20250929-v1:0"
  "A model id with the colon an inference id carries, so the URL's escaping is
part of what the tests below assert.")

(defparameter *reply*
  (concatenate 'string
   "{\"id\":\"msg_bdrk_01\",\"type\":\"message\",\"role\":\"assistant\","
   "\"model\":\"anthropic.claude-sonnet-4-5-20250929-v1:0\","
   "\"content\":[{\"type\":\"text\",\"text\":\"hello \"},"
   "{\"type\":\"text\",\"text\":\"there\"}],"
   "\"stop_reason\":\"end_turn\","
   "\"usage\":{\"input_tokens\":11,\"output_tokens\":3,"
   "\"cache_read_input_tokens\":100,\"cache_creation_input_tokens\":7}}")
  "A Bedrock invoke reply: two text blocks and a warm cache.")

(defparameter *tool-reply*
  (concatenate 'string
   "{\"id\":\"msg_bdrk_02\","
   "\"model\":\"anthropic.claude-sonnet-4-5-20250929-v1:0\","
   "\"content\":[{\"type\":\"text\",\"text\":\"reading\"},"
   "{\"type\":\"tool_use\",\"id\":\"toolu_bdrk_1\",\"name\":\"file-read\","
   "\"input\":{\"path\":\"SOUL.md\"}}],"
   "\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":20,\"output_tokens\":8}}")
  "A Bedrock reply that asks for a tool rather than answering.")

(defparameter *foundation-models*
  (concatenate 'string
   "{\"modelSummaries\":["
   "{\"modelArn\":\"arn:aws:bedrock:us-east-1::foundation-model/"
   "anthropic.claude-sonnet-4-5-20250929-v1:0\","
   "\"modelId\":\"anthropic.claude-sonnet-4-5-20250929-v1:0\","
   "\"modelName\":\"Claude Sonnet 4.5\",\"providerName\":\"Anthropic\","
   "\"inputModalities\":[\"TEXT\"],\"outputModalities\":[\"TEXT\"],"
   "\"responseStreamingSupported\":true,\"customizationsSupported\":[],"
   "\"inferenceTypesSupported\":[\"ON_DEMAND\"]},"
   "{\"modelArn\":\"arn:aws:bedrock:us-east-1::foundation-model/"
   "amazon.titan-text-express-v1\","
   "\"modelId\":\"amazon.titan-text-express-v1\",\"modelName\":\"Titan Text\","
   "\"providerName\":\"Amazon\"}],"
   "\"inferenceProfileSummaries\":["
   "{\"inferenceProfileArn\":\"arn:aws:bedrock:us-east-1:123456789012:"
   "inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0\","
   "\"inferenceProfileId\":\"us.anthropic.claude-sonnet-4-5-20250929-v1:0\","
   "\"inferenceProfileName\":\"Sonnet 4.5 (US)\","
   "\"providerName\":\"Anthropic\"}],"
   "\"nextToken\":null}")
  "The control plane's answer, with a non-Anthropic row to leave out and an
inference profile to keep.")

(defparameter *test-time* (encode-universal-time 0 36 12 30 8 2015 0)
  "20150830T123600Z as a universal time, so a signature is assertable.")

(defparameter *test-credential*
  (enchiridion.llm::make-aws-credential
   :access-key "AKIDEXAMPLE"
   :secret-key "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
  "The credential the signing tests inject, from AWS's published example.")

;;;; The shapes the tests build.

(defun bedrock-provider (&key (api :bedrock-invoke) (region "us-east-1")
                              (key "") (base-url "") (model *invoke-model*)
                              (options '()))
  "Return a provider row shaped the way the provider table builds one.

The handler id and the profile are the same keyword for Bedrock, so API is both."
  (enchiridion.llm::%make-provider :id :bedrock
                                   :name "Amazon Bedrock"
                                   :api api
                                   :profile api
                                   :base-url base-url
                                   :key key
                                   :model model
                                   :options (append (list :region region)
                                                    options)))

(defun build-backend (api provider)
  "Return the backend the handler API builds for PROVIDER."
  (funcall (enchiridion.llm::api-handler-build
            (enchiridion.llm:find-api-handler api))
           provider))

(defun body-data (request)
  "Return REQUEST's body as jzon data, objects as hash tables.

jzon and not PARSE-JSON, because these tests are about whether a field is
present at all: PARSE-JSON turns an absent field and a null one into the same
NIL, and a request that carries \"model\": null is not the same request as one
that omits it."
  (com.inuoe.jzon:parse (enchiridion.llm::http-request-body request)))

(defun cache-breakpoint (request)
  "Return the first cache_control object in REQUEST's body, or NIL."
  (let* ((system (enchiridion.llm::json-value (body-data request) "system"))
         (block (and (vectorp system) (plusp (length system))
                     (aref system 0))))
    (and block (enchiridion.llm::json-value block "cache_control"))))

(defun run-completion (api provider &key (reply *reply*) messages model tools)
  "Return the completion API's backend returns and the request it sent.

The transport is replaced, so nothing here opens a socket: the first value is
what COMPLETE parsed and the second is the HTTP-REQUEST the stub was handed."
  (let ((seen nil))
    (let ((enchiridion.llm::*http-post-function*
            (lambda (request)
              (setf seen request)
              reply)))
      (values (enchiridion.llm:complete
               (build-backend api provider)
               (or messages (list (enchiridion.llm:user-message "hi")))
               :model model
               :tools tools)
              seen))))

(defun run-model-list (provider &key (reply *foundation-models*))
  "Return the rows the lister produces, the URL and the headers it signed.

The GET is replaced the same way the POST is, so a listing test asserts the
query string and the signature without a control plane."
  (let ((seen-url nil)
        (seen-headers nil))
    (let ((enchiridion.llm::*http-get-function*
            (lambda (url &key headers timeout)
              (declare (ignore timeout))
              (setf seen-url url
                    seen-headers headers)
              reply)))
      (values (funcall (enchiridion.llm::api-handler-list-models
                        (enchiridion.llm:find-api-handler :bedrock-invoke))
                       provider)
              seen-url
              seen-headers))))

;;;; Registration.

(deftest both-handlers-are-registered-and-build-a-backend ()
  (dolist (api '(:bedrock-invoke :bedrock-messages))
    (testing (format nil "~A" api)
      (let ((handler (enchiridion.llm:find-api-handler api)))
        (ok (not (null handler)))
        (ok (eq :anthropic (enchiridion.llm::api-handler-schema handler))
            "both shapes speak the Messages schema")
        (ok (not (null (enchiridion.llm::api-handler-list-models handler))))
        (let ((backend (build-backend api (bedrock-provider :api api))))
          (ok (enchiridion.llm:backendp backend))
          (ok (search "bedrock" (enchiridion.llm:backend-name backend)))
          (testing "and it claims the tools it can really send"
            (ok (getf (enchiridion.llm:model-capabilities backend) :tools)))))))
  (testing "and the signed scheme its dialect names is registered"
    (ok (not (null (enchiridion.llm:find-auth-signer :aws-sigv4))))))

;;;; The invoke shape.

(deftest the-invoke-request-puts-the-model-in-the-url ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
    (multiple-value-bind (completion request)
        (run-completion :bedrock-invoke (bedrock-provider :key "a-bearer-token"))
      (let ((data (body-data request))
            (headers (enchiridion.llm::http-request-headers request)))
        (ok (string= "https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-sonnet-4-5-20250929-v1%3A0/invoke"
                     (enchiridion.llm::http-request-url request))
            "the colon of the inference id is escaped, once")
        (ok (string= "bedrock-2023-05-31"
                     (enchiridion.llm::json-value data "anthropic_version"))
            "the revision is a body field on this shape")
        (ng (enchiridion.llm::json-value data "model")
            "the model is in the path, and a second copy is refused")
        (ok (null (header headers :anthropic-version))
            "there is no anthropic-version header on the invoke path")
        (ok (string= "application/json" (header headers :content-type)))
        (ok (string= "hello there" (enchiridion.llm:completion-text completion)))))))

(deftest the-invoke-betas-are-a-body-array ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil))
        (betas '("prompt-caching-2024-07-31"
                 "fine-grained-tool-streaming-2024-05-21")))
    (multiple-value-bind (completion request)
        (run-completion :bedrock-invoke
                        (bedrock-provider :key "a-bearer-token"
                                          :options (list :betas betas)))
      (declare (ignore completion))
      (let ((field (enchiridion.llm::json-value (body-data request)
                                                "anthropic_beta")))
        (ok (vectorp field) "anthropic_beta is an array on this shape")
        (ok (= 2 (length field)))
        (ok (string= "prompt-caching-2024-07-31" (aref field 0))))
      (ng (header (enchiridion.llm::http-request-headers request)
                  :anthropic-beta)))))

(deftest the-invoke-cache-breakpoint-carries-no-ttl ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil))
        (messages (list (enchiridion.llm:system-message "instructions")
                        (enchiridion.llm:user-message "hi"))))
    (multiple-value-bind (completion request)
        (run-completion :bedrock-invoke
                        (bedrock-provider :key "a-bearer-token"
                                          :options '(:cache-ttl "1h"))
                        :messages messages)
      (declare (ignore completion))
      (let ((cache (cache-breakpoint request)))
        (ok (string= "ephemeral" (enchiridion.llm::json-value cache "type"))
            "block level cache_control, which this endpoint accepts")
        (ng (enchiridion.llm::json-value cache "ttl")
            "and no 1h lifetime, which it does not")))))

;;;; The mantle shape.

(deftest the-mantle-request-puts-the-model-in-the-body ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
    (multiple-value-bind (completion request)
        (run-completion :bedrock-messages
                        (bedrock-provider :api :bedrock-messages
                                          :key "a-bearer-token"))
      (let ((data (body-data request))
            (headers (enchiridion.llm::http-request-headers request)))
        (ok (string= "https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages"
                     (enchiridion.llm::http-request-url request)))
        (ok (string= *invoke-model* (enchiridion.llm::json-value data "model")))
        (ng (enchiridion.llm::json-value data "anthropic_version")
            "the revision is a header on this shape")
        (ok (string= "2023-06-01" (header headers :anthropic-version)))
        (ok (string= "hello there" (enchiridion.llm:completion-text completion)))))))

(deftest the-mantle-betas-are-a-header ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil))
        (betas '("prompt-caching-2024-07-31")))
    (multiple-value-bind (completion request)
        (run-completion :bedrock-messages
                        (bedrock-provider :api :bedrock-messages
                                          :key "a-bearer-token"
                                          :options (list :betas betas)))
      (declare (ignore completion))
      (ng (enchiridion.llm::json-value (body-data request) "anthropic_beta"))
      (ok (string= "prompt-caching-2024-07-31"
                   (header (enchiridion.llm::http-request-headers request)
                           :anthropic-beta))))))

(deftest the-mantle-cache-breakpoint-keeps-the-ttl-the-profile-accepts ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil))
        (messages (list (enchiridion.llm:system-message "instructions")
                        (enchiridion.llm:user-message "hi"))))
    (multiple-value-bind (completion request)
        (run-completion :bedrock-messages
                        (bedrock-provider :api :bedrock-messages
                                          :key "a-bearer-token"
                                          :options '(:cache-ttl "1h"))
                        :messages messages)
      (declare (ignore completion))
      (ok (string= "1h"
                   (enchiridion.llm::json-value (cache-breakpoint request)
                                                "ttl"))))))

;;;; The credential.

(deftest a-bearer-token-replaces-the-signature ()
  (with-environment ("AWS_BEARER_TOKEN_BEDROCK" nil)
    (dolist (api '(:bedrock-invoke :bedrock-messages))
      (testing (format nil "~A" api)
        (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
          (multiple-value-bind (completion request)
              (run-completion api (bedrock-provider :api api
                                                    :key "the-provider-key"))
            (declare (ignore completion))
            (let ((headers (enchiridion.llm::http-request-headers request)))
              (ok (string= "Bearer the-provider-key"
                           (header headers :authorization)))
              (ng (header headers :x-amz-date)
                  "a bearer token is not signed")
              (ng (header headers :x-amz-content-sha256)))))))))

(deftest the-environment-token-wins-over-every-credential ()
  (with-environment ("AWS_BEARER_TOKEN_BEDROCK" "the-environment-token")
    (let ((enchiridion.llm::*aws-credentials-function*
            (constantly *test-credential*)))
      (multiple-value-bind (completion request)
          (run-completion :bedrock-invoke (bedrock-provider :key "provider-key"))
        (declare (ignore completion))
        (ok (string= "Bearer the-environment-token"
                     (header (enchiridion.llm::http-request-headers request)
                             :authorization)))))))

(deftest a-provider-key-is-not-used-while-there-is-a-key-to-sign-with ()
  (with-environment ("AWS_BEARER_TOKEN_BEDROCK" nil)
    (let ((enchiridion.llm::*aws-credentials-function*
            (constantly *test-credential*))
          (enchiridion.llm::*signing-time* *test-time*))
      (multiple-value-bind (completion request)
          (run-completion :bedrock-invoke (bedrock-provider :key "provider-key"))
        (declare (ignore completion))
        (ok (search "AWS4-HMAC-SHA256"
                    (header (enchiridion.llm::http-request-headers request)
                            :authorization))
            "an access key means the operator configured a signature")))))

(deftest each-shape-is-signed-for-its-own-service ()
  (with-environment ("AWS_BEARER_TOKEN_BEDROCK" nil)
    (let ((enchiridion.llm::*aws-credentials-function*
            (constantly *test-credential*))
          (enchiridion.llm::*signing-time* *test-time*))
      (dolist (api '(:bedrock-invoke :bedrock-messages))
        (let ((service (if (eq api :bedrock-messages)
                           "bedrock-mantle"
                           "bedrock")))
          (multiple-value-bind (completion request)
              (run-completion api (bedrock-provider :api api))
            (declare (ignore completion))
            (let ((headers (enchiridion.llm::http-request-headers request)))
              (testing (format nil "~A signs for ~A" api service)
                (ok (search (format nil "Credential=AKIDEXAMPLE/20150830/us-east-1/~A/aws4_request"
                                    service)
                            (header headers :authorization)))
                (ok (search "SignedHeaders=" (header headers :authorization)))
                (ok (string= "20150830T123600Z" (header headers :x-amz-date)))
                (ok (not (null (header headers :x-amz-content-sha256))))
                (ok (not (null (header headers :host))))))))))))

(deftest the-host-that-is-signed-is-the-host-that-is-called ()
  (with-environment ("AWS_BEARER_TOKEN_BEDROCK" nil)
    (let ((enchiridion.llm::*aws-credentials-function*
            (constantly *test-credential*))
          (enchiridion.llm::*signing-time* *test-time*))
      (multiple-value-bind (completion request)
          (run-completion :bedrock-invoke (bedrock-provider))
        (declare (ignore completion))
        (ok (string= "bedrock-runtime.us-east-1.amazonaws.com"
                     (header (enchiridion.llm::http-request-headers request)
                             :host))
            "Host is signed, so a proxy that rewrites it breaks the signature")))))

;;;; The reply.

(deftest the-reply-is-read-by-the-anthropic-parser ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
    (multiple-value-bind (completion request)
        (run-completion :bedrock-invoke (bedrock-provider :key "a-bearer-token"))
      (declare (ignore request))
      (ok (string= "hello there" (enchiridion.llm:completion-text completion)))
      (ok (string= *invoke-model* (enchiridion.llm:completion-model completion)))
      (ok (string= "stop" (enchiridion.llm:completion-stop-reason completion)))
      (ok (= 118 (enchiridion.llm:completion-input-tokens completion))
          "input plus the two cache counts, provider normalised")
      (ok (= 3 (enchiridion.llm:completion-output-tokens completion)))
      (ok (= 100 (enchiridion.llm:completion-cache-read-tokens completion)))
      (ok (= 7 (enchiridion.llm:completion-cache-write-tokens completion))))
    (testing "and a tool call survives the round trip"
      (multiple-value-bind (completion request)
          (run-completion :bedrock-invoke (bedrock-provider :key "a-bearer-token")
                          :reply *tool-reply*)
        (declare (ignore request))
        (let ((call (first (enchiridion.llm:completion-tool-calls completion))))
          (ok (string= "toolu_bdrk_1" (enchiridion.llm:tool-call-id call)))
          (ok (string= "file-read" (enchiridion.llm:tool-call-name call)))
          (ok (search "SOUL.md" (enchiridion.llm:tool-call-arguments call))))))))

(deftest an-aws-error-envelope-is-a-transport-error ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
    (handler-case
        (progn
          (run-completion :bedrock-invoke (bedrock-provider :key "a-bearer-token")
                          :reply "{\"message\":\"The provided model identifier is invalid.\"}")
          (ng t "an error envelope must signal"))
      (enchiridion.errors:transport-error (condition)
        (ok (search "invalid" (enchiridion.errors:error-detail condition))))
      (enchiridion.errors:configuration-error (condition)
        (ok nil (format nil "an envelope is a transport failure, not ~A"
                        condition))))
    (testing "the capitalized spelling is the same envelope"
      (handler-case
          (progn
            (run-completion :bedrock-invoke (bedrock-provider :key "a-bearer-token")
                            :reply "{\"Message\":\"Access denied\"}")
            (ng t "an error envelope must signal"))
        (enchiridion.errors:transport-error (condition)
          (ok (string= "Access denied"
                       (enchiridion.errors:error-detail condition))))))))

(deftest a-reply-that-is-not-a-json-object-names-the-reply ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
    (ok (eq :reply
            (signaled-key
             (run-completion :bedrock-invoke (bedrock-provider :key "a-bearer-token")
                             :reply "<html>a proxy answered</html>"))))
    (testing "an array is not an object and not a reply"
      (ok (eq :reply
              (signaled-key
               (run-completion :bedrock-invoke
                               (bedrock-provider :key "a-bearer-token")
                               :reply "[1,2,3]")))))
    (testing "and an empty object is no better"
      (ok (eq :reply
              (signaled-key
               (run-completion :bedrock-invoke
                               (bedrock-provider :key "a-bearer-token")
                               :reply "{}")))))))

;;;; The model list.

(deftest the-foundation-models-fixture-becomes-rows ()
  (with-environment ("AWS_BEARER_TOKEN_BEDROCK" nil)
    (let ((enchiridion.llm::*aws-credentials-function*
            (constantly *test-credential*))
          (enchiridion.llm::*signing-time* *test-time*))
      (multiple-value-bind (rows url headers)
          (run-model-list (bedrock-provider))
        (ok (= 2 (length rows)) "the Amazon row is left out")
        (ok (string= *invoke-model*
                     (enchiridion.llm:model-info-id (first rows))))
        (ok (string= "Claude Sonnet 4.5"
                     (enchiridion.llm:model-info-name (first rows))))
        (ok (enchiridion.llm:model-info-tool-call-p (first rows))
            "every Anthropic model Bedrock serves calls tools")
        (testing "and an inference profile id is a model a caller can ask for"
          (ok (string= "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
                       (enchiridion.llm:model-info-id (second rows))))
          (ok (string= "Sonnet 4.5 (US)"
                       (enchiridion.llm:model-info-name (second rows)))))
        (ok (string= "https://bedrock.us-east-1.amazonaws.com/foundation-models?byProvider=anthropic"
                     url)
            "the filter is part of the signed request, not decoration")
        (testing "and the control plane is signed for the bedrock service"
          (ok (search "Credential=AKIDEXAMPLE/20150830/us-east-1/bedrock/aws4_request"
                      (header headers :authorization)))
          (ok (not (null (header headers :x-amz-date)))))))))

(deftest a-missing-or-odd-model-list-is-not-an-error ()
  (with-environment ("AWS_BEARER_TOKEN_BEDROCK" nil)
    (let ((enchiridion.llm::*aws-credentials-function*
            (constantly *test-credential*)))
      (testing "an empty object lists nothing"
        (multiple-value-bind (rows url headers)
            (run-model-list (bedrock-provider) :reply "{}")
          (declare (ignore url headers))
          (ok (null rows))))
      (testing "a proxy's HTML lists nothing"
        (multiple-value-bind (rows url headers)
            (run-model-list (bedrock-provider) :reply "<html>nope</html>")
          (declare (ignore url headers))
          (ok (null rows))))
      (testing "a bare array is read as the rows"
        (multiple-value-bind (rows url headers)
            (run-model-list
             (bedrock-provider)
             :reply "[{\"modelId\":\"anthropic.claude-v2\",\"modelName\":\"Claude 2\"}]")
          (declare (ignore url headers))
          (ok (= 1 (length rows)))
          (ok (string= "anthropic.claude-v2"
                       (enchiridion.llm:model-info-id (first rows))))))
      (testing "a row named only by its ARN still has a name"
        (multiple-value-bind (rows url headers)
            (run-model-list
             (bedrock-provider)
             :reply "{\"modelSummaries\":[{\"modelArn\":\"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-v2\"}]}")
          (declare (ignore url headers))
          (ok (= 1 (length rows)))
          (ok (string= "anthropic.claude-v2"
                       (enchiridion.llm:model-info-id (first rows)))))))))

;;;; The configuration failures.

(deftest a-missing-region-names-the-key ()
  (with-environment ("AWS_REGION" nil)
    (with-environment ("AWS_DEFAULT_REGION" nil)
      (let ((enchiridion.llm::*aws-credentials-function*
              (constantly *test-credential*)))
        (ok (eq :region
                (signaled-key
                 (run-completion :bedrock-invoke
                                 (bedrock-provider :region nil)))))
        (testing "and the model list needs it too"
          (ok (eq :region
                  (signaled-key
                   (enchiridion.llm::bedrock-list-models
                    (bedrock-provider :region nil))))))))))

(deftest the-region-falls-back-to-the-environment ()
  (with-environment ("AWS_REGION" "eu-central-1")
    (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
      (multiple-value-bind (completion request)
          (run-completion :bedrock-invoke
                          (bedrock-provider :region nil :key "a-bearer-token"))
        (declare (ignore completion))
        (ok (search "bedrock-runtime.eu-central-1.amazonaws.com"
                    (enchiridion.llm::http-request-url request)))))))

(deftest a-missing-credential-names-the-key ()
  (with-environment ("AWS_BEARER_TOKEN_BEDROCK" nil)
    (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
      (ok (eq :aws-credentials
              (signaled-key
               (run-completion :bedrock-invoke
                               (bedrock-provider :key ""))))))))

(deftest a-request-with-no-model-names-the-model ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
    (ok (eq :model
            (signaled-key
             (run-completion :bedrock-invoke
                             (bedrock-provider :key "a-bearer-token"
                                               :model "")
                             :model ""))))))
