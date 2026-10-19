# Models and secrets

The kernel calls one generic function, `complete`, and reads a `completion`. It
never asks which backend answered. Two generic handlers exist, each owning one
wire schema that many vendors speak: the OpenAI chat-completions handler serves
OpenAI, OpenCode Go, Azure, OpenRouter, Groq and the long tail; the Anthropic
Messages handler serves Anthropic's own endpoint and the Anthropic-shaped
gateways. Two vendor-only handlers speak APIs only one cloud offers: Amazon
Bedrock's InvokeModel path and Google Vertex's `:rawPredict` path. Three model
tiers decide which model a piece of work uses. A separate module loads every
secret into memory. It scrubs each loaded value, and each known key shape, out
of text before that text reaches a model or a channel.

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
output only. A cache read is already part of the prompt count, and every backend
stores the input count provider-normalised with the cache counts folded in, so the
function does not add either one twice.

## Handlers and the adapter registry

A provider names a **handler**, and a handler is one wire schema. The registry
lives in `src/enchiridion/llm/registry.cl`; each handler file registers itself
as it loads, so nothing in the core names a vendor.

| Handler             | File           | Schema      | Used by                                                        |
| ------------------- | -------------- | ----------- | -------------------------------------------------------------- |
| `:openai-chat`      | `openai.cl`    | `:openai`   | OpenAI, OpenCode Go, Azure, OpenRouter, Groq, local servers, … |
| `:anthropic-messages` | `anthropic.cl` | `:anthropic` | Anthropic's endpoint and Anthropic-shaped gateways          |
| `:bedrock-invoke`   | `bedrock.cl`   | `:anthropic` | Amazon Bedrock's `/model/{id}/invoke` path                    |
| `:bedrock-messages` | `bedrock.cl`   | `:anthropic` | Amazon Bedrock's native `/anthropic/v1/messages` endpoint     |
| `:vertex-anthropic` | `vertex.cl`    | `:anthropic` | Claude on Google Vertex, `:rawPredict`                        |

Bedrock and Vertex reuse the Messages request and reply builders from
`anthropic.cl` and own only their transport, path, auth and version placement.

`resolve-backend` picks a handler from the selected provider and calls its
builder. An unsupported provider is a `configuration-error` that names the
provider, its models.dev `npm` package, and the fix (`:api` plus `:base-url`
in a `:providers` row). `:backend` still overrides the route by hand;
`:backend :anthropic` with no `:provider` selects the Anthropic row, and any
other value is a `configuration-error` at `:backend`.

| Keyword       | Wire shape        | Default endpoint prefix      |
| ------------- | ----------------- | ---------------------------- |
| `:openai`     | chat completions  | `https://api.openai.com/v1/` |
| `:anthropic`  | the Messages API  | `https://api.anthropic.com/` |

## The runtime catalog

