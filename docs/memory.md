# Memory

The agent's identity is three Markdown files in its agent directory. You edit
them before the first conversation; after the bootstrap, the sleep agent
maintains them during `serve`.

## The identity files

| File | Contents |
| --- | --- |
| `SOUL.md` | Who the agent is, how it speaks, what it refuses, what it is trying to improve |
| `OPERATOR.md` | Who you are, what a good answer looks like, when the agent may act alone or interrupt |
| `WORLD.md` | Real paths, commands, ports and conventions on this machine |

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

The default limits are 6000 characters for `SOUL.md`, 1600 for `OPERATOR.md` and
3000 for `WORLD.md`; `:block-limits` changes them, and the
[settings reference](config-reference.md#memory) lists the keys. `blocks` shows
the count, and the agent's `blockops` tool enforces the limit and refuses
invisible Unicode and a short list of prompt-injection patterns. The same scan
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

Until the last step, the block and file tools refuse agent writes to `SOUL.md`,
`OPERATOR.md` and `WORLD.md` with `Block PERSONA is the operator's until
bootstrap hands over.` The shell tool does not check that gate, so the agent can
still change the files through a shell command.

The last step renames the file to `BOOTSTRAP.done.md` and commits the directory.
`bootstrap reset` restores it when the live file is absent and clears the record.
The bootstrap record lives in `state.json`, so deleting that file resets it.

## History

The agent directory is its own Git repository. The kernel commits after each
successful turn with the message `Turn N via CHANNEL`.

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
