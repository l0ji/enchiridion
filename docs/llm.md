# LLM providers

enchiridion talks to OpenAI-compatible chat APIs, the Anthropic Messages API,
Amazon Bedrock and Google Vertex. One provider row is active at a time. Every
LLM setting belongs under `:llm` in `config.lsp`; the full key list is in the
[settings reference](config-reference.md).

## Built-in providers

| Provider | `:provider` | Key | Default model | Endpoint |
| --- | --- | --- | --- | --- |
| OpenAI | `:openai` | `OPENAI_API_KEY` | `gpt-5.6-luna` | `https://api.openai.com/v1/` |
| OpenCode Go | `:opencode` | `OPENCODE_API_KEY` | `deepseek-v4.1-flash` | `https://opencode.ai/zen/go/v1` |
| Anthropic | `:anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-5-5` | `https://api.anthropic.com/` |

These three rows work without a catalog fetch. Every other provider comes from
the models.dev catalog, or from a row you write.

## Selecting a provider

With no explicit `:provider`, selection takes the first match:

1. a `:base-url` whose host is `opencode.ai`, `api.anthropic.com` or
   `api.openai.com`, then a cached catalog endpoint;
2. `OPENAI_API_KEY`, then `OPENCODE_API_KEY`, then `ANTHROPIC_API_KEY`;
3. the one cached provider whose key variable is present;
4. OpenAI.

Two provider keys in `.env` need an explicit `:provider`, because OpenAI wins
the tie. `:backend :anthropic` also selects the Anthropic row when an OpenAI
key is present. `:backend` accepts `:openai`, `:anthropic`, or an adapter id.

## A provider from the catalog

`providers list` shows every provider this build knows, its endpoint, its key
variable and whether that key is loaded. `providers refresh` fetches the
catalog. Any listed id can be selected:

```lisp
:llm
(:provider :groq)
```

The catalog supplies the endpoint, the key variable and the default model. A
row under `:providers` overrides fields for one id:

```lisp
:llm
(:provider :deepseek)
(:providers
 ((:id :deepseek :profile :deepseek)))
```

DeepSeek speaks the OpenAI wire but reports its chain of thought in
`reasoning_content`. Its package is generic, so the catalog row carries no
profile; the row above names one. `providers show deepseek` prints the merged
row. A row without an `:id` is a configuration error. An operator row wins
field by field over the catalog row and the shipped row.

## A local or custom endpoint

For a server with no catalog entry, write a provider row:

```lisp
:llm
(:provider :local)
(:providers
 ((:id :local
   :base-url "http://127.0.0.1:1234/v1/"
   :profile :openai-local
   :api-key-env "LOCAL_API_KEY"
   :model "local-model"
   :models ("local-model"))))
```

The row needs a key variable with a non-empty value, because the CLI builds a
backend only when it resolves one. A local server needs no credential, so a
dummy value is enough:

```sh
LOCAL_API_KEY=dummy
```

The `:openai-local` profile never sends it. Keep credential values in `.env`,
never in `:headers` in `config.lsp`.

For a hosted endpoint with no catalog entry, `:custom` reads the same facts
from top-level keys and uses the OpenAI-shaped wire unless `:backend` names
another adapter:

```lisp
:llm
(:provider :custom)
(:base-url "https://api.example.com/v1/")
(:api-key-env "EXAMPLE_API_KEY")
(:model-primary "example-model")
```

## Authentication and endpoint quirks

| Scheme | Effect | Used by |
| --- | --- | --- |
| `:bearer` | `Authorization: Bearer KEY` | most OpenAI-compatible APIs |
| `:api-key-header` | a named header, `api-key` by default | Azure, Cloudflare AI Gateway |
| `:x-api-key` | `x-api-key: KEY` | Anthropic |
| `:query-param` | a key in the query string, `key` by default | endpoints that take a key in the URL |
| `:none` | no credential sent | local servers |
| `:aws-sigv4` | the request is signed | Bedrock |
| `:gcp-oauth` | an OAuth bearer token | Vertex |

A row may set `:auth-scheme` and `:auth-header` directly. `:auth-prefix`
comes only from a profile, so a vendor that needs one needs the profile. A
catalog row gets a profile from its package; set these on a row you write
yourself:

| Setup | What to set |
| --- | --- |
| LM Studio, llama.cpp, vLLM | `:profile :openai-local` |
| Ollama | `:profile :ollama`; add `:chat-path "v1/chat/completions"` when the base URL is the server root |
| Azure OpenAI | select `:azure`; set `AZURE_RESOURCE_NAME`; `:model` is the deployment name |
| OpenRouter | select `:openrouter`; key `OPENROUTER_API_KEY` |
| Cloudflare AI Gateway | `:profile :cloudflare-gateway`; append the account and gateway ids to `:base-url` |
| An Anthropic-shaped gateway with a bearer token | `:profile :anthropic-gateway` |
| DeepSeek reasoning fields | `:profile :deepseek` on a hand row |
| Google, Qwen or Z.ai reasoning fields | `:profile :google-openai`, `:qwen` or `:zai` on a hand row |
| Groq | `:profile :groq` when its portability switches are needed |

