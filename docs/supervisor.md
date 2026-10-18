# Supervisor and heartbeat

The supervisor owns the channels, the two files under `run/`, and the heartbeat.
The `chat` and `serve` commands each build one supervisor for the process. The
supervisor never loads agent code. A reload goes through a hook the caller
supplies, so a daemon can do the broker round trip while a test loads in
process. The heartbeat is the only place unattended work starts.

## What the supervisor owns

| Field | Type | Meaning |
| --- | --- | --- |
| `directory` | string | The agent directory |
| `run-directory` | string | Where the control and status files live |
| `config` | plist | The active configuration |
| `store` | store | The memory store, or `nil` |
| `agent` | agent | The live agent, or `nil` |
| `session` | session | The live session, or `nil` |
| `broker` | broker | The broker handle, or `nil` |
| `generation` | integer | The loaded code generation |
| `channels` | list | The channel objects this process runs |
| `running-p` | boolean | True between start and stop |
| `heartbeat-p` | boolean | Whether the schedule runs |
| `heartbeat-interval` | integer | Seconds between ticks |
| `heartbeat-thread` | thread | The heartbeat thread, or `nil` |
| `tick-function` | function | The hook one tick calls, or `nil` |
| `ticks` | integer | How many ticks finished |
| `last-tick` | integer | When the last tick finished |
| `tick-started` | integer | When the running tick started |
| `tick-running-p` | boolean | True while a tick runs |
| `tick-requested-p` | boolean | True when a tick request waits |
| `tick-ok-p` | boolean | False when a tick phase failed |
| `tick-report` | string | What the last tick said |
| `last-compacted-turn` | integer | The last turn that compaction read |
| `last-sleep-turn` | integer | The last turn the sleep agent read |
| `bootstrap-line` | string | One line of bootstrap state |
| `report` | string | The last control report |
| `report-ok-p` | boolean | True when the process answered the last request |
| `handled` | integer | How many control requests the process answered |
| `reload-function` | function | The hook that produces a generation |
| `started` | integer | When the process started |

`make-supervisor` takes these fields and starts nothing. `supervisor-start`
starts the work. The heartbeat interval must be a positive whole number of
seconds. Anything else becomes 900, which is the shipped fifteen minutes. An
interval of zero would be a tick loop, and a string is a mistyped key.

## Startup and shutdown

`supervisor-start` returns at once when `running-p` is true. Otherwise it sets
`started` and `running-p`, and it starts every channel on its own thread. It
then starts the heartbeat thread when `heartbeat-p` is true, and writes the
first status file.

The heartbeat thread starts only when the caller attaches a tick hook.
`make-application-supervisor` attaches `enchiridion.kernel:heartbeat` as that
hook and reads the interval from `:sleep :interval-seconds`. The shipped default
is 900 seconds. The same function attaches the broker round trip as the reload
hook, so this process never compiles agent code.

`supervisor-stop` clears `running-p`, destroys the heartbeat thread, stops each
channel, destroys each channel thread, and writes the last status file. A tick
in flight unwinds on its own. Its task stays `running`, and the next process
marks that task `failed` in the recovery phase below.

## Threads and processes

| Work | Where it runs | Thread name |
| --- | --- | --- |
| The REPL, under `chat` | The main thread | none |
| The control poll, under `serve` | The main thread | none |
| The control poll, under `chat` | One extra thread | `enchiridion control poll` |
| The heartbeat | One extra thread | `enchiridion heartbeat` |
| One channel | One thread for each channel | `enchiridion channel <name>` |

`chat` starts the supervisor itself and puts the control poll on a thread beside
the REPL. The `serve` command receives the supervisor from the command context.
`cmd-serve` starts the supervisor and runs the poll loop in the foreground. The
REPL is the foreground surface of `chat`, so the cli channel is a supervised
channel under `serve` only.

The broker is a separate process and runs as the agent user. A reload verifies
the agent files in a one-shot child as that user, and only a generation that
exits zero reaches the broker.

## The two files

| File | Path | Purpose |
| --- | --- | --- |
| The control file | `run/enchiridion.control` | A caller appends one request per line |
| The status file | `run/enchiridion.status` | The state a reader asks about |

Both files live under `run/`, which is `<home>/run/`. The home is
`ENCHIRIDION_HOME`, or the current directory when that variable is unset.

`write-json-file` writes a temporary file and renames it into place. A reader
therefore sees the old file or the new one, and never half of either. The
function `read-status` returns NIL for a missing file, an unreadable file, and
half a file. The caller wants to know whether a supervisor is up, and a parse
error is not an answer to that question.

`status-fresh-p` returns true when the status file holds `running` true and
`updated` is no older than `+status-fresh-seconds+`, which is 10. The running
flag matters as much as the age. A supervisor that stops writes one last status
file, and that file is milliseconds old.

## The status file fields

