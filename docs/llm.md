# Models and secrets

The kernel calls one generic function, `complete`, and reads a `completion`. It
never asks which backend answered. One backend exists now, the OpenAI-compatible
client, and it serves OpenAI, OpenCode Go, and a local server with the same wire
shape. Three model tiers decide which model a piece of work uses. A separate
module loads every secret into memory. It scrubs each loaded value, and each known
key shape, out of text before that text reaches a model or a channel.

## The provider protocol

The package `enchiridion.llm` defines three generic functions. A backend
implements all three.

| Generic function     | Returns                                                |
| -------------------- | ------------------------------------------------------ |
| `complete`           | a `completion` for a list of messages                  |
| `model-capabilities` | `:tools`, `:cache`, `:streaming`, `:cache-breakpoints` |
| `backend-name`       | a short name for logs                                  |

`complete` receives the backend, `messages`, and the keywords `model`, `tools`,
and `budget`. It returns a `completion`. `backendp` answers whether an object
implements all three operations. SBCL 2.5.4 has no `defprotocol`, so the check
calls `find-method` for `complete`, `model-capabilities`, and `backend-name`.

A `message` holds a role, content, a tool call id, and a list of tool calls. Four
constructors build one: `system-message`, `user-message`, `assistant-message`,
and `tool-message`. The role is user, assistant, system, or tool. A `tool-call`
holds an id, a name, and the arguments as JSON text, because the model writes the
arguments and the tool layer validates them.

A `completion` holds the reply text, the tool calls, the model that answered, the
stop reason, and four token counts. `completion-total-tokens` adds input and
output only. A cache read is already part of the prompt count, so the function
does not add it twice.

## Backends

`:openai` is the only backend with an implementation. `resolve-backend` accepts
`:backend :openai` and signals `configuration-error` with `:key :backend` for
any other value. `config.example.cl` names `:anthropic` and `:litellm` in
comments, but no code implements either one, so a config that selects one does
not start.

`openai-backend` builds the connection.

| Keyword       | Default                      | Effect                                                                       |
| ------------- | ---------------------------- | ---------------------------------------------------------------------------- |
| `:base-url`   | `https://api.openai.com/v1/` | the endpoint prefix, and the builder adds a trailing slash when it is absent |
| `:api-key`    | `""`                         | the bearer token                                                             |
| `:model`      | `*model-primary*`            | the default model for the connection                                         |
| `:session-id` | a new 32 character id        | the routing and prompt cache key                                             |
| `:timeout`    | 60                           | the read timeout and the connect timeout in seconds                          |
| `:retries`    | 2                            | extra attempts that a 429 or a 5xx earns                                     |

`new-session-id` returns 32 hexadecimal characters. One connection reuses one
session id for every turn. `model-capabilities` reports `:tools` true, `:streaming`
true, `:cache` true, and `:cache-breakpoints` nil. Nothing sends a cache
breakpoint yet, and the backend reports the capability as absent rather than as
present and ignored.

## Providers

Two providers speak the OpenAI shape. The plist `+provider-defaults+` holds the
three facts that differ.

| Provider    | Base URL                        | Default model         | Key variable       |
| ----------- | ------------------------------- | --------------------- | ------------------ |
| `:openai`   | `https://api.openai.com/v1/`    | `gpt-5.6-luna`        | `OPENAI_API_KEY`   |
| `:opencode` | `https://opencode.ai/zen/go/v1` | `deepseek-v4.1-flash` | `OPENCODE_API_KEY` |

`detect-provider` picks one in this order. It reads an explicit `:provider`, then
a base URL that `provider-from-base-url` recognizes. It then reads a present
`OPENAI_API_KEY`, a present `OPENCODE_API_KEY`, and finally `:openai`. OpenAI wins
a tie, because it is the default. `provider-from-base-url` matches `opencode.ai`
and `api.openai.com`. A local server matches neither, and its config still works:
the base URL is used as written.

`default-api-key-env` returns the variable name for the active provider, unless
config.cl sets `:api-key-env`. `backend-api-key` reads the value from the secret
loader first and from the process environment second. The loader runs before
provider detection, so a key in `.env` selects a provider the same way an
exported variable does.

`resolve-backend` lets an explicit `:base-url`, `:model-primary`, or
`:api-key-env` win over the provider defaults. The kernel calls `complete` with a
model name, and it never reads the provider.

