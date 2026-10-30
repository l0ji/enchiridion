# Episodic memory

The harness keeps an immutable log of every ordinary turn and derives rankings from that log without asking a model to summarise it.
This page describes what the current implementation does.
[The design record](design/memory.md) is the authority for the full model and for the parts that are still being built.

## What is on

The log and the cue pack are on by default.
Each persisted turn is one row in `episodes`.
The `turns` view is the transcript projection over that log, and the `memories` view is the saved-memory projection over the same rows.
A later turn builds a cue from the operator's text before it calls the model.
The cue selects candidate episodes through the full-text index, the activation score re-ranks them, and the best records are rendered into the user message as a fenced block of data.
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
4. Re-rank the candidates with the activation score.
5. Render up to eight records at four hundred characters each into a pack of at most four thousand four hundred and fifty characters.
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

The pack renders the L0 form of a record.
The whole body is available through the `search` tool.

No accuracy, cost or latency claim is made for the model.
The design record lists the predictions that would settle it, and none has been run.

## See also

- [The design record](design/memory.md)
- [Memory](memory.md)
- [Configuration](configuration.md)
- [Supervisor and heartbeat](supervisor.md)
- [Commands](commands.md)
- [Tools](tools.md)
