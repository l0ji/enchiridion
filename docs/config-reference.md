# Settings reference

For provider, model and channel setup, see [Configuration](configuration.md).

## File format

`config.cl` defines `enchiridion.user:*enchiridion-config*`. It is a quoted list
of section names followed by `(key value)` entries:

```lisp
(in-package #:enchiridion.user)

(defparameter *enchiridion-config*
  '(:llm
    (:provider :opencode)
    :memory
    (:db nil)
    (:block-limits (:persona 8000))))
```

Add entries under the existing section. Use `t` and `nil` for booleans, quotes
for strings, and unquoted numbers. Nested lists are already inside the outer
quote. Unknown keys are ignored, so check spelling. A flat property list is
also accepted for LLM settings.

## LLM

These entries go under `:llm`. Provider-specific examples are in
[LLM providers](llm.md).

| Key | Default | Use |
| --- | --- | --- |
| `:provider` | detect | Provider id; `:custom` for an endpoint with no catalog entry |
| `:backend` | `:openai` | Protocol override: `:openai`, `:anthropic` or a registered adapter id |
| `:base-url` | `nil` | Override the provider endpoint |
| `:api-key-env` | `nil` | Override the variable holding the provider key |
| `:model-primary` | `nil` | Conversation model; unset uses the provider's model |
| `:model-cheap` | `nil` | Memory summary model; unset uses the selected primary model |
| `:model-sleep` | `nil` | Background model; unset uses the selected primary model |
| `:max-tokens` | `4096` in example | Reply cap; omitting it removes the OpenAI cap, while Messages defaults to 4096 |
| `:providers` | shipped rows | Add or override providers by `:id` |
| `:providers-url` | `"https://models.dev/api.json"` | Runtime catalog source |
| `:providers-ttl-seconds` | `86400` in example | Catalog cache lifetime in seconds; omitting it makes the cache always stale |
| `:models-ttl-seconds` | `86400` | Model list cache lifetime in seconds |
| `:offline` | `nil` | Skip automatic catalog and model-list fetches |
| `:region` | `nil` | Bedrock region, otherwise `AWS_REGION` |
| `:project` | `nil` | Vertex project, otherwise `GOOGLE_VERTEX_PROJECT` |
| `:location` | `nil` | Vertex location, otherwise `GOOGLE_VERTEX_LOCATION` |

With no explicit provider, selection checks the base URL, then OpenAI, OpenCode
Go and Anthropic keys in that order, then a unique matching cached provider,
then OpenAI. The example's `(:provider nil)` enables this detection.
`providers refresh` and `providers models ID` can fetch even with `:offline t`.

Each `:providers` row requires an `:id`. An operator row overrides the catalog
and shipped row field by field.

| Row keys | Use |
| --- | --- |
| `:id`, `:name` | Identifier and display name |
| `:api`, `:profile` | API handler and request format |
| `:base-url`, `:api-key-env` | Endpoint and credential variable name, or list of names |
| `:model`, `:default-model`, `:models` | Selected model, fallback and static model list |
| `:headers`, `:query-params` | Extra pairs such as `(("X-Route" "team-a"))` |
| `:region`, `:project`, `:location` | Cloud placement |
| `:max-tokens`, `:models-ttl-seconds` | Reply cap and model cache lifetime |
| `:cache-p`, `:cache-ttl`, `:betas`, `:timeout`, `:retries` | Request options supported by the handler |
| `:auth-scheme`, `:auth-header`, `:chat-path`, `:models-path` | Authentication and path overrides |
| `:max-tokens-field`, `:system-role`, `:reasoning-field` | Request field overrides |

`:headers`, `:query-params`, `:profile` and the request options
`:cache-p`, `:cache-ttl`, `:betas`, `:timeout` and `:retries` can also go under
`:llm`; a provider row's value wins. `:custom` also takes `:models` under
`:llm`. Keep credential values in `.env`, not in headers in `config.cl`.

## Channels

