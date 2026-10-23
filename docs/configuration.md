# Configuration

The harness reads one Lisp file for paths and behavior, and the environment for credentials.
The chapter gives the location and shape of that file and every section and key with its default.
It also gives the provider rows and the order in which the file, the environment, and a command-line flag decide a value.
After it, an operator can select a provider, enable channels, and cap unattended spend without writing a secret value.

## The configuration model

The file is `config.cl`.
The harness loads it with the Lisp `load` function before any command runs, so treat the file as code.
The load defines `enchiridion.user::*enchiridion-config*`, and that value becomes the active configuration for the life of the process.
The file is required. An absent file stops startup with exit 2 and `Configuration is wrong at CONFIG.` plus `config.cl is required. Copy config.example.cl to config.cl and edit it.`
A file that binds no variable is present, so it is accepted and the shipped defaults fill the missing keys.

The file holds paths and behavior only.
A secret value belongs in `.env` or the process environment, and the file names the variable that holds it.

`config-lookup` asks the active configuration first and the shipped defaults second, key by key.
`config-value` reads the active configuration only, so a sectioned file that omits a key does not inherit the shipped value.
A file that names two keys does not blank out the others.

`config.cl` is gitignored, and the tracked `config.example.cl` is the template and the only committed copy of the format.

## Locate the file

The reader tries two paths, in order:

1. `<current directory>/config.cl`
2. `<project root>/config.cl`

The project root is `ENCHIRIDION_SOURCE`, or the nearest directory at or above the current one that holds `enchiridion.asd`.

Create the file from the template:

```sh
cp config.example.cl config.cl
```

An absent file stops startup before any command runs, with the required-file message above.
A file with a read error also stops startup before any command runs.

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
| `:sandbox`  | Agent user id and `/proc` hiding                                   |
| `:memory`   | Memory store path and block limits                                 |
| `:sleep`    | Sleep-time agent switch and interval                               |

A flat property list is also accepted, and the sectioned shape wins when both could match.
Two readers exist: `config-value` reads the `:llm` section then a flat list, and `config-section-value` reads one named section.

A key that belongs outside `:llm` and is read through `config-value` returns the given default in silence.
Write every key in the section that owns it.

Unknown keys are ignored, and values are not type-checked at load.
A reader that needs a number falls back to its default or refuses the value when it uses it.

## The :llm section

| Key                                                        | Type                                    | Default                         | Meaning                                                                                                               |
| ---------------------------------------------------------- | --------------------------------------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `:provider`                                                | keyword or string                       | `:openai`                       | Provider id to select, or `:custom`. A name that resolves to nothing is a configuration error.                        |
| `:backend`                                                 | keyword                                 | `:openai`                       | Wire protocol and matching provider row. `:openai`, `:anthropic`, or a registered adapter id.                         |
| `:base-url`                                                | string or `nil`                         | `nil`                           | Endpoint override. `nil` takes the provider row's endpoint.                                                           |
| `:model-primary`                                           | string or `nil`                         | `nil`                           | Model for reasoning turns. `nil` takes the selected provider row's model.                                             |
| `:model-cheap`                                             | string or `nil`                         | `nil`                           | Model for memory digests and compaction. `nil` takes the provider row's model.                                       |
| `:model-sleep`                                             | string or `nil`                         | `nil`                           | Model for the sleep-time agent. `nil` takes the provider row's model.                                                 |
| `:api-key-env`                                             | string or `nil`                         | `nil`                           | Variable that holds the provider key. `nil` lets the provider row decide.                                             |
| `:max-tokens`                                              | integer                                 | `4096`                          | Reply cap for one request. The dialect names the field.                                                               |
| `:providers`                                               | list of rows                            | three shipped rows              | Define or override providers by id.                                                                                   |
| `:models`                                                  | list of strings                         | `nil`                           | Static model list for `:provider :custom`.                                                                            |
| `:providers-url`                                           | string                                  | `"https://models.dev/api.json"` | Source of the runtime provider catalog.                                                                               |
| `:providers-ttl-seconds`                                   | integer                                 | `86400`                         | Age at which the cached provider index is stale.                                                                      |
| `:models-ttl-seconds`                                      | integer                                 | `86400`                         | Age at which one provider's cached model list is stale.                                                               |
| `:offline`                                                 | boolean                                 | `nil`                           | `t` stops the start-up catalog and model-list fetches. Explicit `providers refresh` and `providers models` still run. |
| `:region`                                                  | string or `nil`                         | `nil`                           | Amazon Bedrock region.                                                                                                |
| `:project`                                                 | string or `nil`                         | `nil`                           | Google Vertex project.                                                                                                |
| `:location`                                                | string or `nil`                         | `nil`                           | Google Vertex location.                                                                                               |
| `:headers`                                                 | list of pairs or `nil`                  | `nil`                           | Extra request headers for the selected provider.                                                                      |
| `:query-params`                                            | list of pairs or `nil`                  | `nil`                           | Extra query parameters for the selected provider.                                                                     |
| `:profile`                                                 | keyword or `nil`                        | `nil`                           | Quirk profile for the selected provider.                                                                              |
| `:cache-p`, `:cache-ttl`, `:betas`, `:timeout`, `:retries` | boolean, string, list, integer, integer | `nil`                           | Per-provider request options. `nil` takes the handler default.                                                        |