| Key | Type | Meaning |
| --- | --- | --- |
| `pid` | integer | The process id |
| `running` | boolean | True while the supervisor runs |
| `started` | integer | When `supervisor-start` ran |
| `updated` | integer | When the process last wrote the file |
| `generation` | integer | The loaded code generation |
| `bootstrap` | string | One line of bootstrap state |
| `report` | string | The last control report |
| `report-ok` | boolean | True when the process answered the last request |
| `handled` | integer | How many control requests the process answered |
| `heartbeat` | object | The tick state in the table below |
| `root` | string | The agent directory |
| `config` | string | A digest of the configuration |
| `channels` | array | One row for each channel |

A channel row holds `name`, `state`, and `enabled`. The key `enabled` is true
when the configuration enables the channel or when this process runs it. A
`--channel` flag enables the channel in the serving process. A row that reported
a channel as disabled while its state said `live` would be the status file
contradicting itself.

The heartbeat object:

| Key | Type | Meaning |
| --- | --- | --- |
| `enabled` | boolean | Whether the schedule runs |
| `ticks` | integer | How many ticks finished |
| `last-tick` | integer | When the last tick finished |
| `running` | boolean | True while a tick runs |
| `started` | integer | When the running tick started |
| `ok` | boolean | False when a tick phase failed |
| `report` | string | What the last tick said |

The file holds nothing secret. It is world readable, so the scrubber cleans the
control report and the tick report on the way out. The `health` command shows
the useful part of the file in this shape:

```text
supervisor pid 1, generation 3.
reload done, generation 3.
heartbeat on, 12 ticks, last at 4123456789: idle
channel http live
```

## Control requests

The supervisor reads the control file once a second, acts on each line, and
empties the file. The last report lands in the status file, so a shell command
that only appended a line learns what happened.

| Request | Effect |
| --- | --- |
| `reload` | Produce a new generation through the reload hook |
| `channels list` | Report the channels |
| `channels enable <name>` | Start the named channel |
| `channels disable <name>` | Stop the named channel |
| `heartbeat on` | Start the schedule |
| `heartbeat off` | Stop the schedule |
| `heartbeat run` | Ask for one tick now |

An unknown verb answers one line and reports a refusal. `channels enable` with
no name answers `which channel?`. A name the process does not hold answers
`channel <name> is not implemented yet.`. The process builds every channel it
can run at startup, so an enable can start a channel that the configuration left
disabled.

`heartbeat off` stops the schedule and not the operator. `heartbeat run` still
ticks, because the request was explicit. The supervisor queues a request that
arrives during a tick instead of dropping it. A request that vanishes is worse
than one that runs a minute later.

`handle-control` returns two values: a one line report, and whether the process
answered the request. A reload that refused a generation returns a report and a
false answer, and the shell command that asked can tell the two apart.

### The two callers

`queue-control` appends one line and returns without waiting. A turn uses this
path, because a turn must not block on a poll. The agent asks for a reload, and
the answer arrives in the transcript of a later turn.

`request-control` is the shell path. It requires a fresh status file first and
records the `handled` counter. Then it appends the line and polls every 0.05
seconds until the counter grows or the wait expires. The default wait is 5
seconds. On expiry it returns NIL, and the caller says that no supervisor
answered.

## The operator commands

| Command | What it reads or asks | Exit status |
| --- | --- | --- |
| `health` | The status file | 1 when no supervisor runs |
| `reload` | `request-control "reload"` | 1 when the supervisor refused |
| `channels ...` | `request-control "channels ..."` | 1 when no supervisor runs |
| `heartbeat ...` | `request-control "heartbeat ..."` | 1 when no supervisor runs |

`health` prints the pid, the generation, the last report, the heartbeat line,
and one line for each channel. It also reports a tick that runs for a long
time. A tick that never returns stops unattended work and leaves the file
looking healthy. The start time of the running tick is the one fact that makes
the stall visible.

`reload` returns 1 when the supervisor refused the generation. A refused reload
keeps the last good code serving, and an operator script has to see that the
agent still runs the old code. The `channels` and `heartbeat` commands return 0
when the supervisor answered, even when the report is a refusal.

## The heartbeat schedule

A tick is due when a request waits, or when the schedule runs and `now -
last-tick` is at least the interval. The loop wakes once a second. That cadence
costs nothing, and a stop or a forced tick takes effect inside a second.

The process measures `last-tick` from the end of a tick. A pass longer than the
interval then runs again when it finishes instead of piling up behind itself.
The function `supervisor-ensure-heartbeat-thread` sets `last-tick` before the
thread starts, so the first tick waits one interval. A pass at once would
compete with the first operator turn and spend tokens before anyone asked for
anything. `heartbeat run` forces one at once.

`supervisor-tick` never signals. The thread that runs it is the whole scheduler
for unattended work. A scheduler that dies on one bad pass is a process that
quietly stops doing any. A failing hook becomes a report line. The tick counter
grows, and the report lands in the status file.

## The sleep agent and its phases

