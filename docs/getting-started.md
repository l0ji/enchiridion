# Getting started

This guide covers creating a local agent and running your first conversation.
Requirements: Linux or macOS with Nix and an API key for at least one LLM
provider.

## 1. Set up config and secrets

```sh
git clone https://tangled.org/hexmani.ac/enchiridion
cd enchiridion
cp config.example.lsp config.lsp
cp .env.example .env
chmod 600 .env
```

Open `.env`, uncomment one provider key (`OPENAI_API_KEY`, `OPENCODE_API_KEY`,
or `ANTHROPIC_API_KEY`), and paste your key.

You do not need to edit `config.lsp` for a first run. With `(:provider nil)`,
enchiridion selects the provider from your key and uses its default model. If
you have multiple provider keys set (including in your shell environment), set
`:provider` explicitly in `config.lsp`. See [Configuration](configuration.md)
for details.

## 2. Initialize the agent

```sh
nix run .#enchiridion -- init
```

This creates `agents/default/` (an isolated git repository) with starter files.
Edit these three before your first conversation:

- `SOUL.md` — the agent's personality, voice, and rules
- `OPERATOR.md` — who you are, how you prefer answers, and when it may act alone
- `WORLD.md` — the machine, paths, and services it can use

Keep `BOOTSTRAP.md` unmodified; the agent works through it during its first
turns. If you want state stored outside the repository, set `ENCHIRIDION_HOME`
to an absolute path before running `init` and keep it set on later runs.

## 3. Talk to it

```sh
nix run .#enchiridion -- chat
nix run .#enchiridion -- ask "What can you do?"
```

- `chat` starts the interactive REPL (`enchiridion> `). Commands start with a
  slash (`/help`, `/stop`, `/quit`, `/who`); anything else is sent as a message.
  `Ctrl-C` cancels the current line or turn without exiting.
- `ask` runs a single turn, prints the reply to stdout (and progress to stderr),
  and exits.

Run `enchiridion help` for all CLI commands, or `enchiridion help <command>` for
subcommands and usage. Commands exit `0` on success, `1` on runtime, turn, or
build failure, `2` on invalid usage or configuration, and `130` on interrupt.

> [!warning]
> In a local checkout, the agent runs as your UNIX user. Its file and shell
> tools can read anything you can, including `.env`. Use the [Docker
> deployment](deployment.md) when you need user separation.

## 4. Keep it running

```sh
nix run .#enchiridion -- serve
```

`serve` runs the supervisor, starts enabled [channels](channels.md), and runs
background memory and task ticks every 15 minutes by default. Press `Ctrl-C` to
stop it.

For server setup, TLS access, health checks, and backups, see
[Deployment](deployment.md).
