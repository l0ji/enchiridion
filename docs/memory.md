# Memory

Memory holds what the agent knows across turns. The kernel reads five blocks when
it builds an agent, compiles them into one prompt, and freezes that prompt for the
session. The store keeps the transcript, the memories, the two harness blocks, the
token ledger, and the task queue in one SQLite file. The heartbeat rewrites the
session block from recent turns, so the prompt does not grow with the transcript.

## Blocks

A block is one named piece of memory. `make-block` builds one, scans its text, and
takes the limit from `*default-block-limits*`. The kernel builds five blocks for an
agent directory.

| Label       | File           | Limit | Writer                      |
| ----------- | -------------- | ----- | --------------------------- |
| `:persona`  | `SOUL.md`      | 1200  | sleep agent, after handover |
| `:operator` | `OPERATOR.md`  | 800   | sleep agent, after handover |
| `:world`    | `WORLD.md`     | 1500  | sleep agent, after handover |
| `:session`  | a `blocks` row | 400   | heartbeat                   |
| `:ledger`   | a `blocks` row | 250   | heartbeat                   |

`*default-block-limits*` is a plist of six labels. It also holds `:bootstrap` with
300 characters. `default-block-limit` returns the plist value for a label, or 1200
for a label the plist does not name.

The limits count characters, not bytes. `block-bytes` returns the character count
of a block. `block-full-p` answers true when the count reaches the limit, and
`block-slack` returns the room that is left.

`set-block-text` replaces the text of a writable block. It refuses four things:

- a frozen block, with `block-frozen` and the block label
- text that repeats the current text, with `configuration-error`
- text with an invisible character or an injection pattern, with `configuration-error`
- text longer than the limit, with `block-overflow`, the limit as `:current`, and the
  attempted length as `:wanted`

The file write comes last, and only when the block has a file. `block-summary`
prints one capacity line per block. `compile-blocks` prints that summary and then
each block as `## label (n/limit characters)`.

The kernel builds the five blocks in `blocks-from-directory`. It reads
`:persona`, `:operator`, and `:world` from their Markdown files, and it falls back
to the seed template when a file is absent. Those three blocks are not writable
for the operator's agent. The `:session` and `:ledger` blocks come from the store,
and the heartbeat writes them.

## The write scan

A write reaches a block only after `scan-block-text` passes. The scan refuses
invisible Unicode: zero width spaces, bidi overrides, the word joiner, the byte
order mark, the soft hyphen, and the tag character range. `invisible-character-p`
is the test.

The scan also refuses eight patterns in `+injection-patterns+`. They name attempts
to ignore instructions, to disregard instructions, to reveal the system prompt,
to print it, and to repeat it. They also name the opening `you are now`, the word
`exfiltrate`, and a request to send a secret. `+injection-scanners+` holds the
compiled form, built once with `create-scanner` in case-insensitive mode.

A hit signals `configuration-error` with `:key :block` and a line that names the
block. The list stays short on purpose, so an operator can read every pattern and
disagree with it. A false positive costs one refused write.

## Seed files

`init-agent` creates an agent directory and writes every seed file that is absent.
It creates `skills/` and `tools/` first. `write-if-absent` returns `:created`,
`:kept`, or `:failed`, and it never overwrites a file. A rerun of init therefore
completes a half finished setup and reports what was already there.

`*seed-templates*` holds eight files, in this order.

| File                        | Kind     | Description          |
| --------------------------- | -------- | -------------------- |
| `GUIDE.md`                  | markdown | operator walkthrough |
| `SOUL.md`                   | markdown | identity             |
| `OPERATOR.md`               | markdown | who it works for     |
| `WORLD.md`                  | markdown | the environment      |
| `BOOTSTRAP.md`              | markdown | first steps          |
| `skills/example-welcome.cl` | lisp     | example skill        |
| `tools/example-echo.cl`     | lisp     | example tool         |
| `state.json`                | json     | runtime state        |

The templates live as Lisp string constants in `seed.cl`, so init needs no file
lookup. `seed-template`, `seed-description`, and `seed-kind` read one row each.
`seed-file-names` returns the eight relative names. `agent-seeded-p` answers
whether a directory holds at least one seed file.

`init-agent` returns an `init-result` with `directory`, `created`, `existing`,
`problems`, and `existed-p`. A write that fails lands in `problems` with its
condition rather than stopping the run. `init-status-line` prints one line for the
first launch. After the files arrive, `ensure-agent-repository` makes the directory
a nested git repository and commits it.

## The store

The store is one SQLite file. `default-store-path` puts it at `memory.db` under
`agents/default/` in `ENCHIRIDION_HOME`, or under the current directory when that
variable is unset. `*store-path*` overrides both. The `:db` key in the `:memory`
section of config.cl names the file.