`enchiridion.kernel:heartbeat` runs four phases in a fixed order. Each phase has
its own guard. A failed phase adds a note, sets `:ok-p` false, and the later
phases still run.

| Order | Phase | What it does |
| --- | --- | --- |
| 1 | Task recovery | Marks every running task failed |
| 2 | The harness blocks | Writes the ledger block and the session fallback |
| 3 | The sleep agent | Claims one task, or runs a maintenance pass |
| 4 | Compaction | Rewrites the session block after new turns |

The report joins the notes with `; `. A tick with nothing to do answers `idle`.
The budget caps below bound the whole tick.

The supervisor builds the sleep agent fresh on every tick, so its prompt carries
the block files as the last pass left them. It is a second agent over the same
directory and the same broker. The operator's agent answers, and this one
consolidates. The three seed blocks are writable for the sleep agent, and the
operator's agent only reads them.

Phase 3 claims one task from the queue. With an empty queue it runs one
maintenance pass when a newer non-sleep turn exists, and otherwise reports
`idle`. One task for each tick, because the tick cap is a few thousand tokens
and a task is a full turn with tools.

The task prompt keeps the whole row and cuts the text at `+task-prompt-limit+`,
which is 4000 characters. The report names the cut, because a task answered from
its first four thousand characters is a fact the operator has to see.

Phase 4 runs when four new turns arrive, which is `+compaction-turns+`. It
rewrites the session block from the previous summary and the recent turns. The
compactor agent has no tools. Its single block holds the compaction brief
instead of the operator's identity files. A summariser that can call tools can
change the thing it summarises.

The sleep agent refuses to run for four reasons, and each reason names a fact:

| Reason | Condition |
| --- | --- |
| `no memory store is open` | No store |
| `no agent is attached` | No agent |
| `no model backend is configured` | No backend |
| `bootstrap has not handed over ...` | The seed files still belong to the operator |

A refused sleep phase writes `sleep skipped: <reason>`. A refused compaction
writes `compaction skipped: <reason>`.

## The task queue

| Status | Meaning |
| --- | --- |
| `:pending` | Waiting for a tick |
| `:running` | A tick claimed it |
| `:done` | Finished |
| `:failed` | The pass failed, or a dead process left the row running |

`dequeue-task` claims the oldest pending task and marks it `running`. A claim is
not a completion. A process that dies mid-task leaves evidence instead of a task
that says done. The update requires the row to stay pending, so two
claimants cannot both win.

`complete-task` marks a running task `done`. `fail-task` marks a running task
`failed`. The code requeues nothing, so unattended work is at-most-once. A task
that crashes its worker would otherwise loop until the day budget stops it.

`recover-tasks` marks every running task failed, and phase 1 runs it at the
start of every tick. The state a previous process left behind becomes visible
instead of silently in progress.

The `tasks` command lists, adds, and removes rows. `tasks list` takes the
optional status word `pending`, `running`, `done`, or `failed`.

## The ledger and the budget caps

Every model call adds one spend row with `model`, `input`, `output`,
`cache-read`, `cache-write`, `channel`, and `time`. The ledger block carries one
line, built to fit the block limit by construction rather than by truncation:

```text
session in 1200 out 340 cache r 0 w 0 calls 4 · day 15400
```

| Cap | Key | Default |
| --- | --- | --- |
| The tick cap | `:max-tokens-per-tick` | 4000 |
| The day cap | `:max-tokens-per-day` | 400000 |

The caps live in the `:budget` section. A missing cap is not a cap, so only the
operator's own limit bounds unattended work.

The tick window is the difference in the store total from the start of the tick.
A timestamp window would count the operator's own turn as unattended spend. With
the shipped cap, one busy second would disable the sleep agent. The day window
is the rolling 24 hours the ledger uses, so a burst across midnight still counts
in full.

`budget-refusal` returns one of two reasons when no model call may start:

```text
the tick cap is spent
the day cap is spent
```

A budget that will not read adds a reason of its own, and the tick writes it in
place of the refusal:

```text
the budget is unreadable: <condition line>
```

The sleep phase and compaction each ask. Phase 1 and phase 2 still run, because
the queue and the ledger are not model calls.

## Refusal paths

| Situation | Result |
| --- | --- |
| No supervisor answers | One line, exit 1 |
| A reload refused the generation | The report goes back, exit 1 |
| An unknown control verb | One line and a refused report |
| An unknown channel name | `channel <name> is not implemented yet.` |
| `heartbeat run` with no tick hook | `no sleep agent is attached to this process.` |
| A spent cap | The tick skips the phase with its reason |
| Bootstrap has not handed over | The tick skips the sleep agent with its reason |

The process also refuses to start a webhook that would answer the network
without a token. The function `check-http-policy` raises that refusal before the
supervisor starts. A bad flag is then one line and an exit status. The
alternative is a channel that dies and restarts every second.

## Related

- [Channels](channels.md)
- [Configuration](configuration.md)
- [Commands](commands.md)
- [Memory](memory.md)
- [Deployment](deployment.md)
