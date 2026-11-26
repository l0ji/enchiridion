;;;; providers.lsp --- Provider table, resolution, and model listing.
;;;;
;;;; Merges rows field-by-field in order: cached catalog < shipped defaults <
;;;; operator :providers. Detection order: explicit :provider, recognized
;;;; :base-url host, shipped key vars (OpenAI/OpenCode/Anthropic), sole catalog
;;;; provider with a key present, then :openai. Model lists are fetched via the
;;;; adapter, cached under run/models/, enriched with catalog pricing, and
;;;; fall back without signaling on failure.

(in-package #:enchiridion.llm)

;;;; Mapping models.dev npm packages to adapters, profiles, and default endpoints.
;;;; Unlisted packages are unsupported unless given :base-url and :api in config.
;;;; Cloudflare's gateway URL is a prefix; operators append account/gateway via :base-url.
(defparameter +npm-adapters+
  '(("@ai-sdk/openai-compatible" :api :openai-chat)
    ("@ai-sdk/openai" :api :openai-chat
                     :base-url "https://api.openai.com/v1")
    ;; Azure requires ${AZURE_RESOURCE_NAME} expansion; missing env yields no endpoint.
    ("@ai-sdk/azure" :api :openai-chat :profile :azure
                    :base-url "https://${AZURE_RESOURCE_NAME}.openai.azure.com/")
    ("@openrouter/ai-sdk-provider" :api :openai-chat :profile :openrouter)
    ("@ai-sdk/groq" :api :openai-chat
                   :base-url "https://api.groq.com/openai/v1")
    ("@ai-sdk/mistral" :api :openai-chat
                       :base-url "https://api.mistral.ai/v1")
    ("@ai-sdk/xai" :api :openai-chat
                  :base-url "https://api.x.ai/v1")
    ("@ai-sdk/cerebras" :api :openai-chat
                        :base-url "https://api.cerebras.ai/v1")
    ("@ai-sdk/togetherai" :api :openai-chat
                          :base-url "https://api.together.xyz/v1")
    ("@ai-sdk/deepinfra" :api :openai-chat
                         :base-url "https://api.deepinfra.com/v1/openai")
    ("venice-ai-sdk-provider" :api :openai-chat
                              :base-url "https://api.venice.ai/api/v1")
    ("@aihubmix/ai-sdk-provider" :api :openai-chat
                                 :base-url "https://aihubmix.com/v1")
    ("@saladtechnologies-oss/ai-sdk-provider" :api :openai-chat
                                              :base-url "https://ai.salad.cloud/v1")
    ("@ai-sdk/gateway" :api :openai-chat
                       :base-url "https://ai-gateway.vercel.sh/v1")
    ("ai-gateway-provider" :api :openai-chat :profile :cloudflare-gateway
                           :base-url "https://gateway.ai.cloudflare.com/v1")
    ("@ai-sdk/anthropic" :api :anthropic-messages :profile :anthropic
                         :base-url "https://api.anthropic.com")
    ("@ai-sdk/amazon-bedrock" :api :bedrock-invoke :profile :bedrock-invoke)
    ("@ai-sdk/google-vertex/anthropic" :api :vertex-anthropic :profile :vertex))
  "Alist mapping supported models.dev npm packages to (:api :profile :base-url) plists.")

(declaim (ftype (function (t) list) npm-adapter))

