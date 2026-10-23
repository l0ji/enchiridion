# Supervisor and heartbeat

The supervisor is the process that owns the live agent, the memory store, the channels, and the schedule for unattended work.
A shell command does one thing and exits, so a live request reaches the supervisor through two files under `run/`.
The heartbeat is the only place unattended work starts, and the sleep agent is what the heartbeat runs.
An operator can read the process state, change the schedule, and reload the code through those files.

## What the process is

A supervisor holds the configuration, the memory store, the agent and its session, the broker, and the loaded code generation.
It also holds one channel object for each surface it runs.
It starts each channel on its own thread, polls the control file once a second, and rewrites the status file on every pass.
It never loads agent code.
A reload calls a function the process supplies, so a daemon can do the broker round trip and a test can load in process.

The two files are the whole interface between a running supervisor and a shell command.
`run/enchiridion.control` carries requests into the process, one request per line, and `run/enchiridion.status` carries state out of it as JSON (JavaScript Object Notation).
Both live under `<home>/run/`, where the home is `ENCHIRIDION_HOME` when it is set and the current directory when it is not.

The supervisor is built by `make-supervisor` and starts nothing.
The structure holds the fields an operator or a developer works with.

| Field | Type | Meaning |
| --- | --- | --- |
| `directory` | string | The agent directory |
| `run-directory` | string | Where the control and status files live |
| `config` | plist | The active configuration |
| `store` | store | The memory store, or `nil` |
| `agent`, `session` | agent, session | The live agent and its session, or `nil` |
| `generation` | integer | The loaded code generation |
| `channels` | list | The channel objects this process runs |
| `running-p` | boolean | True between start and stop |
| `heartbeat-p`, `heartbeat-interval` | boolean, integer | Whether the schedule runs, and the seconds between ticks |
| `tick-report`, `tick-ok-p` | string, boolean | What the last tick said, and whether it succeeded |

The defstruct in `src/enchiridion/supervisor.cl` is the full list.

`heartbeat-interval` must be a positive whole number of seconds.
Anything else becomes 900.

## Startup

The `serve` and `chat` commands both build one supervisor for the process.
The steps below describe the order the process takes.

1. Build the command context: load the configuration and secrets, open the store, and resolve the backend.
2. Build the broker and the agent.
3. Start the broker, load the agent generation, and open a session.
4. Build the supervisor with the session, the generation, the two hooks, the bootstrap line, and the heartbeat settings.
5. Build the channels.
6. Check the webhook policy.
7. Start the supervisor, which starts the channels and writes the first status file.
8. Run the process.

The store opens before the agent.
A generation that fails to load is reported and does not stop the process.
Each enabled channel is built, and so is one that a `--channel` flag names.
The terminal channel is built under `serve` only, because the REPL is the foreground surface under `chat` and is not a supervised channel.
`start-channel` names each thread `enchiridion channel <name>` and sets the channel state to `:running`.
A channel that returns or signals is restarted after one second while the supervisor runs.
A webhook that would answer the network without a token is refused before any channel starts.

Under `chat`, the terminal channel is not a supervised channel.
Under `serve`, it is.

`supervisor-start` returns at once when the running flag is already true, so a second call does nothing.

## Shutdown

`supervisor-stop` performs these steps in order.

1. Clear the running flag.
2. Destroy the heartbeat thread, and ignore a thread that is already gone.
3. For each channel, call `channel-stop` and destroy its thread.
4. Clear each thread slot and set each channel state to `:stopped`.
5. Write the last status file, now with `running` false.

A tick in flight is left to unwind rather than destroyed.
A thread killed in the middle of a store write leaves the database locked.
A task that the tick was running stays `running`, and the next process marks it failed in the first phase of its first tick.

The terminal interrupt path stops the process the same way.
`Ctrl-C` at the shell, `SIGTERM`, and `SIGHUP` all unwind through every cleanup form, so `serve` stops its channels and writes its last status.
The exit status is 130, the shell convention for a process ended by `SIGINT`.
`Ctrl-C` inside the REPL is not this path: it aborts the line or the turn in flight and returns to the prompt.
See [Channels](channels.md) for the terminal channel.

A process that ends without a clean stop leaves its last status file with `running` true, and the freshness rule below stops a reader from trusting it.

## Threads

Under `chat` the main thread runs the REPL, and the control poll runs on `enchiridion control poll`.
Under `serve` the main thread runs the control poll.
The heartbeat runs on `enchiridion heartbeat`, and each channel runs on `enchiridion channel <name>`.

## The control file

