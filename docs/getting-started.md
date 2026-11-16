# Getting started

This page creates an agent and holds the first conversation.

## Requirements

- Linux or macOS with Nix
- An API key for one provider

## Create the agent

```sh
git clone https://tangled.org/hexmani.ac/enchiridion
cd enchiridion
nix run .#check
```

`check` compiles the tree but runs no test. It needs no configuration.

Copy the example configuration, edit it if you need a provider, model, or path, and run the first launch:

```sh
cp config.example.cl config.cl
nix run .#enchiridion
```

The first launch writes the seed files under `./agents/default/` and exits, so the operator can edit them before the agent starts. Set `ENCHIRIDION_HOME` to an absolute path to put `agents/default/` and `run/` somewhere else.

## Give the agent a personality

Three files in the agent directory are the agent's identity:

- `SOUL.md`: who it is
- `OPERATOR.md`: who it works for
- `WORLD.md`: the machine it runs on

Edit them. Leave `BOOTSTRAP.md` alone: it is the first-steps script the agent works through, and the handover archives it.

## Add a provider key

Copy the example secret file and put a provider key in it:

```sh
cp .env.example .env
chmod 600 .env
```

The loader refuses a world-readable `.env`. `OPENAI_API_KEY`, `OPENCODE_API_KEY`, and `ANTHROPIC_API_KEY` select their provider; the configuration may name another variable instead. The key can also come from the process environment.

## Talk to it

```sh
nix run .#enchiridion -- chat
```

Type a line to send a turn. `/help` lists the REPL commands. For one question without a session:

```sh
nix run .#enchiridion -- ask "What can you do?"
```

## Run it persistently

`serve` starts the supervisor, the heartbeat, and the configured channels:

```sh
nix run .#enchiridion -- serve
```

The terminal channel needs a terminal. The HTTP webhook and the Fluxer gateway are described in [Channels](channels.md); [Supervisor and heartbeat](supervisor.md) covers the schedule and the control commands.

## See also

- [Configuration](configuration.md): every configuration key and the secret rules.
- [Commands](commands.md): commands, flags, and exit statuses.
- [Memory](memory.md): the seed files and the bootstrap.
- [Deployment](deployment.md): the container and the isolation test.
