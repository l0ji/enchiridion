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

| Key              | Type              | Default                 | Effect                                                                             |
| ---------------- | ----------------- | ----------------------- | ---------------------------------------------------------------------------------- |
| `:provider`      | keyword or string | `:openai`               | Select a provider. Any shipped, catalog or `:providers` id, or `:custom`. A value that names nothing is a configuration error, not a fallback. |
| `:backend`       | keyword           | `:openai`               | Override the wire protocol: `:openai` or `:anthropic`.                             |
| `:base-url`      | string or `nil`   | `nil`                   | Set the endpoint. The backend adds a trailing slash when the value has none.       |
| `:model-primary` | string            | `"deepseek-v4.1-flash"` | Set the model for reasoning turns.                                                 |
| `:model-cheap`   | string            | `"deepseek-v4.1-flash"` | Set the model for memory digests and compaction.                                   |
| `:model-sleep`   | string            | `"deepseek-v4.1-flash"` | Set the model for the sleep agent.                                                 |
| `:api-key-env`   | string or `nil`   | `nil`                   | Name the variable that holds the API key. `nil` means the provider row decides.     |
| `:max-tokens`    | integer           | `4096`                  | Cap one reply on the Messages API. The OpenAI-shaped wire ignores this key.        |
| `:providers`     | list of rows      | three shipped rows      | Define or override providers by id. See below.                                     |
| `:providers-url` | string            | `https://models.dev/api.json` | Where the runtime provider catalog is fetched from.                          |
| `:providers-ttl-seconds` | integer   | `86400`                 | How long the cached provider index stays fresh. It is compared at start up against the cache's age. |
| `:models-ttl-seconds`    | integer   | `86400`                 | How long one provider's cached model list stays fresh.                             |
| `:offline`       | boolean           | `nil`                   | `t` stops every start-up fetch, the model list included. `providers refresh` and `providers models ID` still run when asked. |
| `:region`        | string or `nil`   | `nil`                   | Bedrock region; `AWS_REGION` or `AWS_DEFAULT_REGION` is used when this is nil.      |
| `:project`       | string or `nil`   | `nil`                   | Vertex project; `GOOGLE_VERTEX_PROJECT` is used when this is nil.                  |
| `:location`      | string or `nil`   | `nil`                   | Vertex location; `GOOGLE_VERTEX_LOCATION` is used when this is nil.                |
| `:headers`       | alist             | `nil`                   | Extra request headers for the selected provider.                                   |
| `:query-params`  | alist             | `nil`                   | Extra query parameters for the selected provider.                                  |
| `:profile`       | keyword           | `nil`                   | Force a quirk profile for the selected provider.                                   |

Each model tier starts equal to the cheap model. The key to raise for a
stronger turn is `:model-primary`.

The keys `:providers-ttl-seconds`, `:models-ttl-seconds`, `:offline`,
`:headers`, `:query-params` and `:profile` are not specific to
`:provider :custom`: each one works for whichever provider is selected.
`:headers`, `:query-params` and `:profile` are merged into the selected
provider's row, and a value written in the row wins over the top-level one.

### Provider rows

Provider knowledge is generated at run time from models.dev and cached under
`run/`; nothing about a provider is committed to the tree except the three rows
in `config.cl` (`:openai`, `:opencode`, `:anthropic`), which ship as
configuration defaults so the default path needs no catalog and no network. A
row defines or overrides one provider, and a row has the same shape wherever it
is written, so the three shipped rows and an operator's row cannot drift apart.

```lisp
(:provider :my-llm)
(:providers
 ((:id my-llm :name "My LLM" :api :openai-chat :profile :openai
   :base-url "https://llm.internal/v1/"
   :api-key-env "MY_LLM_KEY"
   :headers (("X-Tenant" "acme"))
   :models ("m-1" "m-2"))
  ;; Override the catalog's row for a provider it knows.
  (:id deepseek :api-key-env "DEEPSEEK_KEY")
  ;; Amazon Bedrock and Google Vertex.
  (:id amazon-bedrock :api :bedrock-invoke :profile :bedrock-invoke
   :region "us-east-1")
  (:id google-vertex-anthropic :api :vertex-anthropic :profile :vertex
   :project "my-project" :location "us-east5")))
```

