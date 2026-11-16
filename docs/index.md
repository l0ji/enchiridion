# enchiridion documentation

enchiridion is an autonomous agent harness written in Common Lisp.
The supervisor holds the model client, the secrets, the memory store, and the channels; agent code runs in a child process, under its own user in the container and a root-started checkout, and as the operator in an operator checkout (see [Deployment](deployment.md)).
This documentation describes the code as it is.

## Start here

- [Getting started](getting-started.md) creates one agent and holds the first conversation.

## Running an agent

- [Configuration](configuration.md): every key of `config.cl` and the secret rules.
- [Commands](commands.md): commands, flags, arguments, and exit statuses.
- [Channels](channels.md): the terminal, the HTTP webhook, and Fluxer.
- [Supervisor and heartbeat](supervisor.md): the process, the schedule, the status file, and the budget.
- [Deployment](deployment.md): the container, the two users, the isolation test, and backup.

## How it works

- [Memory](memory.md): blocks, seed files, the store, and compaction.
- [Episodic memory](episodic-memory.md): the log, the cue pack, and the gates.
- [Large language model backends](llm.md): backends, the provider catalog, token accounting, and the scrubber.
- [Tools](tools.md): the schema, the registry, the broker, and every built-in tool.
- [Plugins and self-modification](plugins.md): manifests, verification, and reloads.
- [Skills](skills.md): the two kinds of skill.
- [Testing](testing.md): the test systems, the bridge, and the gate.

## Changing the program

- [Development](development.md): layout, build, style, and commit policy.

The [README](../README.md) holds the build and run summary.

## Conventions

| Notation                    | Meaning                                          |
| --------------------------- | ------------------------------------------------ |
| `enchiridion chat`          | A shell command.                                 |
| `/help`                     | A command typed at the REPL prompt.              |
| `config.cl`                 | A file or path.                                  |
| `:model-primary`            | A Lisp keyword or status word.                   |
| `src/enchiridion/kernel.cl` | A source file, relative to the repository root.  |

A default column gives the value the program uses when the key is absent.
An exit status is the value the shell reports.
