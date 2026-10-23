# Getting started

This page will teach you how to create an agent and begin communicating with it.

## Requirements

- A box with Linux or macOS with Nix installed
- An API key for your preferred provider

## Create the agent

Clone the repository and then make sure the harness can be built:

```sh
git clone https://tangled.org/hexmani.ac/enchiridion
nix run .#check
```

If it compiles, you can then modify the example config file to your needs and start the harness:

```sh
cp config.example.cl config.cl
nix run .#enchiridion
```

By default, this will write a set of files in `./agents/default/` and then exit.
To create these files in another directory, set the `ENCHIRIDION_HOME` environment
variable to another absolute path.

## Give the agent a personality

Edit three files in the agent directory:

- `SOUL.md`: information about itself
- `OPERATOR.md`: information about you
- `WORLD.md`: information about its host

Unless you know what you are doing, do not modify BOOTSTRAP.md as your agent
will need to follow its instructions to incorporate your changes.

## Add your provider

In the source code root, copy the `.env.example` file and add the key for your provider:

```sh
cp .env.example .env
chmod 600 .env          # harness will not work if this can be read by anyone beside the user which owns the file!
```

## Start a conversation

To start a basic chat REPL, run `nix run .#enchiridion -- chat` and type a
message. `/help` lists all available commands.

To quickly ask a single question instead:

```sh
nix run .#enchiridion -- ask "What can you do?"
```

## Run persistently

To run the agent as a background server and be communicatable through channels,
use the `serve` command.

For more information, refer to the [[Supervisor and heartbeat]](supervisor.md) and [[Channels]](channels.md) pages.

## See also

- [[Configuration]](configuration.md): every key, the provider rows, and the secret rules.
- [[Commands]](commands.md): the commands, flags, exit statuses, and the REPL.
- [[Supervisor and heartbeat]](supervisor.md): the process, the status file, and the schedule.
- [[Memory]](memory.md): the seed files, the store, and the bootstrap.
- [[Deployment]](deployment.md): the container, the isolation test, and the backup procedure.