| Row key        | Type              | Effect                                                                    |
| -------------- | ----------------- | ------------------------------------------------------------------------- |
| `:id`          | keyword or string | The provider id. Required.                                                |
| `:name`        | string            | Display name.                                                             |
| `:api`         | keyword           | The handler: `:openai-chat`, `:anthropic-messages`, `:bedrock-invoke`, `:bedrock-messages`, `:vertex-anthropic`. |
| `:profile`     | keyword           | The quirk profile. See [Models and secrets](llm.md).                       |
| `:base-url`    | string            | The endpoint.                                                             |
| `:api-key-env` | string or list    | The variable name, or names, that hold the credential.                    |
| `:model`       | string            | The default model for this provider.                                      |
| `:models`      | list of strings   | A static model list, when the endpoint cannot be asked.                   |
| `:headers`, `:query-params` | alist  | Extra headers and query parameters. A header may be written `("Name" "value")` or `("Name" . "value")`; both reach the wire identically. |
| `:region`, `:project`, `:location` | string | Cloud placement for Bedrock and Vertex.                            |

An individual quirk may also be overridden directly on the row: `:auth-scheme`,
`:auth-header`, `:chat-path`, `:models-path`, `:max-tokens-field`,
`:system-role`, `:reasoning-field`.

`:provider :custom` is the generic case: a provider with no preset at all, built
from the top-level `:llm` keys (`:backend`, `:base-url`, `:api-key-env`,
`:headers`, `:query-params`, `:model-*`). `:base-url` is required.

### Provider selection

`detect-provider` reads the keys in this order:

1. An explicit `:provider`. A value that names nothing is a configuration error:
   it says to run `providers refresh` or to add a `:providers` row. It does not
   fall through to base-URL detection.
2. A recognized `:base-url`. `opencode.ai`, `api.anthropic.com` and
   `api.openai.com` are matched first; then any provider in the cached catalog
   whose `api` host matches.
3. An `OPENAI_API_KEY` in the environment or in `.env`.
4. An `OPENCODE_API_KEY`, then an `ANTHROPIC_API_KEY`.
5. Exactly one provider in the cached catalog whose `env` variable is present.
6. Otherwise `:openai`. OpenAI wins a tie, because OpenAI is the default.

A local OpenAI-compatible server matches none of the hosts in step 2, so its
`:base-url` is used as written and the key variable comes from the later steps.
An explicit `:provider` that names nothing never reaches step 2: it stops the
command with that error.

`default-api-key-env` returns `:api-key-env` when the file sets that key.
Without it, the provider row decides. `provider-key-names` returns the
configured name, every shipped and configured row's variables, the selected
provider's variables, and the cached providers' credential-shaped variables; it
deliberately leaves out names such as `AWS_ACCESS_KEY_ID` unless that provider
is the one selected, because a name in this list is read from `.env` and then
removed from the process environment.

### The runtime catalog