`open-store` creates the file and the schema when they are absent, then returns a
`store` with a path, a DBI connection, and a recursive lock. `with-store-lock` runs
a body under that lock, because a channel thread, the control poll, and the
heartbeat share one connection. `store-file-p` reads the sixteen byte SQLite header
and refuses to adopt a file that is not a database. `drop-store` drops every table.

`+schema+` holds seventeen statements. Five create a table, two create an FTS
table, four create an index, and six create a trigger.

| Table          | Columns                                                                                   |
| -------------- | ----------------------------------------------------------------------------------------- |
| `turns`        | `id`, `session`, `role`, `body`, `model`, `channel`, `ts`                                 |
| `memories`     | `id`, `name`, `body`, `session`, `ts`                                                     |
| `blocks`       | `name`, `body`, `ts`                                                                      |
| `usage`        | `id`, `session`, `model`, `input`, `output`, `cache_read`, `cache_write`, `channel`, `ts` |
| `tasks`        | `id`, `body`, `status`, `ts`                                                              |
| `turns_fts`    | FTS5 over `turns.body`                                                                    |
| `memories_fts` | FTS5 over `memories.name` and `memories.body`                                             |

The schema also creates four indexes: `turns_session`, `memories_name`,
`usage_ts`, and `tasks_status`. The two FTS tables are external content tables
over the row tables, so each body exists once. Three triggers per FTS table keep
the index in step on insert, update, and delete. `+store-tables+` lists the seven
tables, index table before row table, and it is also the trigger list.

Every string that reaches a column goes through `scrubbed`, which calls
`enchiridion.llm.secrets:scrub`. The agent can read the transcript through the
search tool, so this is the last gate before the disk.

## Store queries

The turn and search functions:

| Function          | Returns                                                           |
| ----------------- | ----------------------------------------------------------------- |
| `record-turn`     | one `turns` row as a `turn-row`                                   |
| `recent-sessions` | sessions newest first, with `:id`, `:started`, `:ended`, `:turns` |
| `session-count`   | the number of distinct sessions                                   |
| `delete-session`  | the turns removed                                                 |
| `search-sessions` | matches best first, as `turn-row` values                          |
| `recent-turns`    | the newest turns, optionally not from one channel                 |

The memory, block, and ledger functions:

| Function                              | Returns                                                             |
| ------------------------------------- | ------------------------------------------------------------------- |
| `save-memory`                         | the new row id, or a `configuration-error`                          |
| `list-memories`                       | memories newest first                                               |
| `search-memories`                     | matches best first, with `:id`, `:name`, `:body`, `:session`, `:ts` |
| `session-block` / `set-session-block` | the `session` row                                                   |
| `ledger-block` / `set-ledger-block`   | the `ledger` row                                                    |
| `record-usage`                        | the new ledger row id                                               |
| `usage-rows` / `usage-since`          | ledger rows oldest first                                            |
| `usage-summary`                       | the ledger summed by `:model`, `:channel`, or `:day`                |
| `usage-total-since`                   | the ledger summed from a time                                       |
| `usage-session-total`                 | the ledger summed for one session                                   |

`set-session-block` and `set-ledger-block` call `store-checked-block`, which runs
the injection scan and the block limit before the write. The heartbeat writes
those two rows, so nothing else would scan them.

The task queue functions:

| Function        | Returns                                      |
| --------------- | -------------------------------------------- |
| `enqueue-task`  | a pending `task-row`                         |
| `list-tasks`    | tasks oldest first, or only one status       |
| `dequeue-task`  | the oldest pending task, marked `running`    |
| `complete-task` | true when a `running` task became `done`     |
| `fail-task`     | true when a `running` task became `failed`   |
| `recover-tasks` | the count of `running` tasks marked `failed` |
| `count-tasks`   | the number of tasks, or of one status        |
| `remove-task`   | true when a row was deleted                  |

`dequeue-task` marks a task `running` rather than `done`, and the update carries
`AND status = 'pending'`, so two claimants cannot both win. `recover-tasks` marks
every `running` task `failed` at the start of a tick, because a task a dead
process left behind is not in progress. Nothing requeues a failed task.

`fts-query` turns each whitespace separated term into an FTS5 quoted prefix query,
so an operator character such as `+` is a literal. The function drops a term with
no alphanumeric character. A query with no terms at all signals `schema-error`, and
so does a control character. `search-sessions` and `search-memories` use FTS5
`MATCH` with `ORDER BY rank`. No model call runs in the search path, so recall
costs no tokens and cannot invent a memory.

## Loading tiers

Each body of text has three forms. L0 is a one sentence abstract of at most 400
characters (`+l0-chars+`) and answers whether the text matters. L1 is an overview
of at most 8000 characters (`+l1-chars+`) and answers what shape the body has. L2
is the whole body.

