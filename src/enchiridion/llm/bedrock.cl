;;;; bedrock.cl --- Amazon Bedrock's two Anthropic shapes, and its model list.
;;;;
;;;; Bedrock speaks the Messages schema and does not speak Anthropic's
;;;; transport. There are two ways in and they are different APIs:
;;;;
;;;;   :bedrock-invoke    POST {base-url}/model/{model}/invoke
;;;;     The model is in the path, the API revision is a body field called
;;;;     anthropic_version, the beta feature list is a body array called
;;;;     anthropic_beta, and there is no anthropic-version header at all.
;;;;
;;;;   :bedrock-messages  POST https://bedrock-mantle.{region}.api.aws/anthropic/v1/messages
;;;;     Anthropic's own Messages transport behind AWS's newer gateway: the
;;;;     model is in the body, the revision travels in the anthropic-version
;;;;     header and the betas in anthropic-beta.
;;;;
;;;; The differences are data. dialects.cl ships a profile for each shape and
;;;; this file reads it, so the version's location, the beta channel, whether a
;;;; 1h cache TTL is accepted and whether the model goes in the body are all
;;;; decided in one table rather than in branches here. What is left is the two
;;;; things no dialect can carry: the URL, and which credential signs it.
;;;;
;;;; Signing is not written here either. The request goes through AUTH-APPLY and
;;;; the :AWS-SIGV4 signer that aws-sigv4.cl registered, with the region, the
;;;; service and the method bound around the call. A bearer token, when one was
;;;; resolved, replaces the signature: Bedrock accepts either, and an operator
;;;; with a short-lived token should not have to hold a secret key as well.

