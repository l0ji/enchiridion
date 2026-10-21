;;;; registry.cl --- The adapter registry and the provider record it speaks.
;;;;
;;;; OpenCode resolves a provider's npm package to an AI SDK adapter. This tree
;;;; has no SDK, so the equivalent is a registry: an adapter id is a keyword,
;;;; an adapter is a builder plus a model lister, and a provider names one. No
;;;; file above this one branches on a vendor, and no vendor file is referenced
;;;; by name: each handler registers itself as it loads, and the provider table
;;;; only ever asks the registry for an id.
;;;;
;;;; PROVIDER is the record that crosses the boundary between the provider
;;;; table (which knows about models.dev, config and secrets) and a handler
;;;; (which knows about one wire). It is deliberately flat and already
;;;; resolved: a handler receives a base URL, a key, and the options it needs,
;;;; and never reads the configuration or the secret store itself.

(in-package #:enchiridion.llm)

;;; The provider row.

;; Everything here is resolved before a handler sees it. KEY is the credential
;; value and not the name of the variable that holds it, so a handler cannot
;; accidentally print or re-read the name. ENV is kept for `providers show' and
;; for the secret loader's name list. OPTIONS carries the handler-specific
;; extras (a region for Bedrock, a project and location for Vertex, a dialect
;; override plist) as one plist so this structure does not grow a slot per
;; vendor.
(defstruct (provider (:constructor %make-provider))
  (id nil)
  (name "" :type string)
  (api nil)                          ; the api-handler id, a keyword
  (profile nil)                      ; the dialect profile, a keyword
  (base-url "" :type string)
  (key "" :type string)
  (env '() :type list)
  (model nil :type (or null string))
  (default-model nil :type (or null string))
  ;; CACHED-MODELS and not MODELS: a slot named MODELS generates the accessor
  ;; PROVIDER-MODELS, and the provider table exports a function of that name
  ;; which lists the models a live account can use. The collision is a
  ;; redefinition warning, and in this tree a warning is an error.
  (cached-models '() :type list)
  (headers '() :type list)
  (query-params '() :type list)
  (options '() :type list)
  (doc "" :type string)
  (source :catalog))

(defun provider-option (provider key &optional default)
  "Return KEY from PROVIDER's options plist, or DEFAULT."
  (getf (provider-options provider) key default))

;;; One model, as reported by a provider or by models.dev.

;; tool-call-p decides whether the catalog default rule may choose it: a model
;; that cannot call tools cannot drive this harness, whatever its context
;; window says. The four cost slots are USD per million tokens as models.dev
;; reports them; NIL means the source did not say, which is not the same fact
;; as zero.
(defstruct (model-info (:constructor %make-model-info))
  (id "" :type string)
  (name "" :type string)
  (tool-call-p nil :type boolean)
  (reasoning-p nil :type boolean)
  (context nil :type (or null integer))
  (output nil :type (or null integer))
  (cost-input nil :type (or null number))
  (cost-output nil :type (or null number))
  (cost-cache-read nil :type (or null number))
  (cost-cache-write nil :type (or null number))
  (source :provider))

;;; The adapter registry.

;; SCHEMA names the wire schema the handler speaks and nothing else, so a
;; caller that only needs to know "is this the Messages shape" does not have to
;; know about Bedrock. SCHEMA is :OPENAI, :ANTHROPIC, or NIL for a handler with
;; a shape of its own.
;;
;; BUILD is a function of one PROVIDER that returns a BACKEND. LIST-MODELS is a
;; function of one PROVIDER that returns a list of MODEL-INFO, or NIL when the
;; endpoint offers no model list at all. Both are functions and not keywords
;; because a handler may need to close over its own dialect or clock.
(defstruct (api-handler (:constructor %make-api-handler))
  (id nil :type symbol)
  (schema nil)
  (build nil :type (or null function))
  (list-models nil :type (or null function))
  (documentation "" :type string))

(defparameter *api-handlers* (make-hash-table :test #'eq)
  "Adapter id to API-HANDLER. Filled by the handler files as they load.")

(declaim (ftype (function (symbol) t) find-api-handler))

(defun find-api-handler (id)
  "Return the handler registered under ID, or NIL when there is none."
  (and id (gethash id *api-handlers*)))

(defun register-api-handler (id &key schema build list-models documentation)
  "Register the handler ID and return it.

Re-registering an id replaces the previous handler. That is deliberate: a
reload of this tree re-runs every handler file, and a registry that refused a
second registration would stop the second load of an unchanged file."
  (unless (keywordp id)
    (error 'enchiridion.errors:configuration-error
           :key :api
           :detail (format nil "An adapter id must be a keyword, not ~S." id)))
  (setf (gethash id *api-handlers*)
        (%make-api-handler :id id :schema schema :build build
                           :list-models list-models
                           :documentation (or documentation ""))))

(declaim (ftype (function () list) registered-api-handlers))

(defun registered-api-handlers ()
  "Return every registered handler id, sorted, so a listing cannot drift."
  (sort (loop for id being the hash-keys of *api-handlers* collect id)
        #'string< :key #'symbol-name))

(declaim (ftype (function (provider) boolean) provider-supported-p))

(defun provider-supported-p (provider)
  "Return T when PROVIDER names an adapter this build actually has."
  (not (null (find-api-handler (provider-api provider)))))
