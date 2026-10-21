# Large language model backends

Every model call passes through one generic function, `enchiridion.llm:complete`, and returns one `completion`.
The kernel never asks which vendor answered, and a vendor is a registry entry and a data profile.

## The backend protocol

A backend implements three generic functions.

| Generic function     | Arguments                                                                | Returns                                                                          |
| -------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| `complete`           | the backend, `messages`, and the keywords `model`, `tools`, and `budget` | a `completion`                                                                   |
| `model-capabilities` | the backend                                                              | a plist with the keys `:tools`, `:cache`, `:streaming`, and `:cache-breakpoints` |
| `backend-name`       | the backend                                                              | a short string for logs                                                          |

`complete` continues a conversation.
A nil `model` means the backend default, and `tools` holds the tool definitions.
Every shipped backend ignores `budget`, which decides whether a turn starts.

`backendp` checks for one method per operation with `find-method`, because Common Lisp has no protocol type.
An object with a fourth required operation adds its method there.

### Messages

A `message` holds a role, a content string, a tool-call id, and a list of tool calls.
The role is `user`, `assistant`, `system`, or `tool`.
The strings default to the empty string and the list defaults to the empty list.

Four constructors build one, and the struct constructor is private.
`system-message`, `user-message`, `assistant-message`, and `tool-message` set the role and take the text, the calls, or the call id that role needs.

A `tool-call` holds an id, a name, and the arguments as JSON text.
Nothing between the model and the tool layer parses that text.

### Completions

A `completion` is the reply, its calls, and the provider's billing numbers.

| Accessor                        | Type               | Default | Source                                        |
| ------------------------------- | ------------------ | ------- | --------------------------------------------- |
| `completion-text`               | string             | `""`    | the answer as text                            |
| `completion-reasoning-text`     | string             | `""`    | chain of thought, kept apart from the answer  |
| `completion-tool-calls`         | list               | `()`    | the calls, in the order requested             |
| `completion-model`              | string             | `""`    | the model that actually answered              |
| `completion-stop-reason`        | string             | `""`    | `stop`, `length`, or `tool_calls`             |
| `completion-input-tokens`       | integer at least 0 | `0`     | prompt tokens, with cache counts folded in    |
| `completion-output-tokens`      | integer at least 0 | `0`     | generated tokens                              |
| `completion-cache-read-tokens`  | integer at least 0 | `0`     | cached prompt tokens the provider reports     |
| `completion-cache-write-tokens` | integer at least 0 | `0`     | prompt tokens written to the provider's cache |

`completion-total-tokens` adds input and output only.
The input count is provider-normalized, with cache reads folded in.

Reasoning text is never concatenated into the reply, and nothing persists it.

`model-capabilities` reports what a backend supports.

| Backend            | `:tools` | `:streaming` | `:cache` | `:cache-breakpoints` |
| ------------------ | -------- | ------------ | -------- | -------------------- |
| OpenAI chat        | t        | t            | t        | nil                  |
| Anthropic Messages | t        | t            | t        | t                    |
| Amazon Bedrock     | t        | nil          | t        | t                    |
| Google Vertex      | t        | t            | t        | t                    |

## Model tiers

| Tier       | Work                          | Model variable    |
| ---------- | ----------------------------- | ----------------- |
| `:primary` | a reasoning turn              | `*model-primary*` |
| `:cheap`   | memory digests and compaction | `*model-cheap*`   |
| `:sleep`   | the sleep agent               | `*model-sleep*`   |

`sleep-model` answers `*model-cheap*` when `*model-sleep*` is nil.
The sleep agent reads the configured `:model-sleep`, and `configuration.md` owns the defaults.
`tier` maps a name to `:primary`, `:cheap`, or `:sleep`, and an unknown name or nil becomes `:primary`.
`model-for-tier` returns the model for a tier, and `enchiridion:model-for` reads the configured name.

## The adapter registry

An adapter is one wire.
Each handler registers its adapter as it loads, so the core names no vendor.

An adapter holds an id, a schema, a builder, a model lister, and one documentation line.
The schema is `:openai`, `:anthropic`, or nil for a wire of its own.

`register-api-handler` adds an adapter and replaces one with the same id.
A non-keyword id signals `configuration-error` at `:api` with the detail `An adapter id must be a keyword, not ~S.`
`find-api-handler` returns an adapter or nil, and `registered-api-handlers` returns every id sorted, while `provider-supported-p` tests a provider.

Five adapters exist.

| Adapter id            | File           | Schema       | Profile               | Wire                                              |
| --------------------- | -------------- | ------------ | --------------------- | ------------------------------------------------- |
| `:openai-chat`        | `openai.cl`    | `:openai`    | `:openai`             | chat completions, with a dialect for each vendor  |
| `:anthropic-messages` | `anthropic.cl` | `:anthropic` | `:anthropic`          | the Messages API                                  |
| `:bedrock-invoke`     | `bedrock.cl`   | `:anthropic` | `:bedrock-invoke`     | Bedrock InvokeModel with a Messages body          |
| `:bedrock-messages`   | `bedrock.cl`   | `:anthropic` | `:bedrock-messages`   | the Messages transport behind the Bedrock gateway |
| `:vertex-anthropic`   | `vertex.cl`    | `:anthropic` | `:vertex`             | Anthropic models on Vertex AI                     |

`providers.cl` registers generic builders for `:openai-chat` and `:anthropic-messages`.
A handler that registers a builder without a model lister keeps its builder and gains the generic lister.
`handler-protocol`, `handler-profile`, `protocol-profile`, `profile-handler-id`, and `backend-handler-id` convert between an adapter id, a schema, a profile, and a `:backend` value.
A `:backend` value may also name an adapter id.

## Provider rows

A provider row is data.
It names an endpoint, the variables that hold its key, and the adapter or profile that speaks its wire.
`configuration.md` owns the row keys and the shipped rows.

