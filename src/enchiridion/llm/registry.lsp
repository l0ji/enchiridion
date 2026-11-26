;;;; registry.lsp --- Adapter registry and resolved provider record.
;;;;
;;;; Handlers register themselves by keyword id with a builder and optional
;;;; model lister. PROVIDER is the flat, resolved record passed to handlers.

(in-package #:enchiridion.llm)

;;; The provider row.

;; Resolved provider passed to handlers. KEY holds the credential value (not
;; env var name); ENV is kept for display/secret loading; OPTIONS holds
;; adapter-specific extras.
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
  ;; Named CACHED-MODELS to avoid colliding with the PROVIDER-MODELS function.
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

;; Cost slots are USD per million tokens; NIL means unspecified (distinct from 0).
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

;; SCHEMA is :OPENAI, :ANTHROPIC, or NIL. BUILD takes a PROVIDER and returns a
;; BACKEND; LIST-MODELS takes a PROVIDER and returns a list of MODEL-INFO or NIL.
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
  "Register handler ID and return it. Re-registering replaces the existing handler."
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
