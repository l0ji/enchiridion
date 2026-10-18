# Getting started

enchiridion is an autonomous agent harness written in Common Lisp. It runs one
agent in a directory of Markdown files. Nix builds the program, and every
dependency comes from the flake. The operator runs a command, and the command
prints and exits or starts a session. A first launch creates the agent
directory and stops, so the operator can edit the seed files first. The same
command table backs the shell and the REPL.

## What you need

- Nix, with flakes enabled.
- A host on the flake systems list: `x86_64-linux`, `aarch64-linux`, or
  `aarch64-darwin`.
- Git, when you want history in the agent directory. The harness writes the
  files without git and skips only the commit.
- A Linux builder, for the container image. The image is Linux only.

The flake supplies SBCL and every Lisp library. The project does not use
Quicklisp.

## Build, check, and test

```sh
nix develop                      # development shell
nix run .#check                  # compile every file
nix run .#test                   # run the test suite
nix run .#enchiridion -- help    # print the command list
```

| Command                         | What it does                                                               |
| ------------------------------- | -------------------------------------------------------------------------- |
| `nix develop`                   | Start the development shell with SBCL, SQLite, sly, nixfmt, and git.       |
| `nix run .#check`               | Compile the systems and the two entry scripts. A warning fails the build.  |
| `nix run .#test`                | Run the test systems `enchiridion-tests` and `enchiridion-tests/property`. |
| `nix run .#enchiridion -- help` | Run the program with the `help` command.                                   |
| `nix run .#enchiridion`         | Run the program with no command. This is the first launch.                 |
| `nix run .`                     | Run the same program through the `default` app.                            |
| `nix build .#container`         | Build the container image. Linux only.                                     |

`.#check` is the gate. It compiles every system file, then `src/main.cl` and
`src/broker-exec.cl` on their own. A compiler warning becomes an error, so a
clean build is the only passing build.

The `check` command in the program runs the same gate:

```sh
nix run .#enchiridion -- check
```

## First launch

Run the program with no command:

```sh
nix run .#enchiridion
```

The first launch creates the agent directory and writes these files:

| File                        | What it holds                                                                     |
| --------------------------- | --------------------------------------------------------------------------------- |
| `GUIDE.md`                  | The operator walkthrough.                                                         |
| `SOUL.md`                   | The agent identity. The template is a placeholder.                                |
| `OPERATOR.md`               | Who the agent works for. The template is a placeholder.                           |
| `WORLD.md`                  | The environment: paths, commands, and conventions. The template is a placeholder. |
| `BOOTSTRAP.md`              | The first steps, worked through one time.                                         |
| `skills/example-welcome.cl` | An example skill.                                                                 |
| `tools/example-echo.cl`     | An example tool.                                                                  |
| `state.json`                | The runtime state, with the bootstrap step at zero.                               |

Rules for these files:

- The program creates a seed file when it is absent, and never overwrites one.
- A second `init` run reports the files it finds and writes only the gaps. A
  second run with no command prints a ready line and starts nothing.
- The agent directory becomes a git repository. The first commit is
  `Create the agent directory`.
- A host with no git, or with no git identity, still gets the files. Only the
  commit fails.
- The agent cannot write `SOUL.md`, `OPERATOR.md`, or `WORLD.md` until
  bootstrap hands over.

The first launch prints the status line, then this advice, and exits 0:

```text
Bootstrap has not started. Edit SOUL.md, OPERATOR.md, and WORLD.md first,
then run `enchiridion chat`. See agents/default/GUIDE.md for the walkthrough.
```

A write that fails prints the names and the reasons, then exits 1.

The `init` command does the same work on demand:

```sh
nix run .#enchiridion -- init
```

## Where the files live

The home root is `ENCHIRIDION_HOME` when the operator sets it. Without it, the
home root is the current directory. A checkout sets neither, so the harness
uses the directory it starts in.

| Path                                | What it holds                                                                       |
| ----------------------------------- | ----------------------------------------------------------------------------------- |
| `<home>/agents/default/`            | The agent directory.                                                                |
| `<home>/run/enchiridion.control`    | Control requests, one per line.                                                     |
| `<home>/run/enchiridion.status`     | The status file the supervisor rewrites.                                            |
| `<home>/run/broker.sock`            | The broker socket, when the operator sets `ENCHIRIDION_HOME`.                       |
| `<home>/agents/default/broker.sock` | The broker socket, when `ENCHIRIDION_HOME` is unset.                                |
| `<current directory>/config.cl`     | The operator configuration. The project root is the second place the harness looks. |
| `<current directory>/.env`          | The secret file. The current directory wins over the project root.                  |

Two more variables set the roots:

