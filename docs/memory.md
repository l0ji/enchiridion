# Memory

Enchiridion splits memory into three layers so the system prompt stays frozen
(preserving prompt caching) while the agent can still recall past conversations:

1. **Identity blocks** (`SOUL.md`, `OPERATOR.md`, `WORLD.md`, plus
   harness-managed `ADAPT.md`) — compiled once at startup into the system
   prompt.
2. **Episodic log** (`memory.db`) — every turn, tool result, and saved memory
   goes into one SQLite log. Before each turn, full-text search (BM25) packs
   relevant excerpts into the user message—never into the system prompt.
3. **T2 derived claims** (optional/background) — a background pass can distill
   short claims from episodes and test them through automated gates before
   promoting them into retrieval.

## Identity files

The agent directory (`agents/default/` under `ENCHIRIDION_HOME`, or the current
directory) is a git repository containing:

| File | Default limit | Purpose |
| --- | --- | --- |
| `SOUL.md` | 6,000 chars | Who the agent is, how it speaks, what it refuses |
| `OPERATOR.md` | 1,600 chars | Who you are, how you like answers, when it may act alone |
| `WORLD.md` | 3,000 chars | Paths, commands, ports, and conventions on this machine |
| `ADAPT.md` | 1,200 chars | Harness-maintained style and workflow guidance (managed by the harness) |

`GUIDE.md` in the agent directory has writing tips. Check sizes with
`enchiridion blocks`, or print/locate files with `persona`, `operator`, and
`world`. Limits are configurable via `:memory :block-limits` in [Settings
reference](config-reference.md#storage-and-prompt-blocks).

Because the prompt is compiled at startup, edits to identity files take effect
on the next `chat`, `ask`, or `serve`. Block writes and startup both scan for
invisible Unicode and basic prompt-injection patterns (a bad hand-edit refuses
startup with `Configuration is wrong at BLOCK.`).

### Bootstrap

On a fresh agent, `BOOTSTRAP.md` holds a first-run checklist. Until bootstrap
completes:

- The agent's file and block tools cannot modify `SOUL.md`, `OPERATOR.md`, or
  `WORLD.md` (drafts go under `proposed/`), and the built-in `shell` tool is
  disabled.
- You can still edit the identity files yourself at any time.
- Finishing the last step renames `BOOTSTRAP.md` to `BOOTSTRAP.done.md` and
  commits the repo.

Inspect or advance it with `enchiridion bootstrap status|run|step N|reset`
(progress is stored in `state.json`).

### Git history and undo

The kernel commits `agents/default/` after every turn that changes files (`Agent
turn N via CHANNEL`), ignoring `state.json`, `memory.db`, `private/`, `tmp/`,
and `*.fasl`.

```sh
enchiridion journey       # recent commits
enchiridion undo 1        # revert the latest commit
```

## Episodic retrieval and compaction

- **Compaction:** The session summary block (not one of the Markdown files) is
  rewritten every few turns from the previous summary + last 4 turns, and
  rebuilt from the last 24 raw turns every 8 passes.
- **Retrieval:** On each turn, SQLite FTS scores candidate episodes with BM25
  and packs up to 12 excerpts (400-char windows, 4,450-char total budget via
  `:pack-chars`) into the user message under a data-only header with `[ref
  episode-ID]` tags. The agent can fetch full bodies with the `search` tool.
- **Inspecting and searching:** `enchiridion memory "query"` searches saved
  memories and turns directly in SQLite (no LLM call). `enchiridion memory
  status` shows counts and switches.
- **Off by default:** `:rerank` (cheap-model reranking) and `:embed` (dense
  vectors) are off by default; `:push` is unfinished and should stay `nil`.

> [!note]
> Retrieved turns, tool outputs, and claims are **untrusted input**—a relevance
> score does not imply truth or authority, and the data-only header is not an
> isolation boundary. Secret scrubbing strips known credentials, not arbitrary
> private facts.

## T2 derived claims (advanced)

During `serve` ticks, T2 can derive structured claims from episodes into a
candidate **generation** (versioned snapshot) and run five gates before
promoting it:

1. **Provenance** — every claim cites an exact span in an existing episode.
2. **Canary** — retrieval checks across four families (`retrieval`, `update`,
   `safety`, `tail`) all pass.
3. **Utility** — statistically significant improvement on paired Q&A tasks
   (`:gate-margin`, `:gate-min-n`, `:gate-alpha`).
4. **Tail** — recall on rare answers does not drop beyond `:tail-margin`.
5. **Cost** — claims and tokens per derived episode stay within caps.

A failing candidate is quarantined without touching the live generation. On a
fresh log, T2 skips until enough Q&A pairs exist (`enchiridion memory preflight`
reports any missing prerequisites). Manage generations with `enchiridion memory
candidates|gates|build|promote|regate|rollback`.

### Canaries

T2 ships with built-in smoke canaries (`:canaries :built-in`). The agent can
also propose workspace canaries via the `canary` tool; review and approve them
with:

```sh
enchiridion memory canaries
enchiridion memory canaries approve <id>
enchiridion memory canaries discard <id>
enchiridion memory canaries revoke <id>
```

Approved canaries are stored under `canary-approvals/` (on the Docker state
volume, or beside your config locally).

## Adaptation (`ADAPT.md`)

Live replies take style cues from the current exchange. A correction about
length, tone, or format applies to the next reply without waiting for maintenance.

As substantive conversations and tool-using sessions accumulate (120 non-sleep
turns, 6 tool-using sessions), maintenance passes silently shift `ADAPT.md` from
borrowing your style toward the agent's own defaults, and may record at most one
evidence-cited preference per pass (`style`, `workflow`, `format`,
`communication`, or `priority`) from CLI operator turns.

`ADAPT.md` is prompt guidance only—it never grants permissions or overrides
code-enforced bounds (tool schemas, bootstrap locks, budgets, or OS user
isolation). `write-file` and `edit-file` refuse to modify `ADAPT.md`; changes
are committed to git and can be reverted with `enchiridion undo`.

## Backups

Stop enchiridion before copying so SQLite is not mid-write, then archive
`agents/default/` (plus your `:db` file if you moved it outside the agent
directory):

```sh
tar czf enchiridion-agent.tgz -C agents default
```

For Docker volume backups, see [Deployment](deployment.md#state-and-backups).
