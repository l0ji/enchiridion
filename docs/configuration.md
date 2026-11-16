# Configuration

The harness reads one Lisp file for paths and behavior, and the environment for credentials.
This page gives the file's location and shape, every key the code reads, and the order in which the file, the environment, and a flag decide a value.

## The configuration model

The file is `config.cl`.
It is loaded with the Lisp `load` function, so treat it as code.
The load defines `enchiridion.user::*enchiridion-config*`, and that value becomes the active configuration for the life of the process.

A command loads the file only when its row names the capability. `help`, `version`, `check`, `tools`, `health`, `reload`, `channels`, and `heartbeat` never do, and neither do the commands that only read the agent directory, apart from `blocks show` for its configured limits.
A command that needs it and finds none stops with exit 2:

```text
Configuration is wrong at CONFIG.
config.cl is required. Copy config.example.cl to config.cl and edit it.
```

A file that binds no variable is present, so it is accepted and the shipped defaults fill the missing keys.

The file holds paths and behavior only.
A secret value belongs in `.env` or the process environment, and the file names the variable that holds it.

`config-lookup` asks the active configuration first and the shipped defaults second, key by key.
`config-value` reads the `:llm` section, or a flat list, of the active configuration only, so a sectioned file that omits an `:llm` key does not inherit the shipped value.
`config-setting` reads a named section and requires a shipped default, so a new setting cannot be read before it has a default and a line in this page.

`config.cl` is gitignored, and the tracked `config.example.cl` is the template.

## Locate the file

The reader tries these paths, in order:

1. `ENCHIRIDION_CONFIG`, when set
2. `<current directory>/config.cl`
3. `<project root>/config.cl`

The project root is `ENCHIRIDION_SOURCE`, or the nearest directory at or above the current one that holds `enchiridion.asd`.

A process running as root skips the working-directory lookup and reads `ENCHIRIDION_CONFIG` or `<ENCHIRIDION_SOURCE>/config.cl`.
For root, the path must be absolute and without `..`, and the file and every directory above it must be owned by root and must not be group- or world-writable:

```text
Configuration is wrong at CONFIG.
Root config requires root-owned paths without group or world write permission: /path
```

Create the file from the template:

```sh
cp config.example.cl config.cl
```

An absent file stops a command that needs configuration before it starts. A file with a read error does the same.

## Shape

A sectioned configuration is a list of section keywords and `(key value)` entries until the next section keyword.

```lisp
(in-package #:enchiridion.user)

(defparameter *enchiridion-config*
  '(:llm
    (:provider :opencode)
    (:model-primary nil)
    :channels
    (:http (:enabled nil) (:port 8787))))
```

| Section     | Holds                                                              |
| ----------- | ------------------------------------------------------------------ |
| `:llm`      | Provider selection, model tiers, catalog settings, cloud placement |
| `:channels` | One entry per channel                                              |
| `:budget`   | Token caps for unattended work                                     |
| `:sandbox`  | Agent user id and group id                                         |
| `:memory`   | Memory store path, blocks, and retrieval settings                  |
| `:sleep`    | Heartbeat switch and interval                                      |

A flat property list is also accepted, and the sectioned shape wins when both could match.
Unknown keys are ignored, and values are not type-checked at load.

## The :llm section

