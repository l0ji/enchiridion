# Configuration

enchiridion reads one configuration file, `config.cl`. The file holds paths and
behavior only. It never holds a secret value. The tracked template
`config.example.cl` shows the format, and the operator copies that template to
`config.cl`. The program loads the file at start up and makes the value active
for the life of the process. When `config.cl` is absent, the program starts on
the defaults and needs no file at all.

## Where the program reads the file

The reader tries two places, in order:

1. `<current directory>/config.cl`
2. `<project root>/config.cl`

The current directory wins, because a checkout keeps `config.cl` beside the
code. Without `ENCHIRIDION_SOURCE`, the project root is the nearest directory
above the current one that holds `enchiridion.asd`.

`read-config` loads the file with the Lisp `load` function. Then it reads the
variable `enchiridion.user:*enchiridion-config*`. The file must set that
variable in the package `enchiridion.user`. An absent file, or a file that
binds no variable, means the defaults. That case is not an error.

A small file that names two keys:

```lisp
(in-package #:enchiridion.user)

(defparameter *enchiridion-config*
  '(:llm
    (:provider :opencode)
    (:model-primary "deepseek-v4.1-flash")
    (:api-key-env "OPENCODE_API_KEY")

    :channels
    (:http (:enabled t))
    (:fluxer (:enabled nil))))
```

## The two shapes

The reader accepts two shapes:

- The sectioned shape from `config.example.cl`. A section keyword comes first,
  then a list of `(key value)` entries.
- A flat property list. The tests and a small file use that shape.

The sectioned shape wins when both shapes could match. The top-level sections
are `:llm`, `:channels`, `:budget`, `:sandbox`, `:memory`, and `:sleep`.

Two readers exist, and the two are not interchangeable:

- `config-value` reads the `:llm` section, then a flat list.
- `config-section-value` reads one named section.

A key outside `:llm` that goes through `config-value` returns the default in
silence. The program uses `config-section-value` for the budget caps, the sleep
interval, the heartbeat flag, and the agent uid.

## The `:llm` section

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `:provider` | keyword or string | `:openai` | Select the provider. The code recognizes only `:openai` and `:opencode`. |
| `:backend` | keyword | `:openai` | Select the wire protocol. Only `:openai` has an implementation. |
| `:base-url` | string or `nil` | `nil` | Set the endpoint. The backend adds a trailing slash when the value has none. |
| `:model-primary` | string | `"deepseek-v4.1-flash"` | Set the model for reasoning turns. |
| `:model-cheap` | string | `"deepseek-v4.1-flash"` | Set the model for memory digests and compaction. |
| `:model-sleep` | string | `"deepseek-v4.1-flash"` | Set the model for the sleep agent. |
| `:api-key-env` | string | `"OPENAI_API_KEY"` | Name the variable that holds the API key. |

Each model tier starts equal to the cheap model. The key to raise for a
stronger turn is `:model-primary`.

### Provider selection

`detect-provider` reads the keys in this order:

1. `:provider`, when the value is `:openai` or `:opencode`.
2. A recognized `:base-url`. The text `opencode.ai` selects `:opencode`. The
   text `api.openai.com` selects `:openai`.
3. An `OPENAI_API_KEY` in the environment or in `.env`.
4. An `OPENCODE_API_KEY` in the environment or in `.env`.
5. Otherwise `:openai`. OpenAI wins a tie, because OpenAI is the default.

An unrecognized `:provider` value falls through to step 2. A local
OpenAI-compatible server matches no host in step 2, so the `:base-url` still
works and the key variable comes from the later steps.

`default-api-key-env` returns `:api-key-env` when the file sets that key.
Without it, the provider decides: `OPENAI_API_KEY` or `OPENCODE_API_KEY`.

### Backend selection

`resolve-backend` reads `:backend`, `:base-url`, `:model-primary`, and
`:api-key-env`. An explicit `:base-url` or `:model-primary` wins over the
provider default.

Only the `:openai` backend exists. The template names `:anthropic` and
`:litellm` as future protocols, and the current code refuses both. Any value
other than `:openai` stops the command with a configuration error at
`:backend`, and the error names the value.

## The `:channels` section

Each channel has one entry under `:channels`. An entry holds `(key value)`
pairs, and only the keys that channel understands belong in it.

`channel-config` merges the operator entry over the shipped entry, key by key.
An entry with only `:enabled` keeps the default bind address and port. An
explicit `nil` is a value and wins. A channel with no entry is disabled.

### `:cli`

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `:enabled` | boolean | `t` | Start the terminal channel. Only `serve` supervises it. |

