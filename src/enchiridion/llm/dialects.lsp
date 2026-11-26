;;;; dialects.lsp --- Provider wire quirks represented as data.
;;;;
;;;; A DIALECT overrides generic OpenAI/Anthropic wire defaults. A PROFILE is a
;;;; named preset; a NIL dialect uses generic wire behavior.

(in-package #:enchiridion.llm)

(defstruct (dialect (:constructor %make-dialect))
  (protocol nil)                     ; :OPENAI or :ANTHROPIC
  (profile nil)

  ;; --- auth -------------------------------------------------------------
  ;; :BEARER            Authorization: Bearer KEY
  ;; :API-KEY-HEADER    NAME: KEY            (Azure: api-key)
  ;; :X-API-KEY         x-api-key: KEY       (Anthropic)
  ;; :QUERY-PARAM       ?NAME=KEY            (Google's older samples)
  ;; :NONE              no credential header (Ollama, LM Studio)
  ;; :AWS-SIGV4         signed by aws-sigv4.lsp
  ;; :GCP-OAUTH         bearer from gcp-oauth.lsp
  (auth-scheme :bearer)
  (auth-header nil)                  ; header name for :API-KEY-HEADER
  (auth-prefix "")                   ; prefix inside vendor header (e.g. "Bearer ")
  (auth-query nil)                   ; parameter name for :QUERY-PARAM

  ;; --- url --------------------------------------------------------------
  ;; CHAT-PATH is appended to base URL with {model} substituted.
  (chat-path nil)                    ; NIL uses handler default
  (models-path nil)                  ; NIL uses handler default (explicit NIL disables)
  (query-params '() :type list)      ; extra query parameters, e.g. api-version
  (extra-headers '() :type list)     ; extra headers, e.g. attribution

  ;; --- body -------------------------------------------------------------
  (max-tokens-field :max-tokens)     ; :MAX-TOKENS or :MAX-COMPLETION-TOKENS
  (system-role "system")             ; "system" or "developer"
  (send-tool-choice-p t)
  (send-parallel-tool-calls-p t)
  (send-stream-options-p t)
  (extra-body '() :type list)        ; extra request fields merged into body

  ;; --- response ---------------------------------------------------------
  (reasoning-field nil)              ; "reasoning_content", "reasoning", or NIL
  (input-tokens-field "prompt_tokens")
  (output-tokens-field "completion_tokens")
  (cache-read-tokens-field "prompt_tokens_details.cached_tokens")
  (cache-write-tokens-field "cache_creation_input_tokens")
  (tool-arguments-form :either)      ; :STRING, :OBJECT, or :EITHER

  ;; --- anthropic-only ---------------------------------------------------
  (version-location :header)         ; :HEADER (anthropic-version) or :BODY (anthropic_version)
  (version-value nil)
  (model-in-body-p t)
  (beta-channel :header)             ; :HEADER or :BODY for beta feature list
  (cache-ttl-supported-p t)
  (thinking-supported-p t)

  ;; --- model listing ----------------------------------------------------
  ;; :DATA ({"data":[{"id"}]}), :OLLAMA ({"models":[{"name"}]}),
  ;; :OPENROUTER (data with pricing), or NIL for no listing.
  (models-list-shape :data)

  ;; Distinguish omitted keys from explicit NIL
  (explicit '() :type list))

(declaim (ftype (function (t) symbol) dialect-slot))

(defun dialect-slot (key)
  "Return the ENCHIRIDION.LLM slot symbol for keyword KEY, or signal a configuration error."
  (let ((symbol (find-symbol (string-upcase (string key)) '#:enchiridion.llm)))
    (unless symbol
      (error 'enchiridion.errors:configuration-error
             :key :profile
             :detail (format nil "~S is not a provider dialect field." key)))
    symbol))

(declaim (ftype (function (t t &optional t) t) dialect-field))

(defun dialect-field (dialect key &optional default)
  "Return KEY from DIALECT, or DEFAULT when DIALECT is NIL or KEY is unset.
An explicitly set NIL slot returns NIL rather than DEFAULT."
  (if dialect
      (let ((value (slot-value dialect (dialect-slot key))))
        (if (or value (member key (dialect-explicit dialect) :test #'eq))
            value
            default))
      default))

;;;; The profiles.

;; Profile name -> override plist. Only fields differing from struct defaults
;; are listed; explicit NIL overrides a default (e.g. disabling models-path).
(defparameter +dialect-profiles+
  '((:openai . ())
    ;; Local servers (Ollama, LM Studio, llama.cpp): no auth, no tool_choice.
    (:openai-local . (:auth-scheme :none
                      :send-tool-choice-p nil))
    (:ollama . (:auth-scheme :none
               :send-tool-choice-p nil
               :models-path "api/tags"
               :models-list-shape :ollama))
    ;; Azure's 2024-06-01 deployment API uses max_tokens and the system role
    (:azure . (:auth-scheme :api-key-header
               :auth-header "api-key"
               :chat-path "openai/deployments/{model}/chat/completions"
               :query-params (("api-version" "2024-06-01"))
               :max-tokens-field :max-tokens
               :system-role "system"
               :models-path "openai/models"))
    (:openrouter . (:extra-headers (("X-Title" "enchiridion"))
                    :reasoning-field "reasoning"
                    :cache-read-tokens-field "prompt_tokens_details.cached_tokens"
                    :cache-write-tokens-field "prompt_tokens_details.cache_write_tokens"))
    (:deepseek . (:reasoning-field "reasoning_content"
                 :cache-read-tokens-field "prompt_cache_hit_tokens"))
    ;; Google documents tool_choice but not parallel_tool_calls on this shim
    (:google-openai . (:send-parallel-tool-calls-p nil))
    ;; Thinking and parallel tool support vary by model
    (:qwen . (:send-parallel-tool-calls-p nil
             :reasoning-field "reasoning_content"))
    (:zai . (:reasoning-field "reasoning_content"))
    ;; Optional streaming and parallel-tool fields stay off for model portability
    (:groq . (:send-stream-options-p nil
              :send-parallel-tool-calls-p nil))
    (:cloudflare-gateway . (:auth-scheme :api-key-header
                            :auth-header "cf-aig-authorization"
                            :auth-prefix "Bearer "))
    (:anthropic . (:auth-scheme :x-api-key))
    (:anthropic-gateway . (:auth-scheme :bearer))
    ;; Bedrock InvokeModel puts version/betas in body, model in path, and lacks 1h cache TTL.
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
  "Return the override plist for PROFILE, or NIL if unknown."
  (and profile (cdr (assoc profile +dialect-profiles+ :test #'eq))))

(declaim (ftype (function (t) boolean) dialect-profile-p))

(defun dialect-profile-p (profile)
  "Return T when PROFILE names a shipped profile."
  (not (null (assoc profile +dialect-profiles+ :test #'eq))))

(defun make-dialect-for (profile &key protocol overrides)
  "Return a DIALECT for PROFILE with plist OVERRIDES applied.
Explicit NIL values are recorded in DIALECT-EXPLICIT so they override defaults."
  (when (and profile (not (dialect-profile-p profile)))
    (error 'enchiridion.errors:configuration-error
           :key :profile
           :detail (format nil "There is no provider profile called ~S. Known profiles: ~{~A~^, ~}."
                           profile
                           (sort (mapcar #'car +dialect-profiles+) #'string<
                                 :key #'symbol-name))))
  (let ((dialect (%make-dialect :protocol protocol :profile profile)))
    (loop for (key value) on (append (dialect-profile-plist profile) overrides) by #'cddr
          do (setf (slot-value dialect (dialect-slot key)) value)
             (pushnew key (dialect-explicit dialect) :test #'eq))
    dialect))
