# Configuration

`config.lsp` holds settings. `.env` holds API keys and tokens. Both files are
ignored by Git. Copy the examples before editing them:

```sh
cp config.example.lsp config.lsp
cp .env.example .env
chmod 600 .env
```

Restart the program after changing settings. The example lists common settings;
the [settings reference](config-reference.md) lists the rest.

## Provider and models

Uncomment one API key in `.env`. With `(:provider nil)`, enchiridion selects
OpenAI, OpenCode Go or Anthropic from the key you supplied. If more than one key
is present, including exported keys, set the provider explicitly in `config.lsp`.

| Provider | Setting | Key in `.env` | Default model |
| --- | --- | --- | --- |
| OpenAI | `(:provider :openai)` | `OPENAI_API_KEY` | `gpt-5.6-luna` |
| OpenCode Go | `(:provider :opencode)` | `OPENCODE_API_KEY` | `deepseek-v4.1-flash` |
| Anthropic | `(:provider :anthropic)` | `ANTHROPIC_API_KEY` | `claude-sonnet-5-5` |

Model names go in quotes. `primary` defaults to the provider's model; leaving
`cheap` and `sleep` as `nil` uses that same selected model:

```lisp
:llm
(:provider :opencode)
(:model-primary "deepseek-v4.1-flash")
(:model-cheap nil)
(:model-sleep nil)
```

`primary` handles conversations and tools, `cheap` handles memory summaries,
and `sleep` handles background work. These entries all belong inside the quoted
list in `config.lsp`; do not paste a second `:llm` section into it.

For another provider or a local endpoint, see [LLM providers](llm.md).

## Channels

HTTP and Fluxer are off by default. Change their `:enabled` value to `t` to
start them with `serve`. `nil` means off.

### HTTP

```lisp
(:http
 (:enabled t)
 (:bind "127.0.0.1")
 (:port 8787)
 (:token-env "ENCHIRIDION_HTTP_TOKEN"))
```

This listens on the local machine. For a network listener, use `"0.0.0.0"` and
set `ENCHIRIDION_HTTP_TOKEN` in `.env`. Generate a token with
`openssl rand -hex 32`. A non-loopback listener refuses to start without one.

Docker Compose sets the bind address and port on its command line, overriding
these settings. See [Deployment](deployment.md) before exposing the port.
[Channels](channels.md) lists the routes and request format.

### Fluxer

```lisp
(:fluxer
 (:enabled t)
 (:allowed-users ("your-user-id"))
 (:token-env "FLUXER_BOT_TOKEN"))
```

Put the bot token in `.env` and replace `your-user-id` with your Fluxer user id.
Only listed users can send it direct messages. An empty list admits nobody.
The surrounding config list is already quoted, so the user list needs no extra
quote. See [Channels](channels.md) for bot setup.

## Background work

The `:sleep` section controls the schedule during `serve`:

```lisp
:sleep
(:enabled t)
(:interval-seconds 900)

:budget
(:max-tokens-per-tick 4000)
(:max-tokens-per-day 400000)
```

Set `:enabled` to `nil` to disable scheduled background work. The interval is in
seconds. The token caps stop new background phases; an in-flight phase may
exceed them. They do not cap interactive conversations or provider charges.
Use your provider's spending controls for a monetary limit.

## Files and secrets

The program looks for `config.lsp` at `ENCHIRIDION_CONFIG`, in the current
directory, then at the source root. A root process skips the current directory
and requires a root-owned config path. Docker's entrypoint installs that copy.
`config.lsp` is Lisp code, so only load files you trust.

Secrets come from the first existing file among `/run/secrets/.env`,
`./.env`, and `.env` at the source root. Exported environment values override
values in that file. Use one `NAME=VALUE` per line and mode `600`.

| Variable | Use |
| --- | --- |
| `ENCHIRIDION_CONFIG` | Explicit config path |
| `ENCHIRIDION_HOME` | State root containing `agents/default/` and `run/`; defaults to the working directory |
| `ENCHIRIDION_HTTP_TOKEN` | HTTP bearer token |
| `FLUXER_BOT_TOKEN` | Fluxer bot token |

The [settings reference](config-reference.md) covers memory tuning, custom
providers, sandbox settings and the remaining environment variables.