Provider knowledge comes from [models.dev](https://models.dev) at run time and
is cached under `run/`, never in the tree apart from the three rows in
`config.cl` that ship as configuration defaults. `enchiridion providers refresh`
fetches and rewrites the cache by hand. The commands that run a turn (`ask`,
`chat`, `serve`) also refresh it at context build, once per process: the cached
provider index when it is missing or older than `:providers-ttl-seconds`, and
the selected provider's model list when a key is present and its cache is older
than `:models-ttl-seconds`. Inspection commands (`help`, `version`, `secrets`,
`providers list`, `tools`, …) never fetch and never write a cache.
`:providers-url` changes the source. `:offline t` stops every start-up fetch,
the model list included, while `providers refresh` and `providers models ID`
still run because the operator asked for them. Every failure is one warning
line: a turn still runs on the shipped rows and the configured models.

### Backend selection

`resolve-backend` reads `:backend`, `:base-url`, `:model-primary`,
`:api-key-env`, and `:max-tokens`, then asks the provider row for its handler.
An explicit `:base-url` or `:model-primary` wins over the row.

Two handlers cover every vendor that speaks one of the two shared schemas: the
chat-completions handler (`:openai`) and the Messages handler (`:anthropic`).
Two more cover APIs only one cloud offers: `:bedrock-invoke` and
`:bedrock-messages` for Amazon Bedrock, and `:vertex-anthropic` for Claude on
Google Vertex. `:backend :anthropic` selects the Anthropic request shape and the
`:anthropic` row together, so an OpenAI key in the environment cannot pair the
Anthropic endpoint with a chat-completions request. `:provider :anthropic` with
no `:backend` does the same.

Any other value stops the command with a configuration error at `:backend`, and
the error names the value. `:max-tokens` caps one Anthropic reply; it is not
derived from the budget, which caps what a day may spend.

## The `:channels` section

Each channel has one entry under `:channels`. An entry holds `(key value)`
pairs, and only the keys that channel understands belong in it.

`channel-config` merges the operator entry over the shipped entry, key by key.
An entry with only `:enabled` keeps the default bind address and port. An
explicit `nil` is a value and wins. A channel with no entry is disabled.

### `:cli`

| Key        | Type    | Default | Effect                                                  |
| ---------- | ------- | ------- | ------------------------------------------------------- |
| `:enabled` | boolean | `t`     | Start the terminal channel. Only `serve` supervises it. |

### `:http`

| Key               | Type            | Default                    | Effect                                                                         |
| ----------------- | --------------- | -------------------------- | ------------------------------------------------------------------------------ |
| `:enabled`        | boolean         | `nil`                      | Start the webhook.                                                             |
| `:bind`           | string          | `"127.0.0.1"`              | Set the bind address.                                                          |
| `:port`           | integer         | `8787`                     | Set the port.                                                                  |
| `:token-env`      | string          | `"ENCHIRIDION_HTTP_TOKEN"` | Name the variable that holds the bearer token.                                 |
| `:token`          | string or `nil` | `nil`                      | Set a literal bearer token. The program registers the value with the scrubber. |
| `:max-body-bytes` | integer         | `65536`                    | Set the number of request body bytes the webhook reads.                        |

A bind address other than loopback needs a token. The process refuses to start
without one. That check runs before the supervisor starts, so a bad flag costs
one line and an exit status.

The routes, the methods, and the reply shape live in [Channels](channels.md).

### `:fluxer`

| Key              | Type            | Default              | Effect                                           |
| ---------------- | --------------- | -------------------- | ------------------------------------------------ |
| `:enabled`       | boolean         | `nil`                | Start the Fluxer gateway channel.                |
| `:allowed-users` | list of strings | `nil`                | Set the user ids that may send a direct message. |
| `:token-env`     | string          | `"FLUXER_BOT_TOKEN"` | Name the variable that holds the bot token.      |

Deny by default: an empty or absent allowlist means nobody may talk to the
agent.

## The `:budget` section

| Key                    | Type    | Default  | Effect                                       |
| ---------------------- | ------- | -------- | -------------------------------------------- |
| `:max-tokens-per-tick` | integer | `4000`   | Cap the tokens one heartbeat tick may spend. |
| `:max-tokens-per-day`  | integer | `400000` | Cap the tokens one day may spend.            |

The heartbeat starts no new phase when the spend reaches a cap. A phase
already under way finishes. The program reads both keys with
`config-section-value` and gives them to the agent at start up.

## The `:sandbox` section

| Key             | Type    | Default | Effect                                                                       |
| --------------- | ------- | ------- | ---------------------------------------------------------------------------- |
| `:agent-uid`    | integer | `1000`  | Set the uid for the broker and for agent code. The supervisor runs as uid 0. |
| `:proc-hidepid` | integer | `2`     | Record the hidepid value for `/proc`.                                        |

The harness reads `:agent-uid` and passes the value to the broker. The harness
does not read `:proc-hidepid` and does not mount `/proc`. The deployment
supplies that mount. See [Deployment](deployment.md).

## The `:memory` section

| Key             | Type                      | Default   | Effect                                                                             |
| --------------- | ------------------------- | --------- | ---------------------------------------------------------------------------------- |
| `:db`           | string or `nil`           | `nil`     | Set the SQLite store path. A `nil` value selects the store beside the agent files. |
| `:block-limits` | plist of label to integer | see below | Record the character limit for each memory block.                                  |

The default `:block-limits` plist holds `:persona 1200`, `:operator 800`,
`:world 1500`, `:session 400`, and `:ledger 250`.

The harness reads `:db` with `config-memory-db`. The block limits come from
`*default-block-limits*` in the memory module, and no code reads the
configured `:block-limits` value. The shipped limits match the values above.
The shipped table also holds `:bootstrap 300`, a label with no configured
entry. Raising a limit raises the fixed token cost of every prompt. See
[Memory](memory.md).

## The `:sleep` section

| Key                 | Type    | Default | Effect                                            |
| ------------------- | ------- | ------- | ------------------------------------------------- |
| `:enabled`          | boolean | `t`     | Start the heartbeat schedule with the supervisor. |
| `:interval-seconds` | integer | `900`   | Set the seconds between sleep ticks.              |

The supervisor reads `:enabled` as its heartbeat flag. `heartbeat-interval`
reads `:interval-seconds`. A value that is not a positive whole number becomes
900, because an interval of zero is a tick loop.

## The environment and `.env`

The `.env` file holds secret values. The configuration file holds the names of
the variables instead. That rule keeps a secret out of a file that a person
copies between hosts. The repository ignores `config.cl`. The tracked template
is the only copy of the format.

| Variable                 | Effect                                                       |
| ------------------------ | ------------------------------------------------------------ |
| `ENCHIRIDION_HOME`       | Set the home root for the agent directory and `run/`.        |
| `ENCHIRIDION_SOURCE`     | Set the project root for a copy with no checkout above it.   |
| `ENCHIRIDION_SBCL`       | Set the SBCL binary the wrapper installed.                   |
| `OPENAI_API_KEY`         | Hold the OpenAI key, when the file names this variable.      |
| `OPENCODE_API_KEY`       | Hold the OpenCode Go key, when the file names this variable. |
| `ANTHROPIC_API_KEY`      | Hold the Anthropic key, when the file names this variable.   |
| `ENCHIRIDION_HTTP_TOKEN` | Hold the webhook bearer token by default.                    |
| `FLUXER_BOT_TOKEN`       | Hold the Fluxer bot token by default.                        |

The program reads the secret file in this order:

1. `/run/secrets/.env`, the container location.
2. `<current directory>/.env`.
3. `<project root>/.env`.

Then the loader reads every name the configuration names and every provider key
variable `provider-key-names` returns, and the program removes each name from its
own environment. A child process inherits nothing. The value stays in memory for
the life of the process.

The scrubber replaces a loaded value with `[redacted]` in every text path. It
also replaces known key shapes, such as a `Bearer` token or an `sk-` key. The
literal filter ignores a value shorter than eight characters. A short value
would redact most of the transcript. `secrets` prints the loaded names, their
sources, the resolved file, its mode, and whether the file is still present; it
never prints a value. A world-readable `.env` stops the supervisor at start up,
and the container copy at `/run/secrets/.env` is unlinked once the values are in
memory; a checkout `.env` is never deleted.

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
