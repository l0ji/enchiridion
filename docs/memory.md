# Memory

The agent's identity is three Markdown files in its agent directory. You edit
them before the first conversation; after the bootstrap, the sleep agent
maintains them during `serve`.

## The files

| File | Contents |
| --- | --- |
| `SOUL.md` | Who the agent is, how it speaks, what it refuses, what it is trying to improve |
| `OPERATOR.md` | Who you are, what a good answer looks like, when the agent may act alone or interrupt |
| `WORLD.md` | Real paths, commands, ports and conventions on this machine |
| `ADAPT.md` | The bearing and the evidence-cited preferences the harness learns |

`ADAPT.md` is not an identity file you are expected to edit. It is
harness-maintained prompt guidance, included in every prompt, and normally
changed during a maintenance pass. The revert helper is the other writer.

The directory is `agents/default/` under `ENCHIRIDION_HOME`, or under the working
directory when the variable is unset. `init` writes the files and never
overwrites one that exists, so a rerun fills the gaps of a partial setup.

```sh
nix run .#enchiridion -- init
nix run .#enchiridion -- persona          # print SOUL.md
nix run .#enchiridion -- operator edit    # print the path of OPERATOR.md
nix run .#enchiridion -- world            # print WORLD.md
nix run .#enchiridion -- blocks           # characters used of each limit
```

