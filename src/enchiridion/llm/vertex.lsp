;;;; vertex.lsp --- Vertex AI handler for Anthropic models (rawPredict).
;;;;
;;;; Differs from Anthropic's direct endpoint: model is in the path (omitted
;;;; from the body), API revision is in the body as anthropic_version (no
;;;; anthropic-version header), auth uses GCP-ACCESS-TOKEN, and LIST-MODELS
;;;; returns NIL (catalog fallback).

(in-package #:enchiridion.llm)

;;;; The constants.

(defparameter +vertex-anthropic-version+ "vertex-2023-10-16"
  "Vertex AI's anthropic_version body field value (mirrored in dialects.lsp :vertex).")

(defparameter +vertex-api-host-suffix+ "-aiplatform.googleapis.com"
  "Regional Vertex AI host suffix (<location>-aiplatform.googleapis.com).")

(defparameter +vertex-project-variable+ "GOOGLE_VERTEX_PROJECT"
  "Environment/secret variable for the GCP project when not set in provider options.")

(defparameter +vertex-location-variable+ "GOOGLE_VERTEX_LOCATION"
  "Environment/secret variable for the GCP region when not set in provider options.")

(defparameter +vertex-model-list-note+
  "Vertex AI publishes no Anthropic model list at this endpoint; the caller falls back to the catalog."
  "Note explaining that Vertex AI exposes no Anthropic model list endpoint.")

(defparameter +vertex-default-max-tokens+ 4096
  "Default max_tokens when neither provider nor caller specifies one (required by Messages).")

;;;; The connection.

;; Access tokens are fetched per request via ACCESS-TOKEN-FUNCTION so refreshes take effect.
(defstruct (vertex-connection (:constructor %make-vertex-connection))
  (:project "" :type string)
  (:location "" :type string)
  (:model "" :type string)
  (:base-url nil :type (or null string))
  (:max-tokens 4096 :type (integer 1 *))
  (:cache-p t :type boolean)
  (:cache-ttl nil :type (or null string))
  (:headers '() :type list)
  (:timeout 60 :type (integer 1 *))
  (:retries 2 :type (integer 0 *))
  (:access-token-function #'gcp-access-token :type function))

(declaim (ftype (function (t symbol string) string) vertex-required))

(defun vertex-required (value key detail)
  "Return VALUE if it is a non-empty string, else signal CONFIGURATION-ERROR for KEY."
  (or (gcp-nonempty value)
      (error 'enchiridion.errors:configuration-error
             :key key
             :detail detail)))

;; Omit ftype to avoid verbose keyword declarations in SBCL.
(defun vertex-anthropic-backend (&key project location model (base-url nil)
                                      (max-tokens +vertex-default-max-tokens+)
                                      (cache-p t) cache-ttl (headers '())
                                      (timeout 60) (retries 2)
                                      (access-token-function #'gcp-access-token))
  "Build a VERTEX-CONNECTION for Vertex AI's Anthropic rawPredict endpoint.
Requires non-empty PROJECT, LOCATION, and MODEL; BASE-URL overrides the
regional host, and ACCESS-TOKEN-FUNCTION is called per request."
  (%make-vertex-connection
   :project (vertex-required
             project :project
             (format nil "Vertex AI needs a Google Cloud project: pass :project in the provider's options, or set ~A."
                     +vertex-project-variable+))
   :location (vertex-required
              location :location
              (format nil "Vertex AI needs a region: pass :location in the provider's options, or set ~A."
                      +vertex-location-variable+))
   :model (vertex-required
           model :model
           "Vertex AI needs a model: it is a path segment, so there is no request the endpoint would accept without it.")
   :base-url (gcp-nonempty base-url)
   :max-tokens max-tokens
   :cache-p (not (null cache-p))
   :cache-ttl (gcp-nonempty cache-ttl)
   :headers headers
   :timeout timeout
   :retries retries
   :access-token-function access-token-function))

;;;; Building one from a provider row.

(declaim (ftype (function (t) (or null string)) vertex-project-from-provider))
(declaim (ftype (function (t) (or null string)) vertex-location-from-provider))

(defun vertex-project-from-provider (provider)
  "Return the GCP project from PROVIDER's :project option, falling back to +VERTEX-PROJECT-VARIABLE+."
  (or (gcp-nonempty (and provider (provider-option provider :project)))
      (gcp-setting +vertex-project-variable+)))

(defun vertex-location-from-provider (provider)
  "Return the region PROVIDER names, or the one its variable names."
  (or (gcp-nonempty (and provider (provider-option provider :location)))
      (gcp-setting +vertex-location-variable+)))

(defun vertex-anthropic-from-provider (provider)
  "Build a VERTEX-CONNECTION from a resolved PROVIDER record (options win over
env/secrets). Ignores provider dialect profiles since Vertex's wire shape is fixed."
  (vertex-anthropic-backend
   :project (vertex-project-from-provider provider)
   :location (vertex-location-from-provider provider)
   :model (or (gcp-nonempty (provider-model provider))
              (gcp-nonempty (provider-default-model provider)))
   :base-url (gcp-nonempty (provider-base-url provider))
   :max-tokens (let ((value (provider-option provider :max-tokens)))
                 (if (and (integerp value) (plusp value))
                     value
                     +vertex-default-max-tokens+))
   :cache-p (provider-option provider :cache-p t)
   :cache-ttl (gcp-nonempty (provider-option provider :cache-ttl))
   :headers (provider-headers provider)
   :timeout (let ((value (provider-option provider :timeout)))
              (if (and (integerp value) (plusp value)) value 60))
   :retries (let ((value (provider-option provider :retries)))
              (if (and (integerp value) (not (minusp value))) value 2))))

;;;; The request.

(declaim (ftype (function (vertex-connection &optional t) string)
                vertex-endpoint-url))

(defun vertex-endpoint-url (connection &optional model)
  "Return the rawPredict URL for CONNECTION and MODEL (defaulting to
CONNECTION's model), leaving the model segment unencoded."
  (let* ((location (vertex-connection-location connection))
         (base (or (vertex-connection-base-url connection)
                   (format nil "https://~A~A" location
                           +vertex-api-host-suffix+))))
    (format nil "~Av1/projects/~A/locations/~A/publishers/anthropic/models/~A:rawPredict"
            (ensure-trailing-slash base)
            (vertex-connection-project connection)
            location
            (or (gcp-nonempty model) (vertex-connection-model connection)))))

(declaim (ftype (function (string list) list) vertex-headers))

(defun vertex-headers (token extra)
  "Return request headers (Authorization, Content-Type, User-Agent) merged with
EXTRA, deliberately omitting anthropic-version (sent in the body)."
  (merge-headers
   (list (cons :authorization (format nil "Bearer ~A" token))
         (cons :content-type "application/json")
         (cons :user-agent "enchiridion/0.1.0"))
   extra))

;; Omit ftype for keyword arguments.
(defun vertex-request-body (connection messages &key tools model)
  "Build the JSON rawPredict body via ANTHROPIC-REQUEST-BODY with
:model-in-body-p nil and anthropic_version set to +VERTEX-ANTHROPIC-VERSION+."
  (let ((body (anthropic-request-body
               messages
               :model (or (gcp-nonempty model) (vertex-connection-model connection))
               :tools tools
               :max-tokens (vertex-connection-max-tokens connection)
               :cache-p (vertex-connection-cache-p connection)
               :cache-ttl (vertex-connection-cache-ttl connection)
               :model-in-body-p nil)))
    (setf (gethash "anthropic_version" body) +vertex-anthropic-version+)
    (stringify body)))

;;;; The transport.

(defun send-vertex-completion (connection messages model &key tools)
  "Build the request body, mint an access token, POST via POST-WITH-RETRIES,
and parse with ANTHROPIC-PARSE-COMPLETION."
  (let* ((body (vertex-request-body connection messages :model model :tools tools))
         (token (funcall (vertex-connection-access-token-function connection)))
         (request (make-http-request
                   :url (vertex-endpoint-url connection model)
                   :body body
                   :headers (vertex-headers token (vertex-connection-headers connection))
                   :timeout (vertex-connection-timeout connection))))
    (anthropic-parse-completion
     (post-with-retries *http-post-function* request
                        (vertex-connection-retries connection)))))

;;;; The operations.

(defmethod backend-name ((connection vertex-connection))
  "Return a short name for this backend, for logs and `enchiridion doctor'."
  (format nil "vertex-anthropic (~A/~A)"
          (vertex-connection-project connection)
          (vertex-connection-location connection)))

(defmethod model-capabilities ((connection vertex-connection))
  "Return capabilities supported by Vertex Anthropic models."
  (declare (ignore connection))
  '(:tools t :streaming t :cache t :cache-breakpoints t))

(defmethod complete ((connection vertex-connection) messages
                     &key model tools budget)
  "Continue MESSAGES and return a COMPLETION. BUDGET is ignored; MODEL
overrides CONNECTION's model in the URL path."
  (declare (ignore budget))
  (send-vertex-completion connection messages
                          (or (gcp-nonempty model)
                              (vertex-connection-model connection))
                          :tools tools))

;;;; The model list.

(declaim (ftype (function (t) list) vertex-list-models))

(defun vertex-list-models (provider)
  "Return NIL: Vertex AI exposes no Anthropic model list endpoint, so callers
fall back to the catalog."
  (declare (ignore provider))
  nil)

;;;; Registration.

(register-api-handler
 :vertex-anthropic
 :schema :anthropic
 :build #'vertex-anthropic-from-provider
 :list-models #'vertex-list-models
 :documentation
 "Anthropic models on Google Cloud Vertex AI. The Messages shape with the API
revision and the model moved into the request path, a Google Cloud project and
region, and an OAuth access token minted from a service account or supplied by
the operator. No model list: the caller falls back to the catalog.")
