# Episodic memory

The harness keeps an immutable log of every ordinary turn and derives rankings from that log without asking a model to summarise it.
This page describes what the current implementation does.
[The design record](design/memory.md) is the authority for the full model and for the parts that are still being built.

## What is on

The log and the cue pack are on by default.
Each persisted turn is one row in `episodes`.
The `turns` view is the transcript projection over that log, and the `memories` view is the saved-memory projection over the same rows.
A later turn builds a cue from the operator's text before it calls the model.
The cue selects candidate episodes through the full-text index, the score ranks them, and the best records are rendered into the user message as a fenced block of data.
With the shipped weights the ranking is the index's own BM25 relevance; the activation terms are in the score with weight zero until a measurement says otherwise (see [Measured results](#measured-results)).
The system prompt is the frozen snapshot and never changes.

The pack is not stored as the user turn.
The transcript keeps the operator's text, so recalled material cannot become new memory through the conversation.
The pack is scanned with the same injection scan the block writer uses.
A refused pack is dropped and the turn continues.

`episodes` is the one memory table.
`turns` and `memories` are views over it, so the transcript, the search surface, and the saved memories cannot drift from the log.
The model-facing `memory` tool writes a memory episode.

## What is not on yet

The generation lifecycle is implemented and tested: a candidate is built from the log, it is invisible until promoted, promotion swaps the live pointer, and rollback returns it.
It is not on the heartbeat yet, and promotion is not exposed on the command line until the four gates land.
The push channels, the intention tool, the canaries, the gate log, and the code-change proposal queue are designed and scheduled but are not wired into a turn.
Their tables exist in the schema.
`memory status` reports zero generations until a candidate is built.

Push is off.
The design enables it only after a paired no-harm run.

## A turn

1. Scrub the operator's text.
2. Tokenise the text into a cue and store the cue with the retrieval prediction.
3. Ask the full-text index for candidate episodes.
4. Rank the candidates with the score, which is BM25 relevance under the shipped weights.
5. Render up to twelve records into a pack of at most four thousand four hundred and fifty characters. Each record shows the four hundred characters of its body that hold the most cue terms, with an ellipsis where it was cut.
6. Put the pack at the head of the user message, with a data-only header and a `[ref ...]` tag per record.
7. Persist the original text as one episode; the turns view exposes it.
8. Every assistant message and tool result is also an episode.
9. A tool result that reports an exit status carries an outcome; everything else is null.

A cue with no searchable term produces no pack.
A store error produces no pack and one stderr line.
Neither fails the turn.

## The tick

The heartbeat runs a model-free maintenance phase before the sleep agent and before compaction.
It derives rarity and lexical co-occurrence links for episodes that have not been derived, in batches.
The phase is reported as `N episodes derived` when it writes, and adds no note when there is nothing to do.

## Configuration

The `:memory` section of `config.cl` controls the integration.
The shipped values are in `config.example.cl`.

| Key | Default | Meaning |
| --- | --- | --- |
| `:enabled` | true | Master switch. False makes every hook a no-op. |
| `:retrieve` | true | Put a cue pack in the user message. |
| `:push` | false | Enable the four push channels. |
| `:record-sleep` | true | Append sleep and compaction turns to the log. |
| `:pack-chars` | 4450 | Pack budget in characters. |
| `:push-max-fraction` | 0.5 | Push cap as a fraction of the pack. |
| `:maintenance-batch` | 200 | Episodes per maintenance batch. |
| `:graph-limit` | 20000 | Link rows one retrieval may load. |
| `:t2-enabled` | true | T2 is scheduled on; promotion is gated. |
| `:rerank` | false | Reorder the top 30 candidates with one cheap-model call per turn. Measured +9.6 points of answer accuracy; off because it adds a model call to every turn. |
| `:embed` | false | Add dense candidates fused with BM25. Needs an embeddings endpoint and key; not measured yet. |
| `:embed-model` | `"text-embedding-3-small"` | Embedding model. |
| `:embed-dimensions` | 512 | Vector size requested from the model. |
| `:embed-base-url` | OpenAI | OpenAI-shaped endpoint the vectors come from. |
| `:embed-key-env` | `"OPENAI_API_KEY"` | Variable that holds that endpoint's key. |

The remaining keys in the example belong to the generation and gate path and are documented in the design record.

## Commands

```sh
enchiridion memory status        # log counts, live generation, cue index, canaries
enchiridion memory build         # run one bounded candidate build
enchiridion memory "open ports"  # search sessions, memories and episodes
```

