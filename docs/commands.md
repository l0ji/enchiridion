# Commands

One command table backs the shell binary and the terminal read-eval-print loop (REPL).
The chapter lists every command, its arguments, its output, and its exit status.
It also covers the command-line flags, the REPL rules, the live-supervisor requests, and the signal behavior.
After it, an operator can script the harness and read its answers without reading the source.

## How a call works

A table row holds five fields: a name, a minimum argument count, a maximum argument count, a handler, and a summary.
A maximum of `nil` means any number of arguments.

A shell command is one program invocation.
It starts the process, runs one handler, prints, and exits with a status.
`chat` and `serve` keep the process alive instead.

The REPL is the same table with a live process behind it.
A line that starts with `/` is a command.
Any other line is a turn for the agent.

The minimum and maximum are checked before the handler runs.
An unknown name, or a call outside the range, prints one line and returns 2.
A handler that returns no integer is treated as success.

Command names match without case.
Arguments are joined with single spaces for `ask`, for `memory`, and for `tasks add`.
Every other command reads positional words.

## Exit statuses

| Status | Meaning                                                                                        |
| ------ | ---------------------------------------------------------------------------------------------- |
| 0      | The command completed.                                                                         |
| 1      | The command refused its situation and said why, a turn failed, or a build failed.              |
| 2      | The call was not usable: unknown name, wrong argument count, bad flag, or refused configuration. |
| 130    | A signal stopped the process (see [Signals](#signals)).                                         |

A handler prints its own failure line.
A configuration error that escapes a handler prints its report and returns 2.
Any other escaping condition prints the condition and a short backtrace, then returns 1.

An unknown name prints one line and returns 2:

```text
There is no command called NAME. Try `help`.
```

At the REPL the suggestion names `/help`.
A call outside the argument range prints `COMMAND takes ARGUMENTS; got N.` and returns 2.
Every line that names a command uses the spelling of the surface in front of the operator.

## Flags

The command line reads four flags with values.
`--verify-plugin` is read separately (see [Plugin verification](#plugin-verification)).

| Flag              | Value                        | Effect                                                                 |
| ----------------- | ---------------------------- | ---------------------------------------------------------------------- |
| `--channel NAME`  | `cli`, `http`, or `fluxer`   | Start `http` or `fluxer` even when its entry disables it. `serve` builds `cli` regardless. |
| `--bind ADDRESS`  | An address                   | Set the webhook bind address for this process.                          |
| `--port NUMBER`   | 1 to 65535                   | Set the webhook port for this process.                                  |
| `--token-env NAME`| A variable name              | Name the variable that holds the webhook token for this process.        |

The flags configure the channels of `chat` and `serve`.
They come before the command, and for those two commands they also come after it.
A valid flag before another command is accepted and has no effect.
The `--bind`, `--port`, and `--token-env` flags belong to `--channel http`.
A flag belongs to one invocation and never writes `config.cl` (see [Configuration](configuration.md)).

An invalid flag stops the process before any command runs.
The line goes to standard error with the `enchiridion: ` prefix, and the status is 2:

| Mistake                          | Line                                                                       |
| -------------------------------- | -------------------------------------------------------------------------- |
| A flag with no value             | `The --channel flag needs a value.`                                        |
| A channel that does not exist    | `There is no channel called NAME. The channels are cli, http and fluxer.`  |
| A webhook flag without `--channel http` | `The --bind, --port and --token-env flags belong to --channel http.` |
| A port outside the range         | `The port must be a number between 1 and 65535, not VALUE.`                |

A value that starts with `--` is read as the next flag, so `--bind --port 8787` reports that `--bind` needs a value.
A flag that is not one of the four reaches the table as a command name or as an argument.
`enchiridion --wat x` prints the unknown-command line and returns 2.

On a seeded agent directory, channel flags with no command serve.
Before the first launch, they write the seed files instead.

## The command table

| Command     | Arguments                                            | Summary                                             | Exit        |
| ----------- | ---------------------------------------------------- | --------------------------------------------------- | ----------- |
| `init`      | 0 or 1                                               | Create the agent directory and seed files           | 0 or 1      |
| `ask`       | 1 or more                                            | One turn in a short-lived session                   | 0 or 1      |
| `check`     | none                                                 | Compile every system file and both entry scripts     | 0 or 1      |
| `skills`    | 0 to 2: `list`, `show NUMBER`                        | List or show skills                                 | 0, 1, or 2  |
| `tools`     | 0 to 2: `list`, `show NAME`                          | List or show tools                                  | 0, 1, or 2  |
| `blocks`    | 0 to 2: `show`, `edit NUMBER`                        | Blocks with character counts and capacity           | 0, 1, or 2  |
| `persona`   | 0 or 1: `show`, `edit`                               | Show or point at `SOUL.md`                          | 0 or 2      |
| `operator`  | 0 or 1: `show`, `edit`                               | Show or point at `OPERATOR.md`                      | 0 or 2      |
| `world`     | 0 or 1: `show`, `edit`                               | Show or point at `WORLD.md`                         | 0 or 2      |
| `memory`    | 1 or more                                            | Search sessions and memories                        | 0 or 1      |
| `sessions`  | none                                                 | Stored sessions with turn counts                    | 0 or 1      |
| `journey`   | 0 to 2: `list`, `show REV`, `edit REV`, `rm REV`     | Everything the agent has learned or written         | 0 or 2      |
| `undo`      | exactly 1                                            | Roll back the nth change in the agent directory     | 0, 1, or 2  |
| `usage`     | none                                                 | Token ledger by model, channel, and day             | 0 or 1      |
| `budget`    | none                                                 | Spend against the caps                              | 0           |
| `tasks`     | 0 or more: `list [STATUS]`, `add TEXT`, `rm ID`      | The task queue                                      | 0, 1, or 2  |
| `secrets`   | none                                                 | Names and sources, never values                     | 0           |
| `providers` | 0 to 2: `list`, `show ID`, `models ID`, `refresh`    | Provider list, one provider, its models, or a refresh | 0, 1, or 2 |
| `version`   | none                                                 | Version and build provenance                        | 0           |
| `help`      | 0 or 1                                               | Command list, or detail for one                     | 0 or 2      |
| `bootstrap` | 0 to 2: `status`, `run`, `step N`, `reset`          | Bootstrap state, steps, or a reset                  | 0 or 2      |
| `health`    | none                                                 | Read the running supervisor's status                | 0 or 1      |
| `reload`    | none                                                 | Ask a running supervisor to reload its code         | 0 or 1      |
| `channels`  | 0 to 2: `list`, `enable NAME`, `disable NAME`        | List, enable, or disable a channel                  | 0, 1, or 2  |
| `heartbeat` | 0 or 1: `on`, `off`, `run`                           | Turn the heartbeat on or off, or run one tick       | 0, 1, or 2  |
| `chat`      | none                                                 | Start the REPL                                      | 0, 1, or 130 |
| `serve`     | none                                                 | Start the supervisor and its channels               | 1 or 130    |

Every row also returns 2 for a wrong argument count.
The exit column names what the handler can return after the count check.

An absent action argument takes the default.
The defaults are `list` for `skills`, `tools`, `channels`, `journey`, and `tasks`.
They are `show` for `blocks`, `persona`, `operator`, and `world`.
They are `status` for `bootstrap`, and `on` for `heartbeat`.

## Session and build commands

A shell call has the form:

```sh
nix run .#enchiridion -- COMMAND ARGS
```

### init

`init` writes every absent seed file and keeps every present one.
An argument is accepted and ignored.
It prints the status line and one line per file, prefixed `  created `, `  kept    `, or `  problem `.
A problem prints `  problem (NAME . CONDITION)` and returns 1.
The first launch does the same work (see [Getting started](getting-started.md#perform-the-first-launch)).

### ask

`ask` joins its arguments with single spaces and runs one turn in a short-lived session.
It needs a backend and a provider key.
The reply goes to standard output, scrubbed.
The token line goes to standard error as `<model>  in <input>  out <output>`, with `  cached <N>` and `  wrote <N>` appended when the provider reports cache tokens.
The model field is the answering model, or the configured primary model when the provider reports none.
A completed turn returns 0, and a failed or cancelled turn returns 1.
Without a key it prints `Configuration is wrong at API-KEY.` and `No API key. Put OPENAI_API_KEY in .env or the environment.` and returns 1.
`ask` is the only one-shot command that refreshes provider knowledge when `:offline` is nil.

### check

`check` runs `nix --option eval-cache false run .#check` in the current directory with a one hour timeout.
It prints the combined output, returns 0 on success, and returns 1 on a failed build or a missing `nix`.

### chat

`chat` starts the REPL in the foreground.
It builds a supervisor, starts it, and polls the control file on a thread, so a `reload` typed at the REPL reaches a supervisor that answers.
The terminal channel is not supervised under `chat`.
The exit status is 0 when `/quit` or an end of input ends the session, 130 on a signal, and 1 when the supervisor fails to start.
Agent code that fails to load prints a warning and does not stop the session.
It is a shell-only command.

### serve

`serve` starts the supervisor and polls the control file in the foreground.
The `cli` channel is built for this command, and `http` and `fluxer` are built when the configuration enables them or a `--channel` flag names them.
The command runs until a signal stops it and then returns 130, and a startup error returns 1.
It is a shell-only command.
The `cli` channel needs a terminal: without one it prints `enchiridion: stdin is not a terminal, so the cli channel stays down.` and the supervisor restarts it after one second, so the line repeats.

## Inspection commands

### help

`help` prints the command list, or the detail for one command.

```text
ask -- One turn in a short lived session
  arguments: at least 1 argument
```

The arity text is `no arguments`, `at least N arguments`, `exactly N arguments`, or `N to M arguments`.
At the REPL the list labels every command with its slash, appends `/stop`, `/quit`, and `/who`, and leaves out `chat` and `serve`.
`/help chat` prints `chat is a shell-only command, so the REPL does not have it.` and returns 2.
An unknown name returns 2.

### version

`version` prints `enchiridion 0.1.0`, then `source` with the project root, and `branch` and `head` when Git answers.

```text
enchiridion 0.1.0
source /path/to/enchiridion
```

The packaged wrapper sets `ENCHIRIDION_SOURCE` to the installed tree, so `source` names that tree under `nix run`.
With no root above the current directory it prints `no checkout was found above this directory.`
It returns 0.

### secrets

`secrets` prints each loaded name with its source, never a value, then one line about the secret file.

```text
OPENAI_API_KEY from file
secrets file /path/to/enchiridion/.env mode #o600 present
```

The source is `file`, `env`, or `argument`, and `argument` comes from a literal `:token` in `:http`.
With nothing loaded it prints `no secrets are loaded.` and still reports the file line.
A file the loader opened reports `present` or `discarded`, and `discarded` is the steady state in a container.
When no file was read, the line names the path the loader would have tried and reports `present` or `absent`.
The mode reads `unknown` when there is no file mode to report.
It returns 0.

### budget

`budget` prints the caps and the spend against each window.

```text
tick cap: 4000
day cap:  400000
tick spent out: NIL
day spent out:  NIL
```

The caps come from the `:budget` section, and `T` on a spent line means the window is exhausted.
It returns 0.

### providers

`providers list` prints one line per provider with the id, display name, handler, profile, endpoint, key variable, key presence, and row source.
A handler this build does not implement is marked `unsupported`.
`providers show ID` prints every field of one row with `none` for an empty value, and an unknown id returns 2.
`providers models ID` asks the provider which models its account can reach and prints the id, display name, context size, and output size per model, then `<N> model(s).`
A missing ID prints `providers show takes an ID.` or `providers models takes an ID.` and returns 2.
A provider with no model list prints `<ID> offers no model list. Set :model-primary, or use a row with :models.` and returns 1.
`providers refresh` fetches the catalog and prints `provider catalog refreshed: <N> provider(s).`, and a failed fetch returns 1.
`models` and `refresh` reach the network even when `:offline` is t.
A bad action prints `providers takes list, show ID, models ID or refresh.` and returns 2.

## Agent directory commands

### skills

`skills` lists the Lisp files directly under `skills/` in the agent directory, or shows one with `show NUMBER`.
`list` prints one numbered line per skill:

```text
1. example-welcome.cl -- welcome, hello, introduce yourself
```

The trigger line follows the file name when the file declares a `+trigger+` string.
With no files it prints `no skills yet.`
A non-numeric argument prints `expected the number of an entry.` and returns 2, a number past the end prints `there is no entry N.` and returns 1, and a bad action prints `skills takes list or show NUMBER.` and returns 2.
A listing reads the trigger line without evaluating the file, and a file that does not read still appears.

### tools

`tools list` prints `NAME TOKENS tokens - DESCRIPTION` for every registered tool, where the count is the schema cost, or `no tools are registered in this process.`
`tools show NAME` prints the schema as one line of JavaScript Object Notation (JSON).
A missing name prints `tools show needs a tool name.` and returns 2, an unknown name prints `There is no tool called NAME.` and returns 1, and a bad action prints `tools takes list or show NAME.` and returns 2.
The built-in tools are registered for every command, and tools from the agent directory load when a turn runs (`ask`, `chat`, `serve`) (see [Plugins and self-modification](plugins.md)).

### blocks

`blocks` prints one line per block: label, character count, limit, and file.

```text
soul 758/1200 /path/to/home/agents/default/SOUL.md
persona 758/1200 /path/to/home/agents/default/SOUL.md
```

`soul` and `persona` both use `SOUL.md`.
The limit comes from the memory module, not from `:block-limits` in `config.cl` (see [Configuration](configuration.md)).
`edit NUMBER` prints the path of one block file.
A missing or non-numeric number prints `blocks edit needs the number of a block.` and returns 2, a number past the end prints `there is no block N.` and returns 1, and a bad action prints `blocks takes show or edit NUMBER.` and returns 2.

### persona, operator, and world

`persona`, `operator`, and `world` show or point at `SOUL.md`, `OPERATOR.md`, and `WORLD.md`.
`show` prints the file text, and `edit` prints the absolute path.
A bad action prints `NAME takes show or edit.` and returns 2.

### bootstrap

`bootstrap` reads, records, and resets the bootstrap state.
`status` prints one line: `Bootstrap step N of M: <summary>` while steps remain, `Bootstrap complete.` when `BOOTSTRAP.md` is absent, or `Bootstrap complete: N of N steps done.` when the file is present and every step is done.
`step N` records one step and prints the new status line.
`run` prints `bootstrap has N steps left:` and the remaining steps, or `bootstrap is complete; the agent owns the seed files.`
`reset` restores `BOOTSTRAP.md` from `BOOTSTRAP.done.md` when the live file is absent, clears the record, and prints `bootstrap reset to its first step.`
A bad action prints `bootstrap takes status, run, step NUMBER or reset.` and returns 2.
An invalid or unknown step prints `bootstrap step needs a step number.` or `There is no bootstrap step N.` and returns 2.
The meta tool action `bootstrap-step` records a step from the turn surface, and the last step archives `BOOTSTRAP.md`.
[Getting started](getting-started.md#hand-over-the-bootstrap) gives the procedure, and [Memory](memory.md#the-bootstrap) covers the state machine.

### journey

`journey list` prints up to 20 commits as `REV SUBJECT`, or `the agent directory has no history yet.`
The kernel commits after each successful turn with `Turn N via CHANNEL`, and [Memory](memory.md#the-agent-repository) owns that behavior.
A revision argument is a 1-based position in the log or a revision string.
`show REV` prints the revision text, `edit REV` prints `edit <directory> by hand; the change is <revision>.`, and `rm REV` reverts the revision and prints the Git output.
A missing revision prints `journey show needs a revision or a number.` (or the matching line for `edit` and `rm`) and returns 2.
A bad action prints `journey takes list, show, edit or rm.` and returns 2.
A Git failure is ignored, so a failed revert still returns 0.

### undo

`undo N` rolls back one change in the agent directory and resolves the argument like a `journey` revision.
It prints `reverted REV.` and returns 0, prints `could not revert REV.` and returns 1 when Git refuses, and prints `undo needs the number of a change.` and returns 2 when no log entry matches.

## Memory and ledger commands

The store commands need an open memory store.
The program opens the configured store at start up.
A store that cannot be opened prints one warning on standard error and does not stop the command.
The store command then refuses with exit 1:

```text
enchiridion: not keeping a transcript: Configuration is wrong at MEMORY.
COMMAND needs the memory store, and none is open in this process.
```

### memory

`memory` searches stored memories and stored turns for the joined arguments.
The output has two sections:

```text
memories: 0
turns: 0
```

Each row prints as `  KEY: VALUE`.
A search that fails prints no rows for that section.
The exit status is 0 with a store and 1 without one.

### sessions

`sessions` lists stored sessions with their turn counts.

```text
ID 4 turns
3 sessions in the store.
```

The exit status is 0 with a store and 1 without one.

### usage

`usage` prints the token ledger in three grouped sections.

```text
by model
  the ledger is empty.
by channel
  the ledger is empty.
by day
  the ledger is empty.
```

A non-empty section has a header row with the columns `input`, `output`, `cache read`, `cache write`, and `calls`, then one row per group.
The grouping uses one query per section, so the report is the same for the shell and the webhook.
The exit status is 0 with a store and 1 without one.

### tasks

`tasks` reads, adds, and removes work for the sleep-time agent.
Options are `list [STATUS]`, `add TEXT`, and `rm ID`.
`list` prints `ID (status) body` for each task.
An empty queue prints `no tasks.`
A status word filters the list, and the four statuses are `pending`, `running`, `done`, and `failed`.
Any other status word prints `tasks list takes pending, running, done or failed.` and returns 2.

`add` joins the remaining arguments and prints `task ID queued.`
A missing text prints `tasks add needs the text of the task.` and returns 2.

`rm` prints `task ID removed.` or `there is no task ID.`
Both results return 0.
A missing or non-numeric id prints `tasks rm needs the id of a task.` and returns 2.

A bad action prints `tasks takes list, add or rm.` and returns 2.

## The live supervisor

Three commands reach a running supervisor through the control file (see [Supervisor and heartbeat](supervisor.md)).
`reload`, `channels`, and `heartbeat` append one request line to `run/enchiridion.control`.
The supervisor polls that file once per second and writes its answer into `run/enchiridion.status`.
The command waits up to five seconds for the answer.

A status file counts as live for ten seconds and only while its `running` flag is true.
Without a live supervisor, the command prints one line and returns 1 without writing a request:

```text
reload: no supervisor is running, so nothing was asked.
```

The line names the command first.
`health` reads the status file only and does not send a request.

### health

`health` reports the supervisor state.

```text
supervisor pid 12345, generation 2.
reload done, generation 2.
heartbeat on, 7 ticks, last at 4001409114
channel cli stopped
channel http live
```

The first line holds the pid and the generation.
The next line is the last control report, when one exists.
The heartbeat line holds the schedule state, the tick count, and the universal time of the last tick.
A non-empty tick report is appended after a colon.
A tick that is still running adds one line: `  a tick has been running for N second(s).`
A channel line is `channel NAME STATE`.

Without a live supervisor the command prints `no supervisor is running.` and returns 1.
With a live supervisor it returns 0.

### reload

`reload` asks the supervisor to verify and load the agent code again.

```text
reload done, generation 2.
generation 2.
```

The first line is the supervisor report.
The second line is the generation the status file now names.
A refused generation keeps the last good code serving and returns 1:

```text
reload refused: broken self-test returned NIL
```

A supervisor that answers returns 0 on a successful reload.
A command with no supervisor returns 1.

### channels

`channels` lists, enables, or disables a supervised channel.
Options are `list`, `enable NAME`, and `disable NAME`.

```text
cli stopped, http live
generation 1.
```

`list` prints every supervised channel with its state, separated by commas.
`enable NAME` prints `NAME is up.` or `NAME is already up.`
`disable NAME` prints `NAME is down.`

A name that matches no channel prints `channel NAME is not implemented yet.`
The request is still answered, so the command returns 0.
Only the channels the supervisor built can start.
The process builds an `http` or `fluxer` channel when the configuration enables it or a `--channel` flag names it.
A channel disabled at startup therefore has no object to start.

A missing name produces the supervisor report `which channel?` and returns 0.
A bad action prints `channels takes list, enable NAME or disable NAME.` and returns 2.

### heartbeat

`heartbeat` turns the sleep schedule on or off, or asks for one tick.
Options are `on`, `off`, and `run`, and `on` is the default.
`on` prints `heartbeat on.`
`off` prints `heartbeat off.`
A process with no sleep agent attached answers `heartbeat on, but no sleep agent is attached to this process.` to `on`, and returns 0.

`run` asks for one tick and answers at once.
The report is `heartbeat tick requested; the answer lands in the status file.`
A request during a tick answers `a tick is running; one more is queued and the answer lands in the status file.`
With no sleep agent attached it answers `no sleep agent is attached to this process.`

`off` stops the schedule and not the operator, so `run` still forces a tick.
A bad action prints `heartbeat takes on, off or run.` and returns 2.
The command returns 0 when the supervisor answers and 1 when none answers.

## The REPL

`chat` starts the REPL.
The prompt is `enchiridion> `.

| Line     | Behavior                                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------------------- |
| `/help`  | Print the command list in slash form, with the REPL-only commands and without `chat` and `serve`.            |
| `/stop`  | Ask the turn in flight to stop. Print `cancellation requested.` and return 0, or `there is no turn to stop.` and return 1. |
| `/quit`  | Leave the session.                                                                                          |
| `/who`   | Print the attached channel and the supervisor state, then return 0.                                          |
| other `/NAME ARGS` | Run the command table row NAME.                                                                  |
| any other line | Send the line to the agent as one turn.                                                              |

An empty line does nothing.
An end of input leaves the loop.
A slash command that fails prints its line and the loop continues.
The REPL ignores every command status except the request to quit.

A line with no slash is a turn, with one exception.
A single word that names a REPL command prints:

```text
Commands start with a slash: try `/help`.
```

The command name appears in the message, lowercased, and the REPL sends no turn.
Two or more words are always a turn.

`/who` prints the channel and the supervisor state:

```text
channel cli is attached to this command context.
supervisor generation 1
```

The generation line prints only while a supervisor answers.
With no live supervisor it prints `no supervisor is running.`

`/quit` and an end of input leave an ordinary session.
A signal also ends the process (see [Signals](#signals)).
There is no `exit` command.
A shell call with the name `exit` prints the unknown-command line and returns 2.

Ctrl-C does not leave the session.
It aborts the line being read or the turn being answered, prints `interrupted.`, and returns to the prompt.
`/stop` is the cooperative form of the same request for a running turn.

## Signals

One handler at the top level answers Ctrl-C, SIGTERM, and SIGHUP.
It prints one line to standard error and returns 130:

```text
enchiridion: interrupted.
```

The throw unwinds through every cleanup form.
`serve` stops its channels and writes a last status file.
`chat` stops its supervisor.
`ask` closes its context and store.
A closed terminal and `docker stop` therefore stop the process cleanly (see [Deployment](deployment.md)).

The REPL is the one difference.
It answers Ctrl-C itself, by aborting the line or the turn, and declines SIGTERM and SIGHUP.
Those two leave the session and reach the top level, which returns 130.

## Plugin verification

`--verify-plugin` verifies a directory of agent files and exits.
The flag takes one directory.
It is read before the command table, so it is not a command row.
A missing directory prints `--verify-plugin takes a directory.` and returns 2.

Verification runs in a separate child process, so a file that kills the compiler cannot take the running generation with it.
The child drops to a user identifier (uid) of 1000 before it reads one agent file when the parent runs as root.
It compiles and loads every Lisp file under `skills/` and `tools/`, collects every warning, and runs every plugin self-test.
The report goes to standard output.

```text
2 files compiled, 2 self-tests ran
```

A failure prints the reason lines and returns 1:

```text
broken self-test returned NIL
warned.cl: IGNORE declaration for an unknown variable: Y
```

Success returns 0, and a compile error, a warning, and a self-test that returns `nil` are all failures.

The child is selected by `ENCHIRIDION_SBCL`.
Without the variable the harness tries `sbcl`, and a source run must set the variable and give the child a writable compiled-file cache.
The packaged wrapper sets the variable.
[Plugins and self-modification](plugins.md) covers verification and the generation.

## Troubleshooting

| Symptom                                                              | Cause                                                                 | Fix                                                                  |
| -------------------------------------------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `There is no command called NAME.`                                   | The name is not in the table, or a flag reached the table as a name    | Run `help`, and put flags before the command                         |
| `COMMAND takes ARGUMENTS; got N.`                                    | The call is outside the row's argument range                          | Run `help COMMAND` for the range                                     |
| `COMMAND needs the memory store, and none is open in this process.`  | The store did not open                                                | Set `:memory :db` to a writable path (see [Configuration](configuration.md)) |
| `COMMAND: no supervisor is running, so nothing was asked.`           | No live supervisor answers the control file                           | Start `serve` in another terminal                                    |
| `channel NAME is not implemented yet.`                               | The supervisor did not build that channel                             | Enable the channel in the configuration, or pass `--channel NAME`    |
| `The broker did not start before the timeout.`                       | The child Lisp is missing, or its cache directory is not writable     | Run from `nix develop`, and set `ENCHIRIDION_SBCL` to the SBCL path  |
| `--verify-plugin` reports a failure                                  | An agent file warns, fails to compile, or fails its self-test         | Correct the file, then verify again                                  |
| `enchiridion: stdin is not a terminal, so the cli channel stays down.`| `serve` supervises the terminal channel without a terminal            | Run `serve` in a terminal, or use another channel                    |

## See also

- [Getting started](getting-started.md): the first launch and the first session.
- [Configuration](configuration.md): the keys the commands read and the flag precedence.
- [Supervisor and heartbeat](supervisor.md): the control file, the status file, and the tick.
- [Channels](channels.md): the terminal, webhook, and Fluxer channels.
- [Plugins and self-modification](plugins.md): generations, verification, and the broker.