Entries go inside `:channels`. Each channel merges its options over these
defaults. See [Channels](channels.md) for usage.

| Entry | Key | Default |
| --- | --- | --- |
| `:cli` | `:enabled` | `t` |
| `:http` | `:enabled` | `nil` |
| `:http` | `:bind` | `"127.0.0.1"` |
| `:http` | `:port` | `8787` |
| `:http` | `:token-env` | `"ENCHIRIDION_HTTP_TOKEN"` |
| `:http` | `:token` | `nil` |
| `:http` | `:max-body-bytes` | `65536` |
| `:fluxer` | `:enabled` | `nil` |
| `:fluxer` | `:allowed-users` | `nil` |
| `:fluxer` | `:token-env` | `"FLUXER_BOT_TOKEN"` |

The HTTP body limit is in bytes. Prefer `:token-env` over a literal `:token`.
The CLI `:enabled` field is reported in status; `serve` builds the terminal
channel regardless. `--channel` selects a channel for one run; HTTP flags
`--bind`, `--port` and `--token-env` override the file.

## Schedule, budget and agent user

| Section | Key | Default | Use |
| --- | --- | --- | --- |
| `:sleep` | `:enabled` | `t` | Schedule background work during `serve` |
| `:sleep` | `:interval-seconds` | `900` | Time between ticks |
| `:budget` | `:max-tokens-per-tick` | `4000` | Background token cap per tick |
| `:budget` | `:max-tokens-per-day` | `400000` | Rolling 24-hour token cap checked by background work |
| `:sandbox` | `:agent-uid` | `1000` | Agent process user id when started as root |
| `:sandbox` | `:agent-gid` | `1000` | Agent process group id when started as root |

Background caps do not stop interactive requests, and a running phase can exceed
a cap. The day ledger includes interactive usage. T2 promotion work checks the
day cap rather than the tick cap. An invalid sleep interval falls back to 900.
A normal user checkout has no user separation; see [Deployment](deployment.md).

## Memory

All entries below go under `:memory`. Leave these alone for the first run.
[Memory](memory.md) covers normal use; [Episodic memory](episodic-memory.md)
covers retrieval and promotion.

### Storage and conversation

| Key | Default | Use |
| --- | --- | --- |
| `:db` | `nil` | SQLite path; unset uses `agents/default/memory.db` under the state root |
| `:recent-turns` | `6` | Recent user and assistant turns included in a prompt |
| `:recent-window-chars` | `4000` | Character cap for those turns |
| `:block-limits` | see below | Per-block character limits, merged by label |
| `:unlisted-block-limit` | `1200` | Character limit for other blocks |
| `:compaction-rebase-every` | `8` | Compaction passes between rebuilds from raw turns |
| `:compaction-rebase-turns` | `24` | Raw turns read by a rebuild |

Default block limits are `(:persona 6000 :operator 1600 :world 3000 :session 400
:ledger 250 :bootstrap 300)`. Raising them increases prompt size.

### Retrieval

| Key | Default | Use |
| --- | --- | --- |
| `:enabled` | `t` | Enable the episodic log and retrieved context |
| `:retrieve` | `t` | Include retrieved context in turns |
| `:push` | `nil` | Incomplete proactive retrieval; leave disabled |
| `:record-sleep` | `t` | Log sleep and compaction turns |
| `:pack-chars` | `4450` | Retrieved context character cap |
| `:push-max-fraction` | `0.5` | Reserved context share for proactive candidates |
| `:maintenance-batch` | `200` | Episodes processed per maintenance batch |
| `:graph-limit` | `20000` | Maximum link rows loaded by one retrieval |
| `:rerank` | `nil` | Use the cheap model to rerank results |
| `:parameters` | `nil` | Override retrieval weights and decay parameters |

### Embeddings

