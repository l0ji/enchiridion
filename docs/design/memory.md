# Memory integration decision record

This is the design of record for integrating the episodic memory model into enchiridion.
It applies the accepted amendment in `research/human-like-agent-memory/amendment-autonomous-memory.md` and supersedes the earlier design that shipped T2 off.
The implementation follows this record; the executable sketch in the research notes is reference material, written before the amendment, with no generation model.

## Authority

1. `research/human-like-agent-memory/model-unified.md` is the amended specification.
2. This record closes the specification's remaining design questions.
3. The executable sketch is reference code, not a baseline.
4. The enchiridion source tree is the implementation target.

Where a decision here disagrees with the sketch, the decision wins. Where this record is silent, the amended specification wins.

## Process model

T0 and T1a make no model calls.
T0 appends one episode and one activation row per persisted turn; T1a derives links, rarity, cue telemetry, and the turn's retrieval pack.
T1b is criterion reconstruction practice: a model-call tier that is off and not claimed.
T2 runs on schedule by default and writes a candidate generation; only promotion changes the live layer.
The schedule is daily or after 200 new episodes, whichever comes first.
A pass with a missing deriver, canary coverage, utility task set, or tail sampler is a reported no-op with reason `:instrument-missing` and does not build an unpromotable candidate.

## Generations and promotion

A generation is a versioned snapshot of semantic derived rows.
`generations` holds the parent, status, run id, parser version, config hash, log segment, token cost, and promotion result; `memory_state` holds the one live generation id.

Semantic artifacts are generation-scoped: assertions, schemas, summaries, text procedures, conflicts, change events, and semantic links.
Telemetry is global: activation, cue index, lexical co-occurrence links, retrievals, and calibration.
Telemetry is append-only or recomputable and cannot lose content, and T0 and T1a update it without a promotion.

A candidate copies the live semantic rows, then derives episodes not yet processed for that candidate.
A first generation starts empty; a rebuild starts empty and replays the whole log.
Candidates are invisible to normal reads.

Promotion is one transaction: validate, set the candidate live, set the old live retired, update the live pointer, and record the checks.
Rollback is a pointer swap to the parent generation.
A failed post-promotion check rolls back and freezes the next pass.

The promotion gates, in order:

1. Provenance. Every semantic item names at least one surviving log span.
2. Canary. Operator-authored behavioral checks pass. Four families are required: retrieval, update/conflict, safety, degradation/tail. An unchecked suite freezes promotion.
3. Utility. Candidate versus retention-only on paired tasks at matched budget: margin 0.05, at least 100 non-tied pairs, one-sided sign test p < 0.05.
4. Tail. Rare episodes are the top 10 per cent by rarity, minimum 50. Candidate recall must not fall more than 0.02 below retention-only.
5. Volume and cost. At most 8 semantic writes per episode a candidate derived, 200,000 tokens of T2 spend in any 24 hours, and 3,000 tokens per episode derived since the last promotion.

Two controls bound autonomy.
Promotion precision is the share of the last 20 promotions that pass the next canary and utility run, with at least 5 checked promotions; below 0.8 freezes promotion.
Quarantine rate is the share of the last 20 candidates quarantined; above 0.5 freezes promotion and moves T2 to weekly.

## The turn

The retrieved pack enters the user message only.
The system prompt is the frozen block snapshot and never changes, and the pack is not persisted as the user turn.
It is scanned with `scan-block-text`, fenced as data, and carries per-record `[ref ...]` tags.

The cue is computed from the original scrubbed text before retrieval, and the cue and its terms are stored with the retrieval prediction before the pack is shown.
FTS5 generates candidates and the Lisp tokeniser scores them.

A record counts as used only when its exact ref tag appears in the assistant text or a tool argument. There is no self-assessment and no overlap heuristic.
Cited use updates cue index and retrieval-practice activation.
An outcome is recorded only from a tool exit or test result tied to a cited ref, or from an operator correction marker; otherwise the outcome is null.

## Working set and prompt

The five resident blocks are persona 6,000, operator 1,600, world 3,000, session 400, and ledger 250 characters, 11,250 in total.
The cue pack has its own 4,450 character budget.
The bootstrap block is not resident.

Push ships off.
When enabled it is capped at half the pack and may never evict retrieved material ranked above it.
It is enabled only after a paired no-harm run: at least 100 pairs, mean delta at least 0.05, one-sided sign test p < 0.05, harm rate at most 10 per cent, and no family worse by more than 2 points.

## Retrieval

