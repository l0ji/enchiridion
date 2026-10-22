# enchiridion documentation

enchiridion is an autonomous agent harness written in Common Lisp.
The supervisor process holds the model client, the secret values, the memory store, and the channels.
The kernel compiles the memory blocks into one prompt for a session.
A turn calls the model with that prompt, and calls it again for each round of tool calls, up to the tool-round limit.
In the container deployment, agent code runs in a child process under its own user, and the supervisor never loads that code.
A checkout has no uid split, so the supervisor, the broker child, and agent code run as the operator's user (see [Deployment](deployment.md)).

This documentation covers the operator's side of the program and the developer's side of it.
It describes the behaviour of the code as it is, and it names the source file that owns each mechanism.

## Audience

The documentation assumes a reader who is comfortable on Unix and can read Common Lisp.
Three groups use it:

- Operators run the program: build it, write `config.cl`, start the supervisor, and read the status output.
- Developers change the program: add a provider, a tool, a plugin, or a channel.
- Readers of the internals want to know how the prompt, the memory store, and the budget work before changing them.

## How this documentation is organised

Each page has one subject.
A page opens with what the subject is, then gives the procedure the reader needs, then the reference tables.
A fact lives on the page that owns it, and other pages link to that page instead of restating the fact.

Part I, starting the program:

- [Getting started](getting-started.md) builds the program, writes the first agent directory, and holds the first conversation.

Part II, running the program:

- [Configuration](configuration.md) is the reference for every key of `config.cl`, and for the secret rules.
- [Commands](commands.md) is the reference for the commands, their arguments, and their exit statuses.
- [Channels](channels.md) covers the surfaces a message arrives on: the terminal, the HTTP webhook, and Fluxer.
- [Supervisor and heartbeat](supervisor.md) covers the process, the status file, the schedule, and the budget.
- [Deployment](deployment.md) covers the container, the two users, the isolation test, and the backup and upgrade procedure.

Part III, how it works inside:

- [Memory](memory.md) covers the blocks, the seed files, the tiers, the store, and compaction.
- [Large language model backends](llm.md) covers the backends, the provider catalog, the token accounting, and the scrubber.
- [Tools](tools.md) covers the schema, the registry, the pipe, the broker, and every built-in tool.
- [Plugins and self-modification](plugins.md) covers the manifest, verification, and the extension surface.
- [Testing](testing.md) covers the two test systems, the bridge, and the gate.

Part IV, changing the program:

- [Development](development.md) covers the layout, the build, the style rules, and the commit policy.

The [README](../README.md) holds the build and run summary.

## Conventions

| Notation                    | Meaning                                                         |
| --------------------------- | --------------------------------------------------------------- |
| `enchiridion chat`          | A command to run in a shell.                                    |
| `/help`                     | A command to type at the REPL prompt.                           |
| `config.cl`                 | A file or a path.                                               |
| `:model-primary`            | A Lisp keyword: a configuration key, a field, or a status word. |
| `src/enchiridion/kernel.cl` | A source file, relative to the repository root.                 |

A table with a default column gives the value the program uses when the key is absent.
An exit status is the value the shell reports.
`> **Note:**` marks information, `> **Important:**` marks a condition that breaks a guarantee, and `> **Warning:**` marks a risk to data or to secret isolation.

## Reading order

A first installation follows [Getting started](getting-started.md), then [Configuration](configuration.md), then [Commands](commands.md).

An operator who runs the program follows [Supervisor and heartbeat](supervisor.md), then [Channels](channels.md), then [Deployment](deployment.md).

A reader of the internals follows [Memory](memory.md), then [Tools](tools.md), then [Large language model backends](llm.md), then [Plugins and self-modification](plugins.md).

A developer starts at [Development](development.md), then [Testing](testing.md).

## See also

- [Getting started](getting-started.md)
- [Development](development.md)
