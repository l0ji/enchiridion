;;;; vertex.cl --- The Vertex AI handler for Anthropic models.
;;;;
;;;; Vertex AI serves Anthropic's Messages shape, but it is not Anthropic's
;;;; endpoint and it is not the Messages API either. Four things differ, and
;;;; all four are here rather than in anthropic.cl because Anthropic's own
;;;; endpoint does none of them:
;;;;
;;;;   * the endpoint is per region and per project, and names the model in
;;;;     the path. GOOGLE_VERTEX_PROJECT and GOOGLE_VERTEX_LOCATION, or the
;;;;     provider's options, are what it is built from.
;;;;   * the API revision rides in the BODY as anthropic_version, with the
;;;;     value vertex-2023-10-16, where Anthropic's endpoint puts a version in
;;;;     a header. Sending anthropic-version here is an error, so this file
;;;;     sends no such header at all.
;;;;   * the body must NOT name the model, because the path already does and
;;;;     the endpoint refuses a request that names it twice. That is what
;;;;     ANTHROPIC-REQUEST-BODY's MODEL-IN-BODY-P argument is for.
;;;;   * there is no credential to put in a header until one has been minted,
;;;;     so the Authorization header comes from GCP-ACCESS-TOKEN in
;;;;     gcp-oauth.cl.
;;;;
;;;; The model list is the fifth difference and it is an absence: Google
;;;; exposes no Anthropic /v1/models, so the handler answers NIL, which the
;;;; registry already defines as "this endpoint offers no list". A caller that
;;;; asks anyway gets an empty answer and the catalog behind it, not a failed
;;;; request against an endpoint that never existed.
;;;;
;;;; The request body, the URL and the headers are pure functions of a
;;;; connection, so the whole format is testable without a socket. The one
;;;; function that touches the network goes through *HTTP-POST-FUNCTION*, the
;;;; same special every other handler uses.