Three sources merge field by field, most specific first: the operator's rows, the shipped rows, and the cached catalog.
A key present with a nil value wins.
The row becomes a `provider` record before a handler sees it.

| Field                    | Type               | Meaning                                                        |
| ------------------------ | ------------------ | -------------------------------------------------------------- |
| `provider-id`            | keyword            | the row id, normalized from a keyword or a string              |
| `provider-name`          | string             | the display name                                               |
| `provider-api`           | symbol or nil      | the adapter id                                                 |
| `provider-profile`       | symbol or nil      | the dialect profile                                            |
| `provider-base-url`      | string             | the endpoint, with any `${NAME}` placeholder expanded          |
| `provider-key` and `provider-env` | string and list of strings | the credential value and every variable name that can hold it |
| `provider-model` and `provider-default-model` | string or nil | the selected model and the row's fallback                    |
| `provider-cached-models` | list of model rows | models named directly in the row, for an endpoint with no list |
| `provider-headers` and `provider-query-params` | alists | extra request headers and query parameters                  |
| `provider-options`       | plist              | handler options, reached with `provider-option`                |
| `provider-doc` and `provider-source` | string and keyword | the catalog line and `:catalog`, `:shipped`, or `:config` |

The adapter comes from a caller's override, then the row's `:api`, then the npm package, then the profile.
The profile comes from the row's `:profile`, then the npm package, then the adapter, then the protocol, and finally `:openai`.
The base URL comes from an override, then the row, then the npm package's vendor default.
A row with no adapter still yields a record.

The options plist holds `:npm`, `:protocol`, `:backend`, `:dialect-overrides`, and the keys `:max-tokens`, `:models-ttl-seconds`, `:region`, `:project`, `:location`, `:cache-p`, `:cache-ttl`, `:betas`, `:timeout`, and `:retries`.
A row value wins over the configuration value for the same key.

The credential is read from the secret loader first and the process environment second.
An explicit key wins over both.
A key variable that is set counts as present even when its value is empty.

The model is the configured `:model-primary`, then the row's `:model`, then its `:default-model`.
A turn may override it with the `model` argument of `complete`.
Top-level `:headers`, `:query-params`, and `:profile` fill a selected row that does not set them.

`detect-provider` selects in this order.

1. An explicit `:provider` value.
2. A `:base-url` whose host is `opencode.ai`, `api.anthropic.com`, or `api.openai.com`.
3. A `:base-url` whose host matches a cached catalog provider.
4. The presence of `OPENAI_API_KEY`.
5. The presence of `OPENCODE_API_KEY`.
6. The presence of `ANTHROPIC_API_KEY`.
7. The one cached provider whose key variable is present.
8. `:openai`.

Two exported keys need an explicit `:provider` or `:base-url`, because OpenAI wins a tie.

`backend-provider-id` pairs a `:backend` value with a row.
An explicit `:provider` wins, and `:backend :anthropic` selects the Anthropic row even when an OpenAI key is present.

### Resolution and its errors

`resolve-provider` returns the selected provider, and `resolve-backend` returns a backend or refuses.

| Condition                                 | Error                                                                                                                                                                      |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A `:backend` value names no adapter       | `configuration-error` at `:backend`: `No backend for ~S. :BACKEND is :OPENAI or :ANTHROPIC, or one of the adapter ids this build registered: ~{~A~^, ~}.`                  |
| The provider has no adapter in this build | `configuration-error` at `:provider`: `~A (~A) has no adapter in this build~@[ (npm ~A)~]. Set :base-url and :api on its row under :providers in config.cl.`               |
| The provider has no endpoint              | `configuration-error` at `:base-url`: `Provider ~A has no endpoint: set :base-url in its :providers row, or export the variable its default endpoint needs (~{~A~^, ~}).`  |
| The row id is unknown                     | `configuration-error` at `:provider` with the detail `There is no provider called ~A.` The detail also names `enchiridion providers refresh` and a row under `:providers`. |

A row under `:providers` without an `:id` signals `configuration-error` at `:providers` with the detail `A provider row under :providers has no :id: ~S`.

`provider-env-for-id` returns a row's key variable names without resolving the provider.
`default-api-key-env` returns the variable to export: the configured `:api-key-env`, or the selected provider's first name.
`provider-key-names` returns every name that can hold a provider key, including names of providers that are not selected.

## The runtime catalog

Provider facts beyond the shipped rows come from models.dev at run time.
`trim-catalog` keeps what a request needs, and the module caches the result under `run/`.

| File                       | Contents                                                                                                                          |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `run/providers.json`       | one row per provider: id, name, npm package, key variables, endpoint, protocol, computed default model, doc                       |
| `run/provider-models.json` | every model's metadata, keyed by provider: name, context window, output limit, tool calling, reasoning, four prices, release date |

`*catalog-path*` holds the provider index, resolved from the run directory when the file loads.
`ENCHIRIDION_PROVIDERS_PATH` overrides it.
`*catalog-models-path*` overrides the metadata path, which otherwise sits beside the index as `provider-models.json`.
`*catalog-url*` overrides the fetch URL, then `:providers-url`, then `https://models.dev/api.json`.

The trim keeps these fields.

- A provider row keeps `id`, `name`, `npm`, `env`, `api`, `doc`, a computed default model, and the protocol the npm package implies.
- A model keeps `id`, `name`, `tool_call`, `reasoning`, `context`, `output`, `cost_input`, `cost_output`, `cost_cache_read`, `cost_cache_write`, and `release_date`.
- Everything else models.dev carries is dropped.

The default model is the newest model that can call tools, by `release_date` then `last_updated`.
The smallest id breaks a tie, a model with no date sorts first, and a provider with no models has no default.

