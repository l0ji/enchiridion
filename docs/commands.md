# Commands

One command table backs both the shell and the REPL. A row holds a name, a
minimum and a maximum argument count, a handler, and a summary. A shell command
is one program invocation that prints and exits. The REPL is the same commands
with a live process behind them. A handler prints and returns an exit status.

## Call a command

```sh
nix run .#enchiridion -- help
nix run .#enchiridion -- ask "What is in WORLD.md?"
nix run .#enchiridion -- usage
```

In the REPL, a command starts with a slash:

```text
enchiridion> /help
enchiridion> /usage
```

A line without a slash is a turn, and the REPL sends it to the agent.

The command line reads four flags: `--channel NAME`, `--bind ADDRESS`,
`--port NUMBER`, and `--token-env NAME`. The flags come before the command.
For `chat` and `serve`, the flags also come after the command. The `--bind`,
`--port`, and `--token-env` flags belong to `--channel http`.

Four mistakes stop the command with one line and exit 2. The first mistake is a
flag with no value. The second mistake is a channel that is not `cli`, `http`,
or `fluxer`. The third mistake is a `--bind`, `--port`, or `--token-env` flag
without `--channel http`. The fourth mistake is a port outside 1 to 65535.

## Exit statuses

| Status | Meaning |
| --- | --- |
| 0 | The command finished. |
| 1 | The command refused its situation, and it said why. A refused reload also returns 1. An unexpected error prints the condition and a short backtrace, then returns 1. |
| 2 | The call was not usable: unknown name, wrong argument count, bad flag, or refused configuration. |

A command that returns no integer becomes 0. `run-command` checks the argument
count before it calls the handler. A name that is not in the table prints this
line and returns 2:

```text
There is no command called NAME. Try `help`.
```

A call outside the argument range prints `NAME takes ARGUMENTS; got N.` and
returns 2.

## The command table

| Command | Arguments | What it prints | Exit |
| --- | --- | --- | --- |
| `init` | 0 or 1 | The status line, then each created and kept file, then each problem. | 0, or 1 with a problem |
| `ask` | 1 or more | The reply on standard output, the token line on standard error. | 0, or 1 on failure |
| `check` | none | The output of `nix run .#check`. | 0, or 1 when the build fails |
| `skills` | 0 to 2: `list`, `show NUMBER` | A numbered skill list with trigger lines, or one skill file. | 0, 1, or 2 |
| `tools` | 0 to 2: `list`, `show NAME` | Every tool with its schema token cost, or one tool schema as JSON. | 0, 1, or 2 |
| `blocks` | 0 to 2: `show`, `edit NUMBER` | Each block with its character count and limit, or the path of one block file. | 0, 1, or 2 |
| `persona` | 0 or 1: `show`, `edit` | The text of `SOUL.md`, or its path. | 0, or 2 for another action |
| `operator` | 0 or 1: `show`, `edit` | The text of `OPERATOR.md`, or its path. | 0, or 2 |
| `world` | 0 or 1: `show`, `edit` | The text of `WORLD.md`, or its path. | 0, or 2 |
| `memory` | 1 or more | Matching memories and stored turns, with two counts. | 0, or 1 without a store |
| `sessions` | none | Each stored session with its turn count, then the session count. | 0, or 1 without a store |
| `journey` | 0 to 2: `list`, `show REV`, `edit REV`, `rm REV` | The history, one revision, or the result of a revert. | 0, 1, or 2 |
| `undo` | exactly 1: `NUMBER` | `reverted REV.` or `could not revert REV.` | 0, 1, or 2 |
| `usage` | none | The token ledger by model, by channel, and by day. | 0, or 1 without a store |
| `budget` | none | The tick cap, the day cap, and the spend against each cap. | 0 |
| `tasks` | 0 or more: `list [STATUS]`, `add TEXT`, `rm ID` | The task rows, or one line about the change. | 0, 1 without a store, or 2 for a bad call |
| `secrets` | none | Each loaded secret name and its source. | 0 |
| `version` | none | `enchiridion 0.1.0`, the source root, the branch, and the head. | 0 |
| `help` | 0 or 1: `NAME` | Every command with a summary, or the detail for one command. | 0, or 2 for an unknown name |
| `bootstrap` | 0 or 1: `status`, `run`, `reset` | The bootstrap state, the remaining steps, or a reset line. | 0, or 2 for another action |
| `health` | none | The supervisor pid, generation, heartbeat, and channels. | 0, or 1 with no supervisor |
| `reload` | none | The supervisor report, then the generation. | 0, or 1 when refused or absent |
| `channels` | 0 to 2: `list`, `enable NAME`, `disable NAME` | The channel report from the supervisor. | 0, or 1 with no supervisor |
| `heartbeat` | 0 or 1: `on`, `off`, `run` | The supervisor report. | 0, or 1 with no supervisor |
| `chat` | none | The REPL. | 0 when the REPL ends |
| `serve` | none | Channel reports and heartbeat reports as they happen. | 0 when the process stops |