The search form of `memory` prints three sections: memories, turns and episodes.

## Limits

The cue is lexical.
A paraphrase with no shared term cannot reach a candidate through the full-text index, and the association graph does not yet close that gap.

The pack shows a four-hundred-character window of each record, not the whole body.
The whole body is available through the `search` tool.

Only retrieval has been measured, not answers.
The design record's predictions P1–P14 are still unrun.

## Measured results

`bench/` holds a LongMemEval-S benchmark that drives the real write and read paths: every haystack turn goes through `record-turn`, the heartbeat maintenance pass runs over the log, and the question is ranked by the same function the turn path renders.
It calls no model, so it measures what reaches the pack, not the answer the model gives.
[bench/README.md](../bench/README.md) describes the metrics and how to run it.

Over the 470 questions with gold evidence, against the previous defaults, each delta paired per question:

| Metric | Before | After | 95% CI of the delta |
| --- | --- | --- | --- |
| An answer turn ranked in the top 10 | 0.730 | 0.864 | +0.100 to +0.170 |
| Share of answer sessions in the top 10 | 0.736 | 0.914 | +0.147 to +0.209 |
| NDCG@10 over answer turns | 0.435 | 0.642 | +0.182 to +0.234 |
| An answer turn rendered in the pack | 0.698 | 0.883 | +0.151 to +0.221 |
| The gold answer's text in the pack | 0.343 | 0.485 | +0.109 to +0.174 |

McNemar p < 0.0001 for each binary metric.
The pack now fills more of its budget: about 4,100 characters, against about 2,000 before.

Three changes produced the gain:

- **Every episode has an activation row.** Before, none did, so the base-level term was the same for every candidate. With real ages, the proposal's weight of 1.0 on the base level *lowered* top-10 recall from 0.730 to 0.421, so the base-level weight now ships at 0.
- **BM25 relevance is a score term.** The index's relevance was used only to choose candidates and then dropped. BM25 alone beat every blend tried with the base level, spreading activation or distinctiveness; adding spreading at 0.2 or the base level at 0.05 or 0.2 did not improve it.
- **The pack shows the part of a record the cue matched.** It used to show the first paragraph, so a fact in the middle of a long turn never reached the model even when the turn was retrieved. That change alone raised the gold-answer-in-pack rate by 5.3 points with the ranking held fixed.

The benchmark asks every question from a fresh session against a single-user log, so it says nothing about the context, cue-type, importance, inhibition and temporal terms, which are constant across its candidates.
Their weights are unchanged.
Preference questions stay weak (0.533 top-10 recall): the answer turn rarely shares words with the question, which is the paraphrase limit above.

### Later changes

The index now stems words (porter): an answer turn in the top 10 for 0.883 of questions against 0.864 (p = 0.049, borderline), with preference questions rising from 0.533 to 0.633 and nothing else moving.
Maintenance no longer writes co-occurrence links while no score term reads them, which cut the per-episode maintenance cost about sixfold; `rebuild-derived` restores them if spreading activation is turned back on.
Showing each turn's neighbours in the pack did not help: answer-turn coverage was unchanged and session coverage fell 6 points, so `:pack-neighbours` ships at 0.

### Answer accuracy

With `--qa`, the configured cheap model (DeepSeek V4.1 Flash here) answers from the pack and the same model judges the answer against the gold one.
The judge prompts follow LongMemEval's per-type rules but are not its code, so the absolute numbers are comparable only between these runs.

| Configuration | Correct, 470 questions | Temporal (127) | Multi-session (121) | Abstention (30) |
| --- | --- | --- | --- | --- |
| Pack as above | 0.566 | 0.394 | 0.479 | 0.967 |
| With date and role per record | 0.660 | 0.701 | 0.496 | 0.933 |
| With reranking | 0.626 | 0.441 | 0.645 | 0.967 |
| With both | **0.755** | **0.811** | **0.645** | 0.967 |

The date and role header is +9.4 points (95% CI +6.2 to +12.8) and is on: without dates the model cannot answer how long ago something happened.
Reranking adds +9.6 points on top of the header (CI +6.6 to +12.8), mostly on multi-session and knowledge-update questions, and puts an answer turn in the pack for 0.923 of questions against 0.889.
It costs one cheap-model call per turn, so it stays behind `:rerank`.
McNemar p < 0.0001 for each of the three improvements.

## See also

- [The design record](design/memory.md)
- [Memory](memory.md)
- [Configuration](configuration.md)
- [Supervisor and heartbeat](supervisor.md)
- [Commands](commands.md)
- [Tools](tools.md)
