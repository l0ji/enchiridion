# Episodic memory

Every turn is written to one log, and a new turn retrieves from that log before
the model is called. The retrieved text goes into the user message only; the
system prompt is the frozen block snapshot and never changes.

## What runs

`episodes` is the log: user turns, assistant turns, tool results and saved
memories, with session, role, body, model, channel and time. `turns` and
`memories` are views over that table.

A turn builds a cue from the operator's text, asks SQLite's full-text index for
candidate episodes, ranks them, and renders the best records into the user
message under a data-only header. With the shipped weights the ranking is the
index's BM25 relevance.

| Pack property | Value |
| --- | --- |
| Records | Up to 12, cut by the character budget |
| Budget | 4450 characters, `:pack-chars` |
| Excerpt | The 400 characters of a body holding the most cue terms, with an ellipsis where cut |
| Header | UTC date and role after the ref, for example `[ref episode-42] (2026-03-14, user)` |
| Whole bodies | Available through the `search` tool |

When a live generation holds claims, they can join the pack. At most two claims
are shown under their own episode and take no place of their own; up to three
other claims stand alone.

The transcript stores the operator's original text, not the pack. The pack is
not persisted, and retrieval is not an information barrier.

## Generations

A generation is a versioned snapshot of derived claims. A candidate copies the
live rows and derives episodes it has not processed; a build resumes over several
ticks, and a candidate is invisible to normal retrieval until it is promoted.

Promotion retires the old live generation and moves the pointer in one
transaction. Rollback moves the pointer back to the parent. `check-promoted` runs
the canary and utility checks on a newly live generation and rolls it back when
either fails.

The deriver asks the cheap model for strict JSON. Each assertion carries subject,
relation, object, polarity, an exact span, provenance, authority and run id; a
row without a span is rejected, and a unique key makes repeated derivation
idempotent. A conflicting claim is recorded as a conflict between two
assertions; a change event records the episode, subject, relation, old object,
new object and time.

## Trust and threat model

Stored turns, saved memories, tool output and derived claims are untrusted model
input. Anyone who can influence them can plant instructions for a later
retrieval, and a relevance score says nothing about truth or authority. A
retrieval failure is not evidence of model compromise; a test that shows an
attacked record in the pack has shown only that the record was retrieved.

The renderer adds a data-only warning, bounded excerpts and `[ref ...]` tags. It
does not create an isolated channel, and the block writer's injection scan does
not run over the pack. Even a scanner would not stop a model from following
recalled text.

Credential scrubbing removes registered secrets and recognized credential
shapes. It does not find every sensitive fact, and it does not decide whether
private history may go to a provider. Tool calls stay subject to argument
validation and to the broker's OS identity, but that limits execution authority,
not what an agent does with the files and network its own user can reach.

## What is off

Push is off and not usable. `:push` is accepted for compatibility and defaults
to nil, but no turn calls the push path.

T2 is scheduled on (`:t2-enabled t`). A fresh log can lack enough eligible pairs;
a due pass reports `T2 skipped: instruments missing` without building a candidate.
After a skip, a tick can retry once five minutes have elapsed or the instrument
settings have changed. A skip does not reset the pass timer or episode threshold.