`:headers`, `:query-params`, and `:profile` apply to whichever provider is selected.
A value written in the row wins over the top-level value.
A header may be written `("Name" "value")` or `("Name" . "value")`, and both reach the wire identically.

### Provider rows

A row defines or overrides one provider.
A shipped row, a catalog row, and an operator row all use this shape.

| Row key                                                                                          | Type              | Meaning                                                                                                                 |
| ------------------------------------------------------------------------------------------------ | ----------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `:id`                                                                                            | keyword or string | Provider identifier. Required.                                                                                          |
| `:name`                                                                                          | string            | Display name.                                                                                                           |
| `:api`                                                                                           | keyword           | Wire handler, as `:openai-chat`, `:anthropic-messages`, `:bedrock-invoke`, `:bedrock-messages`, or `:vertex-anthropic`. |
| `:profile`                                                                                       | keyword           | Quirk profile.                                                                                                          |
| `:base-url`                                                                                      | string            | Endpoint.                                                                                                               |
| `:api-key-env`                                                                                   | string or list    | Variable name, or names, that hold the credential.                                                                      |
| `:model`, `:default-model`                                                                       | string            | The provider model and its fallback.                                                                                    |
| `:models`                                                                                        | list of strings   | Static model list for an endpoint that cannot be asked.                                                                 |
| `:headers`, `:query-params`                                                                      | list of pairs     | Extra headers and query parameters.                                                                                     |
| `:region`, `:project`, `:location`                                                               | string            | Cloud placement for Bedrock and Vertex.                                                                                 |
| `:max-tokens`, `:models-ttl-seconds`, `:cache-p`, `:cache-ttl`, `:betas`, `:timeout`, `:retries` | mixed             | Per-provider request options; `llm.md` lists them.                                                                      |

An individual quirk may be overridden on the row with `:auth-scheme`, `:auth-header`, `:chat-path`, `:models-path`, `:max-tokens-field`, `:system-role`, or `:reasoning-field`.
[Large language model backends](llm.md) lists the handlers, the profiles, and the quirks.

An operator row overrides the shipped row and the catalog row field by field, and a new `:id` adds one.
A row without `:id` is a configuration error, because a row that names no provider overrides nothing.
`config.example.cl` carries a full `:providers` example.

`:provider :custom` builds a row from the top-level `:llm` keys with no preset and no catalog entry.
`:base-url` is required for `:custom`.

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
A `config.cl` without `:provider` uses the detection order. It does not inherit the shipped `:provider :openai`.
Two exported keys need an explicit `:provider` or `:base-url`.
[Large language model backends](llm.md) lists the complete order.