### `:http`

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `:enabled` | boolean | `nil` | Start the webhook. |
| `:bind` | string | `"127.0.0.1"` | Set the bind address. |
| `:port` | integer | `8787` | Set the port. |
| `:token-env` | string | `"ENCHIRIDION_HTTP_TOKEN"` | Name the variable that holds the bearer token. |
| `:token` | string or `nil` | `nil` | Set a literal bearer token. The program registers the value with the scrubber. |
| `:max-body-bytes` | integer | `65536` | Set the number of request body bytes the webhook reads. |

A bind address other than loopback needs a token. The process refuses to start
without one. That check runs before the supervisor starts, so a bad flag costs
one line and an exit status.

The routes, the methods, and the reply shape live in [Channels](channels.md).

### `:fluxer`

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `:enabled` | boolean | `nil` | Start the Fluxer gateway channel. |
| `:allowed-users` | list of strings | `nil` | Set the user ids that may send a direct message. |
| `:token-env` | string | `"FLUXER_BOT_TOKEN"` | Name the variable that holds the bot token. |

Deny by default: an empty or absent allowlist means nobody may talk to the
agent.

## The `:budget` section

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `:max-tokens-per-tick` | integer | `4000` | Cap the tokens one heartbeat tick may spend. |
| `:max-tokens-per-day` | integer | `400000` | Cap the tokens one day may spend. |

The heartbeat starts no new phase when the spend reaches a cap. A phase
already under way finishes. The program reads both keys with
`config-section-value` and gives them to the agent at start up.

## The `:sandbox` section

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `:agent-uid` | integer | `1000` | Set the uid for the broker and for agent code. The supervisor runs as uid 0. |
| `:proc-hidepid` | integer | `2` | Record the hidepid value for `/proc`. |

The harness reads `:agent-uid` and passes the value to the broker. The harness
does not read `:proc-hidepid` and does not mount `/proc`. The deployment
supplies that mount. See [Deployment](deployment.md).

## The `:memory` section

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `:db` | string or `nil` | `nil` | Set the SQLite store path. A `nil` value selects the store beside the agent files. |
| `:block-limits` | plist of label to integer | see below | Record the character limit for each memory block. |

The default `:block-limits` plist holds `:persona 1200`, `:operator 800`,
`:world 1500`, `:session 400`, and `:ledger 250`.

The harness reads `:db` with `config-memory-db`. The block limits come from
`*default-block-limits*` in the memory module, and no code reads the
configured `:block-limits` value. The shipped limits match the values above.
The shipped table also holds `:bootstrap 300`, a label with no configured
entry. Raising a limit raises the fixed token cost of every prompt. See
[Memory](memory.md).

## The `:sleep` section

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `:enabled` | boolean | `t` | Start the heartbeat schedule with the supervisor. |
| `:interval-seconds` | integer | `900` | Set the seconds between sleep ticks. |

The supervisor reads `:enabled` as its heartbeat flag. `heartbeat-interval`
reads `:interval-seconds`. A value that is not a positive whole number becomes
900, because an interval of zero is a tick loop.

## The environment and `.env`

The `.env` file holds secret values. The configuration file holds the names of
the variables instead. That rule keeps a secret out of a file that a person
copies between hosts. The repository ignores `config.cl`. The tracked template
is the only copy of the format.

| Variable | Effect |
| --- | --- |
| `ENCHIRIDION_HOME` | Set the home root for the agent directory and `run/`. |
| `ENCHIRIDION_SOURCE` | Set the project root for a copy with no checkout above it. |
| `ENCHIRIDION_SBCL` | Set the SBCL binary the wrapper installed. |
| `OPENAI_API_KEY` | Hold the OpenAI key, when the file names this variable. |
| `OPENCODE_API_KEY` | Hold the OpenCode Go key, when the file names this variable. |
| `ENCHIRIDION_HTTP_TOKEN` | Hold the webhook bearer token by default. |
| `FLUXER_BOT_TOKEN` | Hold the Fluxer bot token by default. |

The program reads the secret file in this order:

1. `/run/secrets/.env`, the container location.
2. `<current directory>/.env`.
3. `<project root>/.env`.

Then the loader reads every name the configuration names, and the program
removes each name from its own environment. A child process inherits nothing.
The value stays in memory for the life of the process.

The scrubber replaces a loaded value with `[redacted]` in every text path. It
also replaces known key shapes, such as a `Bearer` token or an `sk-` key. The
literal filter ignores a value shorter than eight characters. A short value
would redact most of the transcript. `secrets` prints the loaded names and
their sources. It never prints a value.

A literal `:token` in the `:http` entry is the one secret-shaped value the
file can hold. The template allows it for a loopback bind and for tests. The
program registers that value with the scrubber.

## Related

- [Getting started](getting-started.md)
- [Commands](commands.md)
- [Models and secrets](llm.md)
- [Channels](channels.md)
- [Supervisor and heartbeat](supervisor.md)
- [Memory](memory.md)
- [Deployment](deployment.md)
