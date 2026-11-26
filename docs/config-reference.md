# Settings reference

Complete reference for `config.lsp` and environment variables. For setup
walkthroughs and examples, see [Configuration](configuration.md).

## File format

`config.lsp` defines `enchiridion.user:*enchiridion-config*` as a quoted list of
section keywords followed by `(key value)` entries:

```lisp
(in-package #:enchiridion.user)

(defparameter *enchiridion-config*
  '(:llm
    (:provider :opencode)
    :memory
    (:db nil)
    (:block-limits (:persona 8000))))
```

Use `t` / `nil` for booleans, quotes for strings, and unquoted numbers. Unknown
keys are silently ignored; verify key spelling carefully.

## `:llm`

| Key | Default | Meaning |
| --- | --- | --- |
| `:provider` | auto-detect | Provider ID, or `:custom` for an unlisted endpoint |
| `:backend` | `:openai` | Protocol override (`:openai`, `:anthropic`, or an adapter ID) |
| `:base-url` | `nil` | Endpoint override |
| `:api-key-env` | `nil` | Env var holding the API key |
| `:model-primary` | `nil` | Conversation/tool model (unset uses provider default) |
| `:model-cheap` | `nil` | Memory summary/maintenance model (falls back to primary) |
| `:model-sleep` | `nil` | Background work model (falls back to primary) |
| `:max-tokens` | `4096` (in example) | Max reply tokens (omitting removes OpenAI cap; Messages defaults to `4096`) |
| `:providers` | shipped rows | List of provider rows to add or override by `:id` |
| `:providers-url` | `"https://models.dev/api.json"` | Catalog source URL |
| `:providers-ttl-seconds` | `86400` (in example) | Catalog cache TTL in seconds (omitting makes cache always stale) |
| `:models-ttl-seconds` | `86400` | Per-provider model list cache TTL in seconds |
| `:offline` | `nil` | Skip automatic catalog and model-list fetches |
| `:region` | `nil` | AWS Bedrock region (fallback: `AWS_REGION`, `AWS_DEFAULT_REGION`) |
| `:project` | `nil` | Google Vertex project (fallback: `GOOGLE_VERTEX_PROJECT`) |
| `:location` | `nil` | Google Vertex location (fallback: `GOOGLE_VERTEX_LOCATION`) |
| `:timeout` | `60` | HTTP request timeout in seconds |
| `:retries` | `2` | Retries on 429 and 5xx |
| `:cache-p`, `:cache-ttl`, `:betas` | `nil` | Handler-supported prompt caching and beta flags |
| `:headers`, `:query-params`, `:profile` | `nil` | Extra request pairs `(("K" "V"))` and dialect profile |

### Provider row keys (inside `:providers`)

Each row must have an `:id`. Operator rows override catalog and built-in rows
field by field.

| Keys | Meaning |
| --- | --- |
| `:id`, `:name` | Provider ID and display name |
| `:api`, `:profile` | Adapter (`:bedrock-invoke`, `:bedrock-messages`, `:vertex-anthropic`, etc.) and request profile |
| `:base-url`, `:api-key-env` | Endpoint URL and key env var name (or list of names) |
| `:model`, `:default-model`, `:models` | Selected model, fallback model, and static model list |
| `:headers`, `:query-params` | Extra request pairs `(("X-Route" "team-a"))` |
| `:region`, `:project`, `:location` | Cloud placement |
| `:max-tokens`, `:models-ttl-seconds` | Reply token cap and model cache TTL |
| `:cache-p`, `:cache-ttl`, `:betas`, `:timeout`, `:retries` | Request options (override `:llm` values) |
| `:auth-scheme`, `:auth-header`, `:chat-path`, `:models-path` | Auth (`:bearer`, `:api-key-header`, `:x-api-key`, `:query-param`, `:none`, `:aws-sigv4`, `:gcp-oauth`) and path overrides |
| `:max-tokens-field`, `:system-role`, `:reasoning-field` | Wire field name overrides |

## `:channels`