Provider knowledge is **not committed to the tree**, with one exception: the
three rows in `config.cl` (`:openai`, `:opencode`, `:anthropic`) ship as
configuration defaults, so the default path works with no catalog and no
network. Everything else about a provider is generated at run time from
[models.dev](https://models.dev):

- `enchiridion providers refresh` fetches `https://models.dev/api.json`
  (`:providers-url`), trims it to the provider index, and writes
  `run/providers.json`. The trim keeps each provider's `id`, `name`, `npm`,
  `env`, `api` and `doc`, maps `npm` to a protocol, and computes a default
  model. The trim decides the protocol only; the provider table in
  `src/enchiridion/llm/providers.cl` (`+npm-adapters+`) maps that protocol, and
  a provider id, to the handler that speaks it.
- The trim's default-model rule: among the provider's models that support tool
  calling, the newest `release_date` wins, tied by the smallest id; otherwise
  the newest model overall; otherwise the smallest id.
- The cache lives under `run/`, which git ignores and the Nix source filter
  excludes. No fetched provider data ever enters the store.
- A missing or corrupt cache is not an error. The three shipped rows in
  `config.cl` (`:openai`, `:opencode`, `:anthropic`) still work, and anything
  else reports that `providers refresh` has not run.
- `${ENV_VAR}` inside a models.dev `api` value is expanded from the loaded
  secret table, which is how providers whose endpoint contains an account id
  (Cloudflare Workers AI, Snowflake Cortex) work without a special case.
- Azure is reachable from the catalog: `@ai-sdk/azure` maps to the default
  endpoint `https://${AZURE_RESOURCE_NAME}.openai.azure.com/`, with
  `${AZURE_RESOURCE_NAME}` expanded from the loaded secret table. When that
  variable is absent the row has no endpoint, and the error says to set
  `:base-url`.
- `:providers-ttl-seconds` (default 86400) is live: it is compared at start up
  to decide when the cached provider index is stale. The commands that run a
  turn (`ask`, `chat`, `serve`) refresh at context build, once per process: the
  catalog when the cached copy is missing or older than the TTL, and the
  selected provider's own model list when a key is present and its cache is
  stale. Inspection commands (`help`, `version`, `secrets`, `providers list`,
  `tools`, …) never fetch and never write a cache. `:offline t` stops all of
  that, the model list included. The two exceptions are the operator's own act
  and still run: `enchiridion providers refresh` and `enchiridion providers
  models ID`.

## Provider rows

A row is the unit of configuration. The three shipped rows are configuration
defaults in `config.cl`, and an operator row of the same shape overrides them
field by field. A row whose `:id` matches a models.dev provider overrides that
provider; a new `:id` adds one.

```lisp
(:providers
 ((:id my-llm :name "My LLM" :api :openai-chat :profile :openai
   :base-url "https://llm.internal/v1/"
   :api-key-env "MY_LLM_KEY"
   :headers (("X-Tenant" "acme"))
   :models ("m-1" "m-2"))
  (:id deepseek :api-key-env "DEEPSEEK_KEY")
  (:id amazon-bedrock :api :bedrock-invoke :profile :bedrock-invoke
   :region "us-east-1")))
```

| Row key           | Effect                                                                    |
| ----------------- | ------------------------------------------------------------------------- |
| `:id`             | The provider id, required                                                 |
| `:name`           | Display name                                                              |
| `:api`            | The handler id                                                            |
| `:profile`        | The quirk profile to apply                                                |
| `:base-url`       | The endpoint                                                              |
| `:api-key-env`    | One variable name, or a list (Bedrock needs several)                      |
| `:model`          | The default model for this provider                                       |
| `:models`         | A static model list, when the endpoint cannot be asked                    |
| `:headers`, `:query-params` | Extra request headers and query parameters                      |
| `:region`, `:project`, `:location` | Cloud placement for Bedrock and Vertex                     |

Any dialect field may be overridden directly on the row: `:auth-scheme`,
`:auth-header`, `:chat-path`, `:models-path`, `:max-tokens-field`,
`:system-role`, `:reasoning-field`. That is what makes a one-off endpoint a
configuration line rather than a patch.

A header may be written either as `("Name" "value")` or as
`("Name" . "value")`; both reach the wire identically.

`:provider :custom` is the generic case: a row with no preset at all, built
entirely from the top-level `:llm` keys (`:backend`, `:base-url`,
`:api-key-env`, `:headers`, `:model-*`). `:base-url` is required.

The top-level `:providers-ttl-seconds`, `:models-ttl-seconds`, `:offline`,
`:headers`, `:query-params` and `:profile` keys are not specific to `:custom`:
each one works for whichever provider is selected. `:headers`, `:query-params`
and `:profile` are merged into the selected provider's row, and a value written
in the row wins over the top-level one.

## Quirk profiles

Every "OpenAI-compatible" vendor is compatible with a different subset. Those
differences are data, in `src/enchiridion/llm/dialects.cl`, and a provider picks
a profile rather than a branch.

| Profile                | What it encodes                                                                 |
| ---------------------- | -------------------------------------------------------------------------------- |
| `:openai`              | The generic wire                                                                 |
| `:openai-local`        | No credential header, no `tool_choice` (Ollama, LM Studio, llama.cpp)             |
| `:ollama`              | As above, and models are listed at `api/tags`                                     |
| `:azure`               | `api-key` header, deployment in the path, `api-version` query, `max_completion_tokens`, the `developer` role |
| `:openrouter`          | Attribution header, `reasoning`, cache write tokens in `prompt_tokens_details`    |
| `:deepseek`            | `reasoning_content`, cache hits in `prompt_cache_hit_tokens`                      |
| `:google-openai`       | Bearer on `/v1beta/openai/`, no `tool_choice`, no `parallel_tool_calls`           |
| `:qwen`                | No `parallel_tool_calls`, `enable_thinking` in the body                           |
| `:zai`                 | `thinking` in the body, `reasoning_content` in the reply                          |
| `:groq`                | Drops `stream_options` and `parallel_tool_calls`, which it rejects                |
| `:cloudflare-gateway`  | `cf-aig-authorization` alongside the upstream key                                 |
| `:anthropic`           | Anthropic's own endpoint, unchanged                                               |
| `:anthropic-gateway`   | A bearer token instead of `x-api-key`                                             |
| `:bedrock-invoke`      | `anthropic_version` in the body, betas in `anthropic_beta`, no 1h cache TTL       |
| `:bedrock-messages`    | The native Messages path under `bedrock-mantle`                                   |
| `:vertex`              | `anthropic_version` in the body, no model in the body, model in the URL           |

A dialect also decides where the chain of thought is read from. It is stored
apart, in `completion-reasoning-text`, and never concatenated into the reply:
reasoning is not the answer.

## Model lists

A model list is asked of the provider that holds the account, not of the repo:

| Handler                | Endpoint                                                        |
| ---------------------- | --------------------------------------------------------------- |
| `:openai-chat`         | `GET {base-url}{models-path}` (`data[].id`; `api/tags` on Ollama) |
| `:anthropic-messages`  | `GET {base-url}v1/models`, paginated with `limit`/`after_id`      |
| `:bedrock-invoke`, `:bedrock-messages` | `ListFoundationModels` on the Bedrock control plane |
| `:vertex-anthropic`    | Not offered by Google; the catalog list is used                  |

The list is cached at `run/models/<provider>.json` with a fetch time and obeys
`:models-ttl-seconds`. The commands that run a turn (`ask`, `chat`, `serve`)
refresh it at context build, once per process, when a key is present and the
cache is stale; an inspection command never fetches, and `:offline t` stops the
refresh along with the rest of start-up fetching. `enchiridion providers models
ID` refreshes it by hand, which is the operator's own act, so it still runs
under `:offline t`. A failure is one warning line and the cached or configured
model; a turn is never stopped by a model list.

## Providers

The three shipped rows, the catalog's rows and the operator's rows are merged in
that order, field by field.

| Provider     | Base URL                        | Default model         | Key variable        |
| ------------ | ------------------------------- | --------------------- | ------------------- |
| `:openai`    | `https://api.openai.com/v1/`    | `gpt-5.6-luna`        | `OPENAI_API_KEY`    |
| `:opencode`  | `https://opencode.ai/zen/go/v1` | `deepseek-v4.1-flash` | `OPENCODE_API_KEY`  |
| `:anthropic` | `https://api.anthropic.com/`    | `claude-sonnet-5-5`   | `ANTHROPIC_API_KEY` |

`detect-provider` picks one in this order:

1. An explicit `:provider`. If it names a provider that nothing knows, that is a
   configuration error: the message says to run `providers refresh` or to add a
   `:providers` row. It does not fall through to base-URL detection.
2. A `:base-url` that names a known host: `opencode.ai`, `api.anthropic.com`,
   `api.openai.com`, then any cached catalog provider's `api` host.
3. A present `OPENAI_API_KEY`, then `OPENCODE_API_KEY`, then
   `ANTHROPIC_API_KEY`.
4. Exactly one cached provider whose `env` name is present.
5. Otherwise `:openai`, because it is the default.

`default-api-key-env` returns `:api-key-env` when the file sets it, and
otherwise the selected provider's first environment variable.

`provider-key-names` returns the configured `:api-key-env`, every shipped and
configured row's variables, the selected provider's full variable list, and the
cached providers' variable names that are credential shaped. It deliberately
does **not** return `AWS_ACCESS_KEY_ID`, `GOOGLE_APPLICATION_CREDENTIALS` or
`CLOUDFLARE_ACCOUNT_ID` unless that provider is the one selected, because a name
in this list is read from `.env` and then removed from the process environment.

`resolve-backend` lets an explicit `:base-url` or `:model-primary` win over the
provider row. The kernel calls `complete` with a model name, and it never reads
the provider.

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

### The Messages API

`anthropic-completion-request` builds the body for the Messages API. The object
holds `model`, `max_tokens` (required by the API), and `messages`. The mapping is
not the OpenAI one.

- A system message is hoisted to a top level `system` array and never appears in
  `messages`. Several system messages become one text block, concatenated in
  order.
- A tool message becomes a USER message whose content holds a `tool_result` block
  with `tool_use_id`. Consecutive tool messages merge into one user message, in
  order, and a text message that follows the results joins that same message after
  them, because a `tool_result` block has to come first in its message.
- An assistant message carries its text and then a `tool_use` block per call. The
  input is a JSON object: the stored argument text is read with
  `com.inuoe.jzon:parse`, which keeps objects as hash tables, and not with
  `parse-json`, which turns them into plists that jzon writes back as arrays. An
  empty or absent argument string becomes an empty object.
- Tools are flat `name`, `description`, `input_schema` objects. The registry's
  `parameters` key is renamed, and `tool_choice` `{"type": "auto"}` is added only
  when there are tools.
- `cache_control` `{"type": "ephemeral"}` goes on the last system block and the
  last tool definition, which is at most two of the four breakpoints the API
  allows, and never on the incoming user message. `:cache-ttl` adds a `ttl` field.

A field the request does not need is absent and never nil: the JSON writer turns
nil into `false`, and an empty `messages` array has to be `[]` rather than
`false`.

`anthropic-parse-completion` reads the reply text itself with
`com.inuoe.jzon:parse`, because `parse-json` cannot tell an empty content array
from an absent field and would collapse a tool input into a plist. It
concatenates every text block into `completion-text`, turns each `tool_use` block
into a tool call whose arguments are the input written back as JSON text, maps the
stop reason, and folds the usage.

| Completion slot      | Source field                                            |
| -------------------- | ------------------------------------------------------- |
| `input-tokens`       | `usage.input_tokens` plus both cache counts (see below) |
| `output-tokens`      | `usage.output_tokens`                                   |
| `cache-read-tokens`  | `usage.cache_read_input_tokens`                         |
| `cache-write-tokens` | `usage.cache_creation_input_tokens`                     |

Anthropic's `input_tokens` excludes the cache reads and the cache writes, so all
three are added for `input-tokens` while the two cache slots are still filled. A
reply with no content field at all signals `backend-error` with `:backend
"anthropic"`. An empty content array is legal and becomes an empty completion,
because a model may end a turn without saying anything. The stop reasons map as
`end_turn` and `stop_sequence` to `stop`, `max_tokens` to `length`, and `tool_use`
to `tool_calls`; anything else passes through as it came.

## Transport and retries

One transport and one retry loop.

A request is a value: a URL, a body, a header list, and a timeout
(`http-request` in `src/enchiridion/llm/http.cl`). A handler builds one, applies
its credential with `auth-apply`, and hands it to `post-with-retries`. There is
no second loop to drift from, and no per-vendor transport.

| Handler                | Path                         | Credential                                        |
| ---------------------- | ---------------------------- | ------------------------------------------------- |
| `:openai-chat`         | `{base-url}{chat-path}`      | `Authorization: Bearer`, or the profile's header   |
| `:anthropic-messages`  | `{base-url}{chat-path}`      | `x-api-key` and `anthropic-version`, or Bearer     |
| `:bedrock-invoke`      | `{base-url}model/{id}/invoke`| `AWS_BEARER_TOKEN_BEDROCK`, or SigV4               |
| `:bedrock-messages`    | `{base-url}anthropic/v1/messages` | the same, signed for service `bedrock-mantle` |
| `:vertex-anthropic`    | `{base-url}.../{model}:rawPredict` | `Authorization: Bearer` from GCP OAuth       |

The chat-completions handler sends a JSON content type, the user agent
`enchiridion/0.1.0`, and the `x-opencode-session` header; OpenCode Go needs that
header as its routing key and its prompt cache key, and a generic server ignores
it. The Messages handler sends `x-api-key` and the required `anthropic-version`,
because that is what every documented example sends; a gateway profile replaces
both through the same merge. `*http-post-function*` and `*http-get-function*`
hold the transport and the one GET, so a test can replace either without a
network.

`post-with-retries` repeats a 429 and any status at or above 500, up to `retries`
extra attempts, and waits `*retry-delay*` seconds times the attempt number.
`*retry-delay*` is 2, and a test binds it to 0. The 5xx rule covers Anthropic's
500, 504, and 529. Any other 4xx becomes a `transport-error` at once, with
`:status` and the provider's own error text. A wrong key or a wrong model does
not become right by a second send.

## Signing

Two handlers cannot use a static header, because their credential signs the
request:

- **Amazon Bedrock.** `AWS_BEARER_TOKEN_BEDROCK` selects a bearer token; the
  absence of it selects AWS Signature Version 4 from `aws-sigv4.cl`, which signs
  with `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and an optional
  `AWS_SESSION_TOKEN` for the region in `:region`, `AWS_REGION` or
  `AWS_DEFAULT_REGION`. The signer registers itself under `:aws-sigv4`, and the
  file ships AWS's published test vectors as fixtures.
- **Google Vertex.** `vertex.cl` asks `gcp-oauth.cl` for a bearer token: an
  `GOOGLE_VERTEX_ACCESS_TOKEN` or `GCLOUD_ACCESS_TOKEN` when one is set,
  otherwise an RS256 JWT built from the service account at
  `GOOGLE_APPLICATION_CREDENTIALS` and exchanged at Google's token endpoint. The
  token is cached in memory until it expires. `gcloud` is never required.

Both signers are functions in the `*auth-signers*` table, so nothing in the core
knows that AWS or Google exists.

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