| Key                     | Type              | Default                         | Meaning                                                                                         |
| ----------------------- | ----------------- | ------------------------------- | ----------------------------------------------------------------------------------------------- |
| `:provider`             | keyword or string | unset (detect)                  | Provider id, or `:custom`. Unset means detection (see [Provider selection](#provider-selection)). |
| `:backend`              | keyword           | `:openai`                       | Wire protocol: `:openai`, `:anthropic`, or a registered adapter id.                              |
| `:base-url`             | string or `nil`   | `nil`                           | Endpoint override. `nil` takes the provider row's endpoint.                                      |
| `:model-primary`        | string or `nil`   | `nil`                           | Model for reasoning turns. `nil` takes the provider row's model.                                 |
| `:model-cheap`          | string or `nil`   | `nil`                           | Model for memory digests and compaction.                                                        |
| `:model-sleep`          | string or `nil`   | `nil`                           | Model for the sleep-time agent.                                                                 |
| `:api-key-env`          | string or `nil`   | `nil`                           | Variable that holds the provider key. `nil` lets the provider row decide.                        |
| `:max-tokens`           | integer           | `4096`                          | Reply cap for one request.                                                                      |
| `:providers`            | list of rows      | three shipped rows              | Define or override providers by id.                                                             |
| `:providers-url`        | string            | `"https://models.dev/api.json"` | Source of the runtime provider catalog.                                                         |
| `:providers-ttl-seconds`| integer           | `86400`                         | Age at which the cached provider index is stale.                                                |
| `:models-ttl-seconds`   | integer           | `86400`                         | Age at which one provider's cached model list is stale.                                         |
| `:offline`              | boolean           | `nil`                           | `t` stops start-up fetches. Explicit `providers refresh` and `providers models` still run.       |
| `:region`               | string or `nil`   | `nil`                           | Amazon Bedrock region.                                                                          |
| `:project`              | string or `nil`   | `nil`                           | Google Vertex project.                                                                          |
| `:location`             | string or `nil`   | `nil`                           | Google Vertex location.                                                                         |

These keys belong to the selected provider and are read when it is resolved: `:models` (a static list for `:custom`), `:headers`, `:query-params`, `:profile`, `:cache-p`, `:cache-ttl`, `:betas`, `:timeout`, and `:retries`.
A row value wins over the top-level value; a `nil` is kept, because a handler's own default may be the thing the operator wants to turn off.
A header may be written `("Name" "value")` or `("Name" . "value")`, and both reach the wire identically.

### Provider rows

A row defines or overrides one provider. A shipped row, a catalog row, and an operator row share this shape.

| Row key | Type | Meaning |
| --- | --- | --- |
| `:id` | keyword or string | Provider identifier. Required. |
| `:name` | string | Display name. |
| `:api` | keyword | Wire handler: `:openai-chat`, `:anthropic-messages`, `:bedrock-invoke`, `:bedrock-messages`, or `:vertex-anthropic`. |
| `:profile` | keyword | Quirk profile. |
| `:base-url` | string | Endpoint. |
| `:api-key-env` | string or list | Variable name, or names, that hold the credential. |
| `:model`, `:default-model` | string | The provider model and its fallback. |
| `:models` | list of strings | Static model list for an endpoint that cannot be asked. |
| `:headers`, `:query-params` | list of pairs | Extra headers and query parameters. |
| `:region`, `:project`, `:location` | string | Cloud placement for Bedrock and Vertex. |
| `:max-tokens`, `:models-ttl-seconds`, `:cache-p`, `:cache-ttl`, `:betas`, `:timeout`, `:retries` | mixed | Per-provider request options. |

An individual quirk may be overridden on the row with `:auth-scheme`, `:auth-header`, `:chat-path`, `:models-path`, `:max-tokens-field`, `:system-role`, or `:reasoning-field`.
[Large language model backends](llm.md) lists the handlers and profiles.

An operator row overrides the shipped row and the catalog row field by field; a new `:id` adds one.
A row without `:id` is a configuration error.
`:provider :custom` builds a row from the top-level `:llm` keys with no preset and no catalog entry; `:base-url` is required.

### Shipped providers

Three rows ship as configuration defaults, so the default path works with no catalog cached and no network.

| Id           | Name        | Profile      | Base URL                        | Default model         | Key variable        |
| ------------ | ----------- | ------------ | ------------------------------- | --------------------- | ------------------- |
| `:openai`    | OpenAI      | `:openai`    | `https://api.openai.com/v1/`    | `gpt-5.6-luna`        | `OPENAI_API_KEY`    |
| `:opencode`  | OpenCode Go | `:openai`    | `https://opencode.ai/zen/go/v1` | `deepseek-v4.1-flash` | `OPENCODE_API_KEY`  |
| `:anthropic` | Anthropic   | `:anthropic` | `https://api.anthropic.com/`    | `claude-sonnet-5-5`   | `ANTHROPIC_API_KEY` |

Provider knowledge beyond those rows comes from the runtime catalog, generated from `https://models.dev/api.json` and cached under `run/` (see [Large language model backends](llm.md)).

### Provider selection

An explicit `:provider` wins.
Without one, detection uses a recognized `:base-url` host, then the key variables `OPENAI_API_KEY`, `OPENCODE_API_KEY`, `ANTHROPIC_API_KEY`, the one cached provider whose variable is present, then OpenAI.
Two exported keys therefore need an explicit `:provider` or `:base-url`.

An explicit `:provider` that names nothing is a configuration error, and the error names `enchiridion providers refresh` and a row under `:providers`.
An explicit `:api-key-env` names the variable for the selected provider; without it the provider row names the variable (see [Secrets and .env](#secrets-and-env)).

## The :channels section

Every channel has one entry under `:channels`, and the entry merges over the shipped entry key by key.
An explicit `nil` wins; a channel with no entry keeps its shipped entry, and `http` and `fluxer` ship disabled.

### The :cli entry

| Key        | Type    | Default | Meaning                                                                                     |
| ---------- | ------- | ------- | ------------------------------------------------------------------------------------------- |
| `:enabled` | boolean | `t`     | State the status file reports. `serve` builds the terminal channel regardless.              |

`serve` supervises the terminal channel, which runs the interactive session when a terminal is attached.
A process with no terminal keeps it down and prints one line (see [Channels](channels.md)).

### The :http entry

| Key               | Type            | Default                    | Meaning                                                  |
| ----------------- | --------------- | -------------------------- | -------------------------------------------------------- |
| `:enabled`        | boolean         | `nil`                      | Start the webhook.                                       |
| `:bind`           | string          | `"127.0.0.1"`              | Bind address.                                            |
| `:port`           | integer         | `8787`                     | Port.                                                    |
| `:token`          | string or `nil` | `nil`                      | Literal bearer token, for a loopback bind and for tests. |
| `:token-env`      | string          | `"ENCHIRIDION_HTTP_TOKEN"` | Variable that holds the bearer token.                    |
| `:max-body-bytes` | integer         | `65536`                    | Request body bytes the webhook reads.                    |

A bind address other than loopback requires a token, and the harness refuses to start without one.
The literal `:token` is the one secret-shaped value the file can hold, and the harness registers it with the scrubber.

### The :fluxer entry

| Key              | Type            | Default              | Meaning                                  |
| ---------------- | --------------- | -------------------- | ---------------------------------------- |
| `:enabled`       | boolean         | `nil`                | Start the Fluxer gateway channel.        |
| `:allowed-users` | list of strings | `nil`                | User ids that may send a direct message. |
| `:token-env`     | string          | `"FLUXER_BOT_TOKEN"` | Variable that holds the bot token.       |

The channel is deny by default, and an empty or absent allowlist admits nobody (see [Channels](channels.md)).

## The :budget section

| Key                    | Type    | Default  | Meaning                           |
| ---------------------- | ------- | -------- | --------------------------------- |
| `:max-tokens-per-tick` | integer | `4000`   | Token cap for one heartbeat tick. |
| `:max-tokens-per-day`  | integer | `400000` | Token cap for one day.            |

The heartbeat starts no new phase once the spend reaches a cap, and a phase under way finishes.
A file that omits a budget key gets the shipped cap (see [Supervisor and heartbeat](supervisor.md)).

## The :sandbox section

| Key          | Type    | Default | Meaning                                              |
| ------------ | ------- | ------- | ---------------------------------------------------- |
| `:agent-uid` | integer | `1000`  | User id for agent code, the broker, and Git.         |
| `:agent-gid` | integer | `1000`  | Group id for the same processes.                     |

The supervisor runs as root in the container and in a root-started checkout, and it holds the secrets.
The broker, the reload verification, `--verify-plugin`, and `git-exec` use `:agent-uid` and `:agent-gid`.
A checkout started as the operator has no uid split: the supervisor, the broker child, and agent code run as that user.
The `/proc` hidepid remount happens in the container entry point before Lisp starts, so `ENCHIRIDION_HIDEPID` sets it (see [Deployment](deployment.md)).

## The :memory section

| Key                        | Type                      | Default                                                                        | Meaning                                                           |
| -------------------------- | ------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| `:db`                      | string or `nil`           | `nil`                                                                          | SQLite store path. `nil` selects `agents/default/memory.db`.       |
| `:recent-turns`            | integer                   | `6`                                                                            | User and assistant turns of the current session carried after the system prompt. |
| `:recent-window-chars`     | integer                   | `4000`                                                                         | Total characters of those turns.                                   |
| `:block-limits`            | plist of label to integer | `:persona 6000 :operator 1600 :world 3000 :session 400 :ledger 250 :bootstrap 300` | Character limit per block, merged key by key over the shipped list. |
| `:unlisted-block-limit`    | integer                   | `1200`                                                                         | Limit for a block whose label the list does not name.              |
| `:enabled`                 | boolean                   | `t`                                                                            | Master switch for the episodic log and the cue pack.               |
| `:retrieve`                | boolean                   | `t`                                                                            | Put a cue pack in the user message.                                |
| `:push`                    | boolean                   | `nil`                                                                          | Enable the four push channels.                                     |
| `:record-sleep`            | boolean                   | `t`                                                                            | Append sleep and compaction turns to the log.                      |
| `:pack-chars`              | integer                   | `4450`                                                                         | Cue pack budget in characters.                                     |
| `:push-max-fraction`       | real                      | `0.5`                                                                          | Push cap as a fraction of the pack.                                |
| `:maintenance-batch`       | integer                   | `200`                                                                          | Episodes per maintenance batch.                                    |
| `:graph-limit`             | integer                   | `20000`                                                                        | Link rows one retrieval may load.                                  |
| `:embed`                   | boolean                   | `nil`                                                                          | Fuse dense candidates with BM25.                                   |
| `:embed-model`             | string                    | `"text-embedding-3-small"`                                                     | Embedding model.                                                   |
| `:embed-dimensions`        | integer                   | `512`                                                                          | Embedding dimensions.                                              |
| `:embed-base-url`          | string                    | `"https://api.openai.com/v1/"`                                                 | Embedding endpoint.                                                |
| `:embed-key-env`           | string                    | `"OPENAI_API_KEY"`                                                             | Variable that holds the embedding key. Always collected as a secret name. |
| `:rerank`                  | boolean                   | `nil`                                                                          | Install the cheap-model reranker.                                  |
| `:t2-max-episodes-per-tick` | integer                   | `5`                                                                            | Episodes one T2 build may derive in one tick.                      |
| `:t2-writes-per-episode`   | integer                   | `8`                                                                            | Most assertions a candidate may write per episode it derived.      |
| `:t2-max-tokens-per-episode` | integer                 | `3000`                                                                         | Most tokens per episode derived since the last promotion.          |
| `:gate-margin`             | real                      | `0.05`                                                                         | Utility-gate minimum mean outcome delta.                           |
| `:gate-min-n`              | integer                   | `100`                                                                          | Utility-gate minimum non-tied pairs.                               |
| `:gate-alpha`              | real                      | `0.05`                                                                         | Utility-gate significance level.                                   |
| `:gate-pack-chars`         | integer                   | `1100`                                                                         | Pack budget both utility arms are scored in.                       |
| `:tail-margin`             | real                      | `0.02`                                                                         | How far candidate recall on rare answers may fall below retention-only. |
| `:utility-max-tasks`       | integer                   | `400`                                                                          | Most question-and-answer pairs one utility run scores.             |
| `:parameters`              | plist or `nil`            | `nil`                                                                          | Overrides merged over the shipped memory parameter defaults.       |
| `:t2-enabled`              | boolean                   | `t`                                                                            | Run T2 passes from the heartbeat on their schedule.                |
| `:t2-interval-seconds`     | integer                   | `86400`                                                                        | Seconds between T2 passes.                                         |
| `:t2-frozen-interval-seconds` | integer                | `604800`                                                                       | Seconds between T2 passes while the quarantine rate is too high.   |
| `:t2-episode-threshold`    | integer                   | `200`                                                                          | New episodes that make a pass due early.                           |
| `:t2-max-tokens-per-pass`  | integer                   | `200000`                                                                       | Most tokens T2 may spend in a rolling twenty-four hours.           |
| `:t2-deriver-max-tokens`   | integer                   | `16384`                                                                        | Reply cap of one T2 deriver call.                                  |
| `:t2-deriver-model`        | string or `nil`           | `nil`                                                                          | Model the T2 deriver calls; `nil` is `:model-cheap`.               |
| `:t2-deriver-concurrency`  | integer                   | `4`                                                                            | Deriver calls in flight at once.                                   |
| `:canaries`                | list or `nil`             | `nil`                                                                          | Operator canaries: `:name`, `:family`, `:cue`, `:expect`, and `:stale`. |
| `:canary-min-families`     | integer                   | `4`                                                                            | Canary families required before a T2 pass can run.                 |
| `:tail-rarity-fraction`    | real                      | `0.10`                                                                         | Share of episodes, rarest first, treated as rare.                  |
| `:tail-min-n`              | integer                   | `50`                                                                           | Fewest rare-answer questions a T2 pass needs.                      |
| `:precision-min`           | real                      | `0.8`                                                                          | Least share of recent promotions that must pass their check.       |
| `:precision-window`        | integer                   | `20`                                                                           | Promotions the precision check reads.                              |
| `:precision-min-checked`   | integer                   | `5`                                                                            | Checked promotions needed before precision can freeze.             |
| `:quarantine-max`          | real                      | `0.5`                                                                          | Most share of recently gated candidates that may be quarantined.   |
| `:quarantine-window`       | integer                   | `20`                                                                           | Gated candidates the quarantine rate reads.                        |
| `:quarantine-min-candidates` | integer                 | `5`                                                                            | Gated candidates needed before the rate can freeze.                |
| `:compaction-rebase-every` | integer                   | `8`                                                                            | Every this many compaction passes, one rebases from raw turns.     |
| `:compaction-rebase-turns` | integer                   | `24`                                                                           | Raw turns a rebase pass reads.                                     |

The store path can also be a pathname object.
The default is under the agent directory, which is on the state volume in the container.
An operator who writes `(:block-limits (:persona 8000))` keeps the shipped limits for the other labels.
Raising a limit raises the fixed token cost of every prompt (see [Memory](memory.md)).

The log and the cue pack are on; push is off.
T2 runs from the heartbeat, but builds nothing until a deriver, a four-family canary suite, the utility task set, and the tail sample are present (see [Episodic memory](episodic-memory.md) and the [design record](design/memory.md)).
Each turn sends the frozen system prompt, then at most `:recent-turns` user and assistant turns of the current session, oldest first, within `:recent-window-chars` characters; the sleep channel and other sessions are never included.
Changing `:parameters` changes the retrieval score, so a change is a new configuration hash and a new measurement run.

## The :sleep section

| Key                 | Type    | Default | Meaning                                           |
| ------------------- | ------- | ------- | ------------------------------------------------- |
| `:enabled`          | boolean | `t`     | Start the heartbeat schedule with the supervisor. |
| `:interval-seconds` | integer | `900`   | Seconds between sleep ticks.                      |

The supervisor takes `:enabled` as its heartbeat flag.
An `:interval-seconds` value that is not a positive integer becomes 900 (see [Supervisor and heartbeat](supervisor.md)).

## Environment variables

| Variable                     | Meaning                                                                                       |
| ---------------------------- | --------------------------------------------------------------------------------------------- |
| `ENCHIRIDION_HOME`           | Home root for `agents/default/` and `run/`. Defaults to the current directory.                 |
| `ENCHIRIDION_CONFIG`         | Explicit path to `config.cl`; first in the search order.                                       |
| `ENCHIRIDION_SOURCE`         | Project root for the second `config.cl` path and for `.env`.                                  |
| `ENCHIRIDION_SBCL`           | Lisp implementation for the broker and plugin verification. The packaged wrapper sets it.      |
| `ENCHIRIDION_GIT`            | Git executable. The packaged wrapper and the container set it. Defaults to `git` on `PATH`.    |
| `ENCHIRIDION_PROVIDERS_PATH` | Path of the provider catalog cache, instead of `run/providers.json`.                           |
| `OPENAI_API_KEY`             | OpenAI credential, unless `:api-key-env` names another variable.                               |
| `OPENCODE_API_KEY`           | OpenCode Go credential.                                                                        |
| `ANTHROPIC_API_KEY`          | Anthropic credential.                                                                          |
| `ENCHIRIDION_HTTP_TOKEN`     | Webhook bearer token, unless the `:http` entry names another variable.                         |
| `FLUXER_BOT_TOKEN`           | Fluxer bot token, unless the `:fluxer` entry names another variable.                           |

A credential variable is removed from the process environment after the loader reads it.

## Secrets and .env

The rule is one sentence: the file names the variable and the environment holds the value.

The loader reads the first secret file that exists, in this order, and reports `<current directory>/.env` when none does:

1. `/run/secrets/.env`, the container location
2. `<current directory>/.env`
3. `<project root>/.env`

Before it reads one pair, the loader checks the mode. A file with the world read bit set is refused with exit status 2:

```text
Configuration is wrong at SECRETS.
/path/to/checkout/.env is mode #o644 and every uid can read it.
Run chmod 600 /path/to/checkout/.env.
```

Use mode 600. A group-readable file passes, and so do an absent file and a mode that cannot be read.

- The format is one `NAME=VALUE` pair per line.
- A line that starts with `#` or `;`, a blank line, a line without `=`, and an empty name or value are skipped.
- A leading `export ` is accepted, and matching single or double quotes around the value are removed.

The loader reads every pair, then every variable name the configuration mentions and every provider key name from the process environment.
An environment value wins over the same name in the file.
After the load, the process removes every loaded name and every credential-shaped variable from its own environment.
A child process inherits nothing, and a later read of `/proc` finds nothing, while the values stay in memory.

On a checkout started as the operator, the file stays on disk and agent code runs as the same user, so its file and shell tools can read `.env`.
The environment scrub keeps the values out of the child environment, but it is not a file system boundary.
The container deployment unlinks the file and runs agent code as another user, and that is the deployment with the secret guarantee (see [Deployment](deployment.md)).

The container copy at `/run/secrets/.env` is unlinked once its values are in memory; the operator's checkout `.env` is never deleted.
A read-only bind mount refuses the unlink, and the process prints one warning and continues:

```text
enchiridion: could not unlink /run/secrets/.env; the secrets file is still on disk.
```

The scrubber replaces a loaded value of at least eight characters with `[redacted]`, and also known credential shapes and role-named fields.
It runs on outbound text and on the status report fields (see [Large language model backends](llm.md)).

## Precedence

| Setting                              | First                             | Then                                  | Last                                   |
| ------------------------------------ | --------------------------------- | ------------------------------------- | -------------------------------------- |
| `config.cl` path                     | `ENCHIRIDION_CONFIG`              | Current directory, then project root (operator only) | Startup stops when a command needs it  |
| Budget caps                          | `config.cl` value                 | Shipped default                       | No other source                        |
| `:http` entry key                    | `--bind`, `--port`, `--token-env` | `config.cl` entry                     | Shipped entry                          |
| Channel start set (`http`, `fluxer`) | `--channel NAME`                  | `:enabled t` in the entry             | Channel not started                    |
| Secret value                         | Process environment               | `.env` value                          | No value                               |
| Provider                             | `:provider`                       | Recognized `:base-url` host           | Key present, then OpenAI               |
| Cloud placement                      | Provider row value                | `:region`, `:project`, or `:location` | Environment variable                   |

A command-line flag belongs to one process, overrides the loaded configuration for that invocation, and never writes the file.
[Commands](commands.md) lists the flags and their validation.

`:offline t` is not a precedence rule.
It stops the start-up fetches without changing the configuration, and an explicit `providers refresh` or `providers models ID` still runs.

## Troubleshooting

| Symptom                                            | Cause                                                | Fix                                                              |
| -------------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------- |
| `Configuration is wrong at SECRETS.`               | The secret file is world readable                    | Run `chmod 600 .env`                                             |
| `config.cl is required.`                           | A command that needs configuration found no file     | Copy `config.example.cl` to `config.cl`                          |
| Startup stops with a reader error                  | `config.cl` has an unbalanced or unreadable form     | Correct the form, then run the command again                     |
| `No API key. Put NAME in .env or the environment.` | No credential was loaded for the selected provider   | Set `:api-key-env`, or put the provider row's variable in `.env` |

## See also

- [Getting started](getting-started.md): the first launch and the seed files.
- [Commands](commands.md): flags, commands, exit statuses, and the `secrets` output.
- [Large language model backends](llm.md): provider resolution, the catalog, and the scrubber.
- [Channels](channels.md): the webhook routes, the Fluxer gateway, and the terminal channel.
