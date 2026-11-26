# Configuration

Settings live in `config.lsp` (a quoted Lisp plist) and credentials live in
`.env` (`NAME=VALUE`, mode `600`). Both files are gitignored; start by copying
`config.example.lsp` and `.env.example`. Restart enchiridion after editing
either file.

This page covers the settings most deployments need. For every configuration key
and environment variable, see the [Settings reference](config-reference.md).

## How files and secrets are loaded

- **Config:** searched in order at `ENCHIRIDION_CONFIG`, `./config.lsp`, then
  `<source-root>/config.lsp`. When running as root, `./config.lsp` is skipped
  and the config path must be root-owned. `config.lsp` is loaded as Lisp, so
  only load files you trust.
- **Secrets:** loaded from the first existing file among `/run/secrets/.env`,
  `./.env`, and `<source-root>/.env`. Exported environment variables override
  `.env`. A world-readable secrets file is refused—keep it `chmod 600`.
- **State root:** `ENCHIRIDION_HOME` (defaults to the current directory) holds
  `agents/default/` and `run/`.

## LLM providers and models

One provider is active at a time. All provider settings go inside the `:llm`
section of `config.lsp` (do not add a second `:llm` section).

### Built-in providers

These three work offline without fetching the provider catalog:

| Provider | `:provider` | Env var in `.env` | Default model |
| --- | --- | --- | --- |
| OpenAI | `:openai` | `OPENAI_API_KEY` | `gpt-5.6-luna` |
| OpenCode Go | `:opencode` | `OPENCODE_API_KEY` | `deepseek-v4.1-flash` |
| Anthropic | `:anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-5-5` |

With `(:provider nil)`, enchiridion auto-detects in order: matching `:base-url`
host → `OPENAI_API_KEY` → `OPENCODE_API_KEY` → `ANTHROPIC_API_KEY` → a unique
cached catalog provider whose key is set → OpenAI. If you have more than one key
in `.env` or your shell, set `:provider` explicitly.

*(Note: reasoning replay during tool rounds is only supported for
`deepseek-v4.1-flash` on OpenCode Go endpoints. Elsewhere, replies that combine
thinking with tool calls are rejected—disable thinking or use a non-thinking
model.)*

### Models

```lisp
:llm
(:provider :opencode)
(:model-primary "deepseek-v4.1-flash")
(:model-cheap nil)   ; memory summaries; nil falls back to primary
(:model-sleep nil)   ; background work; nil falls back to primary
```

`:max-tokens` caps a single reply. If omitted, Anthropic/Messages APIs default
to `4096` and OpenAI-compatible APIs send no cap.

### Providers from the models.dev catalog

Run `enchiridion providers refresh` to fetch the catalog and `enchiridion
providers list` to see available IDs, endpoints, and key variables. Select any
listed ID directly:

```lisp
:llm
(:provider :groq)
```

To customize a catalog provider (for example, adding a dialect profile),
override fields by `:id` under `:providers`:

```lisp
:llm
(:provider :deepseek)
(:providers
 ((:id :deepseek :profile :deepseek)))
```

Use `enchiridion providers show <id>` to inspect the merged row, or `enchiridion
providers models <id>` to query the models your key can access. Set `(:offline
t)` to stop automatic catalog/model fetches during turns (`providers refresh`
and `providers models` still run when you invoke them).

### Local or custom endpoints

For a local server (LM Studio, llama.cpp, vLLM, Ollama), add a row under
`:providers`:

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

Put a placeholder value like `LOCAL_API_KEY=dummy` in `.env` (the CLI checks
that the key variable is non-empty, and `:openai-local` does not send it). For
Ollama, use `:profile :ollama` and add `:chat-path "v1/chat/completions"` if
`:base-url` is the server root.

For a hosted OpenAI-compatible endpoint without a catalog entry, `:custom` lets
you set top-level keys directly:

```lisp
:llm
(:provider :custom)
(:base-url "https://api.example.com/v1/")
(:api-key-env "EXAMPLE_API_KEY")
(:model-primary "example-model")
```

Useful profiles for custom rows: `:openai-local`, `:ollama`,
`:cloudflare-gateway`, `:anthropic-gateway`, `:deepseek`, `:google-openai`,
`:qwen`, `:zai`, `:groq`. Never put API keys in `:headers` inside
`config.lsp`—always reference an env var in `.env`.

### Amazon Bedrock and Google Vertex

- **Bedrock:** set `:api :bedrock-invoke` (InvokeModel) or `:api
  :bedrock-messages` (Anthropic Messages gateway). Region comes from `:region`,
  `AWS_REGION`, or `AWS_DEFAULT_REGION` (required). Auth tries
  `AWS_BEARER_TOKEN_BEDROCK`, then a provider bearer key if no AWS keys exist,
  otherwise SigV4 (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional
  `AWS_SESSION_TOKEN`). Always set a model.
- **Vertex:** set `:api :vertex-anthropic`. Project comes from `:project` or
  `GOOGLE_VERTEX_PROJECT`; region from `:location` or `GOOGLE_VERTEX_LOCATION`.
  Auth tries `GOOGLE_VERTEX_ACCESS_TOKEN`, `GCLOUD_ACCESS_TOKEN`, then
  `GOOGLE_APPLICATION_CREDENTIALS` (service account JSON).

### Request options

`:timeout` (default `60`s), `:retries` (default `2`, retries 429 and 5xx with
`attempt * 2`s backoff), `:max-tokens`, `:cache-p`, `:cache-ttl`, `:betas`,
`:headers`, and `:query-params` work under `:llm` or inside a `:providers` row
(the row wins).

## Channels

HTTP and Fluxer are off by default. Enable them under `:channels` in
`config.lsp` (or temporarily with `--channel http` / `--channel fluxer` on the
CLI):

```lisp
:channels
(:http
 (:enabled t)
 (:bind "127.0.0.1")
 (:port 8787)
 (:token-env "ENCHIRIDION_HTTP_TOKEN"))

(:fluxer
 (:enabled t)
 (:allowed-users ("your-user-id"))
 (:token-env "FLUXER_BOT_TOKEN"))
```

Binding HTTP to anything other than loopback (like `"0.0.0.0"`) refuses to start
unless `ENCHIRIDION_HTTP_TOKEN` is set in `.env` (generate one with `openssl
rand -hex 32`). For Fluxer, `:allowed-users` is a deny-by-default list of string
user IDs (no extra quote needed inside `config.lsp`). See
[Channels](channels.md) for routes, request format, and Fluxer custom status.

## Background work and budgets

During `serve`, the supervisor runs a background tick on a timer:

```lisp
:sleep
(:enabled t)
(:interval-seconds 900)

:budget
(:max-tool-rounds 64)
(:max-tokens-per-tick 400000)
(:max-tokens-per-day 40000000)
```

The token caps only stop new background phases from starting—an in-flight call
can exceed them, and they **do not** cap interactive chats or provider billing.
Set spending limits at your LLM provider.