| Channel | Key | Default | Notes |
| --- | --- | --- | --- |
| `:cli` | `:enabled` | `t` | Reported in status; `serve` always builds the CLI channel |
| `:http` | `:enabled` | `nil` | Enable HTTP webhook under `serve` |
| `:http` | `:bind` | `"127.0.0.1"` | Non-loopback requires a bearer token |
| `:http` | `:port` | `8787` | Listen port |
| `:http` | `:token-env` | `"ENCHIRIDION_HTTP_TOKEN"` | Env var for bearer token (prefer over `:token`) |
| `:http` | `:token` | `nil` | Literal bearer token (avoid; use `:token-env`) |
| `:http` | `:max-body-bytes` | `65536` | Max request body size |
| `:fluxer` | `:enabled` | `nil` | Enable Fluxer gateway under `serve` |
| `:fluxer` | `:allowed-users` | `nil` | List of allowed string user IDs (empty admits nobody) |
| `:fluxer` | `:token-env` | `"FLUXER_BOT_TOKEN"` | Env var for bot token |
| `:fluxer` | `:typing-wait-seconds` | `8` | Maximum wait for a typing sender before sending a ready reply (`0` to `30`, `0` disables) |
| `:fluxer` | `:custom-status` | `nil` | Allow agent to propose a temporary profile status |
| `:fluxer` | `:custom-status-user` | sole allowed user | User ID whose turns may set status (required if >1 allowed user) |
| `:fluxer` | `:custom-status-ttl-seconds` | `300` | Status lifetime before clearing |
| `:fluxer` | `:custom-status-cooldown-seconds` | `60` | Minimum seconds between status changes (`0` disables) |

## `:sleep`, `:budget`, and `:sandbox`

| Section | Key | Default | Meaning |
| --- | --- | --- | --- |
| `:sleep` | `:enabled` | `t` | Run scheduled background ticks during `serve` |
| `:sleep` | `:interval-seconds` | `900` | Seconds between ticks (invalid values fall back to `900`) |
| `:budget` | `:max-tool-rounds` | `64` | Max tool rounds per interactive or sleep turn |
| `:budget` | `:max-tokens-per-tick` | `400000` | Background token cap per tick (`nil` disables) |
| `:budget` | `:max-tokens-per-day` | `40000000` | Rolling 24h token cap checked by background work (`nil` disables) |
| `:sandbox` | `:agent-uid` | `1000` | UID for agent/broker child processes when started as root |
| `:sandbox` | `:agent-gid` | `1000` | GID for agent/broker child processes when started as root |

## `:memory`

Keep the defaults unless you are tuning retrieval or T2 promotion. See
[Memory](memory.md) for how they work.

### Storage and prompt blocks

| Key | Default | Meaning |
| --- | --- | --- |
| `:db` | `nil` | SQLite path (unset uses `agents/default/memory.db`) |
| `:recent-turns` | `6` | Recent user/assistant turns included in each prompt |
| `:recent-window-chars` | `4000` | Character cap for recent turns |
| `:block-limits` | see below | Per-block character limits, merged by label |
| `:unlisted-block-limit` | `1200` | Character limit for any unlisted block |
| `:compaction-rebase-every` | `8` | Compaction passes between full rebuilds from raw turns |
| `:compaction-rebase-turns` | `24` | Raw turns read during a rebuild |

Default `:block-limits`: `(:persona 6000 :operator 1600 :world 3000 :adapt 1200
:session 400 :ledger 250 :bootstrap 300)`.

### Episodic retrieval and embeddings

| Key | Default | Meaning |
| --- | --- | --- |
| `:enabled` | `t` | Master switch for episodic log and retrieval |
| `:retrieve` | `t` | Inject retrieved context pack into user messages |
| `:push` | `nil` | Unfinished proactive retrieval (leave `nil`) |
| `:push-max-fraction` | `0.5` | Context share reserved for push candidates |
| `:record-sleep` | `t` | Log sleep and compaction turns |
| `:pack-chars` | `4450` | Character budget for the retrieved context pack |
| `:maintenance-batch` | `200` | Episodes scored per maintenance batch |
| `:graph-limit` | `20000` | Max lexical link rows loaded per retrieval |
| `:rerank` | `nil` | Use `:model-cheap` to rerank top 30 candidates per turn |
| `:parameters` | `nil` | Override retrieval weights and decay parameters |
| `:embed` | `nil` | Add dense vector search fused with BM25 |
| `:embed-model` | `"text-embedding-3-small"` | Embedding model |
| `:embed-dimensions` | `512` | Embedding vector dimensions |
| `:embed-base-url` | `"https://api.openai.com/v1/"` | Embedding API base URL |
| `:embed-key-env` | `"OPENAI_API_KEY"` | Env var for embedding API key |

