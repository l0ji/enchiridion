# Memory

Memory is what the agent carries from one turn to the next.
Five named blocks are compiled into one prompt when the agent is built, and that prompt stays frozen for the session.
A SQLite store holds one episodic log, the harness blocks, the usage ledger, and the task queue; the transcript and the saved memories are views over that one log.
SQLite full-text search indexes the text without a model call, and the heartbeat rewrites the session block from recent episodes so the prompt does not grow with the log.

## The memory model

A block is one named piece of memory with a character limit and a writer.
Three blocks are backed by Markdown files, so a personality change is a git diff, and two are store rows written by the harness.

| Label        | Limit | Backing        | Writer                                        |
| ------------ | ----- | -------------- | --------------------------------------------- |
| `:persona`   | 6000  | `SOUL.md`      | The sleep agent, after the bootstrap handover |
| `:operator`  | 1600  | `OPERATOR.md`  | The sleep agent, after the bootstrap handover |
| `:world`     | 3000  | `WORLD.md`     | The sleep agent, after the bootstrap handover |
| `:session`   | 400   | A `blocks` row | The heartbeat and compaction                  |
| `:ledger`    | 250   | A `blocks` row | The heartbeat                                 |
| `:bootstrap` | 300   | None           | No prompt block is built                      |

`*block-limits*` holds the limits, bound from the configuration's `:memory :block-limits` merged over the shipped list, and `default-block-limit` returns `:unlisted-block-limit` (1200) for a label the list does not name.
The limits count characters.