| Variable             | Effect                                                     |
| -------------------- | ---------------------------------------------------------- |
| `ENCHIRIDION_HOME`   | Set the home root for the agent directory and `run/`.      |
| `ENCHIRIDION_SOURCE` | Set the project root for a copy with no checkout above it. |

## Talk to the agent

```sh
nix run .#enchiridion -- chat
nix run .#enchiridion -- ask "What is in WORLD.md?"
nix run .#enchiridion -- serve
```

| Command      | What it does                                                            |
| ------------ | ----------------------------------------------------------------------- |
| `chat`       | Start the REPL in the foreground. The process also runs a supervisor.   |
| `ask "TEXT"` | Run one turn in a short-lived session, print the reply, and exit.       |
| `serve`      | Start the supervisor and poll the control file until the process stops. |

`chat` reads a line, then sends the line as a turn. A line that starts with `/`
is a command, for example `/help`. The prompt is `enchiridion> `. The line
`/quit` leaves the session. An end of input also leaves.

The reply goes to standard output. A token line goes to standard error:

```text
deepseek-v4.1-flash  in 1204  out 96  cached 1024
```

The line shows the model, the input tokens, and the output tokens. It adds
`cached N` and `wrote N` when the provider reports cache tokens.

## Common first-run failures

| What you see                                                                                                                 | Cause                                                         | What to do                                                                              |
| ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `Configuration is wrong at :api-key.` and `No API key. Put OPENAI_API_KEY in .env or the environment.` The exit status is 1. | The process holds no API key.                                 | Put the key in `.env` or the environment. The variable name comes from `:api-key-env`.  |
| `enchiridion: stdin is not a terminal, so the cli channel stays down.`                                                       | The terminal channel needs a terminal on standard input.      | Run `serve` from a terminal. In a pipe, `chat` reads an end of input and exits at once. |
| `reload: no supervisor is running, so nothing was asked.` The exit status is 1.                                              | `reload`, `channels`, and `heartbeat` need a live supervisor. | Start `serve` in another terminal. `health` reads the status file only.                 |
| There is no command called NAME. Try `help`. The exit status is 2.                                                           | The name is not in the command table.                         | Run `help`, or read [Commands](commands.md).                                            |
| `The --bind, --port and --token-env flags belong to --channel http.` The exit status is 2.                                   | A webhook flag came without `--channel http`.                 | Add `--channel http` to the command.                                                    |
| `There is no channel called NAME. The channels are cli, http and fluxer.` The exit status is 2.                              | The `--channel` value is not one of the three channels.       | Use `cli`, `http`, or `fluxer`.                                                         |
| `The port must be a number between 1 and 65535, not X.` The exit status is 2.                                                | The `--port` value is not a port number.                      | Give a number in the range.                                                             |
| `enchiridion: not keeping a transcript: ...`                                                                                 | The memory store did not open.                                | The reply still prints. Check the path in `:memory :db`.                                |

Under `serve`, a process with no terminal repeats that line about once per
second. The terminal channel returns at once. The supervisor waits one second,
then starts the channel again, for as long as the process runs. A `chat`
session is different, because the REPL reads an end of input and returns. A
store that will not open costs the transcript, and it does not cost the turn.

## A map of the pages

| Page                                        | What it covers                                        |
| ------------------------------------------- | ----------------------------------------------------- |
| [Documentation index](index.md)             | The full list of pages.                               |
| [Configuration](configuration.md)           | `config.cl`, every key, and the environment.          |
| [Commands](commands.md)                     | Every command, its arguments, and its exit status.    |
| [Channels](channels.md)                     | The channel protocol, `cli`, `http`, and `fluxer`.    |
| [Supervisor and heartbeat](supervisor.md)   | The supervisor, the status file, and the heartbeat.   |
| [Deployment](deployment.md)                 | The container, the two users, and the isolation test. |
| [Memory](memory.md)                         | The blocks, the three tiers, and the store.           |
| [Models and secrets](llm.md)                | The backends, the model tiers, and the scrubber.      |
| [Tools](tools.md)                           | The registry, the broker, and every builtin tool.     |
| [Plugins and self-modification](plugins.md) | The manifest, the verifier, and the loader.           |
| [Testing](testing.md)                       | The two test systems and how to add a test.           |
| [Development](development.md)               | The layout, the packages, and the style rules.        |
| [README](../README.md)                      | The build and run summary.                            |

## Related

- [Configuration](configuration.md)
- [Commands](commands.md)
- [Channels](channels.md)
- [Supervisor and heartbeat](supervisor.md)
- [Deployment](deployment.md)
- [Memory](memory.md)
- [Models and secrets](llm.md)
- [Tools](tools.md)
- [Testing](testing.md)
- [Development](development.md)