A command with an optional argument uses the default when the argument is
absent. The defaults are `list` for `skills`, `tools`, `journey`, and `tasks`.
They are `show` for `blocks`, `persona`, `operator`, and `world`. They are
`status` for `bootstrap`, `on` for `heartbeat`, and `list` for `channels`.

## Commands that need a live process

| Command | What it needs | Without it |
| --- | --- | --- |
| `reload`, `channels`, `heartbeat` | A supervisor and its control file. The request waits up to 5 seconds. | `NAME: no supervisor is running, so nothing was asked.` Exit 1. |
| `health` | A fresh status file. The file stays fresh for 10 seconds. | `no supervisor is running.` Exit 1. |
| `serve` | A supervisor in the command context. | `serve needs a supervisor in the command context.` Exit 1. |
| `memory`, `sessions`, `usage`, `tasks` | An open memory store. | `NAME needs the memory store, and none is open in this process.` Exit 1. |
| `ask` | A backend and an API key. | `No API key. Put NAME in .env or the environment.` Exit 1. |

`chat` and `serve` own a supervisor. The configuration and the flags decide
which channels the supervisor starts. Every other command runs in a short-lived
process and starts no channel.

## Starting and talking

### `init`

Creates the agent directory and the seed files. The handler ignores any
argument. It writes each absent file, and it keeps each present file. Then it
prints the status line, then `created NAME`, `kept NAME`, or `problem NAME` for
every entry. A problem returns 1.

### `chat`

Starts the REPL in the foreground and returns when the operator quits. The
process also starts a supervisor, and it polls the control file on a thread. A
`reload` typed at the REPL therefore reaches the supervisor that answers. The
terminal channel is not a supervised channel under `chat`.

### `ask`

Joins the arguments with single spaces and runs one turn. That join is why an
unquoted question still reads the way the operator typed it. The reply goes to
standard output, scrubbed. The token line goes to standard error. The exit
status is the status of the turn.

### `serve`

Starts the supervisor and polls the control file until the process stops. The
poll loop rewrites the status file on every pass. That rewrite keeps the file
fresh for a shell command in another process. `serve` builds the `cli` channel
only for this command. Without a terminal, that channel returns at once. The
supervisor waits one second, then starts it again, for as long as the process
runs, so the line repeats about once per second.

## The agent directory

### `journey`

| Action | What it prints |
| --- | --- |
| `list` | Up to 20 revisions as `REV SUBJECT`. With no history, one line says so. |
| `show REV` | The revision text. Without a revision, exit 2. |
| `edit REV` | The directory path and a line that names the revision to edit by hand. |
| `rm REV` | The output of the revert. |

A revision is a 1-based position in the log, or a hash.

### `undo`

Reverts the change that `NUMBER` names. It prints `reverted REV.` and returns
0, or `could not revert REV.` and returns 1. A missing number returns 2.

### `persona`, `operator`, `world`

Each command shows one seed file. `show` prints the file text. `edit` prints the
file path for the operator to open. Any other action returns 2. The files are
`SOUL.md`, `OPERATOR.md`, and `WORLD.md`.

### `blocks`

`show` prints one line per block: the label, the character count, the limit,
and the file path. The labels are `soul`, `persona`, `operator`, and `world`.
The first two both use `SOUL.md`, so the listing shows that file two times.

`edit NUMBER` prints the path of one block file and returns 0. A missing number
returns 2. A number past the end returns 1.

### `bootstrap`

| Action | What it prints |
| --- | --- |
| `status` | The one line bootstrap state. |
| `run` | The remaining steps, or one line that says bootstrap is complete. |
| `reset` | `bootstrap reset to its first step.` |

Any other action returns 2. The agent marks a step done with the meta tool, and
not from this command.

## The memory store

The store commands need an open store. The program opens the configured store
at start up. A store that will not open prints one line on standard error, and
the command then refuses with exit 1.

### `memory`

Searches stored memories and stored turns for the joined arguments. It prints
`memories: N`, then one block per row as `  KEY: VALUE`, then `turns: N`, then
the turns. It returns 0.

### `sessions`

Prints `ID N turns` for each stored session, then `N sessions in the store.`
It returns 0.

### `usage`

Prints three grouped sections: by model, by channel, and by day. Each section
holds one line per group with the columns `input`, `output`, `cache read`,
`cache write`, and `calls`. An empty ledger prints `  the ledger is empty.`

### `tasks`

| Action | What it prints |
| --- | --- |
| `list` | One row per task as `ID (status) body`. |
| `list STATUS` | The rows with that status. The four statuses are `pending`, `running`, `done`, and `failed`. |
| `add TEXT` | `task ID queued.` |
| `rm ID` | `task ID removed.`, or `there is no task ID.` Both return 0. |