`:openai` and `:anthropic` are the generic wires, and the Bedrock and Vertex
rows below select their own profiles. A row may also set `:chat-path`,
`:models-path`, `:max-tokens-field`, `:system-role` and `:reasoning-field`
directly.

## Amazon Bedrock

Select the adapter with `:api`:

| Adapter | Endpoint | Model | API revision |
| --- | --- | --- | --- |
| `:bedrock-invoke` | InvokeModel, `model/{model}/invoke` | in the path | `bedrock-2023-05-31` in the body |
| `:bedrock-messages` | the Bedrock gateway, `anthropic/v1/messages` | in the body | `anthropic-version` header |

The region comes from the row's `:region`, then `AWS_REGION`, then
`AWS_DEFAULT_REGION`. There is no default region and the error names all three.

The credential is chosen at request time:

1. `AWS_BEARER_TOKEN_BEDROCK` wins outright.
2. A provider key is sent as a bearer token only when no AWS access key is
   available.
3. Otherwise the request is signed with SigV4 using `AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY`, plus `AWS_SESSION_TOKEN` when it exists.

A Bedrock request with no model is refused, because the model is part of the
path or the body.

## Google Vertex

`:api :vertex-anthropic` serves Anthropic models through Vertex AI. The
endpoint is per project, region and model, and the model is a path segment.

| Setting | Source |
| --- | --- |
| project | row `:project`, then `GOOGLE_VERTEX_PROJECT` |
| region | row `:location`, then `GOOGLE_VERTEX_LOCATION` |
| credential | `GOOGLE_VERTEX_ACCESS_TOKEN`, then `GCLOUD_ACCESS_TOKEN`, then the service account at `GOOGLE_APPLICATION_CREDENTIALS` |

An operator-minted token is used as it stands. A service account JSON is
exchanged for a token at request time. Vertex publishes no Anthropic model
list, so the endpoint answers no list and the catalog answers instead.

## Models

`:model-primary` replaces the row's model for conversation and tool calls.
`:model-cheap` names the model for memory maintenance, and `:model-sleep` names
the model for background passes. When either is unset, the request uses the
backend's model: `:model-primary` if you set it, otherwise the provider row's
model or default.

`:max-tokens` caps one reply, not a day. When the key is absent, the
Messages-shaped APIs send `4096` and the OpenAI-shaped wire sends no cap.

## The provider catalog

The catalog is fetched from `https://models.dev/api.json` on commands that run
a turn and cached under the state root; the two TTL keys set cache lifetimes.

`:offline t` stops every automatic catalog and model-list fetch. `providers
refresh` and `providers models ID` still run, because you asked for them.

A model list is cached per provider under the state root. When the request
fails, one line goes to standard error and the fallback order is the last
cached list, the row's `:models`, the catalog's list, and nothing.

## Request options

`:timeout` (60 seconds), `:retries` (2), `:max-tokens`, `:cache-p`,
`:cache-ttl`, `:betas`, `:headers` and `:query-params` work under `:llm` and in
a `:providers` row; the row wins. Only 429 and 5xx responses are retried, with
attempt N waiting N times 2 seconds. See the [settings
reference](config-reference.md#llm) for the full row key list.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `There is no provider called X.` | no configured row and no catalog entry | run `providers refresh`, or add the row |
| `X (x) has no adapter in this build (npm ...).` | the catalog package has no adapter here | set `:base-url` and `:api`, or name a profile |
| `Provider x has no endpoint` | no base URL, and the variable its default needs is missing | set `:base-url`, or export that variable |
| `transport-error` with `429 after N attempts` | the provider kept refusing | check the account quota, then raise `:retries` |
| `could not list models for X` on standard error | the model endpoint failed | ignore it, set `:models`, or run `providers models X` later |
| `No AWS region is configured` | the row and both AWS region variables are empty | set one |
| `No AWS credential is available to sign with` | access key or secret key missing | set both, or use `AWS_BEARER_TOKEN_BEDROCK` |
| A reply with no choices or no content blocks | the provider returned an error envelope | read the transport error or the provider's message |

A reply that combines thinking with tool calls is a backend error. The message
model cannot replay reasoning blocks, so no request is sent with a transcript
that has lost them. Plain text and ordinary tool calls are unaffected.
