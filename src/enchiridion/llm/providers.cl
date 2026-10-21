;;;; providers.cl --- The provider table: rows, resolution, and model lists.
;;;;
;;;; A provider row is a small set of facts: an id, an endpoint, the names of
;;;; the variables that hold its key, and the model to start from. Nothing here
;;;; is a vendor branch. A row is data, the npm package models.dev reports for
;;;; it maps to an adapter id in the registry, and the adapter that registered
;;;; that id builds the backend. A new provider is a models.dev entry, a config
;;;; row, or one line in the table below --- never a new function in a handler
;;;; file.
;;;;
;;;; Three sources of rows are merged field by field, most specific first:
;;;; the operator's :providers rows, the rows this build ships in config.cl,
;;;; and the cached catalog. The order is why `(:id deepseek :api-key-env
;;;; "DEEPSEEK_KEY")' overrides the catalog's DeepSeek row instead of declaring
;;;; a provider with no endpoint, and why the shipped :openai row keeps working
;;;; with no catalog and no network.
;;;;
;;;; Recognition is deliberately conservative. An explicit :provider wins, then
;;;; a base URL whose host is one this build knows, then the three key
;;;; variables the shipped rows name, then a catalog provider whose variable is
;;;; the only one present, then OpenAI. A machine with two provider keys has to
;;;; say which one it means, because the alternative is a provider that changes
;;;; when an unrelated variable is exported.
;;;;
;;;; The model list is the one part that needs a live account. It is asked for
;;;; through the adapter's own lister, cached under run/models/, priced with the
;;;; catalog's cost metadata, and never allowed to signal: a provider whose
;;;; model endpoint is down must not stop a turn that a cached list could
;;;; serve.

(in-package #:enchiridion.llm)

;;;; The npm package to the adapter that speaks it.
;;;;
;;;; models.dev says which AI SDK package a provider is built with; this tree
;;;; has no SDK, so the package is what says which of this build's adapters
;;;; knows the wire. The table is also the list of packages this build can
;;;; serve at all: anything else is unsupported, and the caller is told to name
;;;; an endpoint and an adapter in its row.
;;;;
;;;; A package whose models.dev entry carries no endpoint also carries the
;;;; vendor's own default here, because a provider with no endpoint is a
;;;; provider that cannot be used at all. The URLs are the ones in the vendor's
;;;; documentation: OpenAI https://api.openai.com/v1, Groq
;;;; https://api.groq.com/openai/v1, Mistral https://api.mistral.ai/v1, xAI
;;;; https://api.x.ai/v1, Cerebras https://api.cerebras.ai/v1, Together
;;;; https://api.together.xyz/v1, DeepInfra https://api.deepinfra.com/v1/openai,
;;;; Venice https://api.venice.ai/api/v1, AIHubMix https://aihubmix.com/v1,
;;;; Salad https://ai.salad.cloud/v1, Vercel's gateway
;;;; https://ai-gateway.vercel.sh/v1, Cloudflare's gateway
;;;; https://gateway.ai.cloudflare.com/v1, Anthropic
;;;; https://api.anthropic.com.
;;;;
;;;; Cloudflare's gateway is the one that cannot be complete: its path carries
;;;; the account id and the gateway id, so the default is the prefix and an
;;;; operator appends the two segments with :base-url. That is still better
;;;; than no endpoint, because the profile's cf-aig-authorization header and
;;;; the rest of the row are then correct.
(defparameter +npm-adapters+
  '(("@ai-sdk/openai-compatible" :api :openai-chat)
    ("@ai-sdk/openai" :api :openai-chat
                     :base-url "https://api.openai.com/v1")
    ;; Azure has no `api' in models.dev: its endpoint contains the resource
    ;; name, which is the account's and not the catalog's. The placeholder is
    ;; expanded from the loaded secret table, and a row with no
    ;; AZURE_RESOURCE_NAME is reported as needing :base-url rather than being
    ;; sent to a relative URL.
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
  "The npm packages this build has an adapter for, and what each one implies.

