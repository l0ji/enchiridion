# Commands

One command table backs the `enchiridion` binary and the terminal REPL.
This page gives the flags, the commands and their arguments, the live supervisor requests, the REPL rules, plugin verification, and the exit statuses.

## How a call works

A table row holds a name, a minimum and maximum argument count, a handler, a summary, and the capabilities the command needs.
The count is checked before the handler runs.
An unknown name or a call outside the range prints one line and returns 2.
A handler that returns no integer is success.
Names match without case.
`ask`, `memory`, and `tasks add` join their arguments with single spaces; every other command reads positional words.

A command builds only the state its row names; a handler that needs more, such as `doctor`, reads it itself.
`help`, `version`, `check`, `tools`, `health`, `reload`, `channels`, and `heartbeat` read no configuration, open no store, and create no state.
An unknown name or a wrong argument count is answered from the table before anything is read.
The commands that only read the agent tree need no configuration either, except `blocks show` for its configured limits.
`init`, `journey`, `undo`, and `bootstrap step` need configuration and Git.
Only `ask`, `chat`, and `serve` build a backend, a broker, and an agent together.
A command that needs `config.cl` and finds none stops with exit 2 (see [Configuration](configuration.md)).

## Exit statuses

| Status | Meaning                                                                        |
| ------ | ------------------------------------------------------------------------------ |
| 0      | The command completed.                                                         |
| 1      | The command refused its situation and said why, a turn failed, or a build failed. |
| 2      | Unknown name, wrong argument count, bad flag, or refused configuration.        |
| 130    | A signal stopped the process (see [Signals](#signals)).                        |

A handler prints its own failure line.
A configuration error that escapes a handler prints its report and returns 2.
Any other escaping condition prints the condition and a short backtrace, then returns 1.

```text
There is no command called NAME. Try `help`.
```

At the REPL the suggestion names `/help`.
A wrong count prints `COMMAND takes ARGUMENTS; got N.` and returns 2.
Every line that names a command uses the spelling of the surface in front of the operator.

## Flags

```text
Usage: enchiridion [--channel NAME] [--bind ADDRESS] [--port NUMBER] [--token-env NAME] [COMMAND [ARGUMENTS]]
```

| Flag               | Value                      | Effect                                                              |
| ------------------ | -------------------------- | ------------------------------------------------------------------- |
| `--channel NAME`   | `cli`, `http`, or `fluxer` | Start `http` or `fluxer` even when the configuration disables it.   |
| `--bind ADDRESS`   | An address                 | Webhook bind address for this process.                              |
| `--port NUMBER`    | 1 to 65535                 | Webhook port for this process.                                      |
| `--token-env NAME` | A variable name            | Variable that holds the webhook token for this process.             |

The flags configure `chat` and `serve`, come before the command, and for those two commands may also come after it.
A valid flag before another command is accepted and has no effect.
The `--bind`, `--port`, and `--token-env` flags belong to `--channel http`.
A flag belongs to one invocation and never writes `config.cl`.

An invalid flag stops the process before any command runs.
The line goes to standard error with the `enchiridion: ` prefix and the status is 2:

| Mistake                                | Line                                                                    |
| -------------------------------------- | ----------------------------------------------------------------------- |
| A flag with no value                   | `The --channel flag needs a value.`                                     |
| A channel that does not exist          | `There is no channel called NAME. The channels are cli, http and fluxer.` |
| A webhook flag without `--channel http` | `The --bind, --port and --token-env flags belong to --channel http.`   |
| A port outside the range               | `The port must be a number between 1 and 65535, not VALUE.`             |

A value that starts with `--` is read as the next flag, so `--bind --port 8787` reports that `--bind` needs a value.
A flag that is not one of the four reaches the table as a command name or an argument.

On a seeded agent directory, channel flags with no command serve.
Before the first launch they write the seed files instead.

## The command table

| Command     | Arguments                                        | Summary                                                       | Exit        |
| ----------- | ------------------------------------------------ | ------------------------------------------------------------- | ----------- |
| `init`      | 0 or 1                                           | Create the agent directory and seed files                     | 0 or 1      |
| `ask`       | 1 or more                                        | One turn in a short lived session                             | 0 or 1      |
| `check`     | none                                             | Compile every system file and the entry scripts               | 0 or 1      |
| `skills`    | 0 to 2: `list`, `show NUMBER`                    | List or show skills                                           | 0, 1, or 2  |
| `tools`     | 0 to 2: `list`, `show NAME`                      | List or show tools                                            | 0, 1, or 2  |
| `blocks`    | 0 to 2: `show`, `edit NUMBER`                    | Blocks with character counts and capacity                     | 0, 1, or 2  |
| `persona`   | 0 or 1: `show`, `edit`                           | `SOUL.md`                                                     | 0 or 2      |
| `operator`  | 0 or 1: `show`, `edit`                           | `OPERATOR.md`                                                 | 0 or 2      |
| `world`     | 0 or 1: `show`, `edit`                           | `WORLD.md`                                                    | 0 or 2      |
| `memory`    | 1 or more: a query or an action                  | Search sessions, memories and episodes                        | 0, 1, or 2  |
| `sessions`  | none                                             | Stored sessions with turn counts                              | 0 or 1      |
| `journey`   | 0 to 2: `list`, `show REV`, `edit REV`, `rm REV` | Everything the agent has learned or written                   | 0 or 2      |
| `undo`      | exactly 1                                        | Roll back the nth change in the agent directory               | 0, 1, or 2  |
| `usage`     | none                                             | Token ledger by model, day and channel                        | 0 or 1      |
| `budget`    | none                                             | Spend against the caps                                        | 0           |
| `tasks`     | 0 or more: `list [STATUS]`, `add TEXT`, `rm ID`  | The task queue                                                | 0, 1, or 2  |
| `secrets`   | none                                             | Names and sources, never values                               | 0           |
| `providers` | 0 to 2: `list`, `show ID`, `models ID`, `refresh` | Provider list, one provider, its models, or a catalog refresh | 0, 1, or 2  |
| `version`   | none                                             | Version and build provenance                                  | 0           |
| `help`      | 0 or 1                                           | Command list, or detail for one                               | 0 or 2      |
| `bootstrap` | 0 to 2: `status`, `run`, `step N`, `reset`       | Bootstrap state, steps, or a reset                            | 0 or 2      |
| `doctor`    | none                                             | Check local dependencies and the broker                       | 0 or 1      |
| `health`    | none                                             | Read the running supervisor's status                          | 0 or 1      |
| `reload`    | none                                             | Ask a running supervisor to reload its code                   | 0 or 1      |
| `channels`  | 0 to 2: `list`, `enable NAME`, `replace NAME`, `disable NAME` | List, enable, replace, or disable a channel     | 0, 1, or 2  |
| `heartbeat` | 0 or 1: `on`, `off`, `run`                       | Turn the heartbeat on, off, or run one                        | 0, 1, or 2  |
| `chat`      | none                                             | Start the REPL                                                | 0, 1, or 130 |
| `serve`     | none                                             | Start the supervisor and its channels                         | 1 or 130    |

Every row also returns 2 for a wrong argument count.

An absent action takes the default: `list` for `skills`, `tools`, `channels`, `journey`, and `tasks`; `show` for `blocks`, `persona`, `operator`, and `world`; `status` for `bootstrap`; and `on` for `heartbeat`.

## Session and build commands

### init

`init` writes every absent seed file and keeps every present one, then prints the status line and one line per file: `  created NAME`, `  kept    NAME`, or `  problem NAME`.
It accepts and ignores one argument.
A problem returns 1.
The first launch runs the same code.

### ask

`ask` joins its arguments and runs one turn in a short-lived session.
The reply goes to standard output, scrubbed.
The token line goes to standard error as `<model>  in <input>  out <output>`, with `  cached <N>` and `  wrote <N>` appended when the provider reports cache tokens.
While the turn runs, its steps go to standard error, so standard output stays the reply alone:

```text
  thought: The operator said hi. BOOTSTRAP.md says to read SOUL.md first...
  -> read-file {"path":"SOUL.md"}  ok, 24 lines
  -> search {"query":"handover"}  failed: Tool search failed. <the reason>
  tool round limit reached after 8 rounds; asking for an answer
```

`thought:` is the model's reasoning when the provider returns it, cut to one line, and `said:` is text the model wrote beside a tool request.
Each `->` line is one tool call with its arguments, then `ok` with the result's line count or `failed` with the error.
On a terminal the step in flight shows a running clock; elsewhere only finished steps are written.
A completed turn returns 0, and a failed or cancelled turn returns 1.
Without a usable key it prints `Configuration is wrong at API-KEY.` and `No API key. Put VARIABLE in .env or the environment.` and returns 1.
`ask` is the only one-shot command that refreshes provider knowledge when `:offline` is nil.

### check

`check` runs `nix --option eval-cache false run .#check` in the current directory with a one hour timeout.
It prints the combined output and returns 0 on success, 1 on a failed build or a missing `nix`.

### chat

`chat` starts the REPL in the foreground and polls the supervisor's control queue on a thread, so a reload typed at the REPL reaches a supervisor that answers.
It returns 0 when `/quit` or an end of input ends the session, 130 on a signal, and 1 when the supervisor fails to start.
Agent code that fails to load prints a warning and does not stop the session.
It is a shell-only command.

### serve

`serve` starts the supervisor and polls in the foreground.
The `cli` channel is built for this command; `http` and `fluxer` are built when the configuration enables them or `--channel` names them.
The command runs until a signal stops it and returns 130; a startup error returns 1.
It is a shell-only command.
Without a terminal the `cli` channel prints `enchiridion: stdin is not a terminal, so the cli channel stays down.` and the supervisor restarts it, so the line repeats.

## Inspection commands

### help

`help` prints the command list, or the detail for one command.

```text
ask -- One turn in a short lived session
  arguments: at least 1 argument
```

The arity text is `no arguments`, `at least N arguments`, `exactly N arguments`, or `N to M arguments`.
At the REPL the list labels every command with its slash, adds `/stop`, `/quit`, and `/who`, and leaves out `chat` and `serve`.
`/help chat` prints `chat is a shell-only command, so the REPL does not have it.` and returns 2.
An unknown name returns 2.

### version

`version` prints `enchiridion 0.1.0`, then `source` with the project root, and `branch` and `head` when Git answers.

```text
enchiridion 0.1.0
source /path/to/enchiridion
branch main
head   5eb09e2...
```

With no checkout above the current directory it prints `no checkout was found above this directory.` and returns 0.

### doctor

`doctor` checks local runtime dependencies without building an agent or a backend.
It checks Git, the configuration, each provider key variable by name, the store, the broker, the seed files, and the bootstrap state.
Each check prints `doctor NAME: ok` or `doctor NAME: failed: TYPE`.
Provider keys print `doctor provider key NAME: present` or `missing`, and the last line is `doctor bootstrap: STATUS`.

A missing or refused configuration is reported, and the remaining checks run on the shipped defaults.
An absent store prints `doctor store open/close: ok: absent; nothing created`; an existing store is opened and closed.
A missing provider key is reported but does not fail the check.
The broker check uses a private socket and log under the temporary directory, so it does not collide with a supervisor that is already serving.
It exits 0 when every check passes and 1 otherwise, and takes no arguments.
At a surface with no health check it prints ``This surface has no health check; run `enchiridion doctor` in a shell.`` and returns 1.

### secrets

`secrets` prints each loaded name with its source, never a value, then one line about the secret file.

```text
OPENAI_API_KEY from file
secrets file /path/to/enchiridion/.env mode #o600 present
```

The source is `file`, `env`, or `argument`; `argument` comes from a literal `:token` in `:http`.
With nothing loaded it prints `no secrets are loaded.` and still reports the file line.
A file the loader opened reports `present` or `discarded`; `discarded` is the steady state in a container.
When no file was read, the line names the path the loader would have tried and reports `present` or `absent`.
The mode reads `unknown` when there is none to report.

### budget

`budget` prints the caps from the `:budget` section.

```text
tick cap: 4000
day cap:  400000
```

When an agent is attached it also prints `tick spent out: BOOL` and `day spent out:  BOOL`, where `T` means that window is exhausted.

### providers

`providers list` prints one line per provider: id, name, handler or `unsupported`, profile, endpoint, key variable, key presence, and row source.
`providers show ID` prints every field of one row with `none` for an empty value; an unknown id returns 2.
`providers models ID` asks the provider which models its account can reach, prints id, its display name when that differs, context size, and output size per model, then `<N> model(s).`
A provider with no model list prints `<ID> offers no model list. Set :model-primary, or use a row with :models.` and returns 1.
`providers refresh` fetches the catalog and prints `provider catalog refreshed: <N> provider(s).`; a failed fetch prints the condition and returns 1.
`models` and `refresh` reach the network even when `:offline` is true.
Missing IDs print `providers show takes an ID.` or `providers models takes an ID.` and return 2.
A bad action prints `providers takes list, show ID, models ID or refresh.` and returns 2.

## Agent directory commands

### skills

`skills` lists the `.cl` files directly under `skills/`, or shows one with `show NUMBER`.

```text
1. example-welcome.cl -- welcome, hello, introduce yourself
```

The trigger line follows the file name when the file declares a `+trigger+` string.
With no files it prints `no skills yet.`
A non-numeric argument prints `expected the number of an entry.` and returns 2; a number past the end prints `there is no entry N.` and returns 1; a bad action prints `skills takes list or show NUMBER.` and returns 2.
A listing reads the trigger without evaluating the file, and a file that does not read still appears.

### tools

`tools list` prints `NAME TOKENS tokens - DESCRIPTION` for every registered tool, or `no tools are registered in this process.`
`tools show NAME` prints the schema as JSON.
A missing name prints `tools show needs a tool name.` and returns 2; an unknown name prints `There is no tool called NAME.` and returns 1; a bad action prints `tools takes list or show NAME.` and returns 2.
Built-in tools are registered for every command; tools from the agent directory load when a turn runs (see [Plugins and self-modification](plugins.md)).

### blocks

`blocks` prints one line for each Markdown-backed label: label, character count, limit, and file.

```text
soul 758/6000 /path/to/home/agents/default/SOUL.md
persona 758/6000 /path/to/home/agents/default/SOUL.md
```

`soul` and `persona` both name `SOUL.md`.
The limit is the configured `:block-limits` value for the label.
`edit NUMBER` prints the path of that label's file.
A missing or non-numeric number prints `blocks edit needs the number of a block.` and returns 2; a number past the end prints `there is no block N.` and returns 1; a bad action prints `blocks takes show or edit NUMBER.` and returns 2.

### persona, operator, and world

`persona`, `operator`, and `world` show or point at `SOUL.md`, `OPERATOR.md`, and `WORLD.md`.
`show` prints the file text, and `edit` prints the absolute path.
A bad action prints `NAME takes show or edit.` and returns 2.

### bootstrap

`bootstrap` reads, records, and resets the bootstrap state.
`status` prints `Bootstrap step N of M: <summary>` while steps remain, `Bootstrap complete.` when `BOOTSTRAP.md` is absent, or `Bootstrap complete: N of N steps done.` when the file is present and every step is done.
`step N` records one step and prints the new status line.
`run` prints `bootstrap has N steps left:` and the remaining steps, or `bootstrap is complete; the agent owns the seed files.`
`reset` restores `BOOTSTRAP.md` from `BOOTSTRAP.done.md` when the live file is absent, clears the record, and prints `bootstrap reset to its first step.`
A bad action prints `bootstrap takes status, run, step NUMBER or reset.` and returns 2.
An invalid step prints `bootstrap step needs a step number.` or `There is no bootstrap step N.` and returns 2.
The meta tool action `bootstrap-step` records a step from a turn; the last step archives `BOOTSTRAP.md` as `BOOTSTRAP.done.md`.
If a session cannot record a step, rename the file by hand:

```sh
mv agents/default/BOOTSTRAP.md agents/default/BOOTSTRAP.done.md
```

A manual rename opens the write gate but leaves the state record and the commit alone.
[Memory](memory.md#the-bootstrap) owns the state machine.

### journey

`journey list` prints up to 20 commits as `REV SUBJECT`, or `the agent directory has no history yet.`
The kernel commits after each successful turn with `Turn N via CHANNEL`.
A revision argument is a 1-based position in the log or a revision string.
`show REV` prints the revision text, `edit REV` prints `edit <directory> by hand; the change is <revision>.`, and `rm REV` reverts the revision and prints the Git output.
A missing revision prints `journey show needs a revision or a number.` and likewise for `edit` and `rm`, returning 2.
A bad action prints `journey takes list, show, edit or rm.` and returns 2.
A Git failure is ignored, so a failed revert still returns 0.

### undo

`undo N` rolls back one change in the agent directory and resolves the argument like a `journey` revision.
It prints `reverted REV.` and returns 0, `could not revert REV.` and returns 1 when Git refuses, and `undo needs the number of a change.` and returns 2 when no log entry matches.

## Memory and ledger commands

The store commands need an open memory store.
A store that cannot be opened prints one warning on standard error and does not stop the command.
The command then refuses with exit 1:

```text
enchiridion: not keeping a transcript: Configuration is wrong at MEMORY.
COMMAND needs the memory store, and none is open in this process.
```

### memory

With a search query, `memory` searches the memories view and the turns view over the one episodic log.

```text
memories: 0
turns: 0
```

Each row prints as `  KEY: VALUE`.
A search that fails prints no rows for that section.

The first argument may be an action instead:

```sh
enchiridion memory status
enchiridion memory build
enchiridion memory import FILE.jsonl
enchiridion memory candidates
enchiridion memory gates ID
enchiridion memory promote ID
enchiridion memory regate ID
enchiridion memory rollback ID
enchiridion memory canaries
```

`candidates` lists every generation: status, episodes derived, writes, tokens, and a promotion result or quarantine reason.
`gates ID` prints that generation's checks in order, each with kind, result, value, and the start of its report.
`promote ID` runs the generation through the gates as the heartbeat would; it never bypasses one, and it exits 1 when the candidate is quarantined, held, or not a candidate.
`regate ID` returns a quarantined generation to candidate and runs the gates again. It is for a quarantine the reading code caused rather than the claims; gating stored claims again calls no model.
`rollback ID` rolls a live generation back to its parent, or marks a candidate rolled back.
`canaries` lists the configured canaries and says whether their families cover `:canary-min-families`.
`build` runs one bounded T2 candidate build. With no assertion deriver installed it reports `no candidate built: no-deriver.` and exits 1.

`import` reads a conversation log as JSON Lines, one turn per line, oldest first:

```json
{"session": "2026-03-01-a", "role": "user", "body": "where is the deploy key", "ts": 1772323200}
{"session": "2026-03-01-a", "role": "assistant", "content": "in vault under ops"}
```

`body` may be spelled `content`; `ts` is optional UNIX seconds.
Each turn is scrubbed and stored like a live one, on the `import` channel.
A session the store already has is skipped whole, so the same file can be imported twice safely.
Nothing calls a model: T2 derives the semantics on its schedule.

`status` prints the switch states and counts:

```text
enabled: T
retrieve: T
push: NIL
episodes: 12
retrievals: 3
generations: 0
live-generation: 0
cue-index: 0
canaries: 0
```

The exit status is 0 with a store and 1 without one.
[Episodic memory](episodic-memory.md) owns the log and the gates.

### sessions

`sessions` lists stored sessions with their turn counts.

```text
ID 4 turns
3 sessions in the store.
```

The exit status is 0 with a store and 1 without one.

### usage

`usage` prints the token ledger by model, by channel, and by day.
A non-empty section has the columns `input`, `output`, `cache read`, `cache write`, and `calls`, then one row per group.
An empty section prints `  the ledger is empty.`
The exit status is 0 with a store and 1 without one.

### tasks

`tasks` reads, adds, and removes work for the sleep-time agent.
Options are `list [STATUS]`, `add TEXT`, and `rm ID`.
`list` prints `ID (status) body`, or `no tasks.` (or `no tasks with status STATUS.`)
A status filters the list; the statuses are `pending`, `running`, `done`, and `failed`.
Any other status prints `tasks list takes pending, running, done or failed.` and returns 2.
`add` joins the remaining arguments and prints `task ID queued.`; a missing text prints `tasks add needs the text of the task.` and returns 2.
`rm` prints `task ID removed.` or `there is no task ID.` and returns 0; a missing or non-numeric id prints `tasks rm needs the id of a task.` and returns 2.
A bad action prints `tasks takes list, add or rm.` and returns 2.

## The live supervisor

`reload`, `channels`, and `heartbeat` act on a running supervisor.
The command writes one request under `run/control/` and reads the supervisor's response, waiting up to five seconds.
The supervisor polls the queue once per second and rewrites `run/enchiridion.status` on every answer.
A status file counts as live for ten seconds and only while its `running` flag is true.

Without a live supervisor the command prints one line and returns 1 without writing a request:

```text
reload: no supervisor is running, so nothing was asked.
```

`health` reads the status file only and sends no request.

### health

`health` reports the supervisor state.

```text
supervisor pid 12345, generation 2.
reload done, generation 2.
heartbeat on, 7 ticks, last at 4001409114
channel cli stopped
channel http live
```

The first line holds the pid and the generation; the next is the last control report, when one exists.
The heartbeat line holds the schedule state, the tick count, and the universal time of the last tick, with a non-empty tick report after a colon.
A tick still running adds `  a tick has been running for N second(s).`
Without a live supervisor it prints `no supervisor is running.` and returns 1; with one it returns 0.

### reload

`reload` asks the supervisor to verify and load the agent code again.

```text
reload done, generation 2.
generation 2.
```

The first line is the supervisor report; the second is the generation the status file now names.
A refused generation keeps the last good code serving and returns 1:

```text
reload refused: broken self-test returned NIL
```

### channels

`channels` lists, enables, replaces, or disables a supervised channel.

```text
cli stopped, http live
generation 1.
```

`list` prints every supervised channel with its state, separated by commas, or `no channels are up.`
`enable NAME` prints `NAME is up.` or `NAME is already up.`
`replace NAME` starts a fresh channel, waits up to 20 seconds for it to report live, and only then stops the old one. A replacement that fails keeps the old channel.
`disable NAME` prints `NAME is down.`
A name the supervisor did not build prints `channel NAME is not implemented yet.` and returns 1.
A missing name produces the supervisor report `which channel?` and returns 1.
A bad action prints `channels takes list, enable NAME, replace NAME or disable NAME.` and returns 2.

### heartbeat

`heartbeat` turns the sleep schedule on or off, or asks for one tick.
Options are `on`, `off`, and `run`; `on` is the default.
`on` prints `heartbeat on.`, or `heartbeat on, but no sleep agent is attached to this process.` when nothing can tick.
`off` prints `heartbeat off.`
`run` asks for one tick and answers at once: `heartbeat tick requested; the answer lands in the status file.`, or `a tick is running; one more is queued and the answer lands in the status file.`
With no sleep agent it answers `no sleep agent is attached to this process.`
`off` stops the schedule and not the operator, so `run` still forces a tick.
A bad action prints `heartbeat takes on, off or run.` and returns 2.
The command returns 0 when a supervisor answers and 1 when none does.

## The REPL

`chat` starts the REPL. The prompt is `enchiridion> `.

| Line               | Behavior                                                                                     |
| ------------------ | -------------------------------------------------------------------------------------------- |
| `/help`            | Print the command list in slash form, with the REPL-only commands and without `chat` and `serve`. |
| `/stop`            | Ask the turn in flight to stop. `cancellation requested.` returns 0; `there is no turn to stop.` returns 1. |
| `/quit`            | Leave the session.                                                                            |
| `/who`             | Print the attached channel and the supervisor state.                                          |
| other `/NAME ARGS` | Run the command table row NAME.                                                               |
| any other line     | Send the line to the agent as one turn.                                                       |

An empty line does nothing, and an end of input leaves the loop.
A slash command that fails prints its line and the loop continues.
A line with no slash is a turn, with one exception: a single word that names a REPL command prints ``Commands start with a slash: try `/help`.`` and sends no turn. Two or more words are always a turn.

`/who` prints the channel and the supervisor state:

```text
channel cli is attached to this command context.
supervisor generation 1
  cli live
```

A generation line prints only while a supervisor answers; otherwise it prints `no supervisor is running.`
Ctrl-C does not leave the session: it aborts the line being read or the turn being answered, prints `interrupted.`, and returns to the prompt.
`/stop` is the cooperative form of the same request.

## Signals

One handler at the top level answers Ctrl-C, SIGTERM, and SIGHUP.
It prints one line to standard error and returns 130:

```text
enchiridion: interrupted.
```

The throw unwinds through every cleanup form, so `serve` stops its channels and writes a last status file, `chat` stops its supervisor, and `ask` closes its context and store.
The REPL answers Ctrl-C itself and declines SIGTERM and SIGHUP; those two reach the top level and return 130.

## Plugin verification

`--verify-plugin` verifies a directory of agent files and exits.
It takes one directory and is read before the command table, so it is not a command row.
A missing directory prints `--verify-plugin takes a directory.` and returns 2.

Verification runs in a separate child process, so a file that kills the compiler cannot take the running generation with it.
The child clears its groups and drops to `:sandbox :agent-uid` and `:agent-gid` before it reads one agent file when the parent runs as root.
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

A compile error, a warning, and a self-test returning nil are all failures.
The child runs the SBCL named by `ENCHIRIDION_SBCL`, or the supervisor's own SBCL.
[Plugins and self-modification](plugins.md) owns the manifest and the generation.

## Troubleshooting

| Symptom                                                              | Cause                                                    | Fix                                                                  |
| -------------------------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------- |
| `There is no command called NAME.`                                   | The name is not in the table, or a flag reached the table | Run `help`, and put flags before the command                         |
| `COMMAND takes ARGUMENTS; got N.`                                    | The call is outside the row's argument range             | Run `help COMMAND` for the range                                     |
| `COMMAND needs the memory store, and none is open in this process.`  | The store did not open                                   | Set `:memory :db` to a writable path (see [Configuration](configuration.md)) |
| `COMMAND: no supervisor is running, so nothing was asked.`           | No live supervisor answers                               | Start `serve` in another terminal                                    |
| `channel NAME is not implemented yet.`                               | The supervisor did not build that channel                | Enable the channel, or pass `--channel NAME`                         |
| `The broker did not start before the timeout.`                       | The child did not bind its socket in 30 seconds          | Read `run/broker.log`                                                |
| `The broker exited with status N before it started.`                 | The child failed while it loaded                         | Read the log lines after the message                                 |
| `Git is required. Install Git and put it on PATH, or set ENCHIRIDION_GIT.` | The Git executable did not answer                  | Install Git, or point `ENCHIRIDION_GIT` at it                        |
| `config.cl is required. Copy config.example.cl to config.cl and edit it.` | A command that needs configuration found no file       | Copy and edit the example                                            |
| `--verify-plugin` reports a failure                                  | An agent file warns, fails to compile, or fails its test | Correct the file, then verify again                                  |

## See also

- [Getting started](getting-started.md): the first launch and the first session.
- [Configuration](configuration.md): the keys the commands read and the flag precedence.
- [Supervisor and heartbeat](supervisor.md): the control queue, the status file, and the tick.
- [Channels](channels.md): the terminal, webhook, and Fluxer channels.
- [Plugins and self-modification](plugins.md): generations, verification, and the broker.