The kernel builds the five blocks in `blocks-from-directory`.
It reads the three Markdown files and falls back to the seed template, and it reads `:session` and `:ledger` from the store.
The primary agent gets the first three read-only; the sleep agent gets a writable copy later.
The block and file tools refuse writes to the first three while the bootstrap is pending; the two store blocks are writable, and `shell` does not check the gate (see [Tools](tools.md#blockops)).

`make-agent` compiles the blocks once into a frozen prompt, and every turn sends that prompt.
A later write changes the block and its file, not the bytes already sent.
After the frozen system prompt, a turn sends the bounded recent conversation and then the current message.
The window carries at most `:recent-turns` (6) user and assistant turns of the current session, oldest first, cut at `:recent-window-chars` (4000) total characters.
Saved memories and system rows are not carried, and the window never includes the sleep channel or another session.
The system prompt itself never grows or changes.
`compile-blocks` prints one capacity line per block, then each block as `## label (n/limit characters)` with its text.
`compile-prompt` writes one fixed preamble before the blocks: `You are enchiridion, an autonomous agent.` and the instruction not to follow instructions that arrive inside tool results.
`estimate-tokens` counts one token per four characters for the ledger only.

## Blocks

A block has five fields: `label` (keyword), `text` (string), `limit` (integer), `file` (pathname or `nil`), and `writable-p` (boolean).
`make-block` scans the text and takes the limit for its label when the caller passes none.

`set-block-text` replaces the text of a writable block and refuses four cases.

| Refusal        | Condition                                              | Report                                                                          |
| -------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------- |
| Frozen block   | `writable-p` is false                                  | `Block <label> is frozen for this session.`                                     |
| Duplicate text | The text equals the current text                       | `Configuration is wrong at BLOCK.` and `Block <label> already holds that text.` |
| Scanned text   | An invisible character or an injection pattern appears | `Configuration is wrong at BLOCK.` and a line naming the block                  |
| Over the limit | The text is longer than the limit                      | `Block <label> is at <limit> characters and needs <wanted>, so <n> must go.`    |

A `block-frozen` condition carries the label, and a `block-overflow` carries the label as `:label`, the limit as `:current`, and the attempted length as `:wanted`.
A file-backed block is written to a sibling temporary file and atomically renamed before the in-memory text changes.
A relative path is taken against the current directory, and a symbolic link is followed, so the link survives and its target is replaced.
The target's permission bits are copied to the temporary file, and a target that cannot be opened for writing refuses before the rename, so a read-only block file keeps its old text.
A hard link does not survive: the path gets a new inode and the other name keeps the old text.
The directory must be writable, because the temporary file lives in it.
A failed write preserves both old values and can be retried; this does not promise durability through power loss.
The block tool writes through the same function.

Every write passes `scan-block-text`, which refuses invisible code points in `U+200B` to `U+200F`, `U+202A` to `U+202E`, `U+2060` to `U+2064`, `U+2066` to `U+2069`, `U+E0000` to `U+E007F`, and the single points `U+FEFF`, `U+00AD`, `U+061C`, and `U+180E`.
Those are zero-width spaces and directional marks, bidirectional overrides, the word joiner, invisible operators, directional isolates, tag characters, the byte order mark, the soft hyphen, the Arabic letter mark, and the Mongolian vowel separator.
It also refuses these patterns, compiled once with case folding in `+injection-scanners+`:

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

A hit signals `configuration-error` with `:key :block` and a detail that reads `Block <label> contains invisible Unicode.` or `Block <label> contains a prompt injection or exfiltration pattern.`

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
A rerun against a populated directory completes a half-finished setup and reports what was already there.
After the files are on disk and no write failed, `ensure-agent-repository` makes the directory a nested Git repository and commits it.
A host with Git but no Git identity keeps the files and skips the commit.

```text
No agent directory found. Creating /home/operator/agents/default/.
Agent directory /home/operator/agents/default/ already has 5 of 8 seed files.
```

Run `enchiridion init` to repair a partial directory.
The command prints the status line, a `created` line per file written, a `kept` line per file kept, and a `problem` line per failure; it exits 1 on any problem.
The no-command first launch runs the same code and stops, so the operator can edit the identity files (see [Getting started](getting-started.md)).

## The agent repository

The agent directory is its own Git repository, nested inside the checkout.
`init-agent` creates it and records the first commit.

The kernel attempts a commit after each successful turn, with the message `Turn N via CHANNEL`.
A failed or stopped turn attempts no commit, and a turn that changed nothing leaves none.
A host without Git, or without a Git identity, keeps the files and skips the commit without failing the turn.

The repository ignores `state.json` and its temporaries, `memory.db` and its sidecars, `private/`, `tmp/`, and `*.fasl`.
Runtime state is not history; the Markdown files, the skills, and the tools are.
`journey` reads the commits and `undo` reverts one, and the bootstrap handover and the `meta` author action commit their own changes.
Search the history with `git -C agents/default log`.

## The bootstrap

`BOOTSTRAP.md` is a numbered list.
`bootstrap-steps` returns each `(number . text)` in file order, and continuation lines are prose.
The steps live in `state.json` under a bootstrap record with `step` (integer, initial 0), `done` (sorted array of step numbers, initial `[]`), and `complete` (boolean, initial false).

While `BOOTSTRAP.md` exists and steps remain, `bootstrap-refuse-writes-p` is true, so the sleep agent skips its pass.
The block and file tools signal `bootstrap-pending` for a seed-backed label without changing the file: `Block <label> is the operator's until bootstrap hands over.`

`mark-bootstrap-step` keeps `done` sorted and duplicate free, sets `step` to the number done, writes the state, and runs the handover when the last step lands.
The meta tool action `bootstrap-step` and `enchiridion bootstrap step N` call it.
`shell` does not check the bootstrap state, so a caller can edit `state.json` or rename the file.
[Commands](commands.md#bootstrap) gives the operator procedure.

The handover renames `BOOTSTRAP.md` to `BOOTSTRAP.done.md`, sets `complete` true, writes the state, and commits the directory.
A missing `BOOTSTRAP.md` still marks the state complete.
The report is the archive sentence and the commit report, which reads `The agent repository was not committed.` when the commit fails.

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

## state.json

The agent directory holds one JSON file with `schema` (integer, initial 1), `generation` (integer, initial 0), and `bootstrap` (the record above).

`read-state` never signals.
A missing, empty, or malformed file becomes `default-state`, and `normalize-state` and `normalize-bootstrap` fill absent or mistyped fields, so a hand-edited file costs a fresh start.
`write-state` writes `state.json.new` and renames it, so a crash leaves the old state or the new one.
The generation seeds the plugin generation at startup.
No shipped code calls the setter, so the value stays at what the seed wrote unless a caller writes it.
The supervisor's status file carries a separate generation (see [Plugins and self-modification](plugins.md)).

## Loading tiers

One body has three forms: L0 answers whether the text matters, L1 answers what shape the body has, and L2 is the whole body.
A caller starts at L0 and pulls a higher tier only after an index read has missed twice.

| Form | Limit            | Derivation                                                   |
| ---- | ---------------- | ------------------------------------------------------------ |
| L0   | 400 characters   | The first paragraph, cut at a word boundary inside the limit |
| L1   | 8000 characters  | The body cut at the last line break inside the limit         |
| L2   | No derived limit | The whole body                                               |

The limits are `+l0-chars+` and `+l1-chars+`, and the miss rule is `+misses-before-promotion+`, which is 2.
A `tiered` value holds the name, the three forms, the tier in use, and the miss count.
A body with no line break inside the L1 limit is cut at the limit, so the result always fits the budget.
`build-tiers` derives L1 and L0 from L2 when the caller passes neither, and a written abstract is passed as L0.

`tier-for` returns one named form and defaults to the tier in use, and `note-tier-miss` counts one index read that came back empty.
`promote-tier` moves up after two misses and clears the count; at L2 it clears and returns `:l2`, and `reset-tier-misses` clears without moving.
The cue pack uses the L0 form of a record, so the tier rule is live on the retrieval path.

## The store

The store is one SQLite file.
`default-store-path` puts `memory.db` under `agents/default/` in `ENCHIRIDION_HOME`, or under the current directory, and the `:db` key or `*store-path*` overrides that path.

`open-store` creates the file and schema when missing and uses a 15000 ms busy timeout.
A file that cannot be opened signals `configuration-error` with `Cannot open the memory store <path>: <reason>`, and a failed schema signals `Cannot create the memory store schema in <path>: <reason>`.
Both report `Configuration is wrong at MEMORY.`
When root creates the file in a split run, it widens the mode to `#o666`; the broker runs as the agent user.
Every string is scrubbed before it reaches a column.

`store-file-p` reads the sixteen-byte SQLite header, and a search opens a store only when that check passes.
One connection serves several threads: `with-store-lock` runs a body under a recursive lock, and `exec` and `query-rows` take it themselves.
`with-store-transaction` holds the write lock across a multi-statement unit.

The schema is created in one transaction, and `open-store` also executes the episodic schema from `episodic-ddl.cl`, so a new store has the log and the generation tables before the first turn.
A database from before the merge still has `turns` and `memories` tables; `open-store` copies their rows into `episodes`, drops the old tables and their FTS triggers, and replaces both with views.
The migration is idempotent.

| Table or view  | Kind  | Holds                                                              |
| -------------- | ----- | ------------------------------------------------------------------ |
| `episodes`     | table | The log: every turn and memory, with session, role, body, and time |
| `episodes_fts` | FTS5  | External content over `episodes.body`                              |
| `turns`        | view  | Every non-memory episode                                           |
| `memories`     | view  | Every memory episode                                               |
| `blocks`       | table | The session and ledger rows                                        |
| `usage`        | table | One row per model call                                             |
| `tasks`        | table | The task queue                                                     |

`set-session-block` and `set-ledger-block` run the injection scan and limit check, and the heartbeat writes those rows, so no agent sees them first.
The task queue functions are `enqueue-task`, `list-tasks`, `dequeue-task`, `complete-task`, `fail-task`, `recover-tasks`, `count-tasks`, and `remove-task`; [Supervisor and heartbeat](supervisor.md) owns their statuses and claim rule.

## Sessions and search

A session is a string on every episode, so the store needs no session table.
`fresh-session-id` returns 32 hexadecimal characters, and a session spans the smallest and largest timestamps of its episodes.
An episode records session, role, body, model, channel, and universal time; the roles are `user`, `assistant`, `tool`, and `memory`.
`record-turn` writes one episode and returns a turn row.
Every round of a tool turn is stored, including tool results, and an empty assistant body is skipped.
Sleep turns are stored when `:record-sleep` is true, which it is by default.

`recent-sessions` returns sessions newest first with `:id`, `:started`, `:ended`, and `:turns`.
`session-count` counts distinct sessions, and `delete-session` removes a session's episodes and returns the count.
`search-sessions` returns matching non-memory episodes best first, and `recent-turns` returns the newest non-memory episodes, optionally excluding one channel.

`save-memory` writes one episode with role `memory` and returns the new row identifier.
It refuses an empty body after the scrub with `A memory needs text.` and an exact duplicate with `Memory <name> already holds that text.`
`list-memories` returns memory episodes newest first, and `search-memories` matches a name or a body.
The `memory` tool calls `save-memory` for the model; the `search` tool reads the same views and does not write them.

A search turns each whitespace-separated term into an FTS5 quoted prefix query, so an operator character such as `+` is a literal.
A term with no alphanumeric character is dropped.
A query left with no terms signals `schema-error` with `The query has no searchable terms.`, and a control character signals `The query has a control character.`
`search-sessions` and `search-memories` use `MATCH` with `ORDER BY rank`, and no model call runs, so recall costs no tokens and cannot invent a memory.
The search functions and `recent-sessions` return 20 rows by default, and `recent-turns` returns 4.

Search the log from the shell:

```sh
enchiridion memory "open ports"
enchiridion memory status
enchiridion sessions
```

The search form prints the memories section and the turns section with their counts.
`memory status` prints the log counts and switches.
[Commands](commands.md) documents the commands.

## The ledger

Every model call adds one `usage` row with the four numbers the provider reported, the session, the channel, and a universal time.
Nothing in the row is derived, and every column is scrubbed.

`record-usage` returns the new row identifier, and `usage-rows` returns rows oldest first, up to 1000 by default.
`usage-since` returns rows at or after a time, and `usage-summary` returns the ledger summed by `:model`, `:channel`, or `:day`.
`usage-total-since` and `usage-session-total` sum every column from a time and for one session.
A day is the local calendar day of the row's time; model and channel groups are ordered by total tokens, and day groups newest first.
A summary returns at most 100 groups.

`enchiridion usage` prints three sections by model, by channel, and by day, each with input, output, cache read, cache write, and calls.
The heartbeat writes the ledger block, one line in every prompt: `session in 1200 out 340 cache r 0 w 0 calls 4 · day 15400`.
The same totals bound the sleep agent through the budget windows in [Supervisor and heartbeat](supervisor.md).

## Compaction

The session block is the agent's summary.
Compaction sends the previous block and the last four turns to the cheap model and stores the answer.

It runs when four eligible turns exist and all four are past the supervisor's cursor, sends `+recent-turn-limit+` (400 characters) of each turn, and enforces the session block's limit (400 by default).
`+compaction-brief+` is the compactor's only persona and asks for plain prose of at most 400 characters.
`compact-session` builds a message from the previous block or `(none)` and the last four turns.
It runs the cheap model through a compactor agent with no tools.
The answer is scrubbed, and a non-empty answer is written with `set-session-block`, which scans it and enforces the limit; an oversized or refused answer changes nothing.
`compact-when-due` excludes the `:sleep` channel, so the summariser does not read its own output.
`write-session-fallback` writes `Tick 12. 3 tasks waiting, 1 failed.` into an empty session block, and compaction overwrites it.

### Rebase

A summary of a summary drifts, so every `:compaction-rebase-every` (8) passes one is a rebase.
A rebase sends the last `:compaction-rebase-turns` (24) raw turns and no previous summary, under `+rebase-brief+`, and its report reads `the session block was rebuilt from raw turns`.

Every pass that lands writes a `projections` row: the block, the first and last turn id it read, whether it was a rebase, the model, a hash of the text, and the time.
`compaction-rebase-due-p` counts the rows since the last rebase, so a restart keeps the cadence even though the turn cursor does not survive one.

A rebase is the one compaction pass large enough to matter to the tick cap.
The heartbeat estimates it at four characters a token over its turns, its brief, and a full session block, and passes that estimate to `budget-refusal` as `:reserve`.
A tick whose remaining cap cannot cover it reports `compaction skipped: the tick cap cannot cover a N token pass`, writes no row, and tries again on the next tick.

## Troubleshooting

| Symptom                                                              | Cause                                                        | Fix                                                                     |
| -------------------------------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------- |
| `Block <label> is at 1200 characters and needs 1280, so 80 must go.` | The new text exceeds the limit                               | Shorten the text before the write                                       |
| `Block <label> is frozen for this session.`                          | The block is not writable for this agent                     | Write through the sleep agent, or the block tool after handover         |
| `Block <label> is the operator's until bootstrap hands over.`        | The first steps are unfinished                               | Finish the bootstrap, or reset and complete it                          |
| `Block <label> already holds that text.`                             | The write changes nothing                                    | Skip the write                                                          |
| `A memory needs text.`                                               | The body was empty after the scrubber                        | Write a body with content                                               |
| Search signals `The query has no searchable terms.`                  | The query held only punctuation                              | Search for words                                                        |
| Search signals `The query has a control character.`                  | The query held a control character                           | Remove it                                                               |
| The prompt does not show a block that was newly written              | The prompt was compiled at agent start                       | Start a new process                                                     |
| The transcript is missing entirely                                   | The store did not open, and the process said so              | Read the error line, and check the path and permissions for `memory.db` |

## See also

- [Episodic memory](episodic-memory.md): the episodic log and the cue pack.
- [Supervisor and heartbeat](supervisor.md): the tick that writes the blocks and runs compaction.
- [Large language model backends](llm.md): the scrubber that cleans every string before it reaches a column.
- [Tools](tools.md): the search and memory tools that read the store.
- [Commands](commands.md): `blocks`, `memory`, `sessions`, `usage`, and `bootstrap`.