(in-package #:enchiridion.llm)

;;;; The connection.

;; api is the handler id AND the dialect profile, deliberately: a Bedrock
;; handler speaks exactly one wire, so there is nothing for the provider table to
;; choose, and a second name for the same fact is a second name to keep in step.
;;
;; key holds the bearer token when the provider table resolved one, and is empty
;; otherwise. region is the provider's own option or NIL, and the environment is
;; consulted at request time rather than here, because a backend is built while
;; a configuration is being read and a missing region should not stop a listing
;; of what is configured.
(defstruct (bedrock-connection (:constructor %make-bedrock-connection))
  (:api :bedrock-invoke :type keyword)
  (:dialect nil :type (or null dialect))
  (:base-url "" :type string)
  (:region nil :type (or null string))
  (:key "" :type string)
  (:headers '() :type list)
  (:model "" :type string)
  (:max-tokens 4096 :type (integer 1 *))
  (:cache-p t :type boolean)
  (:cache-ttl nil :type (or null string))
  (:betas '() :type list)
  (:timeout 60 :type (integer 1 *))
  (:retries 2 :type (integer 0 *)))

;;;; The dialect and the small facts around it.

(declaim (ftype (function (keyword &key (:bearer-p t)) t) bedrock-dialect-for))

(defun bedrock-dialect-for (api &key bearer-p)
  "Return the DIALECT that decorates the handler API's wire.

Two of the profile's fields are corrected here rather than in dialects.cl.
MODEL-IN-BODY-P is NIL on the invoke path because the model is in the URL and
Bedrock refuses a body that names it twice. The auth scheme becomes :BEARER when
a token was resolved, which is how one handler reaches both credentials without
this file writing a header itself."
  (make-dialect-for api
                    :protocol :anthropic
                    :overrides (append (and bearer-p (list :auth-scheme :bearer))
                                       (and (eq api :bedrock-invoke)
                                            (list :model-in-body-p nil)))))

(declaim (ftype (function (bedrock-connection) string) bedrock-region))

(defun bedrock-region (connection)
  "Return the region CONNECTION's endpoint lives in.

The provider's own option wins, then the two environment variables every AWS
toolchain reads. There is no default region: a request signed for the wrong
region is a 403 with nothing in it to say which region was expected, and
assuming us-east-1 would send an operator's request to another continent."
  (let ((region (or (aws-nonempty-string (bedrock-connection-region connection))
                    (aws-nonempty-string
                     (enchiridion.compat:environment-value "AWS_REGION"))
                    (aws-nonempty-string
                     (enchiridion.compat:environment-value "AWS_DEFAULT_REGION")))))
    (or region
        (error 'enchiridion.errors:configuration-error
               :key :region
               :detail "No AWS region is configured: set :region on the provider, or AWS_REGION or AWS_DEFAULT_REGION in the environment."))))

(declaim (ftype (function (bedrock-connection t) string) bedrock-model))

(defun bedrock-model (connection model)
  "Return the model to ask for: the turn's, the connection's, or an error.

The invoke path carries the model in its URL, so a request with no model is a
request with an empty path segment and a 404 that names nothing. Refusing here
names the field."
  (or (aws-nonempty-string model)
      (aws-nonempty-string (bedrock-connection-model connection))
      (error 'enchiridion.errors:configuration-error
             :key :model
             :detail "The Bedrock handler was asked for a completion with no model to ask for.")))

(declaim (ftype (function (bedrock-connection) string) bedrock-service))

(defun bedrock-service (connection)
  "Return the SigV4 service name for CONNECTION's shape.

The two shapes are two services: the invoke path is signed for bedrock, and the
mantle gateway for bedrock-mantle. The control plane is bedrock for both, which
is why the model list passes its service explicitly instead of asking here."
  (if (eq (bedrock-connection-api connection) :bedrock-messages)
      "bedrock-mantle"
      "bedrock"))

(declaim (ftype (function (bedrock-connection) string) bedrock-version))

(defun bedrock-version (connection)
  "Return the API revision this wire announces, wherever the profile puts it.

The invoke profile names bedrock-2023-05-31 in the body; the mantle profile
leaves the field unset because the gateway speaks Anthropic's own revision, and
that is the default here."
  (or (aws-nonempty-string
       (dialect-field (bedrock-connection-dialect connection) :version-value))
      +anthropic-version+))

(declaim (ftype (function (bedrock-connection) boolean) bedrock-version-in-body-p))

(defun bedrock-version-in-body-p (connection)
  "Return T when this shape announces its revision in the body.

The two locations are exclusive, which is the point: a request that carries both
an anthropic_version field and an anthropic-version header is a request that
names two protocols, and Bedrock's invoke path rejects the header outright."
  (eq (dialect-field (bedrock-connection-dialect connection)
                     :version-location :header)
      :body))

(declaim (ftype (function (t) list) bedrock-beta-list))

(defun bedrock-beta-list (value)
  "Return VALUE as a list of beta feature names.

A comma separated string and a list of strings are both accepted, because a
configuration file spells a short list as a string and a Lisp caller spells it as
a list. Anything else is no betas: a beta name that is not a string cannot go on
the wire, and a malformed one should not stop a turn that does not need it."
  (cond
    ((null value) '())
    ((stringp value)
     (remove-if #'zerop
                (mapcar (lambda (beta)
                          (string-trim '(#\Space #\Tab) beta))
                        (aws-split #\, value))
                :key #'length))
    ((listp value) (remove-if-not #'stringp value))
    (t '())))

(declaim (ftype (function (t integer &optional integer) integer)
                bedrock-option-integer))

(defun bedrock-option-integer (value default &optional (minimum 1))
  "Return VALUE when it is a whole number at least MINIMUM, else DEFAULT.

A configuration file is text and an operator's typo reaches this handler as a
string. A type error from a structure constructor names a slot nobody wrote,
while the default value keeps a turn running and the option the operator meant to
change is the one visible in the token count."
  (if (and (integerp value) (>= value minimum)) value default))

(declaim (ftype (function (provider &key (:api t)) bedrock-connection)
                bedrock-backend))

(defun bedrock-backend (provider &key (api :bedrock-invoke))
  "Return a BACKEND that speaks one of Bedrock's two Anthropic shapes.

The connection is built once and holds what does not change between turns; the
region and the credential are resolved per request, because the environment and
the secret store are read at that point."
  (let ((bearer (or (provider-key provider) "")))
    (%make-bedrock-connection
     :api api
     :dialect (bedrock-dialect-for api)
     :base-url (or (provider-base-url provider) "")
     :region (aws-nonempty-string (provider-option provider :region))
     :key bearer
     :headers (or (provider-headers provider) '())
     :model (or (provider-model provider) (provider-default-model provider) "")
     :max-tokens (bedrock-option-integer (provider-option provider :max-tokens)
                                         4096)
     :cache-p (not (null (provider-option provider :cache-p t)))
     :cache-ttl (aws-nonempty-string (provider-option provider :cache-ttl))
     :betas (bedrock-beta-list (provider-option provider :betas))
     :timeout (bedrock-option-integer (provider-option provider :timeout) 60)
     :retries (bedrock-option-integer (provider-option provider :retries) 2 0))))

;;;; The URL.

(declaim (ftype (function (bedrock-connection string string) string)
                bedrock-endpoint-url))

(defun bedrock-endpoint-url (connection path default-host)
  "Return PATH under CONNECTION's base URL, or under DEFAULT-HOST.

A provider that names a base URL is trusted to be the endpoint: a VPC endpoint
and a test double are both that, and neither answers at the regional name. The
slash is added rather than assumed, because a base URL without one turns the
first path segment into a host name."
  (let ((base (bedrock-connection-base-url connection)))
    (if (and (stringp base) (plusp (length base)))
        (concatenate 'string (ensure-trailing-slash base) path)
        (format nil "https://~A/~A" default-host path))))

(declaim (ftype (function (bedrock-connection string) string) bedrock-default-host))

(defun bedrock-default-host (connection region)
  "Return the AWS host name for CONNECTION's shape in REGION."
  (if (eq (bedrock-connection-api connection) :bedrock-messages)
      (format nil "bedrock-mantle.~A.api.aws" region)
      (format nil "bedrock-runtime.~A.amazonaws.com" region)))

(declaim (ftype (function (bedrock-connection string string) string)
                bedrock-request-url))

(defun bedrock-request-url (connection region model)
  "Return the URL for one request from CONNECTION.

The invoke path substitutes the model, escaped as a path segment: an inference
profile id carries a colon, and a colon sent raw in a request target is a URL the
service and the signature can disagree about. The mantle profile names its path
in the dialect because that is the field the table keeps for exactly this."
  (let ((path (or (aws-nonempty-string
                   (dialect-field (bedrock-connection-dialect connection)
                                  :chat-path))
                  (format nil "model/~A/invoke" (aws-uri-encode model)))))
    (bedrock-endpoint-url connection path
                          (bedrock-default-host connection region))))

(declaim (ftype (function (bedrock-connection string) string) bedrock-models-url))

(defun bedrock-models-url (connection region)
  "Return the control plane URL that lists the Anthropic foundation models.

byProvider=anthropic is part of the URL and is signed with the rest of it: the
query string is inside the canonical request, and a parameter appended after
signing is a parameter AWS refuses."
  (bedrock-endpoint-url connection
                        "foundation-models?byProvider=anthropic"
                        (format nil "bedrock.~A.amazonaws.com" region)))

;;;; The body.

(declaim (ftype (function (bedrock-connection list string list) hash-table)
                bedrock-request-body))

(defun bedrock-request-body (connection messages model tools)
  "Return the request body for MESSAGES as data.

Everything that differs between the two shapes comes from the dialect: whether
the model is written, whether the revision goes in the body, and whether the beta
list is a body array. The cache TTL is dropped when the profile says the endpoint
has no 1h lifetime, and cache_control itself is placed by the Anthropic builder
on the blocks that end the reusable prefix, which both endpoints accept."
  (let* ((dialect (bedrock-connection-dialect connection))
         (body (anthropic-request-body
                messages
                :model model
                :tools tools
                :max-tokens (bedrock-connection-max-tokens connection)
                :cache-p (bedrock-connection-cache-p connection)
                :cache-ttl (and (dialect-field dialect :cache-ttl-supported-p)
                                (bedrock-connection-cache-ttl connection))
                :model-in-body-p (dialect-field dialect :model-in-body-p))))
    (when (bedrock-version-in-body-p connection)
      (setf (gethash "anthropic_version" body) (bedrock-version connection)))
    (let ((betas (bedrock-connection-betas connection)))
      (when (and betas
                 (eq (dialect-field dialect :beta-channel :header) :body))
        (setf (gethash "anthropic_beta" body) (coerce betas 'vector))))
    body))

(declaim (ftype (function (bedrock-connection) list) bedrock-request-headers))

(defun bedrock-request-headers (connection)
  "Return the headers a request carries that are not the credential.

The revision header and the beta header are written only when the dialect puts
them in a header, so the invoke path gets neither: an anthropic-version header on
that endpoint is a different API's field, and the betas travel in the body.

The provider's own extra headers are merged underneath, so a configured header
cannot replace the content type that makes the body readable."
  (let* ((dialect (bedrock-connection-dialect connection))
         (headers (list (cons :content-type "application/json"))))
    (when (not (bedrock-version-in-body-p connection))
      (push (cons :anthropic-version (bedrock-version connection)) headers))
    (let ((betas (bedrock-connection-betas connection)))
      (when (and betas
                 (eq (dialect-field dialect :beta-channel :header) :header))
        (push (cons :anthropic-beta (format nil "~{~A~^,~}" betas)) headers)))
    (merge-headers (bedrock-connection-headers connection) headers)))

;;;; The credential.

(declaim (ftype (function (bedrock-connection) (or null string))
                bedrock-bearer-token))

(defun bedrock-bearer-token (connection)
  "Return the bearer token to send, or NIL when the request must be signed.

AWS_BEARER_TOKEN_BEDROCK is AWS's own short lived token and wins outright. A
provider key is a bearer token only while there is no access key to sign with: a
machine that has both is a machine whose operator configured a signature, and the
signature is the credential that was deliberately set up."
  (or (aws-nonempty-string
       (enchiridion.compat:environment-value "AWS_BEARER_TOKEN_BEDROCK"))
      (let ((key (aws-nonempty-string (bedrock-connection-key connection))))
        (when (and key (not (aws-credentials-available-p)))
          key))))

(declaim (ftype (function (bedrock-connection http-request
                                              &key (:extra list) (:method t)
                                                   (:service t))
                          http-request)
                bedrock-authorize))

(defun bedrock-authorize (connection request &key (extra '()) (method "POST")
                                                 service)
  "Return REQUEST with CONNECTION's credential applied.

Through AUTH-APPLY, so the scheme is the dialect's answer and this file writes no
credential header: :BEARER produces the Authorization header from the token, and
:AWS-SIGV4 reaches the signer aws-sigv4.cl registered. A signer needs the region,
the service and the method, and the dialect record carries none of them, so they
are bound around the call; the endpoint that built the URL is what knows them.

SERVICE overrides the shape's own service name, which the control plane needs:
listing models is a bedrock call whichever of the two shapes asked for the list.

EXTRA is where this handler's own headers go, and they are not signed: the
signature covers the host, the x-amz-* headers and the session token, which is
exactly the set AWS requires, and adding the content type to it would mean a
proxy that rewrites a charset breaks every request. AUTH-APPLY merges EXTRA
under whatever the signer returned, so the two do not fight over a name."
  (let* ((bearer (bedrock-bearer-token connection))
         (dialect (if bearer
                      (bedrock-dialect-for (bedrock-connection-api connection)
                                           :bearer-p t)
                      (bedrock-connection-dialect connection)))
         (*aws-region* (bedrock-region connection))
         (*aws-service* (or service (bedrock-service connection)))
         (*aws-request-method* method))
    (auth-apply dialect (or bearer "") request :extra extra)))

;;;; The reply.

(declaim (ftype (function (t) string) bedrock-short-text))

(defun bedrock-short-text (payload)
  "Return PAYLOAD as text, cut to something an error report can carry.

A proxy that answers with an HTML error page answers with a kilobyte of it, and
an error whose detail is a whole page is an error nobody reads."
  (let ((text (if (stringp payload) payload (princ-to-string payload))))
    (if (> (length text) 200)
        (concatenate 'string (subseq text 0 200) "...")
        text)))

(declaim (ftype (function (string) completion) bedrock-completion))

(defun bedrock-completion (payload)
  "Return the COMPLETION described by PAYLOAD, the reply text.

Two failures that look like successes are told apart here. AWS's error envelope
is an object with a message and no content, and it becomes a TRANSPORT-ERROR
carrying the service's own words, because nothing about the request changes by
reading it as a completion. A reply that is not a JSON object at all, an array or
a page of HTML, is a CONFIGURATION-ERROR naming the reply: the shape is wrong
before any content could be wrong.

Everything else goes to ANTHROPIC-PARSE-COMPLETION, which owns the reply shape
and reports a reply with no content blocks itself. PARSE-JSON upcases every key,
so AWS's message and Message are one key by the time they get here."
  (let* ((raw (handler-case (parse-json payload) (error () nil)))
         (data (and (consp raw) (keywordp (first raw)) raw)))
    (unless data
      (error 'enchiridion.errors:configuration-error
             :key :reply
             :detail (format nil "The Bedrock reply is not a JSON object: ~A"
                             (bedrock-short-text payload))))
    (let ((message (aws-nonempty-string (getf data :message))))
      (when message
        (error 'enchiridion.errors:transport-error
               :status 200
               :detail message)))
    (anthropic-parse-completion payload)))

;;;; The model list.
;;;;
;;;; The control plane is the only listing Bedrock offers, and it is deliberately
;;;; forgiving: the control plane has changed shape between API revisions, an
;;;; operator's VPC endpoint may answer with less, and a model list that throws
;;;; is a provider that cannot be listed at all.

(declaim (ftype (function (t t) t) bedrock-row-value))

(defun bedrock-row-value (row key)
  "Return KEY from ROW, one row of the parsed control plane reply, or NIL.

ROWS comes from a provider and may be anything at all: a row that is not an
object answers NIL here rather than signalling, because one odd row must not lose
the rest of the list."
  (if (listp row) (getf row key) nil))

(declaim (ftype (function (t t) list) bedrock-plist-list))

(defun bedrock-plist-list (plist key)
  "Return PLIST's KEY when it is a list, else the empty list."
  (let ((value (bedrock-row-value plist key)))
    (if (listp value) value '())))

(declaim (ftype (function (t) list) bedrock-summary-rows))

(defun bedrock-summary-rows (data)
  "Return the rows in DATA, the parsed control plane reply.

Models and inference profiles are both accepted, and so is a bare array: the
byProvider filter returns modelSummaries, a call that asks for profiles answers
with inferenceProfileSummaries, and a proxy may hand back the array itself."
  (cond
    ((null data) '())
    ((and (listp data) (keywordp (first data)))
     (append (bedrock-plist-list data :modelsummaries)
             (bedrock-plist-list data :inferenceprofilesummaries)))
    ((listp data) data)
    (t '())))

(declaim (ftype (function (t) (or null string)) bedrock-arn-tail))

(defun bedrock-arn-tail (arn)
  "Return the last slash separated field of ARN, or NIL.

A model row from an older revision names its model only by ARN. The tail of an
ARN is the model id or the inference profile id, which is the name a caller
needs, and an ARN with no slash is itself that name."
  (let ((arn (aws-nonempty-string arn)))
    (when arn
      (let ((slash (position #\/ arn :from-end t)))
        (aws-nonempty-string (if slash (subseq arn (1+ slash)) arn))))))

(declaim (ftype (function (t) (or null string)) bedrock-row-id))

(defun bedrock-row-id (row)
  "Return the model id a control plane row names, or NIL.

The id may arrive as a model id, as an inference profile id, or only inside an
ARN, and inference profile ids are the ones a caller wants in a region that has
no on demand access to the model itself."
  (or (aws-nonempty-string (bedrock-row-value row :modelid))
      (aws-nonempty-string (bedrock-row-value row :inferenceprofileid))
      (aws-nonempty-string (bedrock-row-value row :id))
      (bedrock-arn-tail (aws-nonempty-string
                         (bedrock-row-value row :modelarn)))))

(declaim (ftype (function (t) (or null string)) bedrock-row-name))

(defun bedrock-row-name (row)
  "Return the display name a control plane row carries, or NIL."
  (or (aws-nonempty-string (bedrock-row-value row :modelname))
      (aws-nonempty-string (bedrock-row-value row :inferenceprofilename))
      (aws-nonempty-string (bedrock-row-value row :name))))

(declaim (ftype (function (t) boolean) bedrock-anthropic-row-p))

(defun bedrock-anthropic-row-p (row)
  "Return T when ROW names Anthropic as its provider, or names none.

The request asks for byProvider=anthropic. This is what keeps a control plane
that ignored the filter from filling the catalog with models this handler cannot
speak to, and a row from an inference profile, which carries no provider, is kept."
  (let ((provider (aws-nonempty-string (bedrock-row-value row :providername))))
    (or (null provider) (string-equal provider "anthropic"))))

(declaim (ftype (function (t) list) bedrock-model-rows))

(defun bedrock-model-rows (payload)
  "Return MODEL-INFO rows for PAYLOAD, the control plane reply text.

A reply that is not JSON, a missing array and a row with no id all yield fewer
rows and never an error. TOOL-CALL-P is true for every row: the control plane does
not report tool support, and every Anthropic model Bedrock serves calls tools,
which is what the catalog's default rule reads."
  (let* ((data (handler-case (parse-json payload) (error () nil)))
         (rows (bedrock-summary-rows data)))
    (loop for row in rows
          for id = (bedrock-row-id row)
          when (and id (plusp (length id)) (bedrock-anthropic-row-p row))
            collect (%make-model-info :id id
                                      :name (or (bedrock-row-name row) id)
                                      :tool-call-p t
                                      :source :provider))))

(declaim (ftype (function (provider) list) bedrock-list-models))

(defun bedrock-list-models (provider)
  "Return the Anthropic models Bedrock's control plane offers for PROVIDER.

The list is one GET, signed for the bedrock service whichever shape asked, and
read through *HTTP-GET-FUNCTION* so a test can answer from a fixture."
  (let* ((connection (bedrock-backend provider
                                      :api (or (provider-api provider)
                                               :bedrock-invoke)))
         (region (bedrock-region connection))
         (request (make-http-request
                   :url (bedrock-models-url connection region)
                   :body ""
                   :headers '()
                   :timeout (bedrock-connection-timeout connection)))
         (signed (bedrock-authorize connection request :method "GET"
                                                      :service "bedrock")))
    (bedrock-model-rows
     (funcall *http-get-function*
              (http-request-url signed)
              :headers (http-request-headers signed)
              :timeout (bedrock-connection-timeout connection)))))

;;;; The operations.
;;;;
;;;; Last, because COMPLETE calls the builders above and a DEFMETHOD that calls a
;;;; name the compiler has not seen yet compiles into a variable reference and
;;;; fails at run time rather than here.

(defmethod backend-name ((connection bedrock-connection))
  "Return a short name for this backend."
  (format nil "~(~A~) ~A"
          (bedrock-connection-api connection)
          (or (bedrock-connection-region connection) "no region")))

(defmethod model-capabilities ((connection bedrock-connection))
  "Return what this backend's models support.

  :tools             tool calling is available
  :streaming         NIL: the invoke path streams through a different endpoint
  :cache             the provider reports cached prompt tokens
  :cache-breakpoints cache_control is accepted on a content block

:STREAMING is NIL here and T on Anthropic's own backend, and the difference is
real: this handler never calls the streaming operation, and reporting a feature
as present when nothing sends it is how a caller ends up waiting for a reply that
will not arrive."
  (declare (ignore connection))
  '(:tools t :streaming nil :cache t :cache-breakpoints t))

(defmethod complete ((connection bedrock-connection) messages
                     &key model tools budget)
  "Continue MESSAGES and return the COMPLETION.

The body is built first and the URL second, both from the same dialect, so the
model that is in the URL is the model that is absent from the body. BUDGET is
ignored: the budget decides whether a turn starts, not how long a reply may be,
and max_tokens comes from the connection."
  (declare (ignore budget))
  (let* ((region (bedrock-region connection))
         (model (bedrock-model connection model))
         (request (make-http-request
                   :url (bedrock-request-url connection region model)
                   :body (stringify (bedrock-request-body connection messages
                                                         model tools))
                   :headers '()
                   :timeout (bedrock-connection-timeout connection)))
         (signed (bedrock-authorize connection request
                                    :extra (bedrock-request-headers connection))))
    (bedrock-completion
     (post-with-retries *http-post-function* signed
                        (bedrock-connection-retries connection)))))

;;;; Registration.

(register-api-handler
 :bedrock-invoke
 :schema :anthropic
 :build (lambda (provider) (bedrock-backend provider :api :bedrock-invoke))
 :list-models #'bedrock-list-models
 :documentation
 "Amazon Bedrock's InvokeModel path for the Anthropic Messages schema: the model
is in the URL, the revision and the beta list are body fields, and the request is
signed with SigV4 unless a bearer token was resolved.")

(register-api-handler
 :bedrock-messages
 :schema :anthropic
 :build (lambda (provider) (bedrock-backend provider :api :bedrock-messages))
 :list-models #'bedrock-list-models
 :documentation
 "Anthropic's Messages transport behind AWS's Bedrock gateway at
bedrock-mantle.{region}.api.aws: the model is in the body, the revision and the
beta list are headers, and the request is signed with SigV4 under the
bedrock-mantle service unless a bearer token was resolved.")
