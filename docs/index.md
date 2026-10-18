# enchiridion documentation

`enchiridion` is an autonomous agent harness written in Common Lisp. The
supervisor process holds the model client, the secret values, the memory store,
and the channels. The kernel compiles the memory blocks into one prompt for a
session. One turn calls the model with that prompt, and calls it again for each
round of tool calls, up to the tool-round limit.

## The shape of a run

1. `enchiridion` with no command writes the agent directory on the first
   launch, then stops.
2. `enchiridion serve` starts the supervisor and the channels that the
   configuration enables.
3. `enchiridion chat` starts the supervisor with the terminal channel in the
   foreground.
4. A channel delivers a message, and the kernel answers one turn.
5. The ledger records the tokens of every turn. On its interval the heartbeat
   spends unattended budget, and the sleep agent consolidates memory and works
   the task queue.
6. The `health`, `channels`, `heartbeat`, and `reload` commands reach a running
   supervisor through the files in the `run/` directory.

## Two processes, one socket

The supervisor holds the secrets and the model. Agent-authored code runs in a
child process as the agent uid. The supervisor sends a length-prefixed JSON
request and reads a response, and it never sends a secret in a request. The
supervisor never loads the child's code.

[Deployment](deployment.md) covers the container, the two users, and the secret
file. [Tools](tools.md) covers the broker and its wire protocol.

## Where the code lives

| Area | Files | Covered by |
| --- | --- | --- |
| The turn and the prompt | `src/enchiridion/kernel.cl` | [Memory](memory.md) |
| The process and the schedule | `src/enchiridion/supervisor.cl`, `src/enchiridion/sleep.cl` | [Supervisor and heartbeat](supervisor.md) |
| Channels | `src/enchiridion/channel/` | [Channels](channels.md) |
| Memory | `src/enchiridion/memory/` | [Memory](memory.md) |
| Tools and the broker | `src/enchiridion/tools/`, `src/broker-exec.cl` | [Tools](tools.md) |
| Plugins | `src/enchiridion/plugin/` | [Plugins and self-modification](plugins.md) |
| Models and secrets | `src/enchiridion/llm/` | [Models and secrets](llm.md) |
| Configuration | `src/enchiridion/config.cl` | [Configuration](configuration.md) |
| The command table | `src/enchiridion/channel/cli.cl`, `src/main.cl` | [Commands](commands.md) |
| Conditions | `src/enchiridion/errors.cl` | [Commands](commands.md) |
| Portability | `src/enchiridion/compat.cl` | [Development](development.md) |
| The agent directory as a repository | `src/enchiridion/git.cl` | [Development](development.md) |

## The documentation set

| Page | Covers |
| --- | --- |
| [Getting started](getting-started.md) | Build, first launch, the first run, and the first failures |
| [Configuration](configuration.md) | Every key of `config.cl`, and the secret rules |
| [Commands](commands.md) | The shell commands and the REPL commands |
| [Channels](channels.md) | The channel protocol, the terminal, HTTP, and Fluxer |
| [Supervisor and heartbeat](supervisor.md) | The process, the status file, the schedule, the budget |
| [Memory](memory.md) | Blocks, seed files, tiers, the store, and compaction |
| [Models and secrets](llm.md) | Backends, model tiers, token accounting, the scrubber |
| [Tools](tools.md) | The schema, the registry, the pipe, the broker, and every builtin |
| [Plugins and self-modification](plugins.md) | The manifest, verification, and the extension surface |
| [Deployment](deployment.md) | The container, the two users, and the isolation test |
| [Testing](testing.md) | The two test systems, the bridge, and the gate |
| [Development](development.md) | Layout, packages, load order, style, and commits |

## Reading order

- New to the program: [Getting started](getting-started.md), then
  [Configuration](configuration.md), then [Commands](commands.md).
- Running it: [Supervisor and heartbeat](supervisor.md),
  [Channels](channels.md), then [Deployment](deployment.md).
- How it works inside: [Memory](memory.md), [Tools](tools.md),
  [Models and secrets](llm.md), then
  [Plugins and self-modification](plugins.md).
- Working on the code: [Development](development.md), then
  [Testing](testing.md).

## Related

- [Getting started](getting-started.md)
- [Development](development.md)