(in-package #:enchiridion.llm)

;;;; The constants.

(defparameter +vertex-anthropic-version+ "vertex-2023-10-16"
  "The API revision Vertex AI's Anthropic models are served under. It is a
BODY field named anthropic_version, not the anthropic-version header the
Anthropic endpoint wants, and the value is Vertex's own rather than any
revision of the public Messages API.

The :VERTEX profile in dialects.cl carries the same string as its
:VERSION-VALUE, because a generic handler that reads its version from a profile
has to be able to reach this endpoint too. This handler owns the fact instead,
so the two are one string in two places and the test pins the literal.")

(defparameter +vertex-api-host-suffix+ "-aiplatform.googleapis.com"
  "The host a regional Vertex endpoint lives under. The region is a label in
front of it, so us-central1 is us-central1-aiplatform.googleapis.com. A single
global host does not exist for rawPredict.")

(defparameter +vertex-project-variable+ "GOOGLE_VERTEX_PROJECT"
  "The variable naming the Google Cloud project. It is read only when the
provider's options do not carry one.")

(defparameter +vertex-location-variable+ "GOOGLE_VERTEX_LOCATION"
  "The variable naming the region, as in us-central1. It is read only when the
provider's options do not carry one.")

(defparameter +vertex-model-list-note+
  "Vertex AI publishes no Anthropic model list at this endpoint; the caller falls back to the catalog."
  "What a caller is told when it asks this handler for a model list. It is a
sentence and not an error, because a missing list is not a failure: the
registry's LIST-MODELS contract says NIL means the endpoint offers no list, and
the catalog supplies the names instead.")

(defparameter +vertex-default-max-tokens+ 4096
  "The reply cap when neither the provider nor the caller names one. The
Messages shape requires max_tokens on every request and has no server default,
so omitting it is not an option.")

;;;; The connection.

;; A slot per fact the endpoint needs and nothing else. There is no api-key
;; slot: an API key cannot authenticate a Vertex request, and a key slot would
;; only invite one to be put there and silently ignored. The access token is
;; fetched per request through ACCESS-TOKEN-FUNCTION, so a long running process
;; picks up the refreshed token without rebuilding its backend.
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
  "Return VALUE as a non empty string, or signal CONFIGURATION-ERROR for KEY.

An empty string is an absent value, for the same reason it is in gcp-oauth.cl:
a project of \"\" builds a URL that fails at the endpoint with a message about
a resource name rather than about the setting nobody filled in."
  (or (gcp-nonempty value)
      (error 'enchiridion.errors:configuration-error
             :key key
             :detail detail)))

;; No F-TYPE on this one, for the reason RESOLVE-BACKEND has none: SBCL wants
;; every keyword in an F-TYPE lambda list to have been declared in one already,
;; and a dummy declaration per keyword costs more than the annotation catches.
(defun vertex-anthropic-backend (&key project location model (base-url nil)
                                      (max-tokens +vertex-default-max-tokens+)
                                      (cache-p t) cache-ttl (headers '())
                                      (timeout 60) (retries 2)
                                      (access-token-function #'gcp-access-token))
  "Return a BACKEND that speaks Vertex AI's Anthropic rawPredict endpoint.

PROJECT and LOCATION are required: the endpoint is
https://LOCATION-aiplatform.googleapis.com/v1/projects/PROJECT/locations/LOCATION,
and neither half can be guessed. MODEL is required too, because it is a path
segment here and there is no body field to fall back on.

BASE-URL overrides the region-derived host, which is what a private endpoint or
a test proxy needs. CACHE-P and CACHE-TTL are passed through to the body
builder; the cloud endpoints are stricter than Anthropic's own about what a
cache breakpoint may be attached to, and the caller is the one that knows which
endpoint it is building for.

ACCESS-TOKEN-FUNCTION is how a token is obtained, called with no arguments on
every request. It defaults to GCP-ACCESS-TOKEN; a test binds it instead of
minting a service account."
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
  "Return the project PROVIDER names, or the one its variable names.

The provider's own option wins, because a config.cl row is more specific than
an environment variable that may hold another project's value."
  (or (gcp-nonempty (and provider (provider-option provider :project)))
      (gcp-setting +vertex-project-variable+)))

(defun vertex-location-from-provider (provider)
  "Return the region PROVIDER names, or the one its variable names."
  (or (gcp-nonempty (and provider (provider-option provider :location)))
      (gcp-setting +vertex-location-variable+)))

(defun vertex-anthropic-from-provider (provider)
  "Build the Vertex Anthropic BACKEND that PROVIDER describes.

The provider record is already resolved: its OPTIONS carry the project and the
region, its DEFAULT-MODEL carries the model when MODEL does not, and its
HEADERS are merged over the three this handler always sends. Every optional
number falls back to the connection default when the option is absent, so a
provider row that says nothing beyond its endpoint still builds a working
backend.

The provider's PROFILE is not read, and that is deliberate rather than an
omission. A dialect exists so that one handler can serve many vendors; this
handler serves one, and the four facts a dialect could carry for it (the
version field, the model in the path, the credential scheme, the missing model
list) are the four things this file is. A profile override cannot quietly
change the body shape of the one wire whose shape is written here."
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
  "Return the rawPredict URL for CONNECTION, naming MODEL.

MODEL defaults to the connection's own, so a caller that only wants to look at
the URL of a backend does not have to repeat what the backend already holds.
The model is a path segment and is not percent encoded: a Claude model name is
letters, digits, dots and hyphens, all of which are legal in a path as they
stand, and encoding them would produce a path the endpoint does not match."
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
  "Return the headers a Vertex Anthropic request carries.

Three headers and no more. Content-Type is JSON because the body is; User-Agent
names this project rather than dexador, as a validated client does; and
Authorization carries the minted bearer token.

There is deliberately no anthropic-version header. Vertex takes the API
revision in the body, as anthropic_version, and a request that carries both is
rejected. EXTRA is merged last so a provider that really needs a header of its
own can add one or replace one of these."
  (merge-headers
   (list (cons :authorization (format nil "Bearer ~A" token))
         (cons :content-type "application/json")
         (cons :user-agent "enchiridion/0.1.0"))
   extra))

;; No F-TYPE, for the reason the constructor has none: the keyword arguments
;; are the annotation's whole cost and none of its value.
(defun vertex-request-body (connection messages &key tools model)
  "Return the rawPredict body for MESSAGES, as JSON text.

The body is ANTHROPIC-REQUEST-BODY, which is the same builder Anthropic's own
endpoint uses, plus the one field Vertex adds. MODEL-IN-BODY-P is NIL because
the model is already a path segment, and ANTHROPIC-REQUEST-BODY is the function
that decides what that omission means: the key is absent, not null and not an
empty string."
  (let ((body (anthropic-request-body
               messages
               :model (or (gcp-nonempty model) (vertex-connection-model connection))
               :tools tools
               :max-tokens (vertex-connection-max-tokens connection)
               :cache-p (vertex-connection-cache-p connection)
               :cache-ttl (vertex-connection-cache-ttl connection)
               :model-in-body-p nil)))
    ;; anthropic_version is a BODY field here and not a header, and the value
    ;; is Vertex's own revision. STRINGIFY writes the hash table as an object,
    ;; so the key goes in beside the Messages fields and not as a separate
    ;; document.
    (setf (gethash "anthropic_version" body) +vertex-anthropic-version+)
    (stringify body)))

;;;; The transport.

(defun send-vertex-completion (connection messages model &key tools)
  "Return the COMPLETION for MESSAGES from CONNECTION using MODEL.

The reply is Anthropic's own shape, because rawPredict hands back the model's
answer and nothing Google-specific wraps it, so ANTHROPIC-PARSE-COMPLETION
reads it. The token is fetched after the body is built and before the request
is sent: a token is the one part of this request that cannot be built ahead of
time, and fetching it first would mint one for a request that then failed while
being serialized.

The retry loop is POST-WITH-RETRIES, the one every handler uses, so a 429 or a
5xx is repeated here exactly as it is on the OpenAI and Anthropic wires."
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
;;;;
;;;; Last, because COMPLETE calls SEND-VERTEX-COMPLETION and a DEFMETHOD that
;;;; calls a name the compiler has not seen yet compiles into a variable
;;;; reference and fails at run time.

(defmethod backend-name ((connection vertex-connection))
  "Return a short name for this backend, for logs and `enchiridion doctor'."
  (format nil "vertex-anthropic (~A/~A)"
          (vertex-connection-project connection)
          (vertex-connection-location connection)))

(defmethod model-capabilities ((connection vertex-connection))
  "Return what this backend's models support.

  :cache             the provider reports cached prompt tokens
  :cache-breakpoints an explicit cache breakpoint is accepted in the request
  :tools             tool calling is available
  :streaming         a stream can be requested, and is not used here

:CACHE-BREAKPOINTS is true, as it is for Anthropic's own endpoint, because the
same body builder places the same breakpoints and Vertex's Anthropic models
honour them. Reported as present only when the feature is real, so nothing
above has to guess."
  (declare (ignore connection))
  '(:tools t :streaming t :cache t :cache-breakpoints t))

(defmethod complete ((connection vertex-connection) messages
                     &key model tools budget)
  "Continue MESSAGES and return the COMPLETION.

BUDGET is ignored, as it is on every backend: the budget decides whether a turn
starts, not how long a reply may be, and max_tokens comes from the connection.
MODEL overrides the model the connection was built with, and it is a path
segment, so the override changes the URL and the request body is the same
either way."
  (declare (ignore budget))
  (send-vertex-completion connection messages
                          (or (gcp-nonempty model)
                              (vertex-connection-model connection))
                          :tools tools))

;;;; The model list.

(declaim (ftype (function (t) list) vertex-list-models))

(defun vertex-list-models (provider)
  "Return NIL: Vertex AI offers no Anthropic model list at this endpoint.

The registry's contract says a LIST-MODELS function answering NIL means the
endpoint has no list and the caller falls back to the catalog. That is the case
here: Google publishes Anthropic models through its own catalog, not through a
/v1/models route on the publisher endpoint, so a request for one would be a
404 dressed up as a provider failure.

This is the CLI-facing path as well, and an empty list is what it reports. It
is deliberately not an error: nothing is wrong, this endpoint simply does not
have the resource, and +VERTEX-MODEL-LIST-NOTE+ is the sentence that says so."
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
