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
    ;;; OpenCode Go, and OpenAI is the fallback. :provider makes the choice
    ;;; explicit and wins over both the environment and the base URL.
    (:provider :opencode)

    ;;; Which backend protocol to speak. :openai covers OpenCode Go, OpenAI,
    ;;; and any local OpenAI-compatible server. :anthropic covers the Messages
    ;;; API with cache_control. :litellm starts a supervised LiteLLM process.
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
    ;;; name, never the value.
    (:api-key-env "OPENCODE_API_KEY")

   ;;; Channels are a subcategory. Every entry has the same shape, with
   ;;; :enabled, and only the keys that channel understands. The CLI channel
   ;;; is the control plane and starts whenever a terminal is attached.
   :channels
    (:cli (:enabled t))

    (:http
     (:enabled nil)
     ;;; Loopback only by default. A non-loopback bind requires :token, and
     ;;; the harness refuses to start without one.
     (:bind "127.0.0.1")
     (:port 8787)
     (:token nil))

    (:fluxer
     (:enabled nil)
     ;;; Direct messages only for now. No guilds, no mentions, no reactions.
     ;;; Deny by default: an empty allowlist means nobody may talk to the agent.
     (:allowed-users '("REPLACE-WITH-YOUR-FLUXER-USER-ID"))
     (:token-env "FLUXER_BOT_TOKEN"))

   :budget
    ;;; Caps for unattended work. The heartbeat stops acting rather than
    ;;; exceeding these.
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