:API names the adapter in the registry, :PROFILE the dialect quirks to apply,
and :BASE-URL the vendor's default endpoint for the packages whose models.dev
entry carries none. A package that is absent is unsupported: google,
google-vertex, cohere, watsonx, sap, gitlab, qvac and perplexity all have model
lists this tree cannot talk to.")

(declaim (ftype (function (t) list) npm-adapter))

(defun npm-adapter (npm)
  "Return NPM's adapter plist, or NIL when this build has no adapter for it."
  (and (stringp npm) (cdr (assoc npm +npm-adapters+ :test #'string=))))

;;;; Adapter ids, protocols and profiles.

(declaim (ftype (function (t) t) handler-protocol))

(defun handler-protocol (api)
  "Return the wire schema an adapter id speaks, or NIL.

:OPENAI and :ANTHROPIC are the two schemas the registry knows. Bedrock's
invoke path and Vertex's Anthropic path both carry a Messages body, so they
answer :ANTHROPIC; the difference between them and the Messages API is the
transport, and the transport is the handler's business."
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
  "Return the adapter id a named dialect profile implies, or NIL.

This is the fallback for a row that names a :profile and no :api: the two are
not redundant, because a profile is a set of quirks and an adapter is a wire,
and a config.cl row may legitimately name either one. Profiles the npm table
already maps are answered from it, so the two tables cannot drift."
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
  "Return the adapter a :BACKEND value names, or NIL.

:BACKEND is the legacy name for the wire and takes :OPENAI or :ANTHROPIC; an
adapter id registered by a handler file is also accepted, so a config row may
write :bedrock-invoke in either key."
  (case backend
    (:openai :openai-chat)
    (:anthropic :anthropic-messages)
    ((nil) nil)
    (t (and (find-api-handler backend) backend))))

;;;; The three legacy host names and any catalog host.

(declaim (ftype (function (t) boolean) provider-key-present-p))

(defun provider-key-present-p (name)
  "Return T when NAME is in the environment or the secret loader holds it.
The loader runs before this in the CLI, so a key in .env selects a provider the
same way an exported variable does."
  (and (nonempty-string-p name)
       (or (enchiridion.compat:environment-bound-p name)
           (enchiridion.llm.secrets:secret-present-p name))))

(declaim (ftype (function (t) boolean) provider-has-key-p))

(defun provider-has-key-p (provider)
  "Return T when any of PROVIDER's key variables is present."
  (not (null (some #'provider-key-present-p (provider-env provider)))))

(declaim (ftype (function (t) (or null keyword)) provider-from-base-url))

(defun provider-from-base-url (url)
  "Return the provider URL names, or NIL for a server that is none of them.
A local OpenAI-compatible server matches nothing, and its config still works:
the base URL is used as written and the key variable comes from detection."
  (when (stringp url)
    (cond
      ((search "opencode.ai" url) :opencode)
      ((search "api.anthropic.com" url) :anthropic)
      ((search "api.openai.com" url) :openai)
      (t nil))))

(declaim (ftype (function (t) (or null string)) url-host))

(defun url-host (url)
  "Return the host of URL in lower case, without scheme, port or userinfo.
A string that is not a URL answers NIL, so a config.cl base URL that is a
mistake never matches a provider by accident."
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
  "Return the row in ROWS whose :ID is ID, or NIL.
The comparison is by keyword, so a row written with :id :openai and one written
with :id \"openai\" are one row."
  (let ((wanted (provider-id-keyword id)))
    (and wanted
         (find wanted rows
               :key (lambda (row) (provider-id-keyword (getf row :id)))
               :test #'eq))))

(declaim (ftype (function (&rest t) list) merge-rows))

(defun merge-rows (&rest rows)
  "Return ROWS merged in order, a later row winning key by key.

A key present with a NIL value wins: an explicit NIL in config.cl means `not
this', not `unspecified', which is the same rule CHANNEL-CONFIG follows and
the reason a row can turn an inherited field off."
  (let ((merged '()))
    (dolist (row rows merged)
      (loop for (key value) on row by #'cddr
            do (setf (getf merged key) value)))))

(declaim (ftype (function () list) shipped-provider-rows))

(defun shipped-provider-rows ()
  "Return the rows this build ships, from config.cl's own defaults.
They are the last resort that keeps `resolve-backend' working with no catalog
cached and no network: OpenAI, OpenCode Go and Anthropic, complete enough to
build a request."
  (let ((rows (enchiridion:config-value (enchiridion:default-config) :providers)))
    (if (listp rows) rows '())))

(declaim (ftype (function (t) list) operator-provider-rows))

(defun operator-provider-rows (config)
  "Return the rows the operator wrote under :providers, or NIL.

Every row must name an :id, because a row without one cannot override a
catalog provider and cannot be selected by name; a typo that dropped the key
would otherwise become a provider called NIL."
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
  "Return the rows this build and the operator define, each a row plist.

The catalog row is the base, the shipped row is applied over it, and the
operator's row over that, so a row that names only :api-key-env inherits the
endpoint, the npm package and the default model of the provider it names. The
:source records which of the two configured sources won, which is what
`providers' prints."
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
  "Return the key variable names ROW names, as a list of strings.

:API-KEY-ENV is a string in the shipped rows and may be a list in an operator's
row, because a provider can accept more than one variable name; both spellings
are one list here, with no duplicates and with the order the operator wrote."
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
  "Return ROW's :MODELS as a list of MODEL-INFO.

A row that names its models is a row that cannot ask the endpoint, a local
server with no list route or a gateway whose list is wrong. The names are kept
on the provider record so that PROVIDER-MODELS has something to answer with
before it has anything to cache."
  (loop for model in (row-list row :models)
        when (nonempty-string-p model)
          collect (%make-model-info :id model :name model :source :config)))

(declaim (ftype (function (t) list) row-dialect-overrides))

(defun row-dialect-overrides (row)
  "Return ROW's direct dialect overrides as a plist.

Only the seven fields config.example.cl documents are honoured, and a key that
is present with a NIL value is kept: one of these fields genuinely means
absent, and a models-path of NIL is how a provider with no list endpoint says
so. The walk is over the raw plist rather than GETF for exactly that reason."
  (loop for (key value) on row by #'cddr
        when (member key '(:auth-scheme :auth-header :chat-path :models-path
                           :max-tokens-field :system-role :reasoning-field)
                     :test #'eq)
          append (list key value)))

;;;; One row as a PROVIDER.

;; The keys whose value travels to the handler as an option rather than in a
;; slot. The registry has no slot per vendor, and this is where a Bedrock region
;; and a Vertex project stop being general and become one adapter's business.
(defparameter +provider-option-keys+
  '(:max-tokens :models-ttl-seconds :region :project :location
    :cache-p :cache-ttl :betas :timeout :retries)
  "Row and configuration keys copied into a provider's options plist.")

(declaim (ftype (function (t) list) config-api-key-env-list))

(defun config-api-key-env-list (config)
  "Return the configured :API-KEY-ENV as a list, or NIL."
  (let ((value (enchiridion:config-value config :api-key-env)))
    (cond ((nonempty-string-p value) (list value))
          ((listp value) (remove-if-not #'nonempty-string-p value))
          (t '()))))

(declaim (ftype (function (t) (or null string)) expandable-endpoint))

(defun expandable-endpoint (url)
  "Return URL with any ${NAME} placeholder expanded, or NIL when it cannot be.

The catalog's `api' values go through the same expansion in catalog.cl; this
is for the endpoints this table supplies, because a vendor whose endpoint
contains an account name cannot have it written down and must say so instead
of sending the request to a hole."
  (when (nonempty-string-p url)
    (if (search "${" url)
        (ignore-errors (enchiridion.llm::expand-environment url))
        url)))

(declaim (ftype (function (t t) list) provider-options-from))

(defun provider-options-from (row config)
  "Return ROW's options plist, with CONFIG supplying what the row omits.

An option the row names with a NIL value is kept as NIL: :cache-p and friends
have a default in the handler, and a NIL that does not reach the options plist
cannot turn that default off."
  (let ((options (list :npm (getf row :npm)
                       :protocol (getf row :protocol)
                       :backend (getf row :backend)
                       :dialect-overrides (row-dialect-overrides row))))
    (dolist (key +provider-option-keys+ options)
      (let ((value (getf row key :absent)))
        (when (eq value :absent)
          (setf value (enchiridion:config-value config key)))
        (unless (eq value :absent)
          (setf (getf options key) value))))))

(declaim (ftype (function (t t) (or null string)) row-key))

(defun row-key (env api-key)
  "Return the credential for a row whose key variables are ENV.

The value comes from the secret loader first and the environment second,
because .env is not the process environment and the loader is what read it.
The explicit API-KEY wins when it is a string, which is how a caller that
already resolved one --- a CLI flag, the supervisor --- passes it down."
  (or (and (nonempty-string-p api-key) api-key)
      (loop for name in env
            thereis (let ((value (or (enchiridion.llm.secrets:secret-value name)
                                     (enchiridion.compat:environment-value name))))
                      (and (nonempty-string-p value) value)))))

;; No F-TYPE: the six keyword arguments would each need a declaration SBCL has
;; already seen, for the reason RESOLVE-BACKEND gives below.
(defun %provider-from-row (row source &key config api-key base-url api model)
  "Return ROW, a canonical row plist, as a resolved PROVIDER.

SOURCE is :SHIPPED, :CONFIG or :CATALOG. The adapter id comes from the row, the
row's npm package, or the row's profile, in that order, and the base URL from
the row, then the npm package's vendor default. A row this build cannot serve
still produces a record with a NIL adapter: LIST-PROVIDERS has to show it, and
RESOLVE-BACKEND is where the refusal belongs.

API-KEY, BASE-URL, API and MODEL are the caller's overrides; they are what
RESOLVE-PROVIDER fills from the configuration, so that LIST-PROVIDERS shows the
row as written rather than as this process happened to configure it."
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
         (env (let ((names (config-api-key-env-list config)))
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
     :base-url (or (and (nonempty-string-p base-url) base-url)
                   (and (nonempty-string-p (getf row :base-url)) (getf row :base-url))
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
  "Return T when a cached catalog row names an adapter this build has.

The row is not adapted into a PROVIDER for this: the question is about the npm
package, and a full record would also read the environment for a credential
the caller does not want."
  (not (null (find-api-handler
              (getf (npm-adapter (provider-option provider :npm)) :api)))))

;;;; Detection.

(declaim (ftype (function (t) t) catalog-provider-by-host))

(defun catalog-provider-by-host (url)
  "Return the id of the first cached provider whose endpoint host is URL's.

The scan is by sorted id, so two providers that share a host --- a gateway and
the vendor behind it --- always resolve to the same one rather than to whichever
the hash table happened to hand over first.

The row is read directly rather than adapted into a PROVIDER: this runs on the
detection path for every provider in the catalog, and building a record --- and
looking up a credential for it --- is work a host comparison does not need."
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
  "Return the id of the one cached provider whose key variable is present.
Two providers with keys is not a choice, and neither is none; both answer NIL,
which leaves the caller's own default in charge."
  (let ((found '()))
    (dolist (provider (catalog-providers))
      (when (provider-has-key-p provider)
        (push (provider-id provider) found)))
    (when (= 1 (length found)) (first found))))

(declaim (ftype (function (&optional t) keyword) detect-provider))

(defun detect-provider (&optional config)
  "Return the provider CONFIG asks for, or the one the keys select.

The order is explicit config, a recognized base URL host, an OpenAI key, an
OpenCode key, an Anthropic key, the one cached provider whose key variable is
present, then OpenAI. OpenAI wins a tie because it is the default: a machine
holding two provider keys has to have its choice written down, and the
alternative is a provider that changes when an unrelated variable is exported."
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
  "Return the row a (:provider :custom) configuration describes.

Everything comes from the top-level :llm keys, because a custom provider has no
catalog entry and no shipped row to inherit from. :BASE-URL is required: a
provider with no endpoint is not a provider, and the error names the key rather
than failing later with a request to the empty string."
  (let ((base-url (enchiridion:config-value config :base-url)))
    (unless (nonempty-string-p base-url)
      (error 'enchiridion.errors:configuration-error
             :key :base-url
             :detail "(:provider :custom) needs :base-url in the :llm section."))
    (list :id :custom
          :name "Custom"
          ;; NIL :BACKEND means the OpenAI-shaped wire, which is what a custom
          ;; provider that names no route got before this table existed. Naming
          ;; a wire is what :BACKEND is for; leaving the row's adapter NIL
          ;; would make every unlabelled custom endpoint unsupported.
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
  "Return ROW with the top-level :HEADERS, :QUERY-PARAMS and :PROFILE merged in.

A row value wins. The top-level keys are documented as working for whichever
provider is selected, and a provider picked from the catalog has no row of its
own to hold them, so this is where a catalog provider learns about the
operator's extra header or their choice of quirk profile. It is applied to the
selected row only: applying it to every row would make `providers list' claim
that all two hundred providers share one header."
  (let ((result (copy-list row)))
    (dolist (key '(:headers :query-params :profile))
      (when (eq (getf result key :absent) :absent)
        (let ((value (enchiridion:config-value config key :absent)))
          (unless (eq value :absent)
            (setf (getf result key) value)))))
    result))

(defun %resolve-provider (config id &key api-key base-url api (refresh nil))
  "Return the PROVIDER for ID with everything a handler needs resolved.

The row is looked for among the operator's and this build's rows first, then
the cached catalog. Only when both miss is one refresh attempted, and only when
the configuration does not say :OFFLINE: a startup path must not open a socket
because of a typo, and an explicit refresh is what the error tells the operator
to run."
  (let* ((config (or config '()))
         (wanted (or (provider-id-keyword id) id)))
    (if (eq wanted :custom)
        (%provider-from-row (custom-provider-row config) :config
                            :config config :api-key api-key :base-url base-url :api api)
        (let ((row (or (find-row (provider-plists config) wanted)
                       (find-row (catalog-plists) wanted))))
          ;; REFRESH is asked for and is not the default. A command that only
          ;; looks must not fetch models.dev or write a cache file, and the
          ;; callers that do want it -- the start-up path and `providers
          ;; refresh' -- ask in the place that knows the operator permitted it.
          (when (and (null row)
                     refresh
                     (not (enchiridion:config-value config :offline)))
            (ignore-errors (refresh-catalog))
            (setf row (find-row (catalog-plists) wanted)))
          (unless row
            (error 'enchiridion.errors:configuration-error
                   :key :provider
                   :detail (format nil "There is no provider called ~A. Run `enchiridion providers refresh` to fetch the catalog, or add a row for it under :providers in config.cl." wanted)))
          (%provider-from-row (row-with-top-level-defaults row config)
                              (getf row :source)
                              :config config
                              :api-key api-key
                              :base-url (or base-url (enchiridion:config-value config :base-url))
                              :api api
                              :model (or (enchiridion:config-value config :model-primary)
                                         (getf row :model)
                                         (getf row :default-model)))))))

;; No F-TYPE: this function and PROVIDER-MODELS take &KEY arguments, and SBCL
;; wants every keyword in an F-TYPE lambda list to have been declared in one
;; already, which means a dummy declaration per keyword for a function that is
;; three lines long. The cost of the annotation is larger than what it would
;; catch, which is the same choice RESOLVE-BACKEND made.
(defun resolve-provider (config &key api-key)
  "Return the PROVIDER the configuration selects, with everything resolved.

CONFIG is a plist as config.cl holds it. An explicit :PROVIDER wins, then a
recognized :BASE-URL host, then the keys the environment and .env supplied,
then OpenAI; see DETECT-PROVIDER. The key is read from the secret loader first
and the environment second, and API-KEY wins over both."
  (%resolve-provider config (detect-provider config) :api-key api-key))

(declaim (ftype (function (t) t) backend-provider-id))

(defun backend-provider-id (config)
  "Return the id of the provider row RESOLVE-BACKEND would build from CONFIG.

:PROVIDER wins, because an operator who named a row meant that row. Without
one, :BACKEND :ANTHROPIC means the Anthropic row even when an OpenAI key is the
one that is present: a wire and a row have to agree before the endpoint means
anything. Every other case is DETECT-PROVIDER's answer."
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
         :detail (format nil "~A (~A) has no adapter in this build~@[ (npm ~A)~]. Set :base-url and :api on its row under :providers in config.cl."
                         (provider-name provider)
                         (provider-id provider)
                         (provider-option provider :npm))))

(defun resolve-backend (&key (config nil) (api-key nil) (base-url nil))
  "Return the BACKEND that CONFIG asks for.

CONFIG is a plist as config.cl holds it. An explicit :BASE-URL, :MODEL-PRIMARY,
or :API-KEY-ENV wins. When one is absent, DETECT-PROVIDER chooses the provider
from the config, a recognized base URL, or the keys the environment and .env
supplied.

:BACKEND chooses the wire protocol, and the provider row is chosen to match it:
:ANTHROPIC gets the Anthropic row even when an OpenAI or OpenCode key is the
one that is present, and :PROVIDER :ANTHROPIC without a :BACKEND selects the
Anthropic protocol as well, because a row and a request shape have to agree
before the endpoint means anything.

CASE and not ECASE. ECASE is the better construct here in principle, because it
refuses to run if a backend is added without a clause here, but SBCL
gives ECASE no default clause: a clause headed by T is a clause about the
symbol T, so an unknown backend comes back as CASE-FAILURE listing (:OPENAI T)
rather than as the configuration error the operator needs.

The T clause exists so that a typo in a config key is named rather than
reported as a missing function."
  (let* ((config (or config '()))
         (backend (enchiridion:config-value config :backend))
         (declared (backend-handler-id backend)))
    (when (and backend (null declared))
      (error 'enchiridion.errors:configuration-error
             :key :backend
             :detail (format nil "No backend for ~S. :BACKEND is :OPENAI or :ANTHROPIC, or one of the adapter ids this build registered: ~{~A~^, ~}."
                             backend (registered-api-handlers))))
    (let* ((provider (%resolve-provider config (backend-provider-id config)
                                        :api-key api-key
                                        :base-url (or base-url
                                                      (enchiridion:config-value config :base-url))
                                        :api declared))
           (handler (find-api-handler (provider-api provider))))
      (unless (and handler (api-handler-build handler))
        (unsupported-provider-error provider))
      ;; A provider with no endpoint is not a provider: the request would be
      ;; sent to a relative URL and fail with a dexador error that names
      ;; neither the row nor the missing key. The two ways to get here are a
      ;; vendor whose endpoint contains an account name the environment does
      ;; not hold (Azure's AZURE_RESOURCE_NAME) and a row that simply does not
      ;; name one.
      (when (zerop (length (provider-base-url provider)))
        (error 'enchiridion.errors:configuration-error
               :key :base-url
               :detail (format nil "Provider ~A has no endpoint: set :base-url in its :providers row, or export the variable its default endpoint needs (~{~A~^, ~})."
                               (provider-id provider)
                               (provider-env provider))))
      (funcall (api-handler-build handler) provider))))

(declaim (ftype (function (t t) list) provider-env-for-id))

(defun provider-env-for-id (config id)
  "Return the key variable names the row ID carries, or NIL.
Only the rows are read: resolving a provider could refresh the catalog, and the
callers of this one are asking a question that must not open a socket."
  (let ((row (or (find-row (provider-plists config) id)
                 (find-row (catalog-plists) id))))
    (if row (row-env-names row) '())))

(declaim (ftype (function (&optional t) (or null string)) default-api-key-env))

(defun default-api-key-env (&optional config)
  "Return the name of the variable that holds the key for the active provider.
An explicit :API-KEY-ENV in config wins; otherwise the provider the backend
resolution would select decides, so the name the operator is told to export is
the name the request will look for."
  (let ((config (or config '())))
    (or (enchiridion:config-value config :api-key-env)
        (first (provider-env-for-id config (backend-provider-id config))))))

(declaim (ftype (function (&optional t) list) provider-key-names))

(defun provider-key-names (&optional config)
  "Return every variable name that can hold a provider's API key.

The list is the :API-KEY-ENV the operator configured, the shipped rows' names
in table order, the operator's own rows' names, the selected provider's full
list, and every credential-shaped name a cached supported provider names. It is
the whole list and not only the selected provider's name because a key in
another provider's variable is still a secret in this process: the loader has
to read it before `enchiridion secrets` can list it, and the scrubber has to
know the name before it can recognise the value.

A cached provider whose npm package this build has no adapter for is skipped: a
name that cannot hold a key this build would ever send is noise in a scrubber's
list. AWS and Google names are filtered by the same predicate the environment
sweep uses, so the two lists cannot disagree about what a credential is called.

CONFIG is a configuration plist; NIL means the active configuration, which is
the answer ENCHIRIDION:CONFIG gives, and an empty list means no configuration
at all."
  (let* ((config (or config (enchiridion:config)))
         (names '()))
    (flet ((note (name)
             (when (and (nonempty-string-p name)
                        (not (member name names :test #'string=)))
               (setf names (append names (list name))))))
      (note (enchiridion:config-value config :api-key-env))
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
  "Where a provider's own model list is cached, or NIL for models/ under the
run directory. A special so a test writes to a scratch directory instead of
the real run/, exactly like *CATALOG-PATH*.")

(declaim (ftype (function (provider) pathname) model-cache-path))

(defun model-cache-path (provider)
  "Return the file PROVIDER's model list is cached in, under run/models/."
  (let ((directory (or *model-cache-directory*
                       (merge-pathnames "models/" (enchiridion:run-directory)))))
    (merge-pathnames (format nil "~A.json" (provider-cache-name (provider-id provider)))
                     (uiop:ensure-directory-pathname directory))))

(declaim (ftype (function (provider) t) models-ttl))

(defun models-ttl (provider)
  "Return how long PROVIDER's cached model list may be trusted, in seconds.
The row's own value wins over the configuration, and the shipped default is a
day: a model list is a snapshot rather than an inventory."
  (let ((ttl (provider-option provider :models-ttl-seconds)))
    (if (numberp ttl) ttl (enchiridion:config-lookup :models-ttl-seconds 86400))))

(declaim (ftype (function (t t) (or null list)) read-model-cache))

(defun read-model-cache (path ttl)
  "Return the model list cached at PATH, or NIL.

TTL NIL means `any age', which is how a failed refresh falls back to the last
list that worked. A cache with no FETCHED_AT stamp is not fresh for any TTL, so
a file somebody edited by hand cannot be mistaken for a fresh one."
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
  "Write MODELS to PATH with the stamp the TTL is measured against.
The human-readable timestamp rides beside the integer for the operator who
opens the file; the integer is what the comparison reads."
  (write-json-file path
                   (json-object "fetched_at" (get-universal-time)
                                "fetched_at_iso" (iso-timestamp)
                                "models" (mapcar #'model-info->data models))))

(declaim (ftype (function (t) (or null model-info)) ensure-model-info))

(defun ensure-model-info (model)
  "Return MODEL as a MODEL-INFO, or NIL when it names no model.

An adapter's lister is written by a handler file, and the registry's contract
says MODEL-INFO, but a plain id and an object are both reasonable answers from
one. A shape this table cannot read is dropped rather than allowed to reach a
typed slot as something else."
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
  "Return LIVE with METADATA's price, limits and capabilities.

The live list knows which models exist right now; the catalog knows what they
cost and how large they are. Neither answer is complete, and a model that is in
the catalog under a different id keeps the live name."
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

;; No F-TYPE, for the reason RESOLVE-PROVIDER has none: &KEY arguments.
(defun provider-models (provider &key refresh force)
  "Return the MODEL-INFO rows PROVIDER can serve.

The provider's own endpoint is asked when its adapter has a lister, and the
answer is cached under run/models/ with a FETCHED_AT stamp; within
:MODELS-TTL-SECONDS the cache answers without a request, and REFRESH skips the
cache. Cost and limit metadata from the catalog is joined by model id, because
a model endpoint states which models exist and not what they cost.

A failure is never a signal. A provider whose model endpoint is down, or whose
adapter cannot list models at all, answers with the last cached list, then the
row's own :models, then the catalog's list, then nothing, and writes one line
to *ERROR-OUTPUT*. A turn that could be served from the cache must not stop
because the list behind it could not be refreshed."
  (let* ((path (model-cache-path provider))
         (ttl (models-ttl provider))
         (fresh (unless refresh (read-model-cache path ttl))))
    ;; :OFFLINE stops the model list too. An explicit `providers models ID' is
    ;; the operator asking for one request, so it passes FORCE; everything
    ;; else, including the start-up path, reads the cache and the catalog and
    ;; opens nothing.
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
  "Return one plist per known provider, for the `providers' command.

Every configured row is listed, then every catalog row whose id a configured
row does not already cover, so an override replaces the provider it overrides
instead of appearing twice. The order is the printed id, because a listing that
drifts between runs cannot be compared."
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

;;;; The adapters this file can build on its own.
;;;;
;;;; A handler file registers its own adapter as it loads, and when it has,
;;;; nothing here runs. These two exist so that the generic OpenAI and Messages
;;;; wires are always available: they are the two schemas the registry itself
;;;; names, every other wire is a vendor file, and a build in which openai.cl
;;;; has not (yet) registered would otherwise refuse to build a plain OpenAI
;;;; provider. The lister is filled in only when the registered handler has
;;;; none, so a handler's own model list is never replaced.

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
   :max-tokens (provider-option provider :max-tokens)))

(declaim (ftype (function (provider) t) anthropic-messages-build))

(defun anthropic-messages-build (provider)
  "Return the Anthropic Messages backend PROVIDER describes."
  (anthropic-backend
   :base-url (provider-base-url provider)
   :api-key (provider-key provider)
   :model (or (provider-model provider) (provider-default-model provider))
   :max-tokens (or (provider-option provider :max-tokens) 4096)
   :cache-ttl (provider-option provider :cache-ttl)
   :cache-p (provider-option provider :cache-p t)
   :headers (provider-headers provider)
   :dialect (make-dialect-for (provider-profile provider)
                              :protocol :anthropic
                              :overrides (provider-option provider :dialect-overrides))))

(declaim (ftype (function (provider) list) openai-chat-list-models))

(defun openai-chat-list-models (provider)
  "Return the MODEL-INFO rows PROVIDER's own /models endpoint reports.

The shape is the one every OpenAI-compatible server answers, {\"data\":
[{\"id\": ...}]}, and the path is the dialect's; a profile that says it has no
list is asked for nothing rather than for a request that can only fail."
  (let* ((dialect (make-dialect-for (provider-profile provider)
                                    :protocol :openai
                                    :overrides (provider-option provider :dialect-overrides)))
         (shape (dialect-field dialect :models-list-shape :data))
         (path (dialect-field dialect :models-path "models")))
    (when (and shape path)
      (let* ((url (concatenate 'string
                               (ensure-trailing-slash (provider-base-url provider))
                               path))
             (data (parse-json (funcall *http-get-function* url
                                        :timeout +http-get-timeout+)))
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
  "Register the generic adapter ID unless a handler file already did.

A handler that registered both halves is left exactly as it is. A handler with
a build and no lister keeps its build and gains this file's lister, because the
model list is provider-table work and a handler that never wrote one should not
be the reason `providers models' has nothing to ask."
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
                "The generic chat completions wire. openai.cl registers the full one.")

(declaim (ftype (function (provider) list) anthropic-messages-list-models))

(defun anthropic-messages-list-models (provider)
  "Return the MODEL-INFO rows PROVIDER's own /v1/models endpoint reports.

A separate function from the chat-completions lister because the wire is
separate: the path is v1/models and not models, and the rows carry a display
name. The pagination the real handler implements is not repeated here, because
this is the fallback that only runs if anthropic.cl failed to register at all."
  (let* ((dialect (make-dialect-for (provider-profile provider)
                                    :protocol :anthropic
                                    :overrides (provider-option provider :dialect-overrides)))
         (path (dialect-field dialect :models-path "v1/models")))
    (when path
      (let* ((url (concatenate 'string
                               (ensure-trailing-slash (provider-base-url provider))
                               path))
             (headers (anthropic-headers (provider-key provider)
                                         +anthropic-version+
                                         (provider-headers provider)))
             (data (parse-json (funcall *http-get-function* url
                                        :headers headers
                                        :timeout +http-get-timeout+))))
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
                "The generic Messages wire. anthropic.cl registers the full one.")
