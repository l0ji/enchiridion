;;;; config.example.cl --- Template for enchiridion configuration.
;;;;
;;;; Copy this file to config.cl and edit it. config.cl is gitignored, so your
;;;; edits, local paths, and allowed user ids stay out of history. The tracked
;;;; copy of this template is how a new user discovers the format.
;;;;
;;;; The file holds paths and behavior only. It never holds a secret value.
;;;; Secrets come from the environment or from .env beside the source.
;;;; If config.cl is absent, enchiridion starts on defaults and you need not
;;;; write one at all.

(in-package #:enchiridion.user)

(defparameter *enchiridion-config*
  '(:llm
    ;;; This template uses OpenCode Go. Without config.cl, a key in
    ;;; OPENAI_API_KEY selects OpenAI, a key in OPENCODE_API_KEY selects
    ;;; OpenCode Go, a key in ANTHROPIC_API_KEY selects the Messages API, and
    ;;; OpenAI is the fallback. :provider makes the choice explicit and wins
    ;;; over both the environment and the base URL.
    (:provider :opencode)

    ;;; Which backend protocol to speak. :openai covers OpenCode Go, OpenAI,
    ;;; and any local OpenAI-compatible server. :anthropic covers the Messages
    ;;; API, with tool_use blocks and cache_control breakpoints, and selects
    ;;; the :anthropic provider row with it. :litellm starts a supervised
    ;;; LiteLLM process.
    (:backend :openai)

    ;;; Base URL. Omit for the provider default.
    (:base-url "https://opencode.ai/zen/go/v1")

    ;;; Model tiers. Primary handles reasoning turns. Cheap handles memory
    ;;; digests and compaction. Sleep handles the sleep-time agent, which can
    ;;; afford a stronger model because nothing is waiting on it. Every tier
    ;;; defaults to the cheap model, and :model-primary is the one to raise
    ;;; when a turn is worth the stronger one.
    (:model-primary "deepseek-v4.1-flash")
    (:model-cheap   "deepseek-v4.1-flash")
    (:model-sleep   "deepseek-v4.1-flash")

    ;;; Name of the variable in .env that holds the key. The file holds the
    ;;; name, never the value. Omit it and the selected provider names the
    ;;; variable: OPENAI_API_KEY, OPENCODE_API_KEY, or ANTHROPIC_API_KEY.
    (:api-key-env "OPENCODE_API_KEY")

    ;;; The Messages API requires a max_tokens field on every request and has
    ;;; no default of its own. The OpenAI-shaped wire ignores this key.
    (:max-tokens 4096)

   ;;; Channels are a subcategory. Every entry has the same shape, with
   ;;; :enabled, and only the keys that channel understands. The CLI channel
   ;;; is the control plane and starts whenever a terminal is attached.
   :channels
    (:cli (:enabled t))

    (:http
     (:enabled nil)
     ;;; Loopback only by default. A non-loopback bind requires a token, and
     ;;; the harness refuses to start without one. Name the variable here and
     ;;; keep the value in .env or the environment: a token written into this
     ;;; file is a token in a file a person copies between hosts. A literal
     ;;; :token below is accepted and registered with the scrubber, and it is
     ;;; meant for a loopback bind and for tests.
     (:bind "127.0.0.1")
     (:port 8787)
     (:token-env "ENCHIRIDION_HTTP_TOKEN")
     (:token nil)
     ;;; How many bytes of request body the webhook will read. The declared
     ;;; length is checked first and the bytes are counted as they arrive, so
     ;;; a chunked body with no length is bounded too.
     (:max-body-bytes 65536))

    (:fluxer
     (:enabled nil)
     ;;; Direct messages only for now. No guilds, no mentions, no reactions.
     ;;; Deny by default: an empty allowlist means nobody may talk to the agent.
     (:allowed-users '("REPLACE-WITH-YOUR-FLUXER-USER-ID"))
     (:token-env "FLUXER_BOT_TOKEN"))

   :budget
    ;;; Caps for unattended work. The heartbeat starts no new phase once the
    ;;; spend reaches them, so a phase already under way finishes.
    (:max-tokens-per-tick 4000)
    (:max-tokens-per-day 400000)

   :sandbox
    ;;; The agent-side uid. The supervisor runs as uid 0 and holds the secrets.
    ;;; Nothing below this uid can read them.
    (:agent-uid 1000)

    ;;; Mount /proc with hidepid=2 so the sandbox cannot read the
    ;;; supervisor's environment or memory.
    (:proc-hidepid 2)

   :memory
    (:db #p"/var/lib/enchiridion/memory.db")

    ;;; Character limits per memory block. Raising these raises the fixed
    ;;; token cost of every prompt. The three named blocks are backed by
    ;;; SOUL.md, OPERATOR.md, and WORLD.md in the agent directory.
    (:block-limits
      (list :persona  1200
            :operator  800
            :world     1500
            :session   400
            :ledger    250))

   :sleep
    ;;; How often the sleep-time agent wakes to rewrite the seed files,
    ;;; consolidate memory, and work the task queue.
    (:enabled t)
    (:interval-seconds 900)))