The default limits are 6000 characters for `SOUL.md`, 1600 for `OPERATOR.md`,
3000 for `WORLD.md` and 1200 for `ADAPT.md`; `:block-limits` changes them, and
the [settings reference](config-reference.md#memory) lists the keys. `blocks`
shows the count; `blockops` and the adaptation writer enforce the limit and
refuse invisible Unicode and a short list of prompt-injection patterns. The same scan
runs at startup, so a hand-edited file that trips it stops the agent with
`Configuration is wrong at BLOCK.`

`GUIDE.md` in the agent directory has writing advice for the three files.

## The bootstrap

`BOOTSTRAP.md` lists the first steps, and the agent records each one as it goes.

```sh
nix run .#enchiridion -- bootstrap status
nix run .#enchiridion -- bootstrap run
nix run .#enchiridion -- bootstrap step 3
```

The operator may edit `SOUL.md`, `OPERATOR.md`, and `WORLD.md` at any time.
Until handover, the block and file tools refuse agent writes to those files.
The agent saves drafts under `proposed/` and can finish consecutive steps in
one turn. The built-in shell is unavailable until handover. These tool restrictions
are not an OS sandbox. Untouched older stock checklists update on the next turn;
custom checklists and recorded progress are preserved.

The last step renames the file to `BOOTSTRAP.done.md` and commits the directory.
`bootstrap reset` restores it when the live file is absent and clears the record.
The bootstrap record lives in `state.json`, so deleting that file resets it.

## Adaptation

A young agent borrows its operator's style and work habits. As substantive
memory and corroborated experience accumulate, the bearing moves toward the
agent's own defaults. Elapsed time is not a term, and no tick announces the
change.

The two terms are counts the store already has:

| Term | Counts | Full at |
| --- | --- | --- |
| Substantive memory | Non-sleep user and assistant turns | 120 |
| Corroborated experience | Sessions with at least two tool results and an assistant reply | 6 |

Sleep output and tool rows do not enter the memory term, so consolidation
cannot age an agent by talking to itself. Saved memories do not enter it
either: the store writes owner provenance for every saved memory, so that field
does not identify the source. `ADAPT.md` has five bearing bands and changes
only when a maintenance pass runs and a band is crossed.

The maintenance pass may add at most one learned entry, and a bearing change
counts as that pass's one change. The default is no change. An explicit CLI
operator correction may be applied immediately with the turn id and a short
quote. An inferred preference needs at least three separate CLI operator turns.
Only CLI user turns count as operator evidence by default; an embedding can
bind `enchiridion.kernel:*adaptation-operator-channels*`. HTTP and Fluxer
messages carry the user role, but they are not operator identity by themselves,
even when the channel authenticated the sender. They still contribute to
substantive memory and to tool experience. The harness checks the cited turn
ids, their role, their channel, the quote and the category before it writes the
entry.

`ADAPT.md` is guidance. These bounds are enforced outside the prompt and an
adaptation cannot change them:

| Bound | Enforced by |
| --- | --- |
| Identity-file writes before handover | `blockops`, `file`, and the bootstrap state |
| Block size and injection scan | `scan-block-text`, `set-block-text`, `adaptation-write-file` |
| Tool names, arguments and availability | the tool registry and its schemas |
| OS identity, sandbox and file access | the broker and the deployment |
| Token caps and task claims | the budget code and the task queue |
| Writes to `ADAPT.md` | the builtin `write-file` and `edit-file` refuse it |

The builtin `write-file` and `edit-file` tools refuse the agent's `ADAPT.md` at
every bootstrap state, including through a symlink. The builtin `shell` is not
an OS sandbox and can still write the file as the agent user; a direct write
during a maintenance pass is reverted, but a shell write between passes is only
prompt text until the next pass and the operator's Git review. The same is true
of the identity files after handover.

A proposal that names an enforced bound, such as tool access, a permission, a
refusal, a budget or the bootstrap, is refused. The category must be `style`,
`workflow`, `format`, `communication` or `priority`. The guard is a filter, not
a proof: `ADAPT.md` never grants authority, and the code that enforces a bound
never reads it.

Every bearing change and learned entry records its evidence in the store's
`adaptations` table. A bearing row names both counts; an entry row names its
turn ids. The pass is silent: `health` and the tick report say that a
maintenance pass ran, not that the bearing moved or that an entry was learned.
`ADAPT.md` is in the agent directory, so `git -C agents/default log` shows
every change and `nix run .#enchiridion -- undo N` reverts one. The latest
change can also be reverted with `enchiridion.kernel:revert-adaptation` from a
Lisp session.

## History

The agent directory is its own Git repository. The kernel commits after each
successful turn that changed the tree, with the message `Agent turn N via CHANNEL`.
The counter also includes turns that changed nothing, so Git history can skip numbers.

```sh
git -C agents/default log --oneline
nix run .#enchiridion -- journey
nix run .#enchiridion -- undo 1
```

`undo N` counts from the newest commit. The repository ignores `state.json`,
`memory.db`, `private/`, `tmp/` and `*.fasl`; the Markdown files, skills and
tools are the history.

## Inspecting memory

| Command | Shows |
| --- | --- |
| `memory "open ports"` | Full-text search over saved memories and turns |
| `memory status` | Log counts, live generation, retrieval switches |
| `sessions` | Stored sessions with turn counts |
| `usage` | Tokens by model, channel and day, including cache reads and writes |
| `tasks` | The task queue |

A search prints the memories section, then the turns. It reads SQLite's index
directly, so it costs no model call. The store is `memory.db` in the agent
directory, and `:db` sets another path. `memory status` reports zero generations
until T2 builds one; [Episodic memory](episodic-memory.md) covers that.

## Backup

Stop the process before a copy, so the database is not mid-write. The state is
the agent directory plus the database, which is inside it unless `:db` says
otherwise.

```sh
tar czf enchiridion-agent.tgz -C agents default
```

If `:db` names a path elsewhere, copy that file too. Restore the archive into the
same place while the process is stopped. A container deployment backs up the
state volume instead; see [Deployment](deployment.md#state-and-backups).

## Prompt and compaction

The prompt is compiled when the agent starts, so a change to an identity file
reaches the agent on the next `chat`, `ask` or `serve`, not mid-session.

The session block is the agent's summary of the conversation, and it is not one
of the three files. Compaction rewrites it every few turns from the previous
summary and the last four turns; every eighth pass rebuilds it from the last 24
raw turns. An empty answer, or one over 400 characters, changes nothing.
[Deployment](deployment.md#supervisor-and-schedule) covers when a tick runs it.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Block PERSONA is at 6000 characters and needs 6070, so 70 must go.` | A write over the limit | Shorten by that many characters |
| `Block PERSONA is the operator's until bootstrap hands over.` | The first steps are unfinished | Finish or reset the bootstrap |
| `A memory needs text.` | The agent tried to save an empty memory | Ask for a body with content |
| `The query has no searchable terms.` | The query was only punctuation | Search for words |
| A block edit is missing from a running session | The prompt was compiled at start | Start a new process |