`read-catalog-file` accepts this module's wrapper, with `meta` and `providers`, or the flat map models.dev serves.
A missing, unreadable, or corrupt file answers nil, and the configured rows take over.

`refresh-catalog` fetches the URL, trims the document, writes both files, and returns the index read back.
Each write is a temporary file and a rename, so a failure leaves the previous cache in place.

A transport refusal signals `transport-error` with the status and the detail `Could not fetch the provider catalog from ~A.`
A body that cannot be read signals `configuration-error` at `:providers-url` with the detail `The provider catalog at ~A could not be read: ~A`.

`catalog-expired-p` compares the file write date against a TTL, and a nil or non-positive TTL means always stale.
The provider index uses `:providers-ttl-seconds`, and a model list uses `:models-ttl-seconds`.
`:offline t` stops every startup fetch and every model list fetch.
The operator's own `providers refresh` and `providers models` still run.

## Quirk profiles and dialects

A dialect is a record of overrides over the generic wire, and a profile is a named set of values for it.
`dialect-field` answers its default when the dialect is nil, so a nil dialect is the generic wire.
A profile that writes nil for a switch turns it off.

| Slot                         | Default                                 | Meaning                                                                           |
| ---------------------------- | --------------------------------------- | --------------------------------------------------------------------------------- |
| `auth-scheme`                | `:bearer`                               | where the credential goes                                                         |
| `auth-header`                | nil                                     | the header name for `:api-key-header`, default `api-key`                          |
| `auth-prefix`                | `""`                                    | text before the credential in a vendor-named header                               |
| `auth-query`                 | nil                                     | the parameter name for `:query-param`, default `key`                              |
| `chat-path`                  | nil                                     | appended to the base URL, `{model}` is substituted, nil means the handler default |
| `models-path`                | nil                                     | the model list path, nil means the handler default                                |
| `query-params`               | `()`                                    | extra query parameters as name and value pairs                                    |
| `extra-headers`              | `()`                                    | extra headers                                                                     |
| `max-tokens-field`           | `:max-tokens`                           | `:max-tokens` or `:max-completion-tokens`, only the named one is written          |
| `system-role`                | `"system"`                              | `system` or `developer`                                                           |
| `send-tool-choice-p`         | t                                       | send `tool_choice` with tools                                                     |
| `send-parallel-tool-calls-p` | t                                       | send `parallel_tool_calls` with tools                                             |
| `send-stream-options-p`      | t                                       | send `stream_options` with a stream                                               |
| `extra-body`                 | `()`                                    | extra request fields, as a plist of keyword names and values                      |
| `reasoning-field`            | nil                                     | where the chain of thought arrives                                                |
| `input-tokens-field`         | `"prompt_tokens"`                       | where input tokens arrive                                                         |
| `output-tokens-field`        | `"completion_tokens"`                   | where output tokens arrive                                                        |
| `cache-read-tokens-field`    | `"prompt_tokens_details.cached_tokens"` | where cache read tokens arrive                                                    |
| `cache-write-tokens-field`   | `"cache_creation_input_tokens"`         | where cache write tokens arrive                                                   |
| `version-location`           | `:header`                               | `:header` or `:body` for the API revision                                         |
| `version-value`              | nil                                     | the revision, nil means the handler's constant                                    |
| `model-in-body-p`            | t                                       | write the model into the body                                                     |
| `beta-channel`               | `:header`                               | `:header` or `:body` for the beta feature list                                    |
| `cache-ttl-supported-p`      | t                                       | accept a cache TTL                                                                |
| `models-list-shape`          | `:data`                                 | `:data`, `:ollama`, `:openrouter`, or nil for no list                             |
| `tool-arguments-form`        | `:either`                               | declared with no reader in this tree                                              |
| `thinking-supported-p`       | t                                       | declared with no reader in this tree                                              |

The `protocol` slot is recorded and read by no function.

Sixteen profiles ship.

| Profile               | Overrides                                                                                                                            |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `:openai`             | none                                                                                                                                 |
| `:openai-local`       | `:auth-scheme :none`, `:send-tool-choice-p nil`                                                                                      |
| `:ollama`             | as `:openai-local`, and `:models-path "api/tags"`, `:models-list-shape :ollama`                                                      |
| `:azure`              | `api-key` header, `openai/deployments/{model}/chat/completions`, `api-version=2024-06-01`, `max_completion_tokens`, `developer` role |
| `:openrouter`         | `X-Title: enchiridion`, `reasoning` field, cache write tokens under `prompt_tokens_details`                                          |
| `:deepseek`           | `reasoning_content`, cache hits under `prompt_cache_hit_tokens`                                                                      |
| `:google-openai`      | no `tool_choice`, no `parallel_tool_calls`                                                                                           |
| `:qwen`               | no `parallel_tool_calls`, `enable_thinking` true in the body                                                                         |
| `:zai`                | `reasoning_content`, `thinking` enabled in the body                                                                                  |
| `:groq`               | no `stream_options`, no `parallel_tool_calls`                                                                                        |
| `:cloudflare-gateway` | `cf-aig-authorization` header with the prefix `Bearer `                                                                              |
| `:anthropic`          | none                                                                                                                                 |
| `:anthropic-gateway`  | `:auth-scheme :bearer`                                                                                                               |
| `:bedrock-invoke`     | SigV4, revision in the body as `bedrock-2023-05-31`, no model in the body, betas in the body, no 1h cache TTL                        |
| `:bedrock-messages`   | SigV4, path `anthropic/v1/messages`                                                                                                  |
| `:vertex`             | Google OAuth, revision in the body as `vertex-2023-10-16`, no model in the body, no model list                                       |

A row may override seven dialect fields directly: `:auth-scheme`, `:auth-header`, `:chat-path`, `:models-path`, `:max-tokens-field`, `:system-role`, and `:reasoning-field`.
A nil override is kept, because one of these fields genuinely means absent.