The score is the amended specification's eight terms plus L, the full-text index's BM25 relevance.
Base-level activation, spreading activation, and L are rank-normalized; the temporal term stays signed.
The shipped weights set the base level, spreading activation, and distinctiveness to 0 and L to 1, because the LongMemEval-S measurement in [Episodic memory](../episodic-memory.md#measured-results) found that each of the three lowered recall against L alone.
The specification's weights are kept in the parameter comments as the prior.

Top-k is 12, cut by the pack's character budget.
A record renders as the 400-character window of its body that holds the most cue terms, with its UTC date and role after the ref tag, which measured +9.4 points of answer accuracy.
An optional cheap-model reranker (`:rerank`) reorders the top 30 before the cut, and optional dense candidates (`:embed`) are fused with BM25 by reciprocal rank.
Full bodies remain available through the search tool.
Ordering is deterministic by score, then kind, then id, and the graph query is seeded from candidates and bounded at 20,000 rows.

Lexical candidate generation cannot reach a paraphrase with no shared term.
That limitation is accepted and measured by a degraded arm; no embedding dependency is added.

## T2 producer

The assertion parser uses the cheap model and returns strict JSON.
Every assertion carries subject, relation, object, polarity, an exact character span, provenance, authority, and run id; rows without a span are rejected, and the unique key makes a second pass idempotent.

A change event is a row in `change_events`: episode, subject, relation, old object, new object, event time, source.
Only owner or system provenance can produce one, and the five-condition update test requires the event; every other conflicting pair is a revision.

Resolution happens at the point of action, using query time, source authority, action reversibility, and conflict kind.
Temporal containment wins first, higher authority wins for reversible actions, and context-partitioned conflicts resolve by context.
Behaviour-oscillation and source-contradiction conflicts ask the operator, as does irreversible ambiguity.
Resolution is recorded in `conflict_resolutions`; the assertions are not modified, and the pack includes both sides or is marked conflict-bearing.

Text procedures are memory artifacts and follow the admission rule.
Compiled procedures, generated skills and tools, and source are executable artifacts and never promote through T2.
T2 summaries derive only from episode spans; a summary of a summary is forbidden as a memory artifact.

## Compaction

The session block is a prompt projection, not the episodic memory model; retrieval and derivation never read `blocks`.
Every eighth compaction rebases from the last 24 raw turns instead of the previous summary.
`projections` records the source turn range, model, rebase flag, hash, and time.

## Executable changes

The agent writes a structured change proposal: trigger, evidence, proposed change, risk, rollback, and test.
The proposal enters the persistent queue, and the operator accepts, rejects, or asks for more evidence.
The agent may verify the proposal in a sandbox; it may not load the change into the live generation.
A proposal is not a learning signal and is excluded from retrieval, calibration, and outcomes.

## Storage

New tables, no changes to existing tables:

| Scope | Tables |
| --- | --- |
| Immutable log | `episodes`, `episodes_fts` |
| Global telemetry | `activation`, `cue_index`, lexical `links`, `retrievals`, `calibration` |
| Generation semantic layer | `assertions`, `schemas`, `summaries`, text `procedures`, `conflicts`, `change_events`, semantic `links` |
| Generation control | `generations`, `memory_state`, `generation_checks`, `generation_derivations` |
| Operator and evidence | `change_proposals`, `conflict_resolutions`, `gate_log`, `projections`, `canaries` |
| Host projections | `blocks`, `tasks`; `turns` and `memories` are views over `episodes` |

All new tables are `CREATE TABLE IF NOT EXISTS` and are created inside the store transaction.
Foreign keys are on and the busy timeout is 15 seconds.
WAL is not used, because the container's root-to-agent-user split would leave the `-wal` and `-shm` files unwritable by the broker.

## Capacity and retention

Assertions: at most 200 live per subject.
Procedures: at most 64 admitted.
Schemas: at most 32 active.
Intentions: at most 3 injected per turn, default expiry 90 days.
Calibration: rolling 2,000 rows per family.
Pack: top-k 12.

Overflow retires the lowest-activation derived row by setting `retired_ts`.
Episodes are never retired.
Links below the floor are pruned, and cue index rows unused for 90 days are pruned.

## Deletion and privacy

The log is append-only during operation.
`delete-session` deletes a session from the episodic log, and `forget-session` deletes episodes and dependent derived rows in one transaction.
The agent cannot erase the log through a tool; deletion is the operator's act.

## What is not claimed

Context Saturation Gap and predictions P1 to P14 are not measured.
T1b reconstruction is off, and live L1 and L2 promotion is deferred.
Embeddings, WAL, a custom FTS5 tokeniser, and new dependencies are excluded.
Automatic code materialization is excluded.
