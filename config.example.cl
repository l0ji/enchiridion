;;;; config.example.cl --- Template for enchiridion configuration.
;;;;
;;;; Copy this file to config.cl and edit it. config.cl is gitignored, so your
;;;; edits, local paths, and allowed user ids stay out of history.
;;;;
;;;; The file holds paths and behavior only. It never holds a secret value.
;;;; Secrets come from the environment or from .env beside the source.
;;;; Most commands need this file; `help` and `version` do not.

(in-package #:enchiridion.user)

(defparameter *enchiridion-config*
  '(:llm
    ;;; No provider is pinned here. A key in OPENAI_API_KEY selects OpenAI, a
    ;;; key in OPENCODE_API_KEY selects OpenCode Go, a key in
    ;;; ANTHROPIC_API_KEY selects the Messages API, and OpenAI is the fallback.
    ;;; Uncomment :provider to pin the choice.
    ;;;(:provider :openai)

    ;;; The wire protocol: :openai covers OpenAI, OpenCode Go, and any local
    ;;; OpenAI-compatible server; :anthropic covers the Messages API.
    ;;;(:backend :openai)

    ;;; Base URL. Omit it, or leave NIL, for the provider default.
    ;;;(:base-url "https://api.openai.com/v1/")

    ;;; The variable in .env that holds the key. The file holds the name, never
    ;;; the value. Omit it and the selected provider names the variable.
    ;;;(:api-key-env "OPENAI_API_KEY")

    ;;; Primary handles reasoning turns, cheap handles memory digests and
    ;;; compaction, sleep handles the sleep-time agent. NIL means the selected
    ;;; provider row's model.
    (:model-primary nil)
    (:model-cheap   nil)
    (:model-sleep   nil)

    ;;; The Messages API requires max_tokens on every request. The
    ;;; OpenAI-shaped wire ignores this key.
    (:max-tokens 4096)

    ;;; The runtime catalog. Provider knowledge is generated from models.dev at
    ;;; run time and cached under run/. The three rows this build ships are
    ;;; configuration defaults. Turns refresh the cache when it is stale;
    ;;; inspection commands do not. `providers refresh` and `providers models
    ;;; ID` fetch by hand, even when :offline is t.
    (:providers-url "https://models.dev/api.json")
    (:providers-ttl-seconds 86400)   ; the provider index
    (:models-ttl-seconds 86400)      ; one provider's model list
    (:offline nil)

    ;;; Cloud placement. Bedrock reads :region; Vertex reads :project and
    ;;; :location. AWS_REGION, GOOGLE_VERTEX_PROJECT, and GOOGLE_VERTEX_LOCATION
    ;;; fill a key these leave NIL.
    (:region nil)
    (:project nil)
    (:location nil)

    ;;; Providers you define or override. A row has the same shape as the rows
    ;;; this build ships, so any field can be overridden one at a time. A row
    ;;; whose :id matches a models.dev provider overrides it; a new :id adds one.
    ;;; :api names the wire, :profile names the quirks, and an individual quirk
    ;;; may be overridden with :auth-scheme, :auth-header, :chat-path,
    ;;; :models-path, :max-tokens-field, :system-role, or :reasoning-field.
    ;;; A header may be written ("Name" "value") or ("Name" . "value").
    ;;;
    ;;; (:providers
    ;;;  ((:id my-llm :name "My LLM" :api :openai-chat :profile :openai
    ;;;    :base-url "https://llm.internal/v1/"
    ;;;    :api-key-env "MY_LLM_KEY"
    ;;;    :headers (("X-Tenant" "acme"))
    ;;;    :models ("m-1" "m-2"))
    ;;;   (:id deepseek :api-key-env "DEEPSEEK_KEY")
    ;;;   (:id azure :api :openai-chat :profile :azure
    ;;;    :base-url "https://myresource.openai.azure.com/")
    ;;;   (:id amazon-bedrock :api :bedrock-invoke :profile :bedrock-invoke
    ;;;    :region "us-east-1")
    ;;;   (:id google-vertex-anthropic :api :vertex-anthropic
    ;;;    :profile :vertex :project "my-project" :location "us-east5")))

    ;;; The generic custom provider: no preset, everything from the :llm keys
    ;;; above, and one of the two API routes reused.
    ;;;
    ;;; (:provider :custom)
    ;;; (:backend :anthropic)                 ; or :openai
    ;;; (:base-url "https://proxy.internal/")
    ;;; (:api-key-env "PROXY_KEY")
    ;;; (:headers (("X-Route" "team-a")))
    ;;; (:model-primary "claude-sonnet-5-5")

    ;;; Channels. Every entry has the same shape, with :enabled and only the
    ;;; keys that channel understands. The CLI entry is reported in the status
    ;;; file; `serve` builds the terminal channel regardless of this key.
    :channels
    (:cli (:enabled t))

    (:http
     (:enabled nil)
     ;;; Loopback only by default. A non-loopback bind requires a token. Name
     ;;; the variable here and keep the value in .env or the environment. A
     ;;; literal :token is accepted, registered with the scrubber, and meant
     ;;; for a loopback bind and for tests.
     (:bind "127.0.0.1")
     (:port 8787)
     (:token-env "ENCHIRIDION_HTTP_TOKEN")
     (:token nil)
     ;;; How many bytes of request body the webhook reads. The declared length
     ;;; is checked first and the bytes are counted as they arrive, so a chunked
     ;;; body with no length is bounded too.
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
    ;;; The agent-side uid and gid for the container image and for a checkout
    ;;; started as root. The supervisor holds the secrets; the broker, the
    ;;; reload verifier, and git-exec drop to these. A checkout started as the
    ;;; operator has no uid split.
    (:agent-uid 1000)
    (:agent-gid 1000)

    ;;; /proc is mounted with hidepid=2 so the sandbox cannot read the
    ;;; supervisor's environment or memory. The container entrypoint does that
    ;;; remount before Lisp starts, so it is set by ENCHIRIDION_HIDEPID on the
    ;;; run line, not here.

    :memory
    ;;; The common keys are here; docs/configuration.md lists every key and
    ;;; default.
    ;;; The store path. NIL puts memory.db beside the agent files, which is on
    ;;; the state volume in the container. Set an absolute path to override it.
    (:db nil)

    ;;; How much recent conversation a prompt carries after the frozen system
    ;;; prompt: at most this many user and assistant turns of the current
    ;;; session, and this many characters in total.
    (:recent-turns 6)
    (:recent-window-chars 4000)

    ;;; Character limits per memory block. Raising these raises the fixed token
    ;;; cost of every prompt. A label left out keeps its shipped limit.
    ;;;(:block-limits (:persona 6000 :operator 1600 :world 3000
    ;;;                :session 400 :ledger 250 :bootstrap 300))

    ;;; The episodic log and cue retrieval are on. Push is off until a paired
    ;;; no-harm run says otherwise. T2 runs on its schedule, but a pass with no
    ;;; assertion parser, canary set, utility task set, or tail sampler is a
    ;;; reported no-op: it does not spend tokens on a candidate nobody can
    ;;; promote.
    (:enabled t)
    (:retrieve t)
    (:push nil)
    (:rerank nil)
    (:embed nil)
    (:embed-model "text-embedding-3-small")
    (:embed-dimensions 512)
    (:embed-base-url "https://api.openai.com/v1/")
    (:embed-key-env "OPENAI_API_KEY")
    (:record-sleep t)
    (:pack-chars 4450)
    (:push-max-fraction 0.5)
    (:maintenance-batch 200)
    (:graph-limit 20000)
    (:t2-enabled t)
    (:t2-interval-seconds 86400)
    (:t2-episode-threshold 200)
    (:t2-max-episodes-per-tick 5)
    (:t2-max-tokens-per-pass 200000)
    (:t2-deriver-max-tokens 16384)
    (:t2-deriver-concurrency 4)
    (:t2-deriver-model nil)
    (:t2-max-tokens-per-episode 3000)
    (:t2-writes-per-episode 8)
    ;;; Operator-authored behavioural canaries, the memory's only external
    ;;; ground truth. Each entry is a plist of :name, :family, :cue and
    ;;; :expect. The family says what the check asserts for :cue:
    ;;; "retrieval" and "tail", that a record holding :expect comes back;
    ;;; "safety", that none does; "update", that :expect ranks above the
    ;;; entry's :stale value. T2 does not run until four families are covered.
    ;;;
    ;;;(:canaries ((:name "deploy-key" :family "retrieval"
    ;;;             :cue "where is the deploy key" :expect "vault")
    ;;;            (:name "api-port" :family "update"
    ;;;             :cue "which port does the api use" :expect "9090" :stale "8080")
    ;;;            (:name "no-password" :family "safety"
    ;;;             :cue "what is the admin password" :expect "hunter2")
    ;;;            (:name "rare-incident" :family "tail"
    ;;;             :cue "the march outage" :expect "dns")))
    (:canaries nil)
    (:canary-min-families 4)
    (:gate-margin 0.05)
    (:gate-min-n 100)
    (:gate-alpha 0.05)
    (:gate-pack-chars 1100)
    (:tail-rarity-fraction 0.10)
    (:tail-min-n 50)
    (:tail-margin 0.02)
    (:precision-min 0.8)
    (:quarantine-max 0.5)
    (:compaction-rebase-every 8)
    (:compaction-rebase-turns 24)
    ;;; A plist merged over the shipped memory parameter defaults. Every weight
    ;;; and decay value is an invented default; changing one is a new config
    ;;; hash and a new measurement run.
    (:parameters nil)

    :sleep
    ;;; How often the sleep-time agent wakes to maintain the identity files,
    ;;; consolidate memory, and work the task queue.
    (:enabled t)
    (:interval-seconds 900)))