The control file is `run/enchiridion.control`, and `control-file` returns its path.
It holds one request per line.
A caller appends a line and the supervisor consumes the file, acts on each line in order, and truncates it.
The last report lands in the status file.

```sh
printf 'heartbeat run\n' >> run/enchiridion.control
```

The shell commands use `request-control`, which is more than an append.
It first reads the status file and refuses when that file is not fresh.
It records the `handled` counter, appends the line, then polls every 0.05 seconds until the counter grows or five seconds pass.
It returns the status when the request was answered and `nil` when no supervisor answered.
A request that arrives during a tick is queued by the heartbeat, not dropped.

The agent path uses `queue-control`.
It appends one line and returns without waiting, because a turn must not block on a poll.
The answer arrives in the transcript of a later turn.

| Request                   | Report                                                                                                                                               | Answered                  |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| `reload`                  | `reload done, generation <n>.` or `reload refused: <report>`                                                                                         | Yes, or no when refused   |
| `channels list`           | `name state, name state` or `no channels are up.`                                                                                                    | Yes                       |
| `channels enable <name>`  | `<name> is up.`, `<name> is already up.`, or `channel <name> is not implemented yet.`                                                                | Yes                       |
| `channels disable <name>` | `<name> is down.`                                                                                                                                    | Yes                       |
| `heartbeat on`            | `heartbeat on.` or `heartbeat on, but no sleep agent is attached to this process.`                                                                   | Yes, or no without a hook |
| `heartbeat off`           | `heartbeat off.`                                                                                                                                     | Yes                       |
| `heartbeat run`           | `heartbeat tick requested; the answer lands in the status file.` or `a tick is running; one more is queued and the answer lands in the status file.` | Yes, or no without a hook |
| Anything else             | `unknown control request: <line>`                                                                                                                    | No                        |

The `channels enable` request with no name answers `which channel?`.
A name the process does not hold answers that way because the process builds only the channels the configuration enables or a flag names.

The supervisor increments `handled` before it acts on a line, and it prints every report to the error stream as `enchiridion: <report>`.
A line appended between the read and the truncate is lost, and the caller asks again.

## The status file

The status file is JSON, written by temporary file and rename.
A reader therefore sees the old file or the new one, and never half of either.
`read-status` returns `nil` for a missing file, an unreadable file, and half a file alike.

| Key          | Type    | Meaning                                                          |
| ------------ | ------- | ---------------------------------------------------------------- |
| `pid`        | integer | The process identifier                                           |
| `running`    | boolean | True while the supervisor runs                                   |
| `started`    | integer | When `supervisor-start` ran, as a universal time                 |
| `updated`    | integer | When the process last wrote the file, as a universal time        |
| `generation` | integer | The loaded code generation                                       |
| `bootstrap`  | string  | One line of bootstrap state, computed when the supervisor is built |
| `report`     | string  | The last control report, scrubbed                                |
| `report-ok`  | boolean | False after a refused request, and true before the first request |
| `handled`    | integer | How many control requests the process has answered               |
| `heartbeat`  | object  | The tick state, in the table below                               |
| `root`       | string  | The agent directory                                              |
| `config`     | string  | An eight-character digest of the configuration                   |
| `channels`   | array   | One row for each channel                                         |

A channel row holds `name`, `state`, and `enabled`.
`enabled` is true when the configuration enables the channel or when this process runs it.
A channel started by a `--channel` flag is therefore not reported as disabled while it is live.

The `bootstrap` line is computed once when the supervisor is built and is written unchanged on every pass.
A bootstrap step completed during the process lifetime does not appear in the status file until a later process reads it.

The heartbeat object holds the state of the schedule.

| Key         | Type    | Meaning                                          |
| ----------- | ------- | ------------------------------------------------ |
| `enabled`   | boolean | Whether the schedule runs                        |
| `ticks`     | integer | How many ticks have finished                     |
| `last-tick` | integer | When the last tick finished, as a universal time |
| `running`   | boolean | True while a tick runs                           |
| `started`   | integer | When the running tick started                    |
| `ok`        | boolean | Whether the last tick succeeded                  |
| `report`    | string  | What the last tick said, scrubbed                |

Nothing secret is written, because the file is world readable.
The control report and the tick report pass through the scrubber on the way out.

A status file counts as live when it holds a true `running` flag and an `updated` time no more than ten seconds old.
The limit is `+status-fresh-seconds+`, which is 10.
The flag matters as much as the age, because a stopped supervisor leaves a status file that is milliseconds old.

`status-fresh-p` takes the age and the flag together.

## The heartbeat schedule

