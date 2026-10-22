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
    ;;; No provider is pinned here. A key in OPENAI_API_KEY selects OpenAI, a
    ;;; key in OPENCODE_API_KEY selects OpenCode Go, a key in
    ;;; ANTHROPIC_API_KEY selects the Messages API, and OpenAI is the fallback.
    ;;; Uncomment :provider to pin the choice and beat the key detection.
    ;;;(:provider :openai)

    ;;; Which backend protocol to speak. Omit it and the selected provider row
    ;;; names its wire. :openai covers OpenAI, OpenCode Go, and any local
    ;;; OpenAI-compatible server. :anthropic covers the Messages API. An
    ;;; adapter id this build registers also works, and any other value is a
    ;;; configuration error.
    ;;;(:backend :openai)

    ;;; Base URL. Omit it, or leave NIL, for the provider default.
    ;;;(:base-url "https://api.openai.com/v1/")

    ;;; Model tiers. Primary handles reasoning turns. Cheap handles memory
    ;;; digests and compaction. Sleep handles the sleep-time agent, which can
    ;;; afford a stronger model because nothing is waiting on it. NIL means
    ;;; the selected provider row's model. Name a model here to override it.
    (:model-primary nil)
    (:model-cheap   nil)
    (:model-sleep   nil)

    ;;; Name of the variable in .env that holds the key. The file holds the
    ;;; name, never the value. Omit it and the selected provider names the
    ;;; variable: OPENAI_API_KEY, OPENCODE_API_KEY, or ANTHROPIC_API_KEY.
    ;;;(:api-key-env "OPENAI_API_KEY")

    ;;; The Messages API requires a max_tokens field on every request and has
    ;;; no default of its own. The OpenAI-shaped wire ignores this key.
    (:max-tokens 4096)

    ;;; The runtime catalog. Provider knowledge is generated from models.dev at
    ;;; run time and cached under run/; nothing about a provider is committed
    ;;; to the tree apart from the three rows this build ships for :openai,
    ;;; :opencode and :anthropic, which are configuration defaults. The
    ;;; commands that run a turn (ask, chat, serve) refresh the cache at
    ;;; context build, once per process, when the cached index is missing or
    ;;; older than the TTL, and a provider's model list when a key is present
    ;;; and its cache is stale; an inspection command never fetches. The TTLs,
    ;;; :offline, :headers, :query-params and :profile apply to whichever
    ;;; provider is selected. `enchiridion providers refresh` and
    ;;; `enchiridion providers models ID` do it by hand. :offline t stops the
    ;;; start-up fetching, the model list included; those two explicit commands
    ;;; still run.
    (:providers-url "https://models.dev/api.json")
    (:providers-ttl-seconds 86400)   ; the provider index
    (:models-ttl-seconds 86400)      ; one provider's model list
    (:offline nil)

    ;;; Cloud placement. Bedrock reads :region; Vertex reads :project and
    ;;; :location. The environment variables of the same meaning (AWS_REGION,
    ;;; GOOGLE_VERTEX_PROJECT, GOOGLE_VERTEX_LOCATION) win when these are nil.
    (:region nil)
    (:project nil)
    (:location nil)

    ;;; Providers you define or override. A row is the same shape as the rows
    ;;; this build ships for :openai, :opencode and :anthropic, so any field
    ;;; can be overridden one at a time. A row whose :id matches a models.dev
    ;;; provider overrides that provider; a new :id adds one.
    ;;;
    ;;; :api names the wire. :openai-chat covers OpenAI, OpenCode Go, Azure,
    ;;; OpenRouter, Groq and the long tail; :anthropic-messages covers the
    ;;; Messages API; :bedrock-invoke and :bedrock-messages cover Amazon
    ;;; Bedrock; :vertex-anthropic covers Claude on Google Vertex. :profile
    ;;; names the quirks to apply, and an individual quirk may be overridden
    ;;; directly (:auth-scheme, :auth-header, :chat-path, :models-path,
    ;;; :max-tokens-field, :system-role, :reasoning-field). A header may be
    ;;; written ("Name" "value") or ("Name" . "value"); both reach the wire
    ;;; identically.
    ;;;
    ;;; (:providers
    ;;;  ((:id my-llm :name "My LLM" :api :openai-chat :profile :openai
    ;;;    :base-url "https://llm.internal/v1/"
    ;;;    :api-key-env "MY_LLM_KEY"
    ;;;    :headers (("X-Tenant" "acme"))
    ;;;    :models ("m-1" "m-2"))
    ;;;   ;; Override only what differs from the catalog row.
    ;;;   (:id deepseek :api-key-env "DEEPSEEK_KEY")
    ;;;   ;; Azure, which needs the api-key header and a deployment path.
    ;;;   (:id azure :api :openai-chat :profile :azure
    ;;;    :base-url "https://myresource.openai.azure.com/")
    ;;;   ;; Claude on Amazon Bedrock. AWS_BEARER_TOKEN_BEDROCK selects bearer
    ;;;   ;; auth; AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY select SigV4.
    ;;;   (:id amazon-bedrock :api :bedrock-invoke :profile :bedrock-invoke
    ;;;    :region "us-east-1")
    ;;;   ;; Claude on Google Vertex, with a service-account JSON in
    ;;;   ;; GOOGLE_APPLICATION_CREDENTIALS or a token in
    ;;;   ;; GOOGLE_VERTEX_ACCESS_TOKEN.
    ;;;   (:id google-vertex-anthropic :api :vertex-anthropic
    ;;;    :profile :vertex :project "my-project" :location "us-east5")))

    ;;; The generic custom provider: no preset at all, everything from the
    ;;; :llm keys above, and one of the two API routes reused. Set
    ;;; (:provider :custom) and name the route with :backend.
    ;;;
    ;;; (:provider :custom)
    ;;; (:backend :anthropic)                 ; or :openai
    ;;; (:base-url "https://proxy.internal/")
    ;;; (:api-key-env "PROXY_KEY")
    ;;; (:headers (("X-Route" "team-a")))
    ;;; (:model-primary "claude-sonnet-5-5")

   ;;; Channels are a subcategory. Every entry has the same shape, with
   ;;; :enabled, and only the keys that channel understands. The CLI entry is
   ;;; reported in the status file; `serve` builds the terminal channel
   ;;; regardless of this key.
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
    ;;; The agent-side uid for the container image. The supervisor runs as uid 0
    ;;; and holds the secrets; the broker and the reload verifier drop to this
    ;;; uid. A checkout has no uid split.
    (:agent-uid 1000)

    ;;; Mount /proc with hidepid=2 so the sandbox cannot read the
    ;;; supervisor's environment or memory. This is an entrypoint setting
    ;;; (ENCHIRIDION_HIDEPID), not a Lisp configuration key: no code reads
    ;;; :proc-hidepid, so it is not written here.

   :memory
    ;;; The store path. NIL puts memory.db beside the agent files, which is on
    ;;; the state volume in the container. Set an absolute path to override it.
    (:db nil)

    ;;; Character limits per memory block. Raising these raises the fixed
    ;;; token cost of every prompt. The limits live in *default-block-limits*
    ;;; in the memory module; no code reads :block-limits, so the effective
    ;;; values are recorded here as a comment.
    ;;;
    ;;; :persona 1200, :operator 800, :world 1500, :session 400, :ledger 250,
    ;;; and :bootstrap 300.

   :sleep
    ;;; How often the sleep-time agent wakes to maintain the three identity
    ;;; files, consolidate memory, and work the task queue.
    (:enabled t)
    (:interval-seconds 900)))