An explicit `:provider` that names nothing is a configuration error, and the error names `enchiridion providers refresh` and a row under `:providers`.

An explicit `:api-key-env` names the variable for the selected provider, and without it the provider row names the variable (see [Secrets and .env](#secrets-and-env)).

## The :channels section

Every channel has one entry under `:channels`, and the entry merges over the shipped entry key by key.
An entry holds `(key value)` pairs, an explicit `nil` wins, and a channel with no entry is disabled.

### The :cli entry

| Key        | Type    | Default | Meaning                                                                                     |
| ---------- | ------- | ------- | ------------------------------------------------------------------------------------------- |
| `:enabled` | boolean | `t`     | Enabled state that the status file reports. `serve` builds the terminal channel regardless. |

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
A sectioned file that omits a budget key leaves that cap unset.
An unset cap is no cap, not a shipped default, because the reader takes the value it finds.
Write both keys when the file has a `:budget` section (see [Supervisor and heartbeat](supervisor.md)).

## The :sandbox section

| Key             | Type    | Default | Meaning                                              |
| --------------- | ------- | ------- | ---------------------------------------------------- |
| `:agent-uid`    | integer | `1000`  | User identifier for agent code and the broker in the container or a root-started checkout. |
| `:agent-gid`    | integer | `1000`  | Group identifier for the same processes.             |
| `:proc-hidepid` | integer | `2`     | Declared `/proc` hidepid value. No code reads it.    |

The supervisor runs as root in the container deployment and in a checkout started as root, and it holds the secrets.
The broker, the reload verification, and `--verify-plugin` use `:agent-uid` and `:agent-gid`.
A checkout started as the operator has no uid split: the supervisor, the broker child, and agent code run as that user.
[Deployment](deployment.md) covers the root setup.
No Lisp path reads `:proc-hidepid`, and the container entry point reads `ENCHIRIDION_HIDEPID` instead (see [Deployment](deployment.md)).

## The :memory section

| Key             | Type                              | Default                                                                        | Meaning                                                           |
| --------------- | --------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| `:db`           | string or `nil`                   | `nil`                                                                          | SQLite store path. `nil` selects `agents/default/memory.db`.      |
| `:block-limits` | property list of label to integer | `:persona 1200`, `:operator 800`, `:world 1500`, `:session 400`, `:ledger 250` | Declared character limit for each memory block. No code reads it. |

The store path can also be a pathname object.
The default is under the agent directory, which is on the state volume in the container.
No code reads the configured `:block-limits` value.
The effective limits come from `*default-block-limits*` in the memory module, which also holds `:bootstrap` with a limit of 300.
Raising a limit raises the fixed token cost of every prompt (see [Memory](memory.md)).

## The :sleep section

| Key                 | Type    | Default | Meaning                                           |
| ------------------- | ------- | ------- | ------------------------------------------------- |
| `:enabled`          | boolean | `t`     | Start the heartbeat schedule with the supervisor. |
| `:interval-seconds` | integer | `900`   | Seconds between sleep ticks.                      |

The supervisor takes `:enabled` as its heartbeat flag.
A value of `:interval-seconds` that is not a positive integer becomes 900 (see [Supervisor and heartbeat](supervisor.md)).

## Environment variables

| Variable                     | Meaning                                                                                       |
| ---------------------------- | --------------------------------------------------------------------------------------------- |
| `ENCHIRIDION_HOME`           | Home root for `agents/default/` and `run/`. Defaults to the current directory.                |
| `ENCHIRIDION_SOURCE`         | Project root for the second `config.cl` path and for `.env`.                                  |
| `ENCHIRIDION_SBCL`           | Lisp implementation for the broker and for plugin verification. The packaged wrapper sets it. |
| `ENCHIRIDION_GIT`            | Git executable. The packaged wrapper and the container set it. Defaults to `git` on `PATH`.  |
| `ENCHIRIDION_PROVIDERS_PATH` | Path of the provider catalog cache, instead of `run/providers.json`.                          |
| `OPENAI_API_KEY`             | OpenAI credential, unless `:api-key-env` names another variable.                              |
| `OPENCODE_API_KEY`           | OpenCode Go credential.                                                                       |
| `ANTHROPIC_API_KEY`          | Anthropic credential.                                                                         |
| `ENCHIRIDION_HTTP_TOKEN`     | Webhook bearer token, unless the `:http` entry names another variable.                        |
| `FLUXER_BOT_TOKEN`           | Fluxer bot token, unless the `:fluxer` entry names another variable.                          |

A credential variable is removed from the process environment after the loader reads it.

## Secrets and .env

The rule is one sentence: the file names the variable and the environment holds the value.
A secret written into `config.cl` is a secret in a file that people copy between hosts.

The loader reads the first secret file that exists, in this order, and reports `<current directory>/.env` when none does:

1. `/run/secrets/.env`, the container location
2. `<current directory>/.env`
3. `<project root>/.env`

Before it reads one pair, the loader checks the mode, and a file with the world read bit set is refused with exit status 2:

```text
Configuration is wrong at SECRETS.
/path/to/checkout/.env is mode #o644 and every uid can read it.
Run chmod 600 /path/to/checkout/.env.
```

Use mode 600.
A group-readable file passes, and so do an absent file and a mode that cannot be read.

- The `.env` format is one `NAME=VALUE` pair per line.
- A line that starts with `#` or `;`, a blank line, a line without `=`, and an empty name or value are skipped.
- A leading `export ` is accepted, and matching single or double quotes around the value are removed.

The loader reads every pair, then every variable name the configuration mentions and every provider key name from the process environment.

After the load, the process removes every loaded name and every credential-shaped variable from its own environment.
A child process inherits nothing, and a later read of `/proc` finds nothing, while the values stay in memory for the life of the process.

On a checkout started as the operator, the file stays on disk and agent code runs as the same user, so its file and shell tools can read `.env`.
The environment scrub keeps the values out of the child environment, but it is not a file system boundary.
The container deployment unlinks the file and runs agent code as another user, and that is the deployment with the secret guarantee (see [Deployment](deployment.md)).

The container copy at `/run/secrets/.env` is unlinked once its values are in memory, and the operator's checkout `.env` is never deleted.
A read-only bind mount refuses the unlink, which is a supported deployment, and the process prints one warning and continues:

```text
enchiridion: could not unlink /run/secrets/.env; the secrets file is still on disk.
```

The scrubber replaces a loaded value of at least eight characters with `[redacted]`, and also known credential shapes and role-named fields.
It runs on outbound text and on the status report fields.
[Large language model backends](llm.md) covers the three filters.

## Precedence

The later columns run from the highest priority to the lowest.

| Setting                              | First                             | Then                                  | Last                                   |
| ------------------------------------ | --------------------------------- | ------------------------------------- | -------------------------------------- |
| `config.cl` path                     | Current directory                 | Project root                          | Startup stops with exit 2              |
| Budget caps                          | `config.cl` value                 | No cap when the section omits the key | No config, no start                    |
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
| Startup stops before any command runs              | `config.cl` has a reader error or an unbalanced form | Correct the form, then run the command again                     |
| `No API key. Put NAME in .env or the environment.` | No credential was loaded for the selected provider   | Set `:api-key-env`, or put the provider row's variable in `.env` |

## See also

- [Getting started](getting-started.md): the first launch, the seed files, and the first session.
- [Commands](commands.md): flags, commands, exit statuses, and the `secrets` output.
- [Large language model backends](llm.md): provider resolution, the runtime catalog, handler ids, and the scrubber.
- [Channels](channels.md): the webhook routes, the Fluxer gateway, and the terminal channel.