Reranking and embeddings are off. Both switches are accepted and documented in
the [settings reference](config-reference.md#retrieval).

## T2 instruments

A T2 pass starts only when four instruments exist. `t2-preflight` names each
missing one.

| Instrument | Present when | Missing as |
| --- | --- | --- |
| Deriver | An assertion deriver is installed, which `serve` does when a backend exists | `:deriver` |
| Canary coverage | Valid `:canaries` cover `:canary-min-families` of the four families | `:canary-coverage` |
| Utility task set | The log holds `:gate-min-n` question-and-answer pairs | `:utility-task-set` |
| Tail sampler | At least `:tail-min-n` pairs have ranked answers | `:tail-sampler` |

The four canary families are retrieval, update, safety and tail. A canary names a
`family`, a `cue`, an `expect` string, and a `stale` string for the update
family. It checks behaviour in a retrieval, not presence in the store.
`:canaries :built-in` runs four smoke checks against a candidate with temporary
fixture records. The fixtures never enter the transcript. An explicit canary
list replaces the shipped suite and should use records in your workspace.

A utility task pairs a user turn with its final assistant reply, including turns
that used tools. Both arms score the same tasks in `:gate-pack-chars`. The tail
sample ranks eligible answers across the log by rarity. It takes the rarest
`:tail-rarity-fraction`, at least `:tail-min-n` when available and at most 400 pairs.

### Agent proposals

The `canary` tool takes a family, cue, expected text, and an episode ID containing
that text verbatim. For `update`, it also takes the stale value; for `safety`,
`expect` is the text that must stay out. An agent can queue up to 32 distinct
checks. A candidate records each shadow result alongside the live result under
`memory gates ID`. Shadow results do not count toward coverage or affect promotion.

```sh
enchiridion memory canaries
enchiridion memory canaries approve FINGERPRINT
enchiridion memory canaries discard FINGERPRINT
enchiridion memory canaries revoke FINGERPRINT
```

Approval requires the check to pass live lexical retrieval. Approval copies the
reviewed check into `canary-approvals/` beside the operator config, outside the
memory database. Up to 32 checks can be approved.
Discard removes a proposal, not an approval. Revoke stops the check from blocking.
If you delete a source episode, its proposal is deleted; revoke any approved
check separately. For an `update` proposal, verify the stale value before
approving. If the stale text was never recorded, the check only tests retrieval
of the new value. Invalid approval files stop T2 until the operator restores or removes
them. A root supervisor requires root-owned approval paths. If the agent runs
as the operator's UNIX user, the approval files are not a privilege boundary.

## The gates

A candidate passes five gates in order and stops at the first failure.

| Gate | Passes when |
| --- | --- |
| Provenance | Every claim names a span inside an episode still in the log |
| Canary | The families are covered and every canary holds in a retrieval reading the candidate |
| Utility | The mean delta is at least `:gate-margin`, at least `:gate-min-n` pairs are not tied, and the one-sided sign test is below `:gate-alpha` |
| Tail | Recall on rare answers is no more than `:tail-margin` below retention-only |
| Cost | At most `:t2-writes-per-episode` claims per derived episode, and at most `:t2-max-tokens-per-episode` tokens per derived episode since the last promotion |

Each gate writes a `generation_checks` row. A failure quarantines the candidate
with the gate's name and leaves the live layer alone. A candidate that passes is
promoted in one transaction. Thresholds are compared exactly, so a mean delta of
0.05 meets a margin of 0.05.

Promotion precision and quarantine rate can freeze promotion even for a
candidate that passes every gate. A precision freeze has no reset command;
resetting it requires the Lisp function `reset-promotion-precision`. Held
candidates lift a quarantine freeze, and T2 slows to
`:t2-frozen-interval-seconds` meanwhile. The thresholds are in the
[settings reference](config-reference.md#t2-promotion).

## The tick

The heartbeat runs a model-free maintenance pass before the sleep agent and
before compaction. It derives rarity for episodes that have none, in batches,
and writes lexical links only when a retrieval weight reads them. The tick
reports `N episodes derived`, and says nothing when there is no backlog.

T2 runs after maintenance, so the tail sample reads fresh rarity. A pass is due
daily or after `:t2-episode-threshold` new episodes, whichever comes first, and
derives `:t2-max-episodes-per-tick` episodes per tick. A candidate that is still
building is always due, so one pass can span several ticks.

A pass first re-checks a live generation that was promoted and not yet checked; a
failure rolls it back and ends the pass. A new candidate starts only when the
preflight finds every instrument. T2 is refused while promotion precision is
frozen, once it has spent `:t2-max-tokens-per-pass` in 24 hours, or when the day
budget is spent. Its spend counts toward the day cap, not the tick cap.

## Commands

```sh
enchiridion memory status        # counts, live generation, retrieval switches
enchiridion memory "open ports"  # search memories, turns and episodes
enchiridion memory candidates    # every generation and its verdict
enchiridion memory gates ID      # one generation's checks
enchiridion memory promote ID    # run the gates now, never around them
enchiridion memory build         # derive the next batch of a candidate
enchiridion memory regate ID     # retry a quarantined generation
enchiridion memory rollback ID   # roll back a live generation
enchiridion memory canaries      # configured checks and family coverage
enchiridion memory import FILE   # import turns from a JSON Lines file
```

## Configuration

The switches an operator normally touches:

| Key | Default | Meaning |
| --- | --- | --- |
| `:enabled` | `t` | Master switch for the log and retrieval |
| `:retrieve` | `t` | Put a pack in the user message |
| `:push` | `nil` | Accepted for compatibility; the push path is not used |
| `:record-sleep` | `t` | Log sleep and compaction turns |
| `:pack-chars` | `4450` | Pack budget |
| `:rerank` | `nil` | Reorder the top 30 candidates with one cheap-model call per turn |
| `:embed` | `nil` | Add dense candidates fused with BM25 |

Gate, tail and cost keys are in the
[settings reference](config-reference.md#t2-promotion).

## Limits

The cue is lexical, so a paraphrase with no shared term cannot reach a candidate
through the full-text index. The pack shows a 400-character window of each
record; the `search` tool reads the whole body.
