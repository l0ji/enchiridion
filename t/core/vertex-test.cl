;;;; vertex-test.cl --- Vertex AI, its URL, its body and its reply.
;;;;
;;;; The handler is a pure function of a connection until the one call that
;;;; goes on the wire, and that call goes through *HTTP-POST-FUNCTION*. Every
;;;; test here binds it to a stub that keeps the request and answers with a
;;;; fixture, so the URL, the body, the headers and the parse are all checked
;;;; without a socket and without a Google credential.
;;;;
;;;; The reply fixtures are the Anthropic body rawPredict hands back, because
;;;; that is what it hands back: Vertex wraps the request in Google's routing
;;;; and leaves the answer alone.

(defpackage #:enchiridion-vertex-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-vertex-test)

;;;; Fixtures.

(defparameter *text-reply*
  "{\"id\":\"msg_vrtx_01\",\"type\":\"message\",\"role\":\"assistant\",\
\"model\":\"claude-sonnet-5-5\",\
\"content\":[{\"type\":\"text\",\"text\":\"hello from \"},\
{\"type\":\"text\",\"text\":\"vertex\"}],\
\"stop_reason\":\"end_turn\",\
\"usage\":{\"input_tokens\":12,\"output_tokens\":4}}"
  "A successful rawPredict reply.")

(defparameter *tool-reply*
  "{\"id\":\"msg_vrtx_02\",\"model\":\"claude-sonnet-5-5\",\
\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_v1\",\"name\":\"file-read\",\
\"input\":{\"path\":\"SOUL.md\"}}],\
\"stop_reason\":\"tool_use\",\
\"usage\":{\"input_tokens\":30,\"output_tokens\":9,\
\"cache_read_input_tokens\":64,\"cache_creation_input_tokens\":8}}"
  "A reply that asks for a tool, with a warm cache.")

(defparameter *denied-envelope*
  "{\"error\":{\"code\":403,\
\"message\":\"Permission 'aiplatform.endpoints.predict' denied on resource\",\
\"status\":\"PERMISSION_DENIED\"}}"
  "Google's own error envelope, which is not Anthropic's.")

;;;; Helpers.

(declaim (ftype (function (t) t) wire))

(defun wire (text)
  "Return TEXT as jzon data: objects are hash tables and arrays are vectors."
  (com.inuoe.jzon:parse text))

(declaim (ftype (function (&optional string string string) t) test-backend))

(defun test-backend (&optional (project "demo-project")
                       (location "us-central1")
                       (model "claude-sonnet-5-5"))
  "Return an offline Vertex backend whose access token is a constant.

The token function is the seam: the credential path has its own tests, and a
test of the URL and the body should not need a service account to run."
  (enchiridion.llm::vertex-anthropic-backend
   :project project
   :location location
   :model model
   :access-token-function (lambda () "test-token")))

(declaim (ftype (function (&rest t) t) test-provider))

(defun test-provider (&rest options)
  "Return a provider row for the Vertex handler, with OPTIONS as its extras."
  (enchiridion.llm::%make-provider
   :id :vertex
   :name "Vertex AI"
   :api :vertex-anthropic
   :base-url ""
   :model "claude-sonnet-5-5"
   :options options))

(declaim (ftype (function (t string) t) header-value))

(defun header-value (request name)
  "Return the value REQUEST carries for the header NAME, or NIL.

Names are compared case insensitively because HTTP header names are, and one
side of the comparison is a keyword the handler wrote and the other is the
string this test asked for."
  (cdr (assoc name (enchiridion.llm::http-request-headers request)
              :test (lambda (left right)
                      (string-equal (string left) (string right))))))

(defmacro with-captured-request ((request-variable &key (reply '*text-reply*))
                                 &body body)
  "Run BODY with REQUEST-VARIABLE bound to the request the handler sends.

The stub answers with REPLY and records the request, which is the whole of what
a test needs from a transport.

The variable starts as an empty HTTP-REQUEST rather than as NIL, and it is
declared IGNORABLE. The empty request is there for the compiler: the accessors
are declared to take an HTTP-REQUEST, and a binding the compiler can prove is
NIL would make every (HTTP-REQUEST-URL REQUEST) in a test a type warning, which
this system makes an error. IGNORABLE is there for the tests that only want the
reply and never name the request."
  (let ((incoming (gensym "REQUEST-")))
    `(let ((,request-variable (enchiridion.llm:make-http-request)))
       (declare (ignorable ,request-variable))
       (let ((enchiridion.llm::*http-post-function*
               (lambda (,incoming)
                 (setf ,request-variable ,incoming)
                 ,reply)))
         ,@body))))

(defun completion-for (backend text)
  "Return the completion BACKEND reports for one user message TEXT."
  (enchiridion.llm:complete backend (list (enchiridion.llm:user-message text))))

;;;; The registry.

(deftest the-vertex-handler-is-registered-under-the-anthropic-schema ()
  (let ((handler (enchiridion.llm:find-api-handler :vertex-anthropic)))
    (ok handler)
    (ok (eq :anthropic (enchiridion.llm::api-handler-schema handler)))
    (ok (functionp (enchiridion.llm::api-handler-build handler)))
    (ok (functionp (enchiridion.llm::api-handler-list-models handler)))
    (testing "and its documentation says what it is and what it lacks"
      (let ((documentation
              (enchiridion.llm::api-handler-documentation handler)))
        (ok (search "Vertex" documentation))
        (ok (search "No model list" documentation))))))

(deftest a-provider-row-builds-a-backend-that-satisfies-the-protocol ()
  (let* ((provider (test-provider :project "row-project" :location "europe-west1"))
         (build (enchiridion.llm::api-handler-build
                 (enchiridion.llm:find-api-handler :vertex-anthropic)))
         (backend (funcall build provider)))
    (ok (enchiridion.llm:backendp backend))
    (testing "the options name the project and the region"
      (ok (string= "row-project"
                   (enchiridion.llm::vertex-connection-project backend)))
      (ok (string= "europe-west1"
                   (enchiridion.llm::vertex-connection-location backend))))
    (testing "the provider's model is the backend's model"
      (ok (string= "claude-sonnet-5-5"
                   (enchiridion.llm::vertex-connection-model backend))))
    (testing "and the name says which project and region it points at"
      (ok (search "row-project"
                  (enchiridion.llm:backend-name backend)))
      (ok (search "europe-west1"
                  (enchiridion.llm:backend-name backend))))))

(deftest the-project-and-region-fall-back-to-their-variables ()
  (enchiridion.llm.secrets:clear-secrets)
  (unwind-protect
       (progn
         (enchiridion.llm.secrets:register-secret "GOOGLE_VERTEX_PROJECT"
                                                  "env-project")
         (enchiridion.llm.secrets:register-secret "GOOGLE_VERTEX_LOCATION"
                                                  "asia-northeast1")
         (let* ((build (enchiridion.llm::api-handler-build
                        (enchiridion.llm:find-api-handler :vertex-anthropic)))
                (backend (funcall build (test-provider))))
           (ok (string= "env-project"
                        (enchiridion.llm::vertex-connection-project backend)))
           (ok (string= "asia-northeast1"
                        (enchiridion.llm::vertex-connection-location backend))))
         (testing "and the provider's own option still wins"
           (enchiridion.llm.secrets:register-secret "GOOGLE_VERTEX_PROJECT"
                                                    "env-project")
           (let* ((build (enchiridion.llm::api-handler-build
                          (enchiridion.llm:find-api-handler :vertex-anthropic)))
                  (backend (funcall build (test-provider :project "row-project"))))
             (ok (string= "row-project"
                          (enchiridion.llm::vertex-connection-project backend))))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest a-backend-with-no-project-is-a-configuration-error ()
  (handler-case
      (progn
        (enchiridion.llm::vertex-anthropic-backend
         :location "us-central1" :model "claude-sonnet-5-5")
        (ng t "a missing project must signal"))
    (enchiridion.errors:configuration-error (condition)
      (ok (eq :project (enchiridion.errors::configuration-key condition)))
      (ok (search "GOOGLE_VERTEX_PROJECT"
                  (enchiridion.errors:error-detail condition))))))

(deftest a-backend-with-no-region-is-a-configuration-error ()
  (handler-case
      (progn
        (enchiridion.llm::vertex-anthropic-backend
         :project "demo-project" :model "claude-sonnet-5-5")
        (ng t "a missing region must signal"))
    (enchiridion.errors:configuration-error (condition)
      (ok (eq :location (enchiridion.errors::configuration-key condition)))
      (ok (search "GOOGLE_VERTEX_LOCATION"
                  (enchiridion.errors:error-detail condition))))))

(deftest the-model-list-is-empty-rather-than-a-failed-request ()
  (let* ((handler (enchiridion.llm:find-api-handler :vertex-anthropic))
         (models (funcall (enchiridion.llm::api-handler-list-models handler)
                          (test-provider :project "demo-project"
                                         :location "us-central1"))))
    (testing "NIL is the registry's way of saying the endpoint has no list"
      (ok (null models)))
    (testing "and the note says so in words, so the CLI can print it"
      (ok (search "no Anthropic model list"
                  enchiridion.llm::+vertex-model-list-note+)))))

;;;; The URL.

(deftest the-url-names-the-region-the-project-and-the-model ()
  (let ((backend (test-backend)))
    (ok (string=
         "https://us-central1-aiplatform.googleapis.com/v1/projects/demo-project/locations/us-central1/publishers/anthropic/models/claude-sonnet-5-5:rawPredict"
         (enchiridion.llm::vertex-endpoint-url backend)))
    (testing "a different region moves the host and the path together"
      (ok (string=
           "https://europe-west1-aiplatform.googleapis.com/v1/projects/demo-project/locations/europe-west1/publishers/anthropic/models/claude-sonnet-5-5:rawPredict"
           (enchiridion.llm::vertex-endpoint-url
            (test-backend "demo-project" "europe-west1")))))))

(deftest a-turn-model-overrides-the-path-not-the-body ()
  (let ((backend (test-backend)))
    (with-captured-request (request)
      (let ((completion (enchiridion.llm:complete
                         backend
                         (list (enchiridion.llm:user-message "hi"))
                         :model "claude-opus-5")))
        (ok (search "/models/claude-opus-5:rawPredict"
                    (enchiridion.llm::http-request-url request)))
        (testing "the body still names no model at all"
          (ng (search "\"model\"" (enchiridion.llm::http-request-body request))))
        (ok (string= "hello from vertex"
                    (enchiridion.llm:completion-text completion)))))))

;;;; The request.

(deftest the-body-is-the-messages-shape-with-the-vertex-revision ()
  (let ((backend (test-backend)))
    (with-captured-request (request)
      (completion-for backend "hi")
      (let ((body (wire (enchiridion.llm::http-request-body request))))
        (testing "anthropic_version is a body field, with Vertex's own value"
          (ok (string= "vertex-2023-10-16"
                       (gethash "anthropic_version" body))))
        (testing "and the model is absent, not null and not empty"
          (multiple-value-bind (value present) (gethash "model" body)
            (declare (ignore value))
            (ng present)))
        (testing "a required max_tokens is present"
          (ok (eql 4096 (gethash "max_tokens" body))))
        (testing "and the conversation is there"
          (ok (vectorp (gethash "messages" body)))
          (ok (= 1 (length (gethash "messages" body)))))))))

(deftest the-request-names-its-credential-and-its-version-nowhere-else ()
  (let ((backend (test-backend)))
    (with-captured-request (request)
      (completion-for backend "hi")
      (testing "the access token rides in an Authorization header"
        (ok (string= "Bearer test-token"
                     (header-value request "authorization"))))
      (testing "the content type is JSON"
        (ok (string= "application/json"
                     (header-value request "content-type"))))
      (testing "and there is no anthropic-version header: this wire has none"
        (ng (header-value request "anthropic-version")))
      (testing "the URL the request carries is the rawPredict one"
        (ok (search ":rawPredict"
                    (enchiridion.llm::http-request-url request)))))))

(deftest a-provider-header-can-be-added-and-can-replace-one ()
  (testing "a header of the provider's own rides along"
    (let ((backend (enchiridion.llm::vertex-anthropic-backend
                    :project "demo-project" :location "us-central1"
                    :model "claude-sonnet-5-5"
                    :headers (list (cons :x-vertex-test "yes"))
                    :access-token-function (lambda () "test-token"))))
      (with-captured-request (request)
        (completion-for backend "hi")
        (ok (string= "yes" (header-value request "x-vertex-test")))
        (ok (string= "Bearer test-token"
                     (header-value request "authorization"))))))
  (testing "and one that names Authorization replaces the bearer token"
    (let ((backend (enchiridion.llm::vertex-anthropic-backend
                    :project "demo-project" :location "us-central1"
                    :model "claude-sonnet-5-5"
                    :headers (list (cons :authorization "Bearer proxied"))
                    :access-token-function (lambda () "test-token"))))
      (with-captured-request (request)
        (completion-for backend "hi")
        (ok (string= "Bearer proxied"
                     (header-value request "authorization")))))))

;;;; The reply.

(deftest a-vertex-reply-parses-as-an-anthropic-completion ()
  (let ((backend (test-backend)))
    (with-captured-request (request)
      (let ((completion (completion-for backend "hi")))
        (ok (string= "hello from vertex"
                     (enchiridion.llm:completion-text completion)))
        (ok (string= "claude-sonnet-5-5"
                     (enchiridion.llm:completion-model completion)))
        (ok (string= "stop" (enchiridion.llm:completion-stop-reason completion)))
        (ok (eql 12 (enchiridion.llm:completion-input-tokens completion)))
        (ok (eql 4 (enchiridion.llm:completion-output-tokens completion))))))
  (testing "a reply that asks for a tool keeps the call and its arguments"
    (let ((backend (test-backend)))
      (with-captured-request (request :reply *tool-reply*)
        (let* ((completion (completion-for backend "read it"))
               (calls (enchiridion.llm:completion-tool-calls completion)))
          (ok (= 1 (length calls)))
          (ok (string= "toolu_v1" (enchiridion.llm:tool-call-id (first calls))))
          (ok (string= "file-read" (enchiridion.llm:tool-call-name (first calls))))
          (ok (search "SOUL.md"
                      (enchiridion.llm:tool-call-arguments (first calls))))
          (ok (string= "tool_calls"
                       (enchiridion.llm:completion-stop-reason completion)))
          (testing "with the cache split kept apart from the input count"
            (ok (eql 102 (enchiridion.llm:completion-input-tokens completion)))
            (ok (eql 64 (enchiridion.llm:completion-cache-read-tokens completion)))
            (ok (eql 8
                    (enchiridion.llm:completion-cache-write-tokens completion)))))))))

(deftest a-google-error-envelope-becomes-a-transport-error ()
  (let ((backend (test-backend)))
    (let ((enchiridion.llm::*http-post-function*
            (lambda (request)
              (declare (ignore request))
              (error 'dexador.error:http-request-failed
                     :status 403
                     :body *denied-envelope*
                     :headers '()
                     :uri (quri:uri
                           "https://us-central1-aiplatform.googleapis.com/")
                     :method :post))))
      (handler-case
          (progn
            (completion-for backend "hi")
            (ng t "a 403 must signal"))
        (enchiridion.errors:transport-error (condition)
          (ok (eql 403 (enchiridion.errors::transport-status condition)))
          (testing "and the report carries Google's own message"
            (ok (search "aiplatform.endpoints.predict"
                        (enchiridion.errors:error-detail condition)))))))))