`make-dialect-for` applies the profile and then the overrides.
An unknown profile signals `configuration-error` at `:profile` with the detail `There is no provider profile called ~S. Known profiles: ~{~A~^, ~}.`
An unknown key signals `configuration-error` at `:profile` with the detail `~S is not a provider dialect field.`

### Provider packages

models.dev names the AI SDK package, and the package decides whether this build can speak the provider.

| npm package                              | Adapter               | Profile               | Vendor default endpoint                            |
| ---------------------------------------- | --------------------- | --------------------- | -------------------------------------------------- |
| `@ai-sdk/openai-compatible`              | `:openai-chat`        | none                  | none                                               |
| `@ai-sdk/openai`                         | `:openai-chat`        | none                  | `https://api.openai.com/v1`                        |
| `@ai-sdk/azure`                          | `:openai-chat`        | `:azure`              | `https://${AZURE_RESOURCE_NAME}.openai.azure.com/` |
| `@openrouter/ai-sdk-provider`            | `:openai-chat`        | `:openrouter`         | none                                               |
| `@ai-sdk/groq`                           | `:openai-chat`        | none                  | `https://api.groq.com/openai/v1`                   |
| `@ai-sdk/mistral`                        | `:openai-chat`        | none                  | `https://api.mistral.ai/v1`                        |
| `@ai-sdk/xai`                            | `:openai-chat`        | none                  | `https://api.x.ai/v1`                              |
| `@ai-sdk/cerebras`                       | `:openai-chat`        | none                  | `https://api.cerebras.ai/v1`                       |
| `@ai-sdk/togetherai`                     | `:openai-chat`        | none                  | `https://api.together.xyz/v1`                      |
| `@ai-sdk/deepinfra`                      | `:openai-chat`        | none                  | `https://api.deepinfra.com/v1/openai`              |
| `venice-ai-sdk-provider`                 | `:openai-chat`        | none                  | `https://api.venice.ai/api/v1`                     |
| `@aihubmix/ai-sdk-provider`              | `:openai-chat`        | none                  | `https://aihubmix.com/v1`                          |
| `@saladtechnologies-oss/ai-sdk-provider` | `:openai-chat`        | none                  | `https://ai.salad.cloud/v1`                        |
| `@ai-sdk/gateway`                        | `:openai-chat`        | none                  | `https://ai-gateway.vercel.sh/v1`                  |
| `ai-gateway-provider`                    | `:openai-chat`        | `:cloudflare-gateway` | `https://gateway.ai.cloudflare.com/v1`             |
| `@ai-sdk/anthropic`                      | `:anthropic-messages` | `:anthropic`          | `https://api.anthropic.com`                        |
| `@ai-sdk/amazon-bedrock`                 | `:bedrock-invoke`     | `:bedrock-invoke`     | none                                               |
| `@ai-sdk/google-vertex/anthropic`        | `:vertex-anthropic`   | `:vertex`             | none                                               |

A package that is absent is unsupported, and the refusal names the package.
A `${NAME}` placeholder is expanded from the process environment.
An absent or empty name makes the whole endpoint nil, which resolution reports as a provider with no endpoint.
The value is not read from the secret loader.

## The chat completions wire

`:openai-chat` covers OpenAI, OpenCode Go, Azure, OpenRouter, Groq, Qwen, DeepSeek, Mistral, xAI, and the compatible long tail.

### The request

`completion-request` returns JSON text, built as data first because a dialect may rewrite a field.

| Field                                   | When it is written                                                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `model`                                 | always                                                                                            |
| `stream`                                | always, false for every request this tree makes                                                   |
| `messages`                              | always                                                                                            |
| `max_tokens` or `max_completion_tokens` | when the connection has a positive reply cap, the dialect decides the spelling                    |
| `tools`                                 | when the turn carries tool definitions, each wrapped as `{"type": "function", "function": {...}}` |
| `tool_choice`                           | `"auto"` with the tools, when `send-tool-choice-p`                                                |
| `parallel_tool_calls`                   | true with the tools, when `send-parallel-tool-calls-p`                                            |
| `stream_options`                        | `{"include_usage": true}` when a stream and `send-stream-options-p` are both present              |
| dialect extra body fields               | merged last, so a vendor switch is data                                                           |

A message carries `role` and `content`.
A tool message adds `tool_call_id` when its id is nonempty, and an assistant message adds `tool_calls` when it asked for any.
Other messages carry neither key, because some servers reject an unexpected field.
A dialect may rename the `system` role.

Tool arguments are normalized to JSON text, with an absent field or the empty string becoming `{}`.

### The reply

`parse-completion` reads the first choice.

| Completion slot                 | Source field                                                                  |
| ------------------------------- | ----------------------------------------------------------------------------- |
| `completion-text`               | `message.content`, or the empty string                                        |
| `completion-reasoning-text`     | the dialect's reasoning field, on the message or at the top level             |
| `completion-tool-calls`         | `message.tool_calls`, with arguments normalized to JSON text                  |
| `completion-model`              | `model`, or the empty string                                                  |
| `completion-stop-reason`        | `finish_reason`, or the empty string                                          |
| `completion-input-tokens`       | the dialect's input field, default `prompt_tokens`                            |
| `completion-output-tokens`      | the dialect's output field, default `completion_tokens`                       |
| `completion-cache-read-tokens`  | the dialect's cache read field, default `prompt_tokens_details.cached_tokens` |
| `completion-cache-write-tokens` | the dialect's cache write field, default `cache_creation_input_tokens`        |

A reply with no choices signals `backend-error` with `:backend "openai"`.
The detail is `The reply carried no choices: ~S`, which carries the reply's own `error` field.
A dotted field name reads into a nested object.
A provider that reports cached tokens at the top level under a name of its own is served by the dialect field.

