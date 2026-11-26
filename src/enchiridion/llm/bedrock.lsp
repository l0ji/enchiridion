;;;; bedrock.lsp --- Amazon Bedrock's two Anthropic shapes, and its model list.
;;;;
;;;; Two APIs share the Messages schema via dialect profiles in dialects.lsp:
;;;;   :bedrock-invoke    POST {base-url}/model/{model}/invoke
;;;;                      (model in path; anthropic_version & anthropic_beta in body)
;;;;   :bedrock-messages  POST https://bedrock-mantle.{region}.api.aws/anthropic/v1/messages
;;;;                      (model in body; anthropic-version & anthropic-beta in headers)
;;;; Requests authenticate via AUTH-APPLY (:AWS-SIGV4 or :BEARER when a token is resolved).

(in-package #:enchiridion.llm)

;;;; The connection.

;; api is both handler ID and dialect profile. key holds an optional bearer token;
;; region is resolved per request when NIL so config listing works without AWS_REGION.
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
  "Return the DIALECT for API, clearing :model-in-body-p on :bedrock-invoke
(Bedrock rejects a duplicate model in the body) and switching :auth-scheme to
:bearer when BEARER-P is true."
  (make-dialect-for api
                    :protocol :anthropic
                    :overrides (append (and bearer-p (list :auth-scheme :bearer))
                                       (and (eq api :bedrock-invoke)
                                            (list :model-in-body-p nil)))))

(declaim (ftype (function (bedrock-connection) string) bedrock-region))

(defun bedrock-region (connection)
  "Return CONNECTION's AWS region (:region option, then AWS_REGION, then
AWS_DEFAULT_REGION, checking secrets before env), or signal CONFIGURATION-ERROR."
  (let ((region (or (aws-nonempty-string (bedrock-connection-region connection))
                    (secret-or-environment "AWS_REGION")
                    (secret-or-environment "AWS_DEFAULT_REGION"))))
    (or region
        (error 'enchiridion.errors:configuration-error
               :key :region
               :detail "No AWS region is configured: set :region on the provider, or AWS_REGION or AWS_DEFAULT_REGION in the environment or .env."))))

(declaim (ftype (function (bedrock-connection t) string) bedrock-model))

(defun bedrock-model (connection model)
  "Return the model for a request (MODEL, then CONNECTION's model), or signal CONFIGURATION-ERROR."
  (or (aws-nonempty-string model)
      (aws-nonempty-string (bedrock-connection-model connection))
      (error 'enchiridion.errors:configuration-error
             :key :model
             :detail "The Bedrock handler was asked for a completion with no model to ask for.")))

(declaim (ftype (function (bedrock-connection) string) bedrock-service))

(defun bedrock-service (connection)
  "Return the SigV4 service name for CONNECTION (\"bedrock-mantle\" for
:bedrock-messages, \"bedrock\" for :bedrock-invoke)."
  (if (eq (bedrock-connection-api connection) :bedrock-messages)
      "bedrock-mantle"
      "bedrock"))

(declaim (ftype (function (bedrock-connection) string) bedrock-version))

(defun bedrock-version (connection)
  "Return CONNECTION's API revision from its dialect :version-value, defaulting
to +ANTHROPIC-VERSION+."
  (or (aws-nonempty-string
       (dialect-field (bedrock-connection-dialect connection) :version-value))
      +anthropic-version+))

(declaim (ftype (function (bedrock-connection) boolean) bedrock-version-in-body-p))

(defun bedrock-version-in-body-p (connection)
  "Return T when CONNECTION's dialect places the API revision in the request body."
  (eq (dialect-field (bedrock-connection-dialect connection)
                     :version-location :header)
      :body))

(declaim (ftype (function (t integer &optional integer) integer)
                bedrock-option-integer))

(defun bedrock-option-integer (value default &optional (minimum 1))
  "Return VALUE if it is an integer >= MINIMUM, else DEFAULT."
  (if (and (integerp value) (>= value minimum)) value default))

(declaim (ftype (function (provider &key (:api t)) bedrock-connection)
                bedrock-backend))

(defun bedrock-backend (provider &key (api :bedrock-invoke))
  "Build a BEDROCK-CONNECTION for PROVIDER using API; region and credentials
are resolved per request."
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
     :betas (beta-list (provider-option provider :betas))
     :timeout (bedrock-option-integer (provider-option provider :timeout) 60)
     :retries (bedrock-option-integer (provider-option provider :retries) 2 0))))

;;;; The URL.

(declaim (ftype (function (bedrock-connection string string) string)
                bedrock-endpoint-url))

(defun bedrock-endpoint-url (connection path default-host)
  "Resolve PATH under CONNECTION's base URL (ensuring a trailing slash), or
under https://DEFAULT-HOST/."
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
  "Return the request URL for CONNECTION, using the dialect's :chat-path or
model/<uri-encoded-model>/invoke (encoding colons in inference profile IDs)."
  (let ((path (or (aws-nonempty-string
                   (dialect-field (bedrock-connection-dialect connection)
                                  :chat-path))
                  (format nil "model/~A/invoke" (aws-uri-encode model)))))
    (bedrock-endpoint-url connection path
                          (bedrock-default-host connection region))))