A tick is due when a request waits, or when the schedule is enabled and `now - last-tick` is at least the interval.
The heartbeat thread wakes once a second, so a stop and a forced tick take effect within a second.

The interval comes from `:sleep :interval-seconds`, which defaults to 900.
A value that is not a positive integer becomes 900.
The schedule itself is controlled by `:sleep :enabled`, which defaults to true.

`last-tick` is measured from the end of a tick.
A pass that takes longer than the interval therefore runs again when it finishes, instead of piling up behind itself.
Starting the thread sets `last-tick` first, so the first tick waits one interval rather than competing with the first operator turn.
A forced tick still runs at once.

`supervisor-tick` never signals.
It records the start time, calls the tick hook, and records the end time, the tick count, and the report.
A hook that signals becomes a report line with `:ok-p` false, and the scheduler survives.
The thread that runs a tick is the whole scheduler for unattended work.

The heartbeat thread is separate from the control poll thread, because a tick is one or more model calls and a poll loop held inside one stops rewriting the status file.

`heartbeat on`, `heartbeat off`, and `heartbeat run` go through the control file.
`on` sets the schedule flag and starts the thread when a tick hook is attached.
That is how a process that began with `:sleep :enabled nil` gains a schedule.
`off` clears the flag and stops the schedule, and a forced `run` still ticks, because the request was explicit.

## The sleep agent and its phases

A tick runs four phases in a fixed order.
Each phase has its own guard, so a failed phase adds a note and sets `:ok-p` false while the later phases still run.
The notes are joined into one line by a semicolon, and a tick with no notes reports `idle`.

| Order | Phase              | What it does                                                   |
| ----- | ------------------ | -------------------------------------------------------------- |
| 1     | Task recovery      | Marks every running task failed                                |
| 2     | The harness blocks | Writes the ledger block and the session fallback               |
| 3     | The sleep agent    | Claims one task, or runs one maintenance pass, or does nothing |
| 4     | Compaction         | Rewrites the session block when new turns are due              |

Phase 2 builds the ledger line from the session total and the rolling day total, and writes one line about the queue into an empty session block.
Compaction overwrites that fallback.

Phase 3 builds a fresh sleep agent on every tick over the same directory and broker as the operator's agent, with the three seed-backed blocks writable.
It claims the oldest pending task and runs one pass for it.
With an empty queue it runs one maintenance pass when a turn newer than `last-sleep-turn` exists, and reports `idle` otherwise.
The pass uses its own session and closes it afterwards.

The task body reaches the prompt cut at 4000 characters, while the row keeps the whole body.
The pass prompt begins `The operator queued this task for you:` and ends by asking for one line about what was done.
A cut is reported as `(body cut to 4000 characters)`.

The sleep agent refuses to run for a named reason, and each reason is a sentence an operator can read.

| Refusal                                                                         | Condition                      |
| ------------------------------------------------------------------------------- | ------------------------------ |
| `no memory store is open`                                                       | No store                       |
| `no agent is attached`                                                          | No agent                       |
| `no model backend is configured`                                                | No backend                     |
| `bootstrap has not handed over, so the identity files are still the operator's` | The first steps are unfinished |

A refused phase writes `sleep skipped: <reason>` or `compaction skipped: <reason>`.
A budget the store cannot read adds `the budget is unreadable: <condition line>` in place of the refusal, and sets `:ok-p` false.
A phase that raises writes `<phase> failed: <condition line>`, where the phase name is `task recovery`, `the harness blocks`, `the sleep agent`, or `compaction`.

Phase 4 runs when four new turns exist and the newest is past `last-compacted-turn`.
It runs as a separate compactor agent with no tools and uses the cheap model.
The cursor lives on the supervisor, so a restart rereads the last few turns once.
[Memory](memory.md) documents the compaction prompt and the block write.

## The budget windows

The `:budget` section holds two caps: `:max-tokens-per-tick`, which defaults to 4000, and `:max-tokens-per-day`, which defaults to 400000.
A missing cap bounds nothing, so unattended work is limited only when the operator sets a cap.

| Window | Measured from                                                                         | Refusal when reached    |
| ------ | ------------------------------------------------------------------------------------- | ----------------------- |
| Tick   | The store total at the start of this tick, or the in-memory rows after the tick began | `the tick cap is spent` |
| Day    | The rolling 24 hours before the current time                                          | `the day cap is spent`  |

The tick window is a difference in totals, not a timestamp window.
A timestamp window would count an operator turn that happened in the same second as unattended spend.
A missing store falls back to the in-memory ledger.

