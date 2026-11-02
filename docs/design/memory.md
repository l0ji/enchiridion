# Memory integration decision record

This record is the design of record for integrating the episodic memory model into enchiridion.
It applies the accepted amendment in `research/human-like-agent-memory/amendment-autonomous-memory.md` and supersedes the earlier design that shipped T2 off.
The implementation follows this record, not the executable sketch.
The sketch is reference material: it was written before the amendment, has no generation model, and has not been re-run against the amended default.

## Authority

1. `research/human-like-agent-memory/model-unified.md` is the amended specification.
2. This record closes the specification's remaining design questions.
3. The executable sketch in the research notes is reference code, not a baseline.
4. The enchiridion source tree is the implementation target.

Where a decision here disagrees with the sketch, the decision wins.
Where this record is silent, the amended specification wins.

## Process model

T0 and T1a make no model calls.
T0 appends one episode and one activation row per persisted turn.
T1a derives links, rarity, cue telemetry, and the turn's retrieval pack.
T1b is criterion reconstruction practice: a model-call tier that is off and not claimed.
T2 runs on schedule by default.
T2 passes write a candidate generation.
Only promotion changes the live layer.

The schedule is daily or after 200 new episodes, whichever comes first.
A pass with a missing deriver, canary coverage, utility task set, or tail sampler is a reported no-op with reason `:instrument-missing`.
It does not build an unpromotable candidate.

## Generations and promotion

A generation is a versioned snapshot of semantic derived rows.
`generations` holds the parent, status, run id, parser version, config hash, log segment, token cost, and promotion result.
`memory_state` holds the one live generation id.

Semantic artifacts are generation-scoped: assertions, schemas, summaries, text procedures, conflicts, change events, and semantic links.
Telemetry is global: activation, cue index, lexical co-occurrence links, retrievals, and calibration.
Telemetry is append-only or recomputable and cannot lose content.
T0 and T1a must update it without a promotion.

A candidate copies the live semantic rows, then derives episodes not yet processed for that candidate.
A first generation starts empty.
A rebuild starts empty and replays the whole log.
Candidates are invisible to normal reads.

Promotion is one transaction: validate, set the candidate live, set the old live retired, update the live pointer, and record the checks.
Rollback is a pointer swap to the parent generation.
A failed post-promotion check rolls back and freezes the next pass.

The promotion gates, in order:

1. Provenance. Every semantic item names at least one surviving log span.
2. Canary. Operator-authored behavioural checks pass. Four families are required: retrieval, update/conflict, safety, degradation/tail. An unchecked suite freezes promotion.
3. Utility. Candidate versus retention-only on paired tasks at matched budget. Margin 0.05, at least 100 non-tied pairs, one-sided sign test p < 0.05.
4. Tail. Rare episodes are the top 10 per cent by rarity, minimum 50. Candidate retrieval recall must not fall more than 0.02 below retention-only.
5. Volume and cost. At most 400 semantic writes per candidate, 30,000 tokens per pass, 75,000 per promotion.

Two controls bound autonomy.
Promotion precision is the share of the last 20 promotions that pass the next canary and utility run, with at least 5 checked promotions; below 0.8 freezes promotion.
Quarantine rate is the share of the last 20 candidates quarantined; above 0.5 freezes promotion and moves T2 to weekly.

## The turn

The retrieved pack enters the user message only.
The system prompt is the frozen block snapshot and never changes.
The pack is not persisted as the user turn.
It is scanned with `scan-block-text`, fenced as data, and carries per-record `[ref ...]` tags.

The cue is computed from the original scrubbed text before retrieval.
The cue and its terms are stored with the retrieval prediction before the pack is shown.
FTS5 generates candidates and the Lisp tokeniser scores them.

A record counts as used only when its exact ref tag appears in the assistant text or a tool argument.
No self-assessment and no overlap heuristic.
Cited use updates cue index and retrieval-practice activation.
An outcome is recorded only from a tool exit or test result tied to a cited ref, or from an operator correction marker.
Otherwise the outcome is null.

## Working set and prompt

The five resident blocks are persona 6,000, operator 1,600, world 3,000, session 400, and ledger 250 characters, 11,250 in total.
The cue pack has its own 4,450 character budget.
The model's 4,450 figure is the pack budget, not the total.
The bootstrap block is not resident.

Push ships off.
When enabled it is capped at half the pack and may never evict retrieved material ranked above it.
It is enabled only after a paired no-harm run: at least 100 pairs, mean delta at least 0.05, one-sided sign test p < 0.05, harm rate at most 10 per cent, and no family worse by more than 2 points.

## Retrieval