The request headers are `content-type: application/json`, `user-agent: enchiridion/0.1.0`, and `x-opencode-session`.
The credential is applied after the request is built.

The lister sends `GET {base-url}{models-path}`, with the dialect's path, default `models`, and its shape.
The `:data` shape reads `{"data": [{"id": ...}]}`, and `:ollama` reads `{"models": [{"name": ...}]}`.
A nil shape sends no request.

A rich entry is recognized by a `pricing` object or a `supported_parameters` array.
Per-token price strings are converted to USD per million for the model record, with `*read-eval*` bound to nil.
A generic entry reads `context_length`, `context_window`, or `context`, and `max_output_tokens` or `output`.

The request uses `openai-static-headers` and the credential through `auth-apply`.

## The Anthropic Messages wire

`:anthropic-messages` covers Anthropic's endpoint and every Anthropic-shaped gateway.
`anthropic.cl` also owns the builders that Bedrock and Vertex call.

### The request

`anthropic-request-body` builds the body as data.
`max_tokens` is required by the API, so it is always present and defaults to 4096.
The messages array is a vector even when empty, because the JSON writer would otherwise write false.

The mapping differs from the chat completions wire.

- A system message is hoisted to a top-level `system` array and never appears in `messages`.
  Several system messages become one text block joined by two newlines.
- A tool message becomes a user message whose content is a `tool_result` block with `tool_use_id`.
  The wire has no tool role.
- Consecutive entries with the same role merge into one message.
  Results from one round become one user message in call order, and a following text message joins it after the blocks.
- An assistant message carries its text block and then one `tool_use` block per call.
  A turn with neither text nor calls gets an empty text block, because the API refuses an empty content array.
- A tool call's `input` is an object, parsed with the JSON parser directly because a plist would be written back as an array.
- Tools are flat objects with `name`, `description`, and `input_schema`.
  `tool_choice` is `{"type": "auto"}` and is present only with tools.

Prompt caching is a breakpoint on the blocks that end the reusable prefix.
With `cache-p` true, one `{"type": "ephemeral"}` object goes on the last system block and one on the last tool definition.
The API allows four breakpoints, and this backend never places one on a conversation message.
`cache-ttl` adds a `ttl` field, and a profile without TTL support drops it and keeps the breakpoint.

| Field               | When it is written                                              |
| ------------------- | --------------------------------------------------------------- |
| `max_tokens`        | always, the connection's value or 4096                          |
| `messages`          | always, as a vector                                             |
| `system`            | when at least one system message exists                         |
| `model`             | unless the dialect sets `model-in-body-p` to nil                |
| `anthropic_version` | when the dialect puts the revision in the body                  |
| `anthropic_beta`    | when betas exist and the dialect puts the beta list in the body |
| `tools`             | when the turn carries tools                                     |
| `tool_choice`       | with the tools                                                  |

A field the request does not need is absent rather than nil, because the JSON writer writes nil as false.
The default revision is `2023-06-01` in the `anthropic-version` header.
A profile that puts the revision in the body names its own value and omits the header.

### The reply

The reply is read with the JSON parser's object type and not through `parse-json`.
That distinction tells an empty content array from an absent field and keeps a tool input an object.

| Completion slot                 | Source                                                           |
| ------------------------------- | ---------------------------------------------------------------- |
| `completion-text`               | every `text` block, concatenated in order with nothing inserted  |
| `completion-reasoning-text`     | every `thinking` and `redacted_thinking` block, concatenated     |
| `completion-tool-calls`         | every `tool_use` block, with the input written back as JSON text |
| `completion-model`              | `model`                                                          |
| `completion-stop-reason`        | `stop_reason` through the mapping below                          |
| `completion-input-tokens`       | `input_tokens` plus both cache counts                            |
| `completion-output-tokens`      | `output_tokens`                                                  |
| `completion-cache-read-tokens`  | `cache_read_input_tokens`                                        |
| `completion-cache-write-tokens` | `cache_creation_input_tokens`                                    |

| Wire value      | Stop reason  |
| --------------- | ------------ |
| `end_turn`      | `stop`       |
| `stop_sequence` | `stop`       |
| `max_tokens`    | `length`     |
| `tool_use`      | `tool_calls` |
| anything else   | as it came   |

A reply with no content field at all signals `backend-error` with `:backend "anthropic"`.
The detail is `The reply carried no content blocks at all.` when the reply holds no provider message.
Otherwise the detail is `The reply carried no content blocks: ~A`.
An empty content array is legal and becomes an empty completion.

The input count is normalized: `input_tokens` plus both cache counts, while the cache slots stay filled.
`completion-total-tokens` stays input plus output on both wires.

The Messages lister follows pages.

Each request asks for `limit=1000` and uses `after_id` set to the last row of the previous page.
`has_more` decides whether another page exists, and the lister stops after 64 pages.
A row reports tool calling true and reasoning nil, and the display name comes from `display_name`.

Every page uses the same authorization path as a chat request.

## Amazon Bedrock

Bedrock speaks the Messages schema with its own transport.
Two adapters cover its entry points.

| Adapter             | Method and path                    | Default host                             | Model       | Revision                                               | Betas                        | SigV4 service    |
| ------------------- | ---------------------------------- | ---------------------------------------- | ----------- | ------------------------------------------------------ | ---------------------------- | ---------------- |
| `:bedrock-invoke`   | `POST {base}model/{model}/invoke`  | `bedrock-runtime.{region}.amazonaws.com` | in the path | `anthropic_version` in the body (`bedrock-2023-05-31`) | `anthropic_beta` in the body | `bedrock`        |
| `:bedrock-messages` | `POST {base}anthropic/v1/messages` | `bedrock-mantle.{region}.api.aws`        | in the body | `anthropic-version` header (`2023-06-01`)              | `anthropic-beta` header      | `bedrock-mantle` |