## Model tiers

Three tiers name the work, not the model. Each tier maps to one model name.

| Tier       | Work                          | Default model         |
| ---------- | ----------------------------- | --------------------- |
| `:primary` | a reasoning turn              | `deepseek-v4.1-flash` |
| `:cheap`   | memory digests and compaction | `deepseek-v4.1-flash` |
| `:sleep`   | the sleep agent               | `*model-cheap*`       |

`*model-primary*` and `*model-cheap*` both hold `deepseek-v4.1-flash`.
`*model-sleep*` holds nil, and `sleep-model` answers `*model-cheap*` when it does,
so the sleep agent runs on the cheap model by default. The names are
`primary-model`, `cheap-model`, and `sleep-model`, because a function called
`sleep` in a package that uses `CL` is a package lock error.

`tier` normalizes a name to `:primary`, `:cheap`, or `:sleep`. An unknown name
becomes `:primary` rather than a signal, and nil means `:primary`. `model-for-tier`
returns the model name for a tier.

`enchiridion:model-for` is the config reader. It reads `:model-primary`,
`:model-cheap`, or `:model-sleep` from the `:llm` section of config.cl, and it
falls back to the shipped defaults.

Where each tier runs:

| Caller            | Tier                                                |
| ----------------- | --------------------------------------------------- |
| a kernel turn     | the model the caller passes, or the backend default |
| `run-sleep-pass`  | `:sleep`                                            |
| `compact-session` | `:cheap`                                            |

## Request and reply

`completion-request` builds the request body as JSON text. The object holds
`model`, `stream` false, and `messages`. With tools, it adds `tools` and
`tool_choice` `"auto"`. `message->request-message` adds `tool_call_id` to a tool
message and `tool_calls` to an assistant message that asked for any. It adds
neither key to any other message, because some servers refuse an unexpected field.

`parse-completion` reads the first choice and fills the completion.

| Completion slot      | Source field                                |
| -------------------- | ------------------------------------------- |
| `input-tokens`       | `usage.prompt_tokens`                       |
| `output-tokens`      | `usage.completion_tokens`                   |
| `cache-read-tokens`  | `usage.prompt_tokens_details.cached_tokens` |
| `cache-write-tokens` | `usage.cache_creation_input_tokens`         |

A reply with no choices signals `backend-error`, because an empty completion and
a model that said nothing are the same thing to the caller. `parse-json` turns an
object into a plist with keyword keys, an array into a list, and JSON null into
nil. `provider-error-message` reads the provider's own error text, and it answers
one short line when the reply is not JSON at all.

## Transport and retries

`http-post` sends one POST to `base-url` plus `chat/completions`. It uses bearer
authentication, a JSON content type, the user agent `enchiridion/0.1.0`, and the
`x-opencode-session` header. OpenCode Go needs that header as its routing key and
its prompt cache key, and a generic server ignores it. The special
`*http-post-function*` holds the transport, so a test can replace it without a
network.

`send-completion` builds the body once and calls the transport. It repeats a 429
and any 5xx, up to `retries` extra attempts, and it waits `*retry-delay*` seconds
times the attempt number. `*retry-delay*` is 2. Any other 4xx becomes a
`transport-error` at once, with `:status` and the provider's own error text. A
wrong key or a wrong model does not become right by a second send.

## Token accounting

The kernel records each completion as a `spend-row` on the agent, and it writes
the same numbers to the `usage` table. The ledger keeps four provider numbers
apart: input, output, cache read, and cache write.

| Function             | Returns                                                  |
| -------------------- | -------------------------------------------------------- |
| `record-spend`       | one `spend-row` on the agent                             |
| `spend`              | every row, oldest first                                  |
| `spend-since`        | the rows from an index onwards                           |
| `spend-summary`      | the rows summed, with the last model and the round count |
| `spend-total`        | the tokens in one window                                 |
| `budget-exhausted-p` | true when the spend reached a cap                        |
| `persist-usage`      | one `usage` row in the store                             |

`spend-since` takes an index. A caller records `(length (spend agent))` before a
turn. It asks for the tail after the turn, because one turn with tool calls makes
several model calls. The completion that comes back is only the last of them.
`spend-total` sums the whole in-memory ledger for window `:tick`, and the last
86400 seconds for window `:day`. `budget-exhausted-p` reads
`:max-tokens-per-tick` or `:max-tokens-per-day` from the agent budget plist. A
missing cap never stops the work, so unattended work has no limit until the
operator sets one.