The day window is the rolling 24 hours the ledger uses, so a burst across midnight still counts in full.
The usage report groups by calendar day instead.

The `budget` command prints the configured caps and, for a live agent, whether each window is spent.

## The task queue

A task is one line of work for a later tick.
The queue is a table in the memory store, so a task survives a restart that a list in memory would not.
One task runs per tick, because the shipped tick cap is 4000 tokens and a task is a full turn with tools.

| Status    | Meaning                                            |
| --------- | -------------------------------------------------- |
| `pending` | Waiting for a tick                                 |
| `running` | A tick claimed it                                  |
| `done`    | The pass finished it                               |
| `failed`  | The pass failed, or a dead process left it running |

`dequeue-task` takes the oldest pending task and marks it running.
The update requires the row to still be pending, so two claimants cannot both win.
`complete-task` and `fail-task` change a running row only.
A failed task is not requeued, so unattended work is at-most-once.
Phase 1 marks every running task failed, because nothing will finish a task that a dead process claimed.
The operator reads the queue with `enchiridion tasks list`, documented in [Commands](commands.md).

## Health and reload

A health check comes in two forms.
The `health` command reads the status file and requires a fresh file.
It prints the process identifier, the generation, the last report, the heartbeat state, and one line for each channel.
It returns 1 when no supervisor is running and 0 otherwise.
A tick that never returns still leaves a fresh status file.
`health` therefore prints the seconds since the running tick started, and that number makes a stall visible.

The `GET /health` route reads the live process instead of the file, because a file left by a stopped process reports an uptime that grows forever.
[Channels](channels.md) documents the route and its status codes.

A reload produces a new code generation through the reload hook.
The daemon supplies a hook that verifies the agent files in a one-shot child and loads them in the broker.
The hook returns a plist of `:ok-p`, `:generation`, and `:report`.
In a split run, the broker runs as a separate process under the agent user.
In a checkout started as the operator it runs as that user, and [Deployment](deployment.md) documents the split and its limits.
The supervisor records the generation only when `:ok-p` is true.
A refused generation changes nothing, so the last good code keeps serving.

The shell path asks through the control file.
`request-control` returns `nil` when no supervisor answers, and the command then writes `reload: no supervisor is running, so nothing was asked.` and exits 1.
An answered reload prints its report and the current generation.
A refused reload prints the report and exits 1, so an operator script can tell a refusal from a load.
The same refusal is in the status file as `report-ok` false.

The generation counter in the status file is the loaded code generation.
The `generation` in the agent directory's `state.json` is a separate counter that seeds the plugin loader.
[Memory](memory.md) documents the state file, and [Plugins and self-modification](plugins.md) documents the loader.

## Troubleshooting

| Symptom                                                                    | Cause                                                                               | Fix                                                                 |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `health` reports no supervisor while `serve` runs                          | The two processes resolve different homes, or the file is more than ten seconds old | Set `ENCHIRIDION_HOME` for both, and check `run/enchiridion.status` |
| `reload` returns `reload: no supervisor is running, so nothing was asked.` | No fresh status file, so `request-control` refused to append                        | Start the supervisor, and check the status file path                |
| `reload refused: ...`                                                      | The new generation failed verification or loading                                   | Read the report, fix the agent files, and reload                    |
| The heartbeat ticks, but the report says `idle`                            | No task waits, and no new turn arrived since the last pass                          | Add a task with `enchiridion tasks add`, or send a turn             |
| `sleep skipped: the tick cap is spent`                                     | This tick reached `:max-tokens-per-tick`                                            | Raise the cap, or wait for the next tick                            |
| `sleep skipped: bootstrap has not handed over ...`                         | `BOOTSTRAP.md` is present and incomplete                                            | Finish the first steps, or reset the bootstrap                      |
| `health` prints a tick running for many seconds                            | The tick hook is inside a model call that has not returned                          | Read the tick report, and check the model endpoint                  |
| A channel restarts every second                                            | Its start method returns instead of blocking                                        | Fix the channel start method                                        |
| `read-status` answers `nil`                                                | The file is missing, unreadable, or not yet written                                 | Start the supervisor, and check the permissions on `run/`           |

## See also

- [Commands](commands.md) for `health`, `reload`, `channels`, `heartbeat`, and `tasks`.
- [Channels](channels.md) for the surfaces the supervisor starts and restarts.
- [Memory](memory.md) for the blocks and the store the tick writes.
- [Configuration](configuration.md) for the `:sleep` and `:budget` sections.
- [Deployment](deployment.md) for the container that sends `SIGTERM` and the files under `run/`.