A provider that names a base URL is trusted as the endpoint.
Otherwise the URL is built from the region.

The region is the row's `:region`, then `AWS_REGION`, then `AWS_DEFAULT_REGION`.
There is no default region.
Absence signals `configuration-error` at `:region` with the detail `No AWS region is configured: set :region on the provider, or AWS_REGION or AWS_DEFAULT_REGION in the environment.`

The model comes from the turn, then the connection.
Its absence signals `configuration-error` at `:model` with the detail `The Bedrock handler was asked for a completion with no model to ask for.`
The invoke path escapes the model as one path segment, because an inference profile id carries a colon.

The credential is chosen at request time.

1. `AWS_BEARER_TOKEN_BEDROCK` wins outright.
2. A provider key is used as a bearer token only when no AWS access key is available to sign with.
3. Otherwise the request is signed with SigV4 and no credential header is written.

The body is the Anthropic builder with the dialect's choices.
The beta list is an array in the body or a comma separated header, and the cache TTL is dropped when unsupported.
The content type is always sent, and the provider's headers are merged underneath.

A reply that is not a JSON object signals `configuration-error` at `:reply`.
The detail is `The Bedrock reply is not a JSON object: ~A`, truncated to 200 characters plus `...`.
An object with a `message` field and no content is AWS's error envelope and signals `transport-error` with `:status 200` and the service's own words.
Everything else goes to the Anthropic parser.

The model list is one signed `GET` at `foundation-models?byProvider=anthropic` on `bedrock.{region}.amazonaws.com`, signed for the `bedrock` service.
A row takes its id from `modelId`, `inferenceProfileId`, `id`, or the tail of `modelArn`, and its name from `modelName`, `inferenceProfileName`, or `name`.
A row whose `providerName` is neither absent nor `anthropic` is dropped.
Every row reports tool calling, and a malformed reply yields fewer rows and never an error.

## Google Vertex

`:vertex-anthropic` serves Anthropic models through Vertex AI's `:rawPredict`.
The endpoint is per region and per project.

| Setting    | Source                                                      | Error when absent                                                                                                                                     |
| ---------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `project`  | the row's `:project` option, then `GOOGLE_VERTEX_PROJECT`   | `configuration-error` at `:project`: `Vertex AI needs a Google Cloud project: pass :project in the provider's options, or set GOOGLE_VERTEX_PROJECT.` |
| `location` | the row's `:location` option, then `GOOGLE_VERTEX_LOCATION` | `configuration-error` at `:location`: `Vertex AI needs a region: pass :location in the provider's options, or set GOOGLE_VERTEX_LOCATION.`            |
| `model`    | the turn, the provider model, or the provider default model | `configuration-error` at `:model`: `Vertex AI needs a model: it is a path segment, so there is no request the endpoint would accept without it.`      |

The URL is `https://{location}-aiplatform.googleapis.com/v1/projects/{project}/locations/{location}/publishers/anthropic/models/{model}:rawPredict`.
A base URL on the row overrides the region-derived host, and the model is a path segment that is not percent encoded.

The body is the Anthropic builder with `model-in-body-p` nil and `anthropic_version` set to `vertex-2023-10-16`.
The request carries `authorization`, `content-type: application/json`, and `user-agent: enchiridion/0.1.0`, plus the provider's headers.
It carries no `anthropic-version` header, because the revision is a body field here.

The access token is fetched per request by `gcp-access-token` by default, and the provider profile is not read.
This handler serves one vendor, and the four facts a dialect could carry are written in `vertex.cl`.

Google publishes no Anthropic model list at this endpoint, so the lister returns nil and the caller falls back to the catalog.

## Transport and retries

A request is a value.

| Field                  | Type                | Default |
| ---------------------- | ------------------- | ------- |
| `http-request-url`     | string              | `""`    |
| `http-request-body`    | string              | `""`    |
| `http-request-headers` | alist of conses     | `()`    |
| `http-request-timeout` | integer, at least 1 | 60      |

`http-post` sends it with read and connect timeouts both set to the request timeout.
`http-get` is the one GET, with `+http-get-timeout+` at 10 seconds.

A handler builds the request, applies its credential, and hands it to `post-with-retries`.
`post-with-retries` repeats 429 and every status at or above 500, up to the connection's `retries` extra attempts.
Attempt n waits n times `*retry-delay*`, which is 2, so the default waits are 2 and 4 seconds.
Every other 4xx is reported at once.

A failure becomes `transport-error` with `:status` and the detail `~D after ~D attempt~:P: ~A`: the status, the number of attempts, and the provider's error text.
`provider-error-message` reads that text from an `error.message` object, an `error` string, a `message` field, or a `Message` field.
A reply that is not JSON becomes the note `the provider replied with something that is not JSON`.

The reply is parsed after `post-with-retries` returns, so a 200 that is not JSON is not retried.

Three specials make the transport testable without a socket.

| Special                | Default     | Use                                              |
| ---------------------- | ----------- | ------------------------------------------------ |
| `*http-post-function*` | `http-post` | the one POST, bound in tests                     |
| `*http-get-function*`  | `http-get`  | the one GET for the catalog and model lists      |
| `*retry-delay*`        | 2           | base retry delay in seconds, bound to 0 in tests |

Headers are merged case-insensitively, and a header written as a two element list becomes a cons before it reaches the transport.

## Request signing and credentials

Four schemes write a static header or parameter, one sends nothing, and two sign the request.

| Scheme            | Effect                                                               |
| ----------------- | -------------------------------------------------------------------- |
| `:bearer`         | `Authorization: Bearer KEY`                                          |
| `:api-key-header` | `NAME: PREFIXKEY`, with the dialect's header name, default `api-key` |
| `:x-api-key`      | `x-api-key: KEY`                                                     |
| `:query-param`    | `?NAME=KEY`, with the dialect's parameter name, default `key`        |
| `:none`           | no credential                                                        |
| `:aws-sigv4`      | signed by the registered SigV4 signer                                |
| `:gcp-oauth`      | a bearer token from the registered Google signer                     |