(declaim (ftype (function (bedrock-connection string) string) bedrock-models-url))

(defun bedrock-models-url (connection region)
  "Return the control-plane URL for listing Anthropic foundation models
(byProvider=anthropic is included so it is part of the signed query string)."
  (bedrock-endpoint-url connection
                        "foundation-models?byProvider=anthropic"
                        (format nil "bedrock.~A.amazonaws.com" region)))

;;;; The body.

(declaim (ftype (function (bedrock-connection list string list) hash-table)
                bedrock-request-body))

(defun bedrock-request-body (connection messages model tools)
  "Build the Anthropic request body hash table for CONNECTION per its dialect
(omitting model when in path, placing anthropic_version/anthropic_beta in body
when configured, and dropping cache_ttl if unsupported)."
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
  "Return non-credential headers for CONNECTION (anthropic-version and
anthropic-beta only when the dialect puts them in headers), merged over
provider extra headers."
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
  "Return the bearer token to send, or NIL to sign with SigV4.
AWS_BEARER_TOKEN_BEDROCK (secrets then env) always wins; CONNECTION's key is
used as a bearer token only when no AWS signing credentials are available."
  (or (aws-nonempty-string (secret-or-environment "AWS_BEARER_TOKEN_BEDROCK"))
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
  "Apply CONNECTION's credential to REQUEST via AUTH-APPLY (:bearer if a token
is resolved, else :aws-sigv4 with *AWS-REGION*, *AWS-SERVICE*, and
*AWS-REQUEST-METHOD* bound). EXTRA headers are merged under signed headers."
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
  "Return PAYLOAD as text truncated to 200 characters for error details."
  (let ((text (if (stringp payload) payload (princ-to-string payload))))
    (if (> (length text) 200)
        (concatenate 'string (subseq text 0 200) "...")
        text)))

(declaim (ftype (function (string) completion) bedrock-completion))

(defun bedrock-completion (payload)
  "Parse PAYLOAD as a Bedrock completion. Non-object JSON signals
CONFIGURATION-ERROR; an object with a :message key signals TRANSPORT-ERROR
(status 200); otherwise delegates to ANTHROPIC-PARSE-COMPLETION."
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

;;;; The model list (forgiving control-plane parser).

(declaim (ftype (function (t t) t) bedrock-row-value))

(defun bedrock-row-value (row key)
  "Return KEY from plist ROW, or NIL if ROW is not a list."
  (if (listp row) (getf row key) nil))

(declaim (ftype (function (t t) list) bedrock-plist-list))

(defun bedrock-plist-list (plist key)
  "Return PLIST's KEY when it is a list, else the empty list."
  (let ((value (bedrock-row-value plist key)))
    (if (listp value) value '())))

(declaim (ftype (function (t) list) bedrock-summary-rows))

(defun bedrock-summary-rows (data)
  "Extract model rows from parsed control-plane DATA (modelSummaries,
inferenceProfileSummaries, or a bare list)."
  (cond
    ((null data) '())
    ((and (listp data) (keywordp (first data)))
     (append (bedrock-plist-list data :modelsummaries)
             (bedrock-plist-list data :inferenceprofilesummaries)))
    ((listp data) data)
    (t '())))

(declaim (ftype (function (t) (or null string)) bedrock-arn-tail))

(defun bedrock-arn-tail (arn)
  "Return the last slash-separated segment of ARN (or ARN itself if no slash), or NIL."
  (let ((arn (aws-nonempty-string arn)))
    (when arn
      (let ((slash (position #\/ arn :from-end t)))
        (aws-nonempty-string (if slash (subseq arn (1+ slash)) arn))))))

(declaim (ftype (function (t) (or null string)) bedrock-row-id))

(defun bedrock-row-id (row)
  "Return the model or inference profile ID from ROW, falling back to the tail of :modelarn."
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
  "Return T when ROW's :providername is \"anthropic\" or absent (as on inference profiles)."
  (let ((provider (aws-nonempty-string (bedrock-row-value row :providername))))
    (or (null provider) (string-equal provider "anthropic"))))

(declaim (ftype (function (t) list) bedrock-model-rows))

(defun bedrock-model-rows (payload)
  "Parse control-plane PAYLOAD into MODEL-INFO structs for Anthropic rows,
ignoring malformed data and setting :tool-call-p to T."
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
  "Fetch Anthropic models from Bedrock's control plane for PROVIDER via a GET
signed for the \"bedrock\" service."
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
     (get-with-retries signed (bedrock-connection-retries connection)))))

;;;; The operations.

(defmethod backend-name ((connection bedrock-connection))
  "Return a short name for this backend."
  (format nil "~(~A~) ~A"
          (bedrock-connection-api connection)
          (or (bedrock-connection-region connection) "no region")))

(defmethod model-capabilities ((connection bedrock-connection))
  "Return supported capabilities (:streaming is NIL because this handler does
not call the streaming endpoint)."
  (declare (ignore connection))
  '(:tools t :streaming nil :cache t :cache-breakpoints t))

(defmethod complete ((connection bedrock-connection) messages
                     &key model tools budget)
  "Continue MESSAGES and return a COMPLETION. BUDGET is ignored; max_tokens
comes from CONNECTION."
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