(defun npm-adapter (npm)
  "Return NPM's adapter plist, or NIL when this build has no adapter for it."
  (and (stringp npm) (cdr (assoc npm +npm-adapters+ :test #'string=))))

;;;; Adapter ids, protocols and profiles.

(declaim (ftype (function (t) t) handler-protocol))

(defun handler-protocol (api)
  "Return the wire schema (:OPENAI or :ANTHROPIC) spoken by adapter id API, or NIL."
  (case api
    (:openai-chat :openai)
    (:anthropic-messages :anthropic)
    (:bedrock-invoke :anthropic)
    (:bedrock-messages :anthropic)
    (:vertex-anthropic :anthropic)
    (t nil)))

(declaim (ftype (function (t) t) protocol-profile))

(defun protocol-profile (protocol)
  "Return the generic dialect profile for a wire schema, or NIL."
  (case protocol
    (:openai :openai)
    (:anthropic :anthropic)
    (t nil)))

(declaim (ftype (function (t) t) handler-profile))

(defun handler-profile (api)
  "Return the dialect profile an adapter id implies, or NIL."
  (case api
    (:openai-chat :openai)
    (:anthropic-messages :anthropic)
    (:bedrock-invoke :bedrock-invoke)
    (:bedrock-messages :bedrock-messages)
    (:vertex-anthropic :vertex)
    (t (protocol-profile (handler-protocol api)))))

(declaim (ftype (function (t) t) profile-handler-id))

(defun profile-handler-id (profile)
  "Return the adapter id implied by dialect PROFILE, falling back to +NPM-ADAPTERS+, or NIL."
  (case profile
    (:openai :openai-chat)
    (:openai-local :openai-chat)
    (:ollama :openai-chat)
    (:deepseek :openai-chat)
    (:google-openai :openai-chat)
    (:qwen :openai-chat)
    (:zai :openai-chat)
    (:groq :openai-chat)
    (:anthropic :anthropic-messages)
    (:anthropic-gateway :anthropic-messages)
    (:bedrock-messages :bedrock-messages)
    (t (loop for (npm . adapter) in +npm-adapters+
             when (eq (getf adapter :profile) profile)
               return (getf adapter :api)))))

(declaim (ftype (function (t) t) backend-handler-id))

(defun backend-handler-id (backend)
  "Resolve legacy :BACKEND (:OPENAI, :ANTHROPIC) or a registered adapter id to an adapter id, or NIL."
  (case backend
    (:openai :openai-chat)
    (:anthropic :anthropic-messages)
    ((nil) nil)
    (t (and (find-api-handler backend) backend))))

;;;; The three legacy host names and any catalog host.

(declaim (ftype (function (t) boolean) provider-key-present-p))

(defun provider-key-present-p (name)
  "Return T when NAME has a non-empty value in secrets or the environment (ignoring empty vars)."
  (and (nonempty-string-p name)
       (or (enchiridion.llm.secrets:secret-present-p name)
           (nonempty-string-p (enchiridion.compat:environment-value name)))))

(declaim (ftype (function (t) boolean) provider-has-key-p))

(defun provider-has-key-p (provider)
  "Return T when any of PROVIDER's key variables is present."
  (not (null (some #'provider-key-present-p (provider-env provider)))))

(declaim (ftype (function (t) (or null keyword)) provider-from-base-url))

(defun provider-from-base-url (url)
  "Return :OPENCODE, :ANTHROPIC, or :OPENAI if URL matches a known shipped host, else NIL."
  (when (stringp url)
    (cond
      ((search "opencode.ai" url) :opencode)
      ((search "api.anthropic.com" url) :anthropic)
      ((search "api.openai.com" url) :openai)
      (t nil))))

(declaim (ftype (function (t) (or null string)) url-host))

(defun url-host (url)
  "Return the lowercased host of URL without scheme, userinfo, or port, or NIL."
  (when (nonempty-string-p url)
    (let* ((start (cond ((and (>= (length url) 8)
                              (string-equal "https://" url :end2 8))
                         8)
                        ((and (>= (length url) 7)
                              (string-equal "http://" url :end2 7))
                         7)
                        (t 0)))
           (rest (subseq url start))
           (stop (or (position-if (lambda (character)
                                    (member character '(#\/ #\? #\#)))
                                  rest)
                     (length rest)))
           (authority (subseq rest 0 stop))
           (at (position #\@ authority))
           (host-port (if at (subseq authority (1+ at)) authority))
           (colon (position #\: host-port)))
      (string-downcase (if colon (subseq host-port 0 colon) host-port)))))

;;;; Rows.

(declaim (ftype (function (t t) t) find-row))

(defun find-row (rows id)
  "Return the row in ROWS whose :ID matches ID (normalized to keyword), or NIL."
  (let ((wanted (provider-id-keyword id)))
    (and wanted
         (find wanted rows
               :key (lambda (row) (provider-id-keyword (getf row :id)))
               :test #'eq))))

(declaim (ftype (function (&rest t) list) merge-rows))

(defun merge-rows (&rest rows)
  "Merge row plists in order, later rows winning key by key (explicit NIL overrides earlier values)."
  (let ((merged '()))
    (dolist (row rows merged)
      (loop for (key value) on row by #'cddr
            do (setf (getf merged key) value)))))

(declaim (ftype (function () list) shipped-provider-rows))

(defun shipped-provider-rows ()
  "Return the built-in :providers rows from default-config (offline fallback)."
  (let ((rows (enchiridion:config-value (enchiridion:default-config) :providers)))
    (if (listp rows) rows '())))

(declaim (ftype (function (t) list) operator-provider-rows))

(defun operator-provider-rows (config)
  "Return the operator's :providers rows from CONFIG, signaling if any row lacks an :id."
  (let ((rows (enchiridion:config-value config :providers)))
    (dolist (row (if (listp rows) rows '()))
      (unless (provider-id-keyword (getf row :id))
        (error 'enchiridion.errors:configuration-error
               :key :providers
               :detail (format nil "A provider row under :providers has no :id: ~S" row))))
    (if (listp rows) rows '())))

(declaim (ftype (function (t) list) catalog-row-plist))

(defun catalog-row-plist (provider)
  "Return one cached PROVIDER as a row plist, so it can be merged like a row."
  (list :id (provider-id provider)
        :name (provider-name provider)
        :npm (provider-option provider :npm)
        :protocol (provider-option provider :protocol)
        :base-url (provider-base-url provider)
        :api-key-env (provider-env provider)
        :default-model (provider-default-model provider)
        :doc (provider-doc provider)
        :source :catalog))

(declaim (ftype (function () list) catalog-plists))

(defun catalog-plists ()
  "Return every cached catalog provider as a row plist."
  (mapcar #'catalog-row-plist (catalog-providers)))

(declaim (ftype (function (t) list) provider-plists))

(defun provider-plists (config)
  "Return shipped and operator rows merged over cached catalog rows (catalog < shipped < operator).
Sets :source to :config or :shipped."
  (let ((shipped (shipped-provider-rows))
        (operator (operator-provider-rows config))
        (catalog (catalog-plists))
        (ids '()))
    (dolist (row shipped)
      (pushnew (provider-id-keyword (getf row :id)) ids :test #'eq))
    (dolist (row operator)
      (pushnew (provider-id-keyword (getf row :id)) ids :test #'eq))
    (loop for id in (nreverse ids)
          for row = (merge-rows (find-row catalog id)
                                (find-row shipped id)
                                (find-row operator id))
          collect (progn
                    (setf (getf row :source)
                          (if (find-row operator id) :config :shipped))
                    row))))

;;;; Row fields.

(declaim (ftype (function (t) list) row-env-names))

(defun row-env-names (row)
  "Return ROW's :api-key-env as a deduplicated list of nonempty strings in order."
  (let ((value (getf row :api-key-env))
        (names '()))
    (dolist (name (cond ((stringp value) (list value))
                        ((listp value) value)
                        (t '())))
      (when (and (nonempty-string-p name)
                 (not (member name names :test #'string=)))
        (setf names (append names (list name)))))
    names))

(declaim (ftype (function (t t) list) row-list))

(defun row-list (row key)
  "Return ROW's KEY as a list, or NIL."
  (let ((value (getf row key)))
    (if (listp value) value '())))

(declaim (ftype (function (t) list) row-model-infos))

(defun row-model-infos (row)
  "Return ROW's static :models list as MODEL-INFO structs (used when a provider cannot list models)."
  (loop for model in (row-list row :models)
        when (nonempty-string-p model)
          collect (%make-model-info :id model :name model :source :config)))

(declaim (ftype (function (t) list) row-dialect-overrides))

(defun row-dialect-overrides (row)
  "Extract the seven supported dialect override keys from ROW, preserving explicit NIL values."
  (loop for (key value) on row by #'cddr
        when (member key '(:auth-scheme :auth-header :chat-path :models-path
                           :max-tokens-field :system-role :reasoning-field)
                     :test #'eq)
          append (list key value)))

;;;; One row as a PROVIDER.

(defparameter +provider-option-keys+
  '(:max-tokens :models-ttl-seconds :region :project :location
    :cache-p :cache-ttl :betas :timeout :retries)
  "Row and configuration keys copied into a provider's options plist.")

(declaim (ftype (function (t) (or null string)) expandable-endpoint))

(defun expandable-endpoint (url)
  "Expand ${NAME} placeholders in URL via secrets/env, returning NIL if expansion fails."
  (when (nonempty-string-p url)
    (if (search "${" url)
        (ignore-errors (enchiridion.llm::expand-environment url))
        url)))

(defparameter +option-integer-floors+
  '((:max-tokens . 1) (:timeout . 1) (:retries . 0) (:models-ttl-seconds . 0))
  "Minimum allowed integer values for numeric provider options; invalid values are ignored with a warning.")

(declaim (ftype (function (t t) boolean) usable-option-integer-p))

(defun usable-option-integer-p (value floor)
  "Return T when VALUE is a whole number FLOOR accepts."
  (and (integerp value) (>= value floor)))

(declaim (ftype (function (t keyword t) null) note-unusable-option))

(defun note-unusable-option (id key floor)
  "Warn on *ERROR-OUTPUT* that KEY for provider ID failed its integer FLOOR check, returning NIL."
  (format *error-output*
          "~&enchiridion: ignoring ~S for ~A: it is not a whole number of at least ~D.~
           ~&  The adapter's own default is used instead.~%"
          key id floor)
  (finish-output *error-output*)
  nil)

(declaim (ftype (function (t t) list) provider-options-from))

(defun provider-options-from (row config)
  "Build ROW's options plist, falling back to CONFIG for omitted keys.
Preserves explicit NIL values; drops invalid numeric options with a warning."
  (let ((options (list :npm (getf row :npm)
                       :protocol (getf row :protocol)
                       :backend (getf row :backend)
                       :dialect-overrides (row-dialect-overrides row))))
    (dolist (key +provider-option-keys+ options)
      (let* ((value (getf row key :absent))
             (floor (assoc key +option-integer-floors+ :test #'eq)))
        (when (eq value :absent)
          (setf value (enchiridion:config-value config key :absent)))
        (cond
          ((eq value :absent))
          ((null floor) (setf (getf options key) value))
          ((usable-option-integer-p value (cdr floor))
           (setf (getf options key) value))
          ;; An explicit NIL is a value: it means `unset', which is the
          ;; handler's default, so it is not a typo and gets no line.
          ((null value))
          (t (note-unusable-option (or (provider-id-keyword (getf row :id))
                                       (getf row :id)
                                       :provider)
                                   key (cdr floor))))))))

(declaim (ftype (function (t t) (or null string)) row-key))

(defun row-key (env api-key)
  "Resolve the API key: explicit API-KEY, then first nonempty value in ENV from secrets or environment."
  (or (and (nonempty-string-p api-key) api-key)
      (loop for name in env
            thereis (let ((value (or (enchiridion.llm.secrets:secret-value name)
                                     (enchiridion.compat:environment-value name))))
                      (and (nonempty-string-p value) value)))))

;; No FTYPE: SBCL requires pre-declared keyword types in &KEY FTYPEs.
(defun %provider-from-row (row source &key config api-key base-url api model)
  "Resolve canonical row plist ROW into a PROVIDER struct with SOURCE (:SHIPPED, :CONFIG, :CATALOG).
Adapter resolution: explicit API > row :api > npm adapter > profile. Leaves :api NIL if unsupported."
  (let* ((config (or config '()))
         (id (or (provider-id-keyword (getf row :id)) (getf row :id)))
         (npm (getf row :npm))
         (adapter (or (npm-adapter npm) '()))
         (handler (or api
                      (getf row :api)
                      (getf adapter :api)
                      (and (getf row :profile)
                           (profile-handler-id (getf row :profile)))))
         (protocol (or (getf row :protocol) (handler-protocol handler)))
         (profile (or (getf row :profile)
                      (getf adapter :profile)
                      (handler-profile handler)
                      (protocol-profile protocol)
                      :openai))
         (env (let ((names (enchiridion:config-api-key-env-list config)))
                (dolist (name (row-env-names row))
                  (unless (member name names :test #'string=)
                    (setf names (append names (list name)))))
                names))
         (default-model (or (getf row :default-model) (getf row :model)))
         (options (provider-options-from row config)))
    (%make-provider
     :id id
     :name (or (and (nonempty-string-p (getf row :name)) (getf row :name))
               (provider-cache-name id))
     :api handler
     :profile profile
     :base-url (or (expandable-endpoint base-url)
                   (expandable-endpoint (getf row :base-url))
                   (expandable-endpoint (getf adapter :base-url))
                   "")
     :key (or (row-key env api-key) "")
     :env env
     :model (or (and (nonempty-string-p model) model)
                (and (nonempty-string-p (getf row :model)) (getf row :model))
                default-model)
     :default-model default-model
     :headers (row-list row :headers)
     :query-params (row-list row :query-params)
     :cached-models (row-model-infos row)
     :doc (or (getf row :doc) "")
     :source source
     :options options)))

(declaim (ftype (function (t) list) provider-rows))

(defun provider-rows (config)
  "Return the shipped and operator rows as PROVIDER structs."
  (mapcar (lambda (row) (%provider-from-row row (getf row :source) :config config))
          (provider-plists config)))

(declaim (ftype (function (provider &optional t) provider) catalog-provider-row))

(defun catalog-provider-row (provider &optional config)
  "Return one cached PROVIDER with its adapter, profile and base URL resolved."
  (%provider-from-row (catalog-row-plist provider) :catalog :config config))

(declaim (ftype (function (provider) boolean) catalog-row-supported-p))

(defun catalog-row-supported-p (provider)
  "Return T when cached catalog PROVIDER's npm package maps to a registered adapter."
  (not (null (find-api-handler
              (getf (npm-adapter (provider-option provider :npm)) :api)))))

;;;; Detection.

(declaim (ftype (function (t) t) catalog-provider-by-host))

(defun catalog-provider-by-host (url)
  "Return the id of the first cached provider (sorted by id) whose endpoint host matches URL."
  (let ((host (url-host url)))
    (when host
      (loop for provider in (sort (copy-list (catalog-providers))
                                  #'string< :key (lambda (candidate)
                                                   (provider-cache-name
                                                    (provider-id candidate))))
            for adapter = (npm-adapter (provider-option provider :npm))
            for endpoint = (or (and (nonempty-string-p (provider-base-url provider))
                                    (provider-base-url provider))
                               (getf adapter :base-url))
            when (string-equal host (url-host endpoint))
              return (provider-id provider)))))

(declaim (ftype (function (t) t) detect-provider-from-base-url))

(defun detect-provider-from-base-url (url)
  "Return the provider a base URL selects: a shipped host, then a catalog one."
  (when (nonempty-string-p url)
    (or (provider-from-base-url url)
        (catalog-provider-by-host url))))

(declaim (ftype (function () t) only-catalog-provider-with-key))

(defun only-catalog-provider-with-key ()
  "Return the id of the sole cached provider with a key present, or NIL if zero or multiple match."
  (let ((found '()))
    (dolist (provider (catalog-providers))
      (when (provider-has-key-p provider)
        (push (provider-id provider) found)))
    (when (= 1 (length found)) (first found))))

(declaim (ftype (function (&optional t) keyword) detect-provider))

(defun detect-provider (&optional config)
  "Detect provider id from CONFIG: explicit :provider > :base-url host >
OPENAI/OPENCODE/ANTHROPIC key env > sole catalog provider with key > :openai."
  (let ((config (or config '())))
    (or (provider-id-keyword (enchiridion:config-value config :provider))
        (detect-provider-from-base-url (enchiridion:config-value config :base-url))
        (and (provider-key-present-p "OPENAI_API_KEY") :openai)
        (and (provider-key-present-p "OPENCODE_API_KEY") :opencode)
        (and (provider-key-present-p "ANTHROPIC_API_KEY") :anthropic)
        (only-catalog-provider-with-key)
        :openai)))

;;;; Resolution.

(declaim (ftype (function (t) list) custom-provider-row))

(defun custom-provider-row (config)
  "Build a row plist for (:provider :custom) from top-level :llm keys; requires :base-url."
  (let ((base-url (enchiridion:config-value config :base-url)))
    (unless (nonempty-string-p base-url)
      (error 'enchiridion.errors:configuration-error
             :key :base-url
             :detail "(:provider :custom) needs :base-url in the :llm section."))
    (list :id :custom
          :name "Custom"
          ;; Default to :openai-chat when :backend is unspecified.
          :api (or (backend-handler-id (enchiridion:config-value config :backend))
                   :openai-chat)
          :backend (or (enchiridion:config-value config :backend) :openai)
          :base-url base-url
          :api-key-env (enchiridion:config-value config :api-key-env)
          :model (enchiridion:config-value config :model-primary)
          :default-model (enchiridion:config-value config :model-primary)
          :models (enchiridion:config-value config :models)
          :headers (enchiridion:config-value config :headers)
          :query-params (enchiridion:config-value config :query-params)
          :region (enchiridion:config-value config :region)
          :project (enchiridion:config-value config :project)
          :location (enchiridion:config-value config :location)
          :source :config)))

(declaim (ftype (function (list t) list) row-with-top-level-defaults))

(defun row-with-top-level-defaults (row config)
  "Merge top-level :headers, :query-params, and :profile from CONFIG into ROW when absent."
  (let ((result (copy-list row)))
    (dolist (key '(:headers :query-params :profile))
      (when (eq (getf result key :absent) :absent)
        (let ((value (enchiridion:config-value config key :absent)))
          (unless (eq value :absent)
            (setf (getf result key) value)))))
    result))

(defun %resolve-provider (config id &key api-key base-url api (refresh nil))
  "Resolve provider ID from operator/shipped rows then cached catalog.
Refreshes catalog once on miss only when REFRESH is true and :offline is false."
  (let* ((config (or config '()))
         (wanted (or (provider-id-keyword id) id)))
    (if (eq wanted :custom)
        (%provider-from-row (custom-provider-row config) :config
                            :config config :api-key api-key :base-url base-url :api api)
        (let ((row (or (find-row (provider-plists config) wanted)
                       (find-row (catalog-plists) wanted))))
          (when (and (null row)
                     refresh
                     (not (enchiridion:config-value config :offline)))
            (ignore-errors (refresh-catalog))
            (setf row (find-row (catalog-plists) wanted)))
          (unless row
            (error 'enchiridion.errors:configuration-error
                   :key :provider
                   :detail (format nil "There is no provider called ~A. Run `enchiridion providers refresh` to fetch the catalog, or add a row for it under :providers in config.lsp." wanted)))
          (%provider-from-row (row-with-top-level-defaults row config)
                              (getf row :source)
                              :config config
                              :api-key api-key
                              :base-url (or base-url (enchiridion:config-value config :base-url))
                              :api api
                              :model (or (enchiridion:config-value config :model-primary)
                                         (getf row :model)
                                         (getf row :default-model)))))))

;; No FTYPE: &KEY arguments.
(defun resolve-provider (config &key api-key)
  "Resolve the active PROVIDER for CONFIG via DETECT-PROVIDER, with optional API-KEY override."
  (%resolve-provider config (detect-provider config) :api-key api-key))

(declaim (ftype (function (t) t) backend-provider-id))

(defun backend-provider-id (config)
  "Return the provider id for RESOLVE-BACKEND: explicit :provider, :anthropic if :backend is :anthropic, else DETECT-PROVIDER."
  (let ((explicit (enchiridion:config-value config :provider)))
    (if explicit
        (provider-id-keyword explicit)
        (if (eq (enchiridion:config-value config :backend) :anthropic)
            :anthropic
            (detect-provider config)))))

(declaim (ftype (function (provider) t) unsupported-provider-error))

(defun unsupported-provider-error (provider)
  "Signal the configuration error for a provider this build cannot serve."
  (error 'enchiridion.errors:configuration-error
         :key :provider
         :detail (format nil "~A (~A) has no adapter in this build~@[ (npm ~A)~]. Set :base-url and :api on its row under :providers in config.lsp."
                         (provider-name provider)
                         (provider-id provider)
                         (provider-option provider :npm))))

(defun resolve-backend (&key (config nil) (api-key nil) (base-url nil))
  "Build and return the BACKEND for CONFIG, with optional API-KEY and BASE-URL overrides.
Refuses a :backend wire that mismatches the auto-detected provider unless :provider or :base-url is explicit."
  (let* ((config (or config '()))
         (backend (enchiridion:config-value config :backend))
         (declared (backend-handler-id backend)))
    (when (and backend (null declared))
      (error 'enchiridion.errors:configuration-error
             :key :backend
             :detail (format nil "No backend for ~S. :BACKEND is :OPENAI or :ANTHROPIC, or one of the adapter ids this build registered: ~{~A~^, ~}."
                             backend (registered-api-handlers))))
    (let* ((wanted (backend-provider-id config))
           (configured (or base-url
                           (enchiridion:config-value config :base-url)))
           (provider (%resolve-provider config wanted
                                        :api-key api-key
                                        :base-url configured
                                        :api declared))
           (handler (find-api-handler (provider-api provider))))
      ;; Refuse :backend override when it conflicts with an auto-detected provider's native wire.
      (when (and declared (null configured)
                 (null (enchiridion:config-value config :provider)))
        (let ((native (provider-api (%resolve-provider config wanted
                                                       :api-key api-key))))
          (unless (eq native (provider-api provider))
            (error 'enchiridion.errors:configuration-error
                   :key :backend
                   :detail (format nil ":BACKEND ~S asks for the ~A wire, but the provider this configuration selects (~A) speaks ~A. Name the row that serves that wire with :provider, or the endpoint that does with :base-url."
                                   backend
                                   (provider-api provider)
                                   (provider-id provider)
                                   native)))))
      (unless (and handler (api-handler-build handler))
        (unsupported-provider-error provider))
      ;; Reject empty endpoints (e.g., unexpanded Azure resource name or missing :base-url).
      (when (zerop (length (provider-base-url provider)))
        (error 'enchiridion.errors:configuration-error
               :key :base-url
               :detail (format nil "Provider ~A has no endpoint: set :base-url in its :providers row, or export the variable its default endpoint needs (~{~A~^, ~})."
                               (provider-id provider)
                               (provider-env provider))))
      (funcall (api-handler-build handler) provider))))

(declaim (ftype (function (t t) list) provider-env-for-id))

(defun provider-env-for-id (config id)
  "Return key variable names for provider ID from configured or cached rows without triggering network I/O."
  (let ((row (or (find-row (provider-plists config) id)
                 (find-row (catalog-plists) id))))
    (if row (row-env-names row) '())))

(declaim (ftype (function (&optional t) (or null string)) default-api-key-env))

(defun default-api-key-env (&optional config)
  "Return the primary key env var name for CONFIG (:api-key-env override, else active provider's first env var)."
  (let ((config (or config '())))
    (or (first (enchiridion:config-api-key-env-list config))
        (first (provider-env-for-id config (backend-provider-id config))))))

(declaim (ftype (function (&optional t) list) provider-key-names))

(defun provider-key-names (&optional config)
  "Return all deduplicated API key env var names across CONFIG, shipped/operator rows,
the active provider, and credential-shaped vars of supported cached catalog providers."
  (let* ((config (or config (enchiridion:config)))
         (names '()))
    (flet ((note (name)
             (when (and (nonempty-string-p name)
                        (not (member name names :test #'string=)))
               (setf names (append names (list name))))))
      (dolist (name (enchiridion:config-api-key-env-list config)) (note name))
      (dolist (row (shipped-provider-rows))
        (dolist (name (row-env-names row)) (note name)))
      (dolist (row (operator-provider-rows config))
        (dolist (name (row-env-names row)) (note name)))
      (dolist (name (provider-env-for-id config (backend-provider-id config)))
        (note name))
      (dolist (provider (catalog-providers))
        (when (catalog-row-supported-p provider)
          (dolist (name (provider-env provider))
            (when (enchiridion.llm.secrets:credential-variable-p name)
              (note name))))))
    names))

;;;; The model list.

(defparameter *model-cache-directory* nil
  "Override directory for per-provider model caches, or NIL for run/models/.")

(declaim (ftype (function (provider) pathname) model-cache-path))

(defun model-cache-path (provider)
  "Return the file PROVIDER's model list is cached in, under run/models/."
  (let ((directory (or *model-cache-directory*
                       (merge-pathnames "models/" (enchiridion:run-directory)))))
    (merge-pathnames (format nil "~A.json" (provider-cache-name (provider-id provider)))
                     (uiop:ensure-directory-pathname directory))))

(declaim (ftype (function (provider) t) models-ttl))

(defun models-ttl (provider)
  "Return model cache TTL in seconds for PROVIDER (row option > :models-ttl-seconds > 86400)."
  (let ((ttl (provider-option provider :models-ttl-seconds)))
    (if (numberp ttl) ttl (enchiridion:config-lookup :models-ttl-seconds 86400))))

(declaim (ftype (function (t t) (or null list)) read-model-cache))

(defun read-model-cache (path ttl)
  "Read cached MODEL-INFO list from PATH if within TTL seconds (TTL NIL accepts any age; missing fetched_at is stale)."
  (let ((data (ignore-errors (parse-json (uiop:read-file-string path)))))
    (when data
      (let ((stamp (catalog-field data "fetched_at")))
        (when (or (null ttl)
                  (and (integerp stamp)
                       (numberp ttl)
                       (plusp ttl)
                       (<= (- (get-universal-time) stamp) ttl)))
          (model-info-array (catalog-field data "models") :provider))))))

(declaim (ftype (function (model-info) hash-table) model-info->data))

(defun model-info->data (model)
  "Return MODEL as the JSON object the per-provider cache carries."
  (json-object "id" (model-info-id model)
               "name" (model-info-name model)
               "tool_call" (model-info-tool-call-p model)
               "reasoning" (model-info-reasoning-p model)
               "context" (model-info-context model)
               "output" (model-info-output model)
               "cost_input" (model-info-cost-input model)
               "cost_output" (model-info-cost-output model)
               "cost_cache_read" (model-info-cost-cache-read model)
               "cost_cache_write" (model-info-cost-cache-write model)))

(declaim (ftype (function (t list) t) write-model-cache))

(defun write-model-cache (path models)
  "Write MODELS to PATH with universal-time fetched_at (used for TTL) and ISO timestamp."
  (write-json-file path
                   (json-object "fetched_at" (get-universal-time)
                                "fetched_at_iso" (iso-timestamp)
                                "models" (mapcar #'model-info->data models))))

(declaim (ftype (function (t) (or null model-info)) ensure-model-info))

(defun ensure-model-info (model)
  "Coerce MODEL (MODEL-INFO, id string, or alist/plist with \"id\") to MODEL-INFO, or NIL."
  (cond
    ((model-info-p model) model)
    ((nonempty-string-p model)
     (%make-model-info :id model :name model :source :provider))
    ((consp model)
     (let ((id (catalog-field model "id")))
       (when (nonempty-string-p id)
         (%make-model-info :id id
                           :name (or (catalog-string model "name") id)
                           :source :provider))))
    (t nil)))

(declaim (ftype (function (t) list) normalize-model-list))

(defun normalize-model-list (models)
  "Return MODELS as a list of MODEL-INFO, dropping what is not a model."
  (if (consp models)
      (loop for model in models
            for info = (ensure-model-info model)
            when info collect info)
      '()))

(declaim (ftype (function (model-info model-info) model-info) merge-model-info))

(defun merge-model-info (live metadata)
  "Copy LIVE and overlay capabilities, limits, and costs from catalog METADATA, keeping LIVE's name if nonempty."
  (let ((merged (copy-model-info live)))
    (setf (model-info-tool-call-p merged) (model-info-tool-call-p metadata)
          (model-info-reasoning-p merged) (model-info-reasoning-p metadata)
          (model-info-context merged) (model-info-context metadata)
          (model-info-output merged) (model-info-output metadata)
          (model-info-cost-input merged) (model-info-cost-input metadata)
          (model-info-cost-output merged) (model-info-cost-output metadata)
          (model-info-cost-cache-read merged) (model-info-cost-cache-read metadata)
          (model-info-cost-cache-write merged) (model-info-cost-cache-write metadata))
    (when (zerop (length (model-info-name merged)))
      (setf (model-info-name merged) (model-info-name metadata)))
    merged))

(declaim (ftype (function (list provider) list) join-catalog-metadata))

(defun join-catalog-metadata (models provider)
  "Return MODELS with the catalog's price and limit metadata joined by id."
  (let ((metadata (catalog-models-for provider)))
    (if (null metadata)
        models
        (let ((index (make-hash-table :test #'equal)))
          (dolist (model metadata)
            (setf (gethash (model-info-id model) index) model))
          (mapcar (lambda (model)
                    (let ((found (gethash (model-info-id model) index)))
                      (if found (merge-model-info model found) model)))
                  models)))))

;; No FTYPE: &KEY arguments.
(defun provider-models (provider &key refresh force)
  "Return MODEL-INFO rows for PROVIDER, joining catalog pricing/limits by id.
Uses run/models/ cache within TTL unless REFRESH is true; respects :offline unless FORCE is true.
Never signals: on error or missing lister, logs to *ERROR-OUTPUT* and falls back to stale cache > row :models > catalog."
  (let* ((path (model-cache-path provider))
         (ttl (models-ttl provider))
         (fresh (unless refresh (read-model-cache path ttl))))
    (when (and (not force) (enchiridion:config-lookup :offline))
      (return-from provider-models
        (or (read-model-cache path nil)
            (provider-cached-models provider)
            (catalog-models-for provider)
            '())))
    (if fresh
        fresh
        (let* ((stale (read-model-cache path nil))
               (fallback (or stale
                             (provider-cached-models provider)
                             (catalog-models-for provider)
                             '()))
               (handler (find-api-handler (provider-api provider)))
               (lister (and handler (api-handler-list-models handler))))
          (cond
            ((null lister) fallback)
            (t
             (handler-case
                 (let* ((live (normalize-model-list (funcall lister provider)))
                        (result (join-catalog-metadata
                                 (or live
                                     (provider-cached-models provider)
                                     (catalog-models-for provider)
                                     '())
                                 provider)))
                   (ignore-errors (write-model-cache path result))
                   result)
               (error (condition)
                 (format *error-output*
                         "~&enchiridion: could not list models for ~A: ~A~%"
                         (provider-name provider) condition)
                 (finish-output *error-output*)
                 fallback))))))))

;;;; The listing.

(declaim (ftype (function (provider) list) provider-listing))

(defun provider-listing (provider)
  "Return PROVIDER as the plist the `providers' command prints."
  (list :id (provider-id provider)
        :name (provider-name provider)
        :api (provider-api provider)
        :profile (provider-profile provider)
        :base-url (provider-base-url provider)
        :api-key-env (first (provider-env provider))
        :env (provider-env provider)
        :key-present-p (provider-has-key-p provider)
        :supported-p (provider-supported-p provider)
        :source (provider-source provider)
        :default-model (provider-default-model provider)))

;; No F-TYPE: &KEY arguments.
(defun list-providers (&key config)
  "Return sorted provider listing plists for all configured rows plus non-overridden catalog providers."
  (let* ((config (or config '()))
         (rows (provider-rows config))
         (catalog (mapcar (lambda (provider) (catalog-provider-row provider config))
                          (catalog-providers)))
         (extra (remove-if (lambda (provider)
                             (find (provider-id provider) rows
                                   :key #'provider-id :test #'eq))
                           catalog)))
    (sort (mapcar #'provider-listing (append rows extra))
          #'string< :key (lambda (row) (string (getf row :id))))))

;;;; Fallback generic OpenAI and Anthropic adapters (used if handler files haven't registered).

(declaim (ftype (function (provider) t) openai-chat-build))

(defun openai-chat-build (provider)
  "Return the OpenAI chat completions backend PROVIDER describes."
  (openai-backend
   :base-url (provider-base-url provider)
   :api-key (provider-key provider)
   :model (or (provider-model provider) (provider-default-model provider))
   :headers (provider-headers provider)
   :dialect (make-dialect-for (provider-profile provider)
                              :protocol :openai
                              :overrides (append (provider-option provider :dialect-overrides)
                                                 (when (provider-query-params provider)
                                                   (list :query-params
                                                         (provider-query-params provider)))))
   :max-tokens (provider-option provider :max-tokens)
   :timeout (provider-option provider :timeout 60)
   :retries (provider-option provider :retries 2)))

(declaim (ftype (function (provider) t) anthropic-messages-build))

(defun anthropic-messages-build (provider)
  "Return the Anthropic Messages backend PROVIDER describes."
  (anthropic-backend
   :base-url (provider-base-url provider)
   :api-key (provider-key provider)
   :model (or (provider-model provider) (provider-default-model provider))
   :max-tokens (or (provider-option provider :max-tokens) 4096)
   :betas (provider-option provider :betas)
   :cache-ttl (provider-option provider :cache-ttl)
   :cache-p (provider-option provider :cache-p t)
   :headers (provider-headers provider)
   :dialect (make-dialect-for (provider-profile provider)
                              :protocol :anthropic
                              :overrides (provider-option provider :dialect-overrides))))

(declaim (ftype (function (provider) list) openai-chat-list-models))

(defun openai-chat-list-models (provider)
  "Fetch MODEL-INFO rows from PROVIDER's OpenAI-compatible models endpoint, or NIL if dialect has none."
  (let* ((dialect (make-dialect-for (provider-profile provider)
                                    :protocol :openai
                                    :overrides (provider-option provider :dialect-overrides)))
         (shape (dialect-field dialect :models-list-shape :data))
         (path (dialect-field dialect :models-path "models")))
    (when (and shape path)
      (let* ((request (auth-apply
                       dialect (provider-key provider)
                       (make-http-request
                        :url (concatenate
                              'string
                              (ensure-trailing-slash (provider-base-url provider))
                              path)
                        :timeout (provider-option provider :timeout
                                                  +http-get-timeout+))))
             (data (parse-json (get-with-retries
                                request (provider-option provider :retries 2))))
             (entries (catalog-field data "data")))
        (loop for entry in (if (consp entries) entries '())
              for id = (catalog-string entry "id")
              when (nonempty-string-p id)
                collect (%make-model-info
                         :id id
                         :name (or (catalog-string entry "name") id)
                         :source :provider))))))

(declaim (ftype (function (symbol t function function string) t) ensure-adapter))

(defun ensure-adapter (id schema build list-models documentation)
  "Register adapter ID if absent, or attach LIST-MODELS to an existing handler that lacks one."
  (let ((existing (find-api-handler id)))
    (cond
      ((and existing (api-handler-list-models existing)) existing)
      (t (register-api-handler
          id
          :schema (or (and existing (api-handler-schema existing)) schema)
          :build (or (and existing (api-handler-build existing)) build)
          :list-models list-models
          :documentation (if existing
                             (api-handler-documentation existing)
                             documentation))))))

(ensure-adapter :openai-chat :openai
                #'openai-chat-build #'openai-chat-list-models
                "The generic chat completions wire. openai.lsp registers the full one.")

(declaim (ftype (function (provider) list) anthropic-messages-list-models))

(defun anthropic-messages-list-models (provider)
  "Fallback lister for Anthropic /v1/models (no pagination; used only if anthropic.lsp did not register)."
  (let* ((dialect (make-dialect-for (provider-profile provider)
                                    :protocol :anthropic
                                    :overrides (provider-option provider :dialect-overrides)))
         (path (dialect-field dialect :models-path "v1/models")))
    (when path
      (let* ((url (concatenate 'string
                               (ensure-trailing-slash (provider-base-url provider))
                               path))
             (request (anthropic-authorize
                       dialect (provider-key provider) +anthropic-version+
                       (provider-headers provider)
                       (make-http-request
                        :url url
                        :timeout (provider-option provider :timeout
                                                  +http-get-timeout+))))
             (data (parse-json (get-with-retries
                                request (provider-option provider :retries 2)))))
        (loop for entry in (let ((entries (catalog-field data "data")))
                             (if (consp entries) entries '()))
              for id = (catalog-string entry "id")
              when (nonempty-string-p id)
                collect (%make-model-info
                         :id id
                         :name (or (catalog-string entry "display_name") id)
                         :source :provider))))))

(ensure-adapter :anthropic-messages :anthropic
                #'anthropic-messages-build #'anthropic-messages-list-models
                "The generic Messages wire. anthropic.lsp registers the full one.")
