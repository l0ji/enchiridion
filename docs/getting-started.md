# Getting started

This page creates an agent and holds the first conversation.

## Requirements

- Linux or macOS with Nix
- An API key for one provider

## Create the agent

```sh
git clone https://tangled.org/hexmani.ac/enchiridion
cd enchiridion
cp config.example.lsp config.lsp
cp .env.example .env
chmod 600 .env
```

Open `.env`, uncomment one provider line, and replace `add-key` with your key.

| Provider | Line to uncomment |
| --- | --- |
| OpenAI | `OPENAI_API_KEY=add-key` |
| OpenCode Go | `OPENCODE_API_KEY=add-key` |
| Anthropic | `ANTHROPIC_API_KEY=add-key` |

You can leave `config.lsp` alone for the first run. The key selects the provider,
and the provider supplies a default model. If your shell exports another
provider key, set `:provider` explicitly. See [Configuration](configuration.md)
for provider, model and channel settings.

## Create the agent

```sh
nix run .#enchiridion -- init
```

This creates `agents/default/`. Edit these files before starting a conversation:

| File | What to put in it |
| --- | --- |
| `SOUL.md` | The agent's personality and instructions |
| `OPERATOR.md` | Your name, preferences and expectations |
| `WORLD.md` | The machine and services it can use |

Leave `BOOTSTRAP.md` for the agent to work through on its first turns.
Set `ENCHIRIDION_HOME` to an absolute directory before running `init` if you want
state somewhere other than this checkout. Use the same value on later runs.

## Talk to it

```sh
nix run .#enchiridion -- chat
nix run .#enchiridion -- ask "What can you do?"
```

`chat` opens the REPL. Type `/help` for commands or `/quit` to leave.
`ask` sends one question and exits.

> [!warning]
> In a normal checkout the agent runs as your user. Its file and shell tools can
> read your files, including `.env`. Use the container deployment for a separate
> agent user.

## Keep it running

```sh
nix run .#enchiridion -- serve
```

`serve` starts the supervisor and runs background work every 15 minutes by default.
It also starts the enabled [channels](channels.md). In a terminal you can chat;
on a server, configure HTTP or Fluxer. `Ctrl-C` stops it.

For server setup, health checks and backups, use [Deployment](deployment.md).