### T2 claim derivation and promotion gates

| Key | Default | Meaning |
| --- | --- | --- |
| `:t2-enabled` | `t` | Allow scheduled T2 promotion passes |
| `:t2-interval-seconds` | `86400` | Normal interval between passes |
| `:t2-frozen-interval-seconds` | `604800` | Slowdown interval while quarantined |
| `:t2-episode-threshold` | `200` | New episodes that trigger a pass early |
| `:t2-max-episodes-per-tick` | `5` | Episodes derived per tick |
| `:t2-max-tokens-per-pass` | `2000000` | Rolling 24h token cap for T2 |
| `:t2-deriver-max-tokens` | `16384` | Max tokens per derivation call |
| `:t2-deriver-model` | `nil` | Derivation model (unset uses `:model-cheap`) |
| `:t2-deriver-concurrency` | `4` | Concurrent derivation calls |
| `:t2-max-tokens-per-episode` | `16000` | Cost gate: max tokens per derived episode |
| `:t2-writes-per-episode` | `8` | Cost gate: max claims per derived episode |
| `:canaries` | `:built-in` | Shipped smoke checks, or custom list (`:name`, `:family`, `:cue`, `:expect`, `:stale`) |
| `:canary-min-families` | `4` | Required canary families (`retrieval`, `update`, `safety`, `tail`) |
| `:gate-margin` | `0.05` | Minimum mean utility gain |
| `:gate-min-n` | `100` | Minimum non-tied utility pairs |
| `:gate-alpha` | `0.05` | One-sided sign test significance threshold |
| `:gate-pack-chars` | `1100` | Pack character cap used in utility comparison |
| `:utility-max-tasks` | `400` | Max Q&A pairs scored in utility gate |
| `:tail-rarity-fraction` | `0.10` | Rarest fraction of eligible answers sampled |
| `:tail-min-n` | `50` | Minimum tail sample size (capped at `400`) |
| `:tail-margin` | `0.02` | Maximum allowed recall drop on rare answers |
| `:precision-min` | `0.8` | Minimum passing fraction of checked promotions |
| `:precision-window` | `20` | Recent promotions counted for precision |
| `:precision-min-checked` | `5` | Minimum checked promotions before enforcing precision |
| `:quarantine-max` | `0.5` | Max fraction of quarantined candidates before freeze |
| `:quarantine-window` | `20` | Recent candidates counted for quarantine rate |
| `:quarantine-min-candidates` | `5` | Minimum candidates before enforcing quarantine rate |

## Environment variables

| Variable | Meaning |
| --- | --- |
| `ENCHIRIDION_CONFIG` | Explicit path to `config.lsp` (must be absolute and root-owned when running as root) |
| `ENCHIRIDION_HOME` | State root containing `agents/default/` and `run/` (defaults to working directory) |
| `ENCHIRIDION_CANARY_APPROVALS` | Directory for approved T2 canaries (Docker sets this under the state root) |
| `ENCHIRIDION_SOURCE` | Installed source root (also searched for `config.lsp` and `.env`) |
| `ENCHIRIDION_SBCL` | SBCL binary for broker and plugin verification children |
| `ENCHIRIDION_GIT` | Git binary (defaults to `git` on `PATH`) |
| `ENCHIRIDION_PROVIDERS_PATH` | Override catalog cache path (default: `run/providers.json`) |
| `ENCHIRIDION_HIDEPID` | Container `/proc` remount option (default `2`; `0` skips remount) |
| `ENCHIRIDION_REQUIRE_HIDEPID` | Set `1` to make a failed `/proc` remount fatal |
| `ENCHIRIDION_HTTP_TOKEN` | Default HTTP webhook bearer token |
| `FLUXER_BOT_TOKEN` | Default Fluxer bot token |