The score is the amended specification's eight terms plus L, the full-text index's BM25 relevance.
Base-level activation, spreading activation and L are rank-normalised.
The temporal term stays signed.
The shipped weights set the base level, spreading activation and distinctiveness to 0 and L to 1, because the LongMemEval-S measurement in [Episodic memory](../episodic-memory.md#measured-results) found that each of the three lowered recall against L alone.
The specification's weights are kept in the parameter comments as the prior.
Top-k is 12, cut by the pack's character budget.
A record renders as the 400-character window of its body that holds the most cue terms.
Each record carries its UTC date and role after the ref tag, which measured +9.4 points of answer accuracy.
An optional cheap-model reranker (`:rerank`) reorders the top 30 before the cut, and optional dense candidates (`:embed`) are fused with BM25 by reciprocal rank.
Full bodies remain available through the search tool.
Ordering is deterministic by score, then kind, then id.
The graph query is seeded from candidates and bounded at 20,000 rows.

Lexical candidate generation cannot reach a paraphrase with no shared term.
That limitation is accepted and measured by a degraded arm.
No embedding dependency is added.

## T2 producer

The assertion parser uses the cheap model and returns strict JSON.
Every assertion carries subject, relation, object, polarity, an exact character span, provenance, authority, and run id.
Rows without a span are rejected.
The unique key makes a second pass idempotent.

A change event is a row in `change_events`: episode, subject, relation, old object, new object, event time, source.
Only owner or system provenance can produce one.
The five-condition update test requires the event.
Every other conflicting pair is a revision.

Resolution happens at the point of action.
The policy uses query time, source authority, action reversibility, and conflict kind.
Temporal containment wins first.
Higher authority wins for reversible actions.
Context-partitioned conflicts resolve by context.
Behaviour-oscillation and source-contradiction conflicts ask the operator.
Irreversible ambiguity asks the operator.
Resolution is recorded in `conflict_resolutions`; the assertions are not modified.
The pack includes both sides or is marked conflict-bearing.

Text procedures are memory artifacts and follow the admission rule.
Compiled procedures, generated skills and tools, and source are executable artifacts.
They never promote through T2.

## Compaction

The session block is a prompt projection, not the episodic memory model.
Retrieval and derivation never read `blocks`.
Every eighth compaction rebases from the last 24 raw turns instead of the previous summary.
`projections` records the source turn range, model, rebase flag, hash, and time.

T2 summaries derive only from episode spans.
A summary of a summary is forbidden as a memory artifact.
This closes iterative summarisation drift inside the memory layer.

## Executable changes

The agent writes a structured change proposal: trigger, evidence, proposed change, risk, rollback, and test.
The proposal enters the persistent queue.
The operator accepts, rejects, or asks for more evidence.
The agent may verify the proposal in a sandbox.
It may not load the change into the live generation.
A proposal is not a learning signal and is excluded from retrieval, calibration, and outcomes.

## Storage

New tables, no changes to existing tables:

| Scope | Tables |
| --- | --- |
| Immutable log | `episodes`, `episodes_fts` |
| Global telemetry | `activation`, `cue_index`, lexical `links`, `retrievals`, `calibration` |
| Generation semantic layer | `assertions`, `schemas`, `summaries`, text `procedures`, `conflicts`, `change_events`, semantic `links` |
| Generation control | `generations`, `memory_state`, `generation_checks`, `generation_derivations` |
| Operator and evidence | `change_proposals`, `conflict_resolutions`, `gate_log`, `log_runs`, `projections`, `canaries` |
| Host projections | `blocks`, `tasks`; `turns` and `memories` are views over `episodes` |

All new tables are `CREATE TABLE IF NOT EXISTS` and are created inside the store transaction.
Foreign keys are on.
The busy timeout is 15 seconds.
WAL is not used because the container's root-to-agent-user split would leave the `-wal` and `-shm` files unwritable by the broker.

## Capacity and retention

Assertions: at most 200 live per subject.
Procedures: at most 64 admitted.
Schemas: at most 32 active.
Intentions: at most 3 injected per turn, default expiry 90 days.
Calibration: rolling 2,000 rows per family.
Pack: top-k 12.

Overflow retires the lowest-activation derived row by setting `retired_ts`.
Episodes are never retired.
Links below the floor are pruned.
Cue index rows unused for 90 days are pruned.

## Deletion and privacy

The log is append-only during operation.
`delete-session` deletes the session from the episodic log.
an operator `forget SESSION` action deletes episodes and dependent derived rows in one transaction.
The operator owns that command.
The agent cannot erase the log through a tool.

## What is not claimed

Context Saturation Gap and predictions P1 to P14 are not measured.
T1b reconstruction is off.
Live L1 and L2 promotion is deferred.
Embeddings, WAL, a custom FTS5 tokeniser, and new dependencies are excluded.
Automatic code materialisation is excluded.

## Decision to fixture map

| Decision | Fixture |
| --- | --- |
| T2 on schedule, preflight no-op | heartbeat test with missing instruments |
| Candidate isolation and atomic promotion | generation test |
| Rollback and post-promotion check | generation test |
| Provenance gate | candidate with an orphan assertion |
| Canary and coverage | gate test |
| Utility sign test | gate test |
| Tail gate | gate test |
| Volume and cost | gate test |
| Promotion precision and quarantine | gate test |
| Pack budget and non-eviction | pack test |
| Prompt bytes unchanged | kernel property test |
| Exact ref usage | usage test |
| Null outcome | usage test |
| Update versus revision | conflict test |
| Resolution policy | conflict test |
| Compaction rebase | projection test |
| Backfill idempotence | store test |
| Rebuild | generation test |
| Proposal never loads live | proposal test |