The store sums the same rows for a report. `usage-summary` groups by `:model`,
`:channel`, or `:day`, and `usage-total-since` sums from a time. The `:day` group
uses the local calendar day of the row. The budget window stays the rolling
twenty-four hours, because a burst across midnight must count in full.

`estimate-tokens` gives the prompt a cheap estimate of one token per four
characters. The ledger uses the provider numbers, so the estimate never changes a
bill.

## Secrets

`secrets-file` returns the file to read. The container path `/run/secrets/.env`
wins when it exists. Otherwise the function tries each directory in order, and the
first `.env` wins. `main.cl` passes the current directory and then the project
root, because the binary can live in a store path.

`load-secrets` reads the file and then the named environment variables.
`parse-env-line` reads one `NAME=VALUE` line. It skips a blank line, a comment
that starts with `#` or `;`, and a malformed line. It also removes a matching
pair of quotes. `load-secrets-from` reads a stream. A malformed line never stops
the start, so one typo in `.env` costs one secret and not the run.

| Function           | Returns                                            |
| ------------------ | -------------------------------------------------- |
| `register-secret`  | the name, after it stores the value and the source |
| `secret-present-p` | true when the name is loaded                       |
| `secret-value`     | the value, or nil                                  |
| `secret-source`    | `:file`, `:env`, or `:argument`                    |
| `secret-names`     | every loaded name, sorted                          |
| `clear-secrets`    | nothing, after it forgets every value              |

`register-secret` ignores an empty value and a value that is not a string. A new
secret clears the combined pattern, so the next scrub rebuilds it.
`*loaded-secrets*` holds the values and `*loaded-sources*` holds the source note,
and neither table prints a value.

`configured-secret-names` collects the `:api-key-env`, the Fluxer `:token-env`,
and the webhook `:token-env` from config.cl. `load-configured-secrets` in
`main.cl` loads those names, then unsets each one from the process environment.
The value stays in memory for the life of the process, and a child process
inherits nothing.

`secret-value` reads a value. Four call sites read one: `main.cl` twice,
`backend-api-key` in the OpenAI client, and the Fluxer channel. The scrubber does
not call it, because `pattern` reads `*loaded-secrets*` directly. Nothing prints a
value, and `enchiridion secrets` prints a name and its source.

## The scrubber

`scrub` replaces every match with `[redacted]`. Three filters feed one combined
pattern.

| Filter  | What it matches                                                                                              |
| ------- | ------------------------------------------------------------------------------------------------------------ |
| Literal | a loaded value of at least `*minimum-secret-length*` characters                                              |
| Shape   | `Bearer` tokens, `sk-` keys, `ghp_` tokens, `xox` tokens, JWTs, and `key=value` pairs that name a credential |
| Role    | a field named token, secret, password, or api_key, whatever the value looks like                             |

`*minimum-secret-length*` is 8. A shorter loaded value never reaches the literal
filter, because one short secret would turn the whole transcript into
`[redacted]`.

The literal parts come first and longest first, so a short secret cannot match the
head of a longer one. `pattern` rebuilds the combined pattern when the number of
loaded secrets changes. `scrubber` always returns a scanner, because the shape
patterns exist even when nothing is loaded. `+role-names+` holds the field names
for the role filter, and it includes token, secret, password, api_key,
api_secret, credentials, authorization, and the private key.

`scrub-object` recurses through strings, conses, vectors, and hash tables.
`scrub-tree` does the same and also replaces the value of a role-named field
outright. That filter catches a credential this process never loaded, which is the
prompt injection case. `seal` and `unseal` turn the replacement off and on, and
`sealed-p` reports the state.

Where the scrubber runs: the kernel scrubs the compiled prompt and the operator
text before a turn. Every tool result becomes scrubbed text. The store scrubs
every string on the way to a column. A non-string comes back unchanged, because a
scrubber that signals would take the agent down with it.

## Related

- [Memory](memory.md)
- [Configuration](configuration.md)
- [Commands](commands.md)
- [Supervisor and heartbeat](supervisor.md)
- [Testing](testing.md)
