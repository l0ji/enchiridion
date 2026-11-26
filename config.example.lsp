;;;; Copy to config.lsp. Keep API keys and tokens in .env.
;;;; All settings: docs/config-reference.md

(in-package #:enchiridion.user)

(defparameter *enchiridion-config*
  '(:llm
    ;; :openai, :opencode or :anthropic. NIL selects from available API keys
    (:provider nil)

    ;; NIL uses the default model. Cheap and sleep fall back to primary
    (:model-primary nil)             ; conversations and tools
    (:model-cheap nil)               ; memory summaries
    (:model-sleep nil)               ; background work
    (:max-tokens 4096)               ; reply token cap
    (:providers-ttl-seconds 86400)   ; catalog cache lifetime, seconds

    :channels
    ;; HTTP and Fluxer are off until enabled here or with --channel
    (:http
     (:enabled nil)
     (:bind "127.0.0.1")
     (:port 8787)
     (:token-env "ENCHIRIDION_HTTP_TOKEN"))

    (:fluxer
     (:enabled nil)
     (:allowed-users nil)            ; e.g. ("your-user-id")
     (:token-env "FLUXER_BOT_TOKEN")
     (:custom-status nil)            ; temporary public status
     (:custom-status-user nil))      ; only this user may set it

    :sleep
    ;; Background work during serve. NIL disables the schedule
    (:enabled t)
    (:interval-seconds 900)

    :budget
    (:max-tool-rounds 64)          ; per interactive or sleep turn
    ;; Background token caps, not spending limits for chat or ask
    (:max-tokens-per-tick 400000)
    (:max-tokens-per-day 40000000)))