`build-tiers` derives L1 and L0 from L2 when the caller does not pass them. L1 is
L2 cut at the last line break inside 8000 characters. L0 is the first paragraph of
L2, cut at a word boundary inside 400 characters. A caller with a written abstract
passes it as L0.

`tier-for` returns the text of one named tier, and defaults to the tier in use.
`note-tier-miss` counts one index read that came back empty. `promote-tier` moves
one tier up, and it moves only after `+misses-before-promotion+` misses, which is 2. A move clears the count. At L2 a further call clears the count and returns
`:l2` rather than signalling. `reset-tier-misses` clears the count without a move.

The derivation is mechanical: the same body always yields the same three strings.
A tier that changed bytes mid-session would invalidate the prompt prefix cache.

Limit: the tier machinery has no production caller. `build-tiers` runs from the
test system only, so no live prompt reads a tier today.

## The bootstrap state machine

`state.json` holds three keys: `schema` (1), `generation` (0), and `bootstrap`.
The bootstrap record holds `step`, `done`, and `complete`. `read-state` never
signals: a missing, empty, or malformed file becomes `default-state`.
`normalize-state` and `normalize-bootstrap` fill an absent or mistyped field with
its default. A hand edited file therefore costs a fresh start, not a type error
three functions later. `write-state` writes `state.json.new` first and renames it
last, so a crash leaves the old state or the new one, never half of either.

`bootstrap-steps` reads `BOOTSTRAP.md` and returns each numbered line as
`(number . text)`. `bootstrap-remaining` returns the steps that `done` does not
name. `bootstrap-complete-p` answers true when no step remains. An absent
`BOOTSTRAP.md` has no steps, so it counts as complete. `bootstrap-status` returns
`(:step N :done (...) :total M :complete BOOL :remaining (...))`.

`mark-bootstrap-step` adds a step number, keeps the list sorted and duplicate
free, and runs the handover when the last step lands. `bootstrap-handover` renames
`BOOTSTRAP.md` to `BOOTSTRAP.done.md`, marks the record complete, writes the
state, and commits the directory. `reset-bootstrap` restores `BOOTSTRAP.md` from
the archive and clears the record.

`bootstrap-refuse-writes-p` answers true while `BOOTSTRAP.md` exists and steps
remain. The sleep agent reads that answer and skips its pass, so the three seed
files stay the operator's during the first steps.
`bootstrap-step-summary` cuts one step to sixty characters, and
`bootstrap-status-line` prints the state as one line.

## Digests and compaction

`heartbeat` runs one tick in a fixed order. It fails every task that a dead
process left running. It writes the ledger block and the session fallback. It runs
the sleep agent. It then compacts the session block. Each phase has its own guard,
so one failed phase does not stop the rest.

`compact-session` builds a prompt from two parts. The first part is the previous
session block, which is the summary so far. The second part is the last four turns
verbatim (`+compaction-turns+`), each cut to 400 characters
(`+recent-turn-limit+`). It runs the cheap model (`:cheap`) through a compactor
agent. That agent holds no tools and only the `+compaction-brief+` persona,
because a summariser needs no personality and no tools. The brief asks for plain
prose of at most four hundred characters. The pass scrubs the answer, then
`set-session-block` scans it and checks it against the 400 character limit before
it lands.

`compact-when-due` runs compaction when four new turns exist and the newest turn
is past `supervisor-last-compacted-turn`. The cursor lives on the supervisor, so a
restart rereads the last turns once. `write-session-fallback` puts one line about
the task queue in an empty session block, and compaction overwrites it.

`ledger-line` builds the ledger block as one line by construction, rather than by
truncation. The shape is:

```text
session in N out N cache r N w N calls N · day N
```

## Session search and the frozen prompt

The `search` tool answers from the store with scope `memory`, which is the default,
or walks the agent files with scope `files`. A `path` argument selects the file
walk. The store opens only when `store-file-p` is true, so a search never creates a
database. One hit is one line, and `+search-hit-chars+` cuts a hit to 400
characters.

`make-agent` compiles the five blocks into one prompt once. `compile-prompt` puts
`+prompt-preamble+` first and then the compiled blocks. The kernel sends that
snapshot as the system message on every turn of the session. A later block write
lands in the block object and in its file, but it does not change the bytes of a
compiled prompt. That rule keeps the provider prefix cache valid, and a cached
turn costs less than a cold one.

`estimate-tokens` returns one token per four characters of prompt text, for the
ledger only.

## Related

- [Models and secrets](llm.md)
- [Configuration](configuration.md)
- [Supervisor and heartbeat](supervisor.md)
- [Tools](tools.md)
- [Testing](testing.md)