`auth-apply` appends the credential and dialect query parameters to the URL, keeping an existing query string.
It merges the credential headers, the dialect's extra headers, and the caller's extra headers, and a signer's headers win a name clash.

### AWS Signature Version 4

`aws-sigv4.cl` builds a canonical request from the method, path, query, headers, and body hash, and signs the string to sign with a derived key.
The Authorization header is `AWS4-HMAC-SHA256 Credential=.../..., SignedHeaders=..., Signature=...`.

The signed headers always include `host` and `x-amz-date`.
`x-amz-content-sha256` is included by default, and `x-amz-security-token` when a session token exists.
The credential is read from the secret loader first and the environment second, and an explicit credential wins over both.

| Variable                   | Use                                      |
| -------------------------- | ---------------------------------------- |
| `AWS_ACCESS_KEY_ID`        | the access key                           |
| `AWS_SECRET_ACCESS_KEY`    | the secret key                           |
| `AWS_SESSION_TOKEN`        | an optional session token                |
| `AWS_REGION`               | the region when the row names none       |
| `AWS_DEFAULT_REGION`       | the region after `AWS_REGION`            |
| `AWS_BEARER_TOKEN_BEDROCK` | a bearer token that replaces a signature |

A missing access key or secret key signals `configuration-error` at `:aws-credentials`.
The detail is `No AWS credential is available to sign with: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or load them as secrets.`

The region, service, and method are bound around the signer call.
A nil `*aws-service*` means `bedrock`, a nil `*aws-request-method*` means `POST`, and the signer is registered under `:aws-sigv4`.

### Google Cloud OAuth

`gcp-oauth.cl` is the only source of a Google access token.
Two sources are tried in order.

1. A token the operator minted, from `GOOGLE_VERTEX_ACCESS_TOKEN` then `GCLOUD_ACCESS_TOKEN`, read from the secret loader then the environment.
   It is used as it stands and is not cached.
2. A service account JSON at `GOOGLE_APPLICATION_CREDENTIALS`.
   Its PKCS#8 private key signs an RS256 JWT, which is exchanged at `https://oauth2.googleapis.com/token` for a token with the `cloud-platform` scope.

It is cached in memory until `expires_in` minus 60 seconds, or for 3600 seconds when no `expires_in` arrives.
Nothing is written to disk, the assertion lifetime is 3600 seconds, and the token request has a 30 second timeout.

A token endpoint refusal is a `transport-error` with its own `error_description`.
An unreadable reply signals `backend-error` with `:backend "gcp"` and the detail `The Google token endpoint answered with something that is not JSON: ~A`.
A reply with no access token signals the same condition with the detail `The Google token endpoint returned no access token: ~A`.

| Condition                     | Error detail                                                                                                                                                   |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No credential at all          | `No Google credential: set GOOGLE_APPLICATION_CREDENTIALS to a service account file, or GOOGLE_VERTEX_ACCESS_TOKEN or GCLOUD_ACCESS_TOKEN to an access token.` |
| The named file does not exist | `~A names ~A, which does not exist.`                                                                                                                           |
| The file is not JSON          | `~A could not be read as JSON: ~A`                                                                                                                             |
| A field is missing            | `The service account has no ~A (~A).`                                                                                                                          |
| The private key is not PEM    | `The service account private_key is not a PEM block: it has no BEGIN and END banners.`                                                                         |
| The base64 cannot be decoded  | `The service account private key is not readable base64: ~A`                                                                                                   |
| The DER is malformed          | `The service account private key is malformed: ~A`                                                                                                             |

All of them signal `configuration-error` at `:gcp-credentials`.

The signer is registered under `:gcp-oauth`.

## Model lists

`provider-models` returns the model rows a provider can serve.
The provider's endpoint is asked when its adapter has a lister, and the answer is cached.
The chat completions lister reads `{base-url}{models-path}`, and the Messages lister reads `v1/models` in pages.
Bedrock reads the control plane model list, and Vertex offers none.

The cache file is `run/models/{provider}.json`.
The name is the id lowercased, with every character outside letters, digits, hyphen, underscore, and dot replaced by a hyphen.
`*model-cache-directory*` overrides the directory.
Each file carries `fetched_at`, `fetched_at_iso`, and a `models` array.

A cached list is fresh for `:models-ttl-seconds`, and the row option wins over the configuration.
`refresh` skips the cache, and `force` overrides `:offline`.

A failure is never a signal.
The fallback order is the last cached list at any age, the row's own `:models`, the catalog's list, and nothing.
One line goes to standard error: `enchiridion: could not list models for ~A: ~A`.
The operator's `providers models ID` command bypasses `:offline` and may refresh one provider's cache.
With `:offline t` and no `force`, the cache, the row's models, and the catalog answer without a request.

Cost and limit metadata from the catalog is joined by model id.
The live list keeps its ids and names and takes the metadata's prices, context window, output limit, and capability flags.

The record is a `model-info`.
It holds `model-info-id`, `model-info-name`, `model-info-tool-call-p`, `model-info-reasoning-p`, `model-info-context`, `model-info-output`, `model-info-cost-input`, `model-info-cost-output`, `model-info-cost-cache-read`, `model-info-cost-cache-write`, and `model-info-source`.
The costs are USD per million tokens, and the source is `:provider`, `:catalog`, or `:config`.
A nil cost or limit means the source did not state the fact.

## Token accounting

Every backend fills four token slots from the provider's usage object, and the cache split is kept apart from ordinary input.

The two wires count input differently and are normalized to one meaning.