A bad status word returns 2. `add` with no text returns 2. `rm` without an id
returns 2.

### `budget`

Prints the tick cap and the day cap from the `:budget` section. A live agent
adds two lines: `tick spent out:` and `day spent out:`. Each line shows whether
that window is spent. It returns 0.

## The live supervisor

### `health`

Reads the status file and reports whether a supervisor answers. It prints
`supervisor pid PID, generation G.`, then the last report, then a heartbeat
line, then one line per channel. The heartbeat line shows `on` or `off`, the
tick count, the last tick time, and the last tick report. A tick that is still
running adds the seconds since the tick started. With no fresh status file it
prints `no supervisor is running.` and returns 1.

### `reload`

Asks the supervisor to verify and load the agent code again. The request goes
to the control file, and the answer comes back in the status file. It prints
the report, then `generation N.` A refused generation keeps the last good code
and returns 1.

### `channels`

| Action | What it prints |
| --- | --- |
| `list` | Each supervised channel with its state. |
| `enable NAME` | `NAME is up.` or `NAME is already up.` |
| `disable NAME` | `NAME is down.` |

A name that no channel matches prints `channel NAME is not implemented yet.`
The request still returns 0. Any other action returns 2.

### `heartbeat`

| Action | What it prints |
| --- | --- |
| `on` | `heartbeat on.` |
| `off` | `heartbeat off.` |
| `run` | A line that says the supervisor takes the tick or queues it. |

`off` stops the schedule and not the operator, so `run` still asks for a tick.
A process with no sleep agent attached answers with a refusal line, and the
command still returns 0.

## The installation

### `check`

Runs `nix --option eval-cache false run .#check` with a one hour timeout. It
prints the combined output of the build. It returns 0 when the build passes,
and 1 when the build fails or when `nix` is absent.

### `version`

Prints `enchiridion 0.1.0`. Then it finds the project root and prints `source`,
`branch`, and `head` when it can. With no checkout above the directory, it
prints one line that says so. It returns 0.

### `secrets`

Prints `NAME from SOURCE` for each loaded secret. The source is `env`, `file`,
or `argument`. It never prints a value. With nothing loaded it prints
`no secrets are loaded.` It returns 0.

### `help`

Without an argument it prints every command name and summary, one row each.
With a name it prints `NAME -- SUMMARY` and `  arguments: ARITY`. The arity
text reads `no arguments`, `at least N arguments`, `exactly N arguments`, or
`N to M arguments`. An unknown name returns 2.

### `skills`

`list` prints every skill file with a number and its trigger line. A skill with
no trigger shows only its name. `show NUMBER` prints the file text. A missing
number returns 2, and a number past the end returns 1.

### `tools`

`list` prints every registered tool as `NAME TOKENS tokens - DESCRIPTION`,
where the token count is the cost of the schema. `show NAME` prints the schema
as JSON. A missing name returns 2, and an unknown tool returns 1.

## The REPL

The prompt is `enchiridion> `. A line that starts with `/` is a command, and
the rest of the line is the argument list. The REPL folds the command name to
lower case.

| Line | What it does |
| --- | --- |
| `/help` | Prints the command list. |
| `/stop` | Asks the turn in flight to stop. It prints `cancellation requested.` and returns 0. Without a cancel function it prints `there is no turn to stop.` and returns 1. |
| `/quit` | Leaves the session. `run-repl` returns `:quit`. |
| `/who` | Prints the attached channel and the supervisor state, then returns 0. |

`stop`, `quit`, and `who` are REPL-only, because they act on the live turn. The
other commands are the table above, and the REPL calls the same handler the
shell calls. A REPL-only name needs the slash. The word `quit` without a slash
is a turn, and the agent answers it.

An empty line does nothing. A line that names no command prints the
unknown-command line, and the REPL reads the next one. `run-repl` ignores the
status of every command except `/quit`. An end of input leaves the loop, and
`run-repl` returns `:eof`.

There is no `exit` command. A shell call with the name `exit` prints the
unknown-command line and returns 2. Use `/quit` or an end of input.

## The `--verify-plugin` flag

```sh
nix run .#enchiridion -- --verify-plugin agents/default/
```

The flag takes one directory. It verifies the directory in a child process at
uid 1000, and it prints the report. It returns 0 when the directory verifies, 1
when the verification fails, and 2 when the directory argument is absent. The
program reads the flag before the command table, so the flag is not a command
row. See [Plugins and self-modification](plugins.md).

## Related

- [Getting started](getting-started.md)
- [Configuration](configuration.md)
- [Supervisor and heartbeat](supervisor.md)
- [Channels](channels.md)
- [Memory](memory.md)
- [Tools](tools.md)
- [Plugins and self-modification](plugins.md)