| Key | Default | Use |
| --- | --- | --- |
| `:embed` | `nil` | Add vector search to text search |
| `:embed-model` | `"text-embedding-3-small"` | Embedding model |
| `:embed-dimensions` | `512` | Vector dimensions |
| `:embed-base-url` | `"https://api.openai.com/v1/"` | Embedding endpoint |
| `:embed-key-env` | `"OPENAI_API_KEY"` | Embedding credential variable |

### T2 promotion

T2 derives shorter claims from episodes and tests them before promotion.
It needs evaluation inputs, including operator-written canaries; enabling it
alone does not make it run. See [Episodic memory](episodic-memory.md).

| Key | Default | Use |
| --- | --- | --- |
| `:t2-enabled` | `t` | Allow scheduled promotion passes |
| `:t2-interval-seconds` | `86400` | Normal interval between passes |
| `:t2-frozen-interval-seconds` | `604800` | Interval when quarantine rate is too high |
| `:t2-episode-threshold` | `200` | New episodes that make a pass due early |
| `:t2-max-episodes-per-tick` | `5` | Episodes derived per tick |
| `:t2-max-tokens-per-pass` | `200000` | Promotion token cap over a rolling 24 hours |
| `:t2-deriver-max-tokens` | `16384` | Reply cap for one derivation request |
| `:t2-deriver-model` | `nil` | Derivation model; unset uses the cheap model |
| `:t2-deriver-concurrency` | `4` | Concurrent derivation requests |
| `:t2-max-tokens-per-episode` | `3000` | Token cap per episode derived since the last promotion |
| `:t2-writes-per-episode` | `8` | Claim cap per derived episode |
| `:canaries` | `nil` | Checks with `:name`, `:family`, `:cue`, `:expect` and optional `:stale` |
| `:canary-min-families` | `4` | Required canary families |
| `:gate-margin` | `0.05` | Minimum mean utility gain |
| `:gate-min-n` | `100` | Minimum non-tied utility pairs |
| `:gate-alpha` | `0.05` | Utility significance threshold |
| `:gate-pack-chars` | `1100` | Context character cap for both utility comparisons |
| `:utility-max-tasks` | `400` | Maximum utility question-and-answer pairs |
| `:tail-rarity-fraction` | `0.10` | Fraction of episodes treated as rare |
| `:tail-min-n` | `50` | Minimum rare-answer questions |
| `:tail-margin` | `0.02` | Allowed drop in rare-answer recall |
| `:precision-min` | `0.8` | Minimum passing fraction of checked promotions |
| `:precision-window` | `20` | Recent promotions used for the precision check |
| `:precision-min-checked` | `5` | Required checked promotions |
| `:quarantine-max` | `0.5` | Maximum fraction of quarantined candidates |
| `:quarantine-window` | `20` | Recent candidates used for the quarantine check |
| `:quarantine-min-candidates` | `5` | Required candidates before checking quarantine rate |

## Environment

Provider keys and channel tokens are listed in [Configuration](configuration.md).
The packaged wrappers set the executable and library paths.

| Variable | Use |
| --- | --- |
| `ENCHIRIDION_CONFIG` | Explicit config file path |
| `ENCHIRIDION_HOME` | State root; defaults to the working directory |
| `ENCHIRIDION_SOURCE` | Installed source root, also searched for config and `.env` |
| `ENCHIRIDION_SBCL` | SBCL executable for broker and verification children |
| `ENCHIRIDION_GIT` | Git executable; defaults to `git` on `PATH` |
| `ENCHIRIDION_PROVIDERS_PATH` | Catalog cache path instead of `run/providers.json` |
| `ENCHIRIDION_HIDEPID` | Container `/proc` remount option; defaults to `2`, `0` skips it |
| `ENCHIRIDION_REQUIRE_HIDEPID` | `1` makes a failed `/proc` remount fatal |

Use an absolute `ENCHIRIDION_CONFIG` path for root. The file and parent directories
must be root-owned, with no group or world write permission, including symlink
targets. [Deployment](deployment.md) covers the container's secret mount and
process isolation.
