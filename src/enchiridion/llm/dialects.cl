;;;; dialects.cl --- The quirks of one provider, as data.
;;;;
;;;; Every "OpenAI-compatible" vendor is compatible with a different subset.
;;;; Azure wants the key in an api-key header and the deployment in the path;
;;;; Google's compatibility shim lives under /v1beta/openai and rejects
;;;; tool_choice; DeepSeek reports its chain of thought in reasoning_content
;;;; and its cache hits in prompt_cache_hit_tokens; a local server wants no
;;;; auth at all. None of those is a reason for a handler of its own, and all
;;;; of them are a reason not to scatter IFs through openai.cl.
;;;;
;;;; A DIALECT is a record of those differences. A PROFILE is a named set of
;;;; values for it. A provider picks a profile (models.dev's npm plus the
;;;; provider id and host decide which), and config.cl may override any single
;;;; field, which is what makes a one-off endpoint a configuration line rather
;;;; than a patch.
;;;;
;;;; The fields are all optional and all defaulted to the generic behaviour, so
;;;; a provider with no profile at all behaves exactly like the plain OpenAI or
;;;; Anthropic wire. That is what every existing test relies on.

(in-package #:enchiridion.llm)

(defstruct (dialect (:constructor %make-dialect))
  ;; Which schema this dialect decorates. :OPENAI and :ANTHROPIC are the two
  ;; the handlers implement; the field is here so a profile cannot be applied
  ;; to the wrong wire by accident.
  (protocol nil)
  (profile nil)

  ;; --- auth -------------------------------------------------------------
  ;; :BEARER            Authorization: Bearer KEY
  ;; :API-KEY-HEADER    NAME: KEY            (Azure: api-key)
  ;; :X-API-KEY         x-api-key: KEY       (Anthropic)
  ;; :QUERY-PARAM       ?NAME=KEY            (Google's older samples)
  ;; :NONE              no credential header at all (Ollama, LM Studio)
  ;; :AWS-SIGV4         signed by aws-sigv4.cl
  ;; :GCP-OAUTH         bearer from gcp-oauth.cl
  (auth-scheme :bearer)
  (auth-header nil)                  ; header name for :API-KEY-HEADER
  ;; A literal that goes in front of the credential inside a vendor-named
  ;; header: Cloudflare's gateway wants `Bearer <token>` under a header of its
  ;; own, and the token alone is not a valid value there.
  (auth-prefix "")
  (auth-query nil)                   ; parameter name for :QUERY-PARAM

  ;; --- url --------------------------------------------------------------
  ;; CHAT-PATH is appended to the provider's base URL. {model} is substituted,
  ;; which is how Azure's deployment path is expressed without a branch.
  (chat-path nil)                    ; NIL means the handler's own default
  (models-path nil)                  ; NIL means the handler's own default
  (query-params '() :type list)      ; extra query parameters, e.g. api-version
  (extra-headers '() :type list)     ; extra headers, e.g. attribution

  ;; --- body -------------------------------------------------------------
  ;; :MAX_TOKENS or :MAX_COMPLETION_TOKENS. The named field is written; the
  ;; other is not, because a provider that wants one often rejects the other.
  (max-tokens-field :max-tokens)
  ;; "system" or "developer". OpenAI's reasoning models took the developer
  ;; role where the system role used to be.
  (system-role "system")
  (send-tool-choice-p t)
  (send-parallel-tool-calls-p t)
  (send-stream-options-p t)
  ;; Extra request fields merged into the body, so a vendor's thinking switch
  ;; is a data line and not a function. NIL means none.
  (extra-body '() :type list)

  ;; --- response ---------------------------------------------------------
  ;; Where the chain of thought arrives, when it arrives beside the answer:
  ;; "reasoning_content", "reasoning", or NIL.
  (reasoning-field nil)
  ;; Where the token counts arrive. The generic OpenAI names are the default;
  ;; DeepSeek reports cache hits under names of its own.
  (input-tokens-field "prompt_tokens")
  (output-tokens-field "completion_tokens")
  (cache-read-tokens-field "prompt_tokens_details.cached_tokens")
  (cache-write-tokens-field "cache_creation_input_tokens")
  ;; :STRING, :OBJECT or :EITHER. Some servers hand the tool arguments back as
  ;; an object where the specification says a JSON string.
  (tool-arguments-form :either)

  ;; --- anthropic-only ---------------------------------------------------
  ;; :HEADER writes anthropic-version, :BODY writes anthropic_version.
  (version-location :header)
  (version-value nil)
  (model-in-body-p t)
  ;; :HEADER or :BODY for the beta feature list.
  (beta-channel :header)
  (cache-ttl-supported-p t)
  (thinking-supported-p t)

  ;; --- model listing ----------------------------------------------------
  ;; :DATA ({"data":[{"id"}]}), :OLLAMA ({"models":[{"name"}]}),
  ;; :OPENROUTER (data with pricing), or NIL for no listing at all.
  (models-list-shape :data))

(declaim (ftype (function (t) symbol) dialect-slot))

(defun dialect-slot (key)
  "Return KEY as the slot symbol of DIALECT, or signal a configuration error.

The keys are written as keywords in the profile table because that is how a
config.cl row spells them, and SLOT-VALUE wants the symbol the defstruct
interned in this package. A keyword is not EQL to that symbol however equal
their names look, so the translation is done once, here, rather than trusted
to work."
  (let ((symbol (find-symbol (string-upcase (string key)) '#:enchiridion.llm)))
    (unless symbol
      (error 'enchiridion.errors:configuration-error
             :key :profile
             :detail (format nil "~S is not a provider dialect field." key)))
    symbol))

(declaim (ftype (function (t t &optional t) t) dialect-field))

(defun dialect-field (dialect key &optional default)
  "Return KEY from DIALECT, or DEFAULT when DIALECT is NIL.

A NIL dialect is the generic wire, so every caller can read a field without a
guard and the generic path is the absence of an override rather than a second
set of defaults."
  (if dialect
      (let ((value (slot-value dialect (dialect-slot key))))
        (if (null value) default value))
      default))

;;;; The profiles.

;; Each entry is PROFILE . PLIST. Only the fields that differ from the generic
;; wire are listed; everything else is the struct default, and a field listed
;; as NIL is a deliberate "the generic value is wrong here and absence is the
;; answer" (a path with no default, a reasoning field that does not exist).
;;
;; The base URLs are not here on purpose. models.dev carries an `api' for every
;; provider that has one, and a provider that lacks it names its endpoint in
;; config.cl. The two exceptions, the vendor packages whose base URL models.dev
;; does not carry, are in +npm-adapters+ in providers.cl where the package is
;; what supplies it.
(defparameter +dialect-profiles+
  '((:openai . ())
    ;; A local server (Ollama, LM Studio, llama.cpp) has no credential to
    ;; check but still requires a value in its client, ignores tool_choice, and
    ;; lists its models at a path of its own on Ollama.
    (:openai-local . (:auth-scheme :none
                      :send-tool-choice-p nil))
    (:ollama . (:auth-scheme :none
               :send-tool-choice-p nil
               :models-path "api/tags"
               :models-list-shape :ollama))
    ;; Azure: key in api-key, deployment in the path, api-version in the
    ;; query, max_completion_tokens instead of the deprecated max_tokens, and
    ;; the developer role where the system role used to be. The classic path is
    ;; the default; the newer /openai/v1 shape is a config override.
    (:azure . (:auth-scheme :api-key-header
               :auth-header "api-key"
               :chat-path "openai/deployments/{model}/chat/completions"
               :query-params (("api-version" "2024-06-01"))
               :max-tokens-field :max-completion-tokens
               :system-role "developer"))
    (:openrouter . (:extra-headers (("X-Title" "enchiridion"))
                    :reasoning-field "reasoning"
                    :cache-read-tokens-field "prompt_tokens_details.cached_tokens"
                    :cache-write-tokens-field "prompt_tokens_details.cache_write_tokens"))
    (:deepseek . (:reasoning-field "reasoning_content"
                 :cache-read-tokens-field "prompt_cache_hit_tokens"))
    ;; Google's OpenAI-compatibility shim lives under /v1beta/openai and does
    ;; not accept tool_choice or parallel_tool_calls.
    (:google-openai . (:send-tool-choice-p nil
                       :send-parallel-tool-calls-p nil))
    ;; Qwen's compatible mode silently drops several OpenAI fields, refuses
    ;; tool_choice "required", defaults parallel_tool_calls to false, and
    ;; switches thinking on with enable_thinking. Sending only what it honours
    ;; is cheaper than watching it ignore the rest.
    (:qwen . (:send-parallel-tool-calls-p nil
             :extra-body (:enable_thinking t)))
    (:zai . (:reasoning-field "reasoning_content"
             :extra-body (:thinking (:type "enabled"))))
    ;; Groq answers 400 to a body with an unsupported field, so the few it does
    ;; not implement are simply not sent.
    (:groq . (:send-stream-options-p nil
              :send-parallel-tool-calls-p nil))
    (:cloudflare-gateway . (:auth-scheme :api-key-header
                            :auth-header "cf-aig-authorization"
                            :auth-prefix "Bearer "))
    ;; Anthropic's own endpoint, unchanged.
    (:anthropic . ())
    ;; An Anthropic-shaped gateway that authenticates with a bearer token
    ;; instead of x-api-key, as OpenRouter's Messages endpoint does.
    (:anthropic-gateway . (:auth-scheme :bearer))
    ;; Bedrock's InvokeModel path carries the version in the body, has no
    ;; anthropic-version header, and no 1h cache TTL. The model is a path
    ;; segment, so the body must not name it.
    (:bedrock-invoke . (:auth-scheme :aws-sigv4
                        :version-location :body
                        :version-value "bedrock-2023-05-31"
                        :model-in-body-p nil
                        :beta-channel :body
                        :cache-ttl-supported-p nil))
    (:bedrock-messages . (:auth-scheme :aws-sigv4
                          :chat-path "anthropic/v1/messages"))
    (:vertex . (:auth-scheme :gcp-oauth
                :version-location :body
                :version-value "vertex-2023-10-16"
                :model-in-body-p nil
                :models-path nil)))
  "Quirk profile to the fields it overrides. Everything absent is generic.")

(declaim (ftype (function (t) t) dialect-profile-plist))

(defun dialect-profile-plist (profile)
  "Return the plist for PROFILE, or NIL when there is no such profile.

An unknown profile is not an error here: the caller names the profile in a
configuration error, because it knows which provider asked for it."
  (and profile (cdr (assoc profile +dialect-profiles+ :test #'eq))))

(declaim (ftype (function (t) boolean) dialect-profile-p))

(defun dialect-profile-p (profile)
  "Return T when PROFILE names a shipped profile."
  (not (null (assoc profile +dialect-profiles+ :test #'eq))))

(defun make-dialect-for (profile &key protocol overrides)
  "Return the DIALECT for PROFILE with OVERRIDES applied.

OVERRIDES is a plist of dialect slot names to values, as a config.cl provider
row gives them. An override whose value is NIL is applied as NIL and not
ignored: the operator wrote it, and one of these fields genuinely means
absent (a models-path of NIL is how a provider with no list endpoint says
so)."
  (when (and profile (not (dialect-profile-p profile)))
    (error 'enchiridion.errors:configuration-error
           :key :profile
           :detail (format nil "There is no provider profile called ~S. Known profiles: ~{~A~^, ~}."
                           profile
                           (sort (mapcar #'car +dialect-profiles+) #'string<
                                 :key #'symbol-name))))
  (let ((dialect (%make-dialect :protocol protocol :profile profile)))
    (loop for (key value) on (append (dialect-profile-plist profile) overrides) by #'cddr
          do (setf (slot-value dialect (dialect-slot key)) value))
    dialect))
