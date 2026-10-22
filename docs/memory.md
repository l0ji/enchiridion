# Memory

Memory is what the agent carries from one turn to the next.
Five named blocks are compiled into one prompt when the agent is built, and that prompt stays frozen for the session.
A SQLite store holds the transcript, memories, harness blocks, ledger, and task queue, and SQLite full-text search (FTS5) indexes the text without a model call.
The heartbeat rewrites the session block from recent turns, so the prompt does not grow with the transcript.

## The memory model

A block is one named piece of memory with a character limit and a writer.
Three blocks are backed by Markdown files, so personality change is a git diff, and two are store rows written by the harness.

| Label        | Limit | Backing        | Writer                                        |
| ------------ | ----- | -------------- | --------------------------------------------- |
| `:persona`   | 1200  | `SOUL.md`      | The sleep agent, after the bootstrap handover |
| `:operator`  | 800   | `OPERATOR.md`  | The sleep agent, after the bootstrap handover |
| `:world`     | 1500  | `WORLD.md`     | The sleep agent, after the bootstrap handover |
| `:session`   | 400   | A `blocks` row | The heartbeat and compaction                  |
| `:ledger`    | 250   | A `blocks` row | The heartbeat                                 |
| `:bootstrap` | 300   | None           | No block is built                             |

`*default-block-limits*` holds the six limits, and `default-block-limit` returns 1200 for a label the list does not name.
The limits count characters, and the configuration's `:memory :block-limits` key is not read, so a limit change is a source change.