| Wire             | Reported input                  | Stored input                                                                     |
| ---------------- | ------------------------------- | -------------------------------------------------------------------------------- |
| Chat completions | `prompt_tokens`, cache included | the reported number                                                              |
| Messages         | `input_tokens`, cache excluded  | `input_tokens` plus `cache_read_input_tokens` plus `cache_creation_input_tokens` |

A missing, null, or non-integer count becomes zero.
`completion-total-tokens` adds input and output only.
The kernel records each completion in the spend ledger and the usage table, and `supervisor.md` owns both.

## Secrets

`configuration.md` owns the secret file, its mode, and the `.env` format.
This section covers the loader functions and the scrubber.

### Loading

`load-secrets` takes a path and a list of variable names, loads both, and returns every loaded name.
The caller unsets those names from its own environment afterward.
`parse-env-line` skips a blank line, a comment, and a malformed line, and removes matching quotes.

| Accessor           | Returns                                               |
| ------------------ | ----------------------------------------------------- |
| `register-secret`  | the name, after storing the value and the source      |
| `secret-present-p` | true when the name is loaded                          |
| `secret-value`     | the value, or nil                                     |
| `secret-source`    | `:file`, `:env`, or `:argument`                       |
| `secret-names`     | every loaded name, sorted                             |
| `clear-secrets`    | nothing, after forgetting every value and the pattern |

An empty value and a non-string value are ignored, and a new secret clears the combined pattern.

`credential-variable-p` decides which variable names hold a credential, from the name only, and the test is case-insensitive.
A name is a credential when it is one of `OPENAI_API_KEY`, `OPENCODE_API_KEY`, `ANTHROPIC_API_KEY`, `FLUXER_BOT_TOKEN`, or `ENCHIRIDION_HTTP_TOKEN`.
It is also one when it contains `_API_KEY`, `_APIKEY`, `_TOKEN`, `_SECRET`, `_PASSWORD`, `_PASSWD`, `_PRIVATE_KEY`, or `AUTHORIZATION`.
Ordinary runtime names are not credentials, including `PATH`, `HOME`, `SBCL_HOME`, `CL_SOURCE_REGISTRY`, and the `XDG_` names.

The names a configuration says hold secrets belong to `configuration.md`.
The supervisor unions them with `provider-key-names` before it loads.

### The scrubber

`scrub` replaces every match with `[redacted]`, using one combined pattern built from three filters.

| Filter  | Matches                                                                                                                               |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Literal | any loaded value of at least `*minimum-secret-length*` characters                                                                     |
| Shape   | a bearer token, an `sk-` key, a `gh[pousr]_` token, an `xox[baprs]-` token, a JWT, or a `key=value` pair whose key names a credential |
| Role    | a field named token, secret, password, api key, credential, or authorization, whatever the value looks like                           |

The shape thresholds are 8 character bodies for `sk-` and `xox` tokens, 16 for `gh` tokens, and 6 for a credential-named `key=value` pair.
A bearer token is the word after `Bearer`, and a JWT is a token that begins with `eyJ`.

`*minimum-secret-length*` is 8.

The literal parts are sorted longest first, and the pattern is rebuilt when the number of loaded secrets changes.
The shape patterns apply even when no secret is loaded.

| Operation      | Effect                                                                              |
| -------------- | ----------------------------------------------------------------------------------- |
| `scrub`        | text with every match replaced, and a non-string returned unchanged                 |
| `scrub-object` | every string and every key inside a cons, vector, or hash table scrubbed            |
| `scrub-tree`   | every string scrubbed, and the value of a role-named field replaced with the marker |
| `seal`         | stop replacing, for a test that must re-read a value                                |
| `unseal`       | resume replacing                                                                    |
| `sealed-p`     | the current state                                                                   |

`scrub-tree` does not descend into a hash table, so a table needs `scrub-object`.
The role filter catches a credential this process never loaded.

A non-string comes back unchanged from `scrub`.
The kernel scrubs the prompt, the operator text, and every tool result, and the broker scrubs every result it returns.
`memory.md` owns the store's scrubbing.

## Troubleshooting

| Symptom                                                        | Cause                                                         | Fix                                                                     |
| -------------------------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `There is no provider called X.`                               | no configured row and no cached catalog entry                 | run `providers refresh`, or add the row under `:providers`              |
| `X (x) has no adapter in this build (npm ...).`                | the package has no adapter in this build                      | set `:base-url` and `:api` on the row                                   |
| `Provider x has no endpoint`                                   | no base URL and an absent placeholder variable                | set `:base-url`, or export the variable the endpoint needs              |
| `transport-error` with `429 after N attempts`                  | the provider kept refusing after the retry budget             | check the account quota, then raise `:retries` or `:timeout` on the row |
| `could not list models for X` on standard error                | the model endpoint failed or the adapter has no lister        | ignore it, set `:models` on the row, or run `providers models ID` later |
| `No AWS region is configured`                                  | the row, `AWS_REGION`, and `AWS_DEFAULT_REGION` are all empty | set one of them                                                         |
| `No AWS credential is available to sign with`                  | an access key or a secret key is missing                      | set both AWS variables, or use `AWS_BEARER_TOKEN_BEDROCK`               |
| A reply with no choices or no content blocks                   | the provider returned an error envelope                       | read the transport error or the provider's message                      |

## See also

- [Configuration](configuration.md) for the provider row keys, the shipped rows, and the secret name list.
- [Tools](tools.md) for the tool definitions that `complete` receives and the tool calls a completion returns.
- [Commands](commands.md) for `providers`, `secrets`, and the exit statuses of each command.
- [Supervisor and heartbeat](supervisor.md) for the spend ledger, the budget windows, and the process that holds the key.
- [Memory](memory.md) for the store's own scrubbing and the search that reads stored turns.