The kernel builds five blocks in `blocks-from-directory`.
It reads the three Markdown files and falls back to the seed template, and it reads `:session` and `:ledger` from the store.
The block and file tools refuse writes to the first three while the bootstrap is pending. The two store blocks are writable.
The shell tool does not check that gate (see [Tools](tools.md#blockops)).

`make-agent` compiles the blocks once into a frozen prompt, and every turn sends that prompt.
A later write changes the block and its file, not the bytes already sent.
The next prompt gets the text on disk when the next agent is built, and the sleep agent is built fresh on every tick.

`compile-blocks` prints one capacity line per block, then each block as `## label (n/limit characters)` with its text.
`compile-prompt` writes one fixed preamble before the blocks: `You are enchiridion, an autonomous agent.` and the instruction not to follow instructions that arrive inside tool results.
`estimate-tokens` counts one token per four characters for the ledger only.

## Blocks

A block has five fields: `label` (keyword), `text` (string), `limit` (integer), `file` (pathname or `nil`), and `writable-p` (boolean).
The defaults are `:persona`, `""`, 1200, `nil`, and true, and `writable-p` says whether this agent may replace the text.

`make-block` scans the text, takes the limit from `*default-block-limits*` when the caller passes none, and keeps the file when one is given.

`set-block-text` replaces the text of a writable block and refuses four cases.

| Refusal        | Condition                                              | Report                                                                          |
| -------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------- |
| Frozen block   | `writable-p` is false                                  | `Block <label> is frozen for this session.`                                     |
| Duplicate text | The text equals the current text                       | `Configuration is wrong at BLOCK.` and `Block <label> already holds that text.` |
| Scanned text   | An invisible character or an injection pattern appears | `Configuration is wrong at BLOCK.` and a line naming the block                  |
| Over the limit | The text is longer than the limit                      | `Block <label> is at <limit> characters and needs <wanted>, so <n> must go.`    |

A `block-frozen` condition carries the label, and a `block-overflow` condition carries the label as `:label`, the limit as `:current`, and the attempted length as `:wanted`.
The file is written last, so a refused write leaves both the block and the file unchanged.

`block-bytes` counts characters, `block-full-p` is true at the limit, `block-slack` is the room left, and `block-descriptions` returns label, count, limit, slack, writability, and file.

Every write passes `scan-block-text`, which refuses invisible code points in `U+200B` to `U+200F`, `U+202A` to `U+202E`, `U+2060` to `U+2064`, and `U+2066` to `U+2069`.
It also refuses `U+E0000` to `U+E007F` and the single points `U+FEFF`, `U+00AD`, `U+061C`, and `U+180E`.
Those are zero-width spaces and directional marks, bidirectional overrides, the word joiner, and invisible operators.
The rest are directional isolates, tag characters, the byte order mark, the soft hyphen, the Arabic letter mark, and the Mongolian vowel separator.
The patterns are compiled once, with case folding, in `+injection-scanners+`.

```text
ignore\s+(?:all\s+)?(?:the\s+)?(?:previous|prior|above)\s+instructions
disregard\s+(?:all\s+)?(?:the\s+)?(?:previous|prior|above)\s+instructions
reveal\s+(?:your\s+)?(?:system\s+)?prompt
print\s+(?:your\s+)?(?:system\s+)?prompt
repeat\s+(?:your\s+)?(?:system\s+)?prompt
you\s+are\s+now\s+(?:a|an|the)\b
exfiltrate
send\s+(?:the\s+)?(?:secret|token|key|password)\s+to
```

A hit signals a `configuration-error` with `:key :block` and a detail that reads `Block <label> contains invisible Unicode.` or `Block <label> contains a prompt injection or exfiltration pattern.`

## Seed files

`init-agent` creates an agent directory and writes every seed file that is absent.
It creates the `skills/` and `tools/` directories first, then writes the templates in this order.

| File                        | Kind     | Contents                 |
| --------------------------- | -------- | ------------------------ |
| `GUIDE.md`                  | markdown | The operator walkthrough |
| `SOUL.md`                   | markdown | Identity                 |
| `OPERATOR.md`               | markdown | Who the agent works for  |
| `WORLD.md`                  | markdown | The environment          |
| `BOOTSTRAP.md`              | markdown | The first steps          |
| `skills/example-welcome.cl` | lisp     | An example skill         |
| `tools/example-echo.cl`     | lisp     | An example tool          |
| `state.json`                | json     | The runtime state        |

`write-if-absent` never overwrites and answers `:created`, `:kept`, or `:failed` with the condition when a write fails.
A rerun against a populated directory completes a half finished setup and reports what was already there.
`seed-template`, `seed-description`, and `seed-kind` read one row each.
`seed-file-names` returns the eight relative names, and `agent-seeded-p` answers whether a directory holds at least one seed file.

After the files are on disk and no write failed, `ensure-agent-repository` makes the directory a nested git repository and commits it.
A host without git keeps the files and skips the commit.

`init-agent` returns an `init-result` with the directory, the files created, the files kept, and the problems.
It also holds a flag that says whether the directory already held a seed file, and `init-status-line` renders one line.

```text
No agent directory found. Creating /home/operator/agents/default/.
Agent directory /home/operator/agents/default/ already has 5 of 8 seed files.
```

Run init by hand to repair a partial directory.

```sh
enchiridion init
```

The command prints the status line, a `created` line per file written, a `kept` line per file kept, and a `problem` line per failure.
It exits 1 on any problem and 0 otherwise.
The no-command first launch runs the same code and stops, so the operator can edit the three identity files.
[Getting started](getting-started.md) covers that run.

## The agent repository

The agent directory is its own git repository, nested inside the checkout.
`init-agent` creates it and records the first commit when Git is available.

The kernel attempts a commit after each successful turn, with the message `Turn N via CHANNEL`.
A turn that fails or is stopped before it ends attempts no commit. A turn that changed nothing also leaves no commit.
A host without Git, or without a Git identity, keeps the files. It skips the commit without failing the turn.

The repository ignores `state.json`, `memory.db`, `private/`, `tmp/`, and `*.fasl`.
Runtime state is not history. The Markdown files, the skills, and the tools are the history.

`journey` reads the commits and `undo` reverts one.
The bootstrap handover and the `meta` author action commit their own changes.
[Commands](commands.md) documents `journey` and `undo`, and [Tools](tools.md) owns the `meta` tool.
Search the history with `git -C agents/default log`.

## The bootstrap

`BOOTSTRAP.md` is a numbered list.
`bootstrap-steps` returns each `(number . text)` in file order, and continuation lines are prose.

The steps live in `state.json` under a bootstrap record.
The record holds `step` (integer, initial 0), `done` (sorted array of step numbers, initial `[]`), and `complete` (boolean, initial false).

While `BOOTSTRAP.md` exists and steps remain, `bootstrap-refuse-writes-p` is true, so the sleep agent skips its pass.
The block and file tools signal `bootstrap-pending` for a seed-backed label without changing the file.
The report reads `Block <label> is the operator's until bootstrap hands over.`

`mark-bootstrap-step` keeps `done` sorted and duplicate free, sets `step` to the number done, writes the state, and runs the handover when the last step lands.
The meta tool action `bootstrap-step` and `enchiridion bootstrap step N` call it.
The block and file tools are the enforced gate. `shell` does not check the bootstrap state, so a caller can edit `state.json` or rename the file.
[Getting started](getting-started.md#hand-over-the-bootstrap) gives the operator procedure.

The handover renames `BOOTSTRAP.md` to `BOOTSTRAP.done.md`, sets `complete` true, writes the state, and commits the directory.
A missing `BOOTSTRAP.md` still marks the state complete.
The report is one line: the archive sentence and the commit report, which reads `The agent repository was not committed.` when the commit fails.

```text
Bootstrap complete; BOOTSTRAP.md is now BOOTSTRAP.done.md. Commit 3f2a91c recorded the change.
Bootstrap complete; there was no BOOTSTRAP.md to archive. Nothing changed, so there was nothing to commit.
```

`reset-bootstrap` restores `BOOTSTRAP.done.md` as `BOOTSTRAP.md` only when `BOOTSTRAP.md` is absent, clears the record, and writes the state.
A live `BOOTSTRAP.md` is never overwritten.

`bootstrap-status` returns `(:step N :done (N...) :total M :complete BOOL :remaining ((N . TEXT)...))`, and `bootstrap-status-line` renders one of:

```text
Bootstrap step 3 of 8: Wait for the answers. Do not guess at a fact that was not given.
Bootstrap complete: 8 of 8 steps done.
Bootstrap complete.
```

`bootstrap-step-summary` cuts a step to 60 characters for that line and replaces a newline with a space.
The `bootstrap` command shows the line, the remaining steps, or resets the record, and [Commands](commands.md) documents its arguments.

## state.json

The agent directory holds one JSON file with `schema` (integer, initial 1), `generation` (integer, initial 0), and `bootstrap` (the record above).

`read-state` never signals.
A missing, empty, or malformed file becomes `default-state`, and `normalize-state` and `normalize-bootstrap` fill absent or mistyped fields, so a hand-edited file costs a fresh start.

`write-state` writes `state.json.new` and renames it, so a crash leaves the old state or the new one.
`ensure-state` accepts a state object or a directory.
`state-generation` and `set-state-generation` read and write the counter.
The setter takes a state object in memory or a directory it reads, changes, and writes back.

The generation seeds the plugin generation at startup.
No shipped code calls the setter, so the value stays at what the seed wrote unless a caller writes it.
The supervisor's status file carries a separate generation, and [Plugins and self-modification](plugins.md) documents the loader.

## Loading tiers

One body has three forms: L0 answers whether the text matters, L1 answers what shape the body has, and L2 is the whole body.
A caller starts at L0 and pulls a higher tier only after an index read has missed twice.

| Form | Limit            | Derivation                                                   |
| ---- | ---------------- | ------------------------------------------------------------ |
| L0   | 400 characters   | The first paragraph, cut at a word boundary inside the limit |
| L1   | 8000 characters  | The body cut at the last line break inside the limit         |
| L2   | No derived limit | The whole body                                               |

The limits are `+l0-chars+`, `+l1-chars+`, and the miss rule is `+misses-before-promotion+`, which is 2.
A `tiered` value holds the name, the three forms, the tier in use, and the miss count.
`tier-name` and `tier-misses` read the name and the count.
A body with no line break inside the L1 limit is cut at the limit, so the result always fits the budget.

`build-tiers` derives L1 and L0 from L2 when the caller passes neither, and a written abstract is passed as L0.

```lisp
(enchiridion.memory:tier-for
 (enchiridion.memory:build-tiers "world" "# World
The machine runs Debian."))
```

`tier-for` returns one named form and defaults to the tier in use, and `note-tier-miss` counts one index read that came back empty.
`promote-tier` moves up after `+misses-before-promotion+` (2) misses and clears the count.
At L2 it clears and returns `:l2`, and `reset-tier-misses` clears without moving.

The derivation is mechanical, and no shipped code calls it: `build-tiers` runs from the test suite only, so no live prompt reads a tier.

## The store

The store is one SQLite file.
`default-store-path` puts `memory.db` under `agents/default/` in `ENCHIRIDION_HOME`, or under the current directory, and the `:db` key or `*store-path*` overrides that path.

`open-store` creates the file and schema when missing and uses a 5000 ms busy timeout.
A file that cannot be opened signals `configuration-error` with `Cannot open the memory store <path>: <reason>`, and a failed schema signals one with `Cannot create the memory store schema in <path>: <reason>`.
Both report `Configuration is wrong at MEMORY.`
When root creates the file in the container, it widens the mode to `#o666`. The broker runs as the agent user there.
Every string is scrubbed before it reaches a column, so the store holds no secret.

`store-file-p` reads the sixteen-byte SQLite header, and a search opens a store only when that check passes.
An empty or non-database file is therefore a leftover, and not a store.

One connection serves several threads: `with-store-lock` runs a body under a recursive lock, and `exec` and `query-rows` take it themselves.

The schema is seventeen statements, each `IF NOT EXISTS`, so opening a store needs no migration.

| Table          | Columns                                                                                   |
| -------------- | ----------------------------------------------------------------------------------------- |
| `turns`        | `id`, `session`, `role`, `body`, `model`, `channel`, `ts`                                 |
| `memories`     | `id`, `name`, `body`, `session`, `ts`                                                     |
| `blocks`       | `name`, `body`, `ts`                                                                      |
| `usage`        | `id`, `session`, `model`, `input`, `output`, `cache_read`, `cache_write`, `channel`, `ts` |
| `tasks`        | `id`, `body`, `status`, `ts`                                                              |
| `turns_fts`    | An FTS5 external content table over `turns.body`                                          |
| `memories_fts` | An FTS5 external content table over `memories.name` and `memories.body`                   |

The four indexes are `turns_session`, `memories_name`, `usage_ts`, and `tasks_status`.
The search tables are external content tables over the row tables.
Three triggers per table keep them in step through an insert, an update, and a delete.
`+store-tables+` lists the seven tables in drop order, and `drop-store` drops them and leaves the connection open.
`set-session-block` and `set-ledger-block` run the injection scan and limit check, and `session-block` and `ledger-block` read the rows.
The heartbeat writes those rows, so no agent sees them first.
The task queue functions are `enqueue-task`, `list-tasks`, `dequeue-task`, `complete-task`, `fail-task`, `recover-tasks`, `count-tasks`, and `remove-task`.
Their statuses and claim rule belong to [Supervisor and heartbeat](supervisor.md).

## Sessions and search

A session is a string on every turn row, so the store needs no session table.
`fresh-session-id` returns 32 hexadecimal characters, and a session spans the smallest and largest timestamps of its turns.

A turn row records session, role, body, model, channel, and universal time.
The roles are `user`, `assistant`, and `tool`, and `record-turn` defaults the session to `default` and the role to `user`.
Every round of a tool turn is stored, including tool results, and an empty assistant body is skipped.

`record-turn` returns the stored `turn-row`, and `recent-sessions` returns sessions newest first with `:id`, `:started`, `:ended`, and `:turns`.
`session-count` counts distinct sessions, and `delete-session` removes a session's turns and returns the count.
`search-sessions` returns matching turns best first, and `recent-turns` returns the newest turns, optionally excluding one channel.

`save-memory` stores one named body and returns the new row identifier.
It refuses an empty body after the scrub with `A memory needs text.` and an exact duplicate with `Memory <name> already holds that text.`
`list-memories` returns memories newest first, and `search-memories` matches a name or a body.
The `memory` tool calls `save-memory` for the model. The `search` tool reads memories and does not write them.

A search turns each whitespace-separated term into an FTS5 quoted prefix query, so an operator character such as `+` is a literal.
A term with no alphanumeric character is dropped.
A query left with no terms signals `schema-error` with `The query has no searchable terms.`, and a control character signals one with `The query has a control character.`
`search-sessions` and `search-memories` use `MATCH` with `ORDER BY rank`, and no model call runs, so recall costs no tokens and cannot invent a memory.
The search functions and `recent-sessions` return 20 rows by default, and `recent-turns` returns 4.

The search tool in [Tools](tools.md) reads the same store and opens it only when `store-file-p` passes.

Search the transcript and the saved memories from the shell.

```sh
enchiridion memory "open ports"
enchiridion sessions
```

`memory` prints the memories section and the turns section with their counts, and `sessions` prints one line per stored session with its turn count.
[Commands](commands.md) documents both commands.

## The ledger

Every model call adds one `usage` row with the four numbers the provider reported, the session, the channel, and a universal time.
Nothing in the row is derived, and every column is scrubbed.

`record-usage` returns the new row identifier, and `usage-rows` returns rows oldest first, up to 1000 by default.
`usage-since` returns rows at or after a time, and `usage-summary` returns the ledger summed by `:model`, `:channel`, or `:day`.
`usage-total-since` and `usage-session-total` sum every column from a time and for one session.

`usage-summary` groups by model, by channel, or by day.
A day is the local calendar day of the row's time.
Model and channel groups are ordered by total tokens, and day groups are ordered newest first.
A sum beyond a 64-bit integer is coerced to an integer for printing, and `:total` is input plus output.
A summary returns at most 100 groups.

Print the report from the shell.

```sh
enchiridion usage
```

The command prints three sections by model, by channel, and by day, each with input, output, cache read, cache write, and calls.
[Commands](commands.md) documents the columns.

The heartbeat writes the ledger block, one line in every prompt: `session in 1200 out 340 cache r 0 w 0 calls 4 · day 15400`.
The line is built to fit the block limit by construction.
The same totals bound the sleep agent through the budget windows in [Supervisor and heartbeat](supervisor.md).

## Compaction

The session block is the agent's summary.
Compaction sends the previous block and the last four turns to the cheap model and stores the answer.

Compaction runs when `+compaction-turns+` (4) new turns exist, sends `+recent-turn-limit+` (400 characters) of each turn, and enforces a 400-character session block.
`+compaction-brief+` is the compactor's only persona and asks for plain prose of at most 400 characters.

`compact-session` builds a message from the previous block or `(none)` and the last four turns, each cut to 400 characters.
It runs the cheap model through a compactor agent with no tools and only the brief as its persona.
The answer is scrubbed, and a non-empty answer is written with `set-session-block`, which scans it and enforces the 400-character limit.
An oversized or refused answer changes nothing.

`compact-when-due` runs when exactly four recent turns exist and the newest is past `last-compacted-turn`.
The cursor lives on the supervisor, and the pass excludes the `:sleep` channel, so the summariser does not read its own output.

`write-session-fallback` writes `Tick 12. 3 tasks waiting, 1 failed.` into an empty session block, and compaction overwrites it.

## Troubleshooting

| Symptom                                                              | Cause                                                        | Fix                                                                     |
| -------------------------------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------- |
| `Block <label> is at 1200 characters and needs 1280, so 80 must go.` | The new text exceeds the limit                               | Shorten the text before the write                                       |
| `Block <label> is frozen for this session.`                          | The block object is not writable for this agent              | Write through the sleep agent, or through the block tool after handover |
| `Block <label> is the operator's until bootstrap hands over.`        | The first steps are unfinished                               | Finish the bootstrap, or reset and complete it                          |
| `Block <label> already holds that text.`                             | The write changes nothing                                    | Skip the write                                                          |
| `A memory needs text.`                                               | The body was empty after the scrubber                        | Write a body with content                                               |
| `Memory notes already holds that text.`                              | The name and body pair already exists                        | Use another name, or update the existing memory                         |
| Search signals `The query has no searchable terms.`                  | The query held only punctuation                              | Search for words                                                        |
| Search signals `The query has a control character.`                  | The query held a control character                           | Remove it                                                               |
| `enchiridion memory` prints a section with no rows                   | The store has no matching rows, or the text was never stored | Search for another term, and check that the store path is right         |
| The prompt does not show a block that was newly written              | The prompt was compiled at agent start and does not change   | Start a new process                                                     |
| The transcript is missing entirely                                   | The store did not open, and the process said so              | Read the error line, and check the path and permissions for `memory.db` |
| The session block is one line about the queue                        | Compaction has not run since the block was empty             | Send four more turns, or wait for the next tick                         |

## See also

- [Supervisor and heartbeat](supervisor.md) for the tick that writes the blocks and runs compaction.
- [Large language model backends](llm.md) for the scrubber that cleans every string before it reaches a column.
- [Tools](tools.md) for the search tool and the memory tool that read the store.
- [Commands](commands.md) for `blocks`, `memory`, `sessions`, `usage`, and `bootstrap`.
- [Plugins and self-modification](plugins.md) for the loader generation that the process starts from.
