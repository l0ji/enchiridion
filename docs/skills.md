# Skills

A skill is a file under `skills/` that teaches the agent something it would otherwise work out again.
Two kinds exist side by side: an executable Lisp skill, which is compiled into a generation and can answer a tool call, and a reference Markdown skill, which is text the agent can read.
This page is the design for both, and every section says what the tree implements today and what is still a decision.

## Two kinds

| Kind      | File             | The harness does                                        | Status                     |
| --------- | ---------------- | ------------------------------------------------------- | -------------------------- |
| Executable | `skills/*.cl`   | Compiles and loads it into the generation, registers its tool | Implemented          |
| Reference  | `skills/*.md`   | Reports it in a generation; `read-reference-skill` returns the text | Reported, not indexed      |

An executable skill is a [plugin](plugins.md) that lives under `skills/` rather than `tools/`, and the two directories differ in load order and in nothing else.
A reference skill is never compiled, so it cannot define a tool, hold a handler, or run.

## Where a skill lives

`agent-source-files` reads `skills/` before `tools/`, and the file name orders each directory, so a skill can define a function that a tool file calls.
Only files directly in `skills/` are read: the walk is `uiop:directory-files`, so a subdirectory of `skills/` is not a skill and a file named for a dot is skipped.
The extension is matched case-insensitively, so `NOTES.MD` is a reference skill.

| Path                    | Kind       | Read by                     | Compiled |
| ----------------------- | ---------- | --------------------------- | -------- |
| `skills/*.cl`           | Executable | `agent-source-files`        | Yes      |
| `skills/*.md`           | Reference  | `reference-skill-files`     | No       |
| `tools/*.cl`            | A tool     | `agent-source-files`, later | Yes      |
| `SOUL.md`, `WORLD.md`   | An identity file, not a skill | The memory seed pass | No   |

A skill directory with a `SKILL.md` inside it is not a convention this tree reads.
A flat file per skill is the convention, because the loader's file list is the generation.

## Executable skills

An executable skill calls `enchiridion.plugin:define-plugin` once or more, with a `tool` form, a handler, and a self-test.
[Plugins and self-modification](plugins.md) owns the macro, the manifest reader, verification, and the extension surface; this page only says where a skill sits in that picture.

The trigger line is the convention that makes a skill findable before it is loaded.
A skill declares it as a `defparameter +trigger+` whose value is a string of the words that make the skill relevant, and `enchiridion skills list` reads that form as data with `*read-eval*` nil, so listing a skill never runs it.
The trigger is short because it is meant to be charged on every turn, and in this tree it is charged nowhere yet: the listing shows it to the operator, and no prompt reads it.

## Reference skills

A reference skill is Markdown that a person or an agent wrote for the agent to read later.
`reference-skill-files` lists the ones under `skills/`, `read-reference-skill` returns one as UTF-8 text and refuses any file that is not Markdown, and both `load-generation` and `verify-directory` report the list in `:reference-skills`.
That is the whole of what exists: the list is filled in and nothing reads it.

The metadata a reference skill needs is the part that is not implemented, and the format below is the design rather than a shipped contract.

```markdown
---
name: deploy-checks
when: deploying, shipping, a release
---

# Deploy checks

Run the migration before the restart.
```

The reader would take the first `---` block only, accept `key: value` lines and nothing else, and know two keys:

| Key    | Meaning                                                     | Absent        |
| ------ | ----------------------------------------------------------- | ------------- |
| `name` | The skill id, when the file name is not the id the author wants | The file name, lowercased |
| `when` | The words that make the skill relevant, like `+trigger+`     | No trigger    |

Nested values, lists, and unknown keys would be a `configuration-error` naming the line, because a metadata block that half parses is worse than one that is absent.
The block would be bounded at 4 KiB, and a file without one would be listed by its file name.

> **Important:** none of that is implemented. A Markdown skill is readable today and appears in a generation's `:reference-skills`, but `enchiridion skills list` shows only `.cl` files. The harness does not parse the metadata, does not index the skill, and does not put it in a prompt.

## Stable ids and collisions

The id of a skill is its file name without the extension, lowercased, for both kinds.
An id is what a listing shows and what the model would ask for, so it has to be stable across a reload and independent of load order.

Two files cannot collide within one kind, because a directory holds one `deploy.cl`.
Across kinds, `skills/deploy.cl` and `skills/deploy.md` share the id `deploy`, and one of them would have to win.
That is an open decision:

| Option                    | Effect                                                                     |
| ------------------------- | -------------------------------------------------------------------------- |
| Refuse the generation     | Deterministic and loud, and one id never means two things                   |
| Namespace by kind         | `deploy` for the executable one and `deploy.reference` for the other        |

The recommendation is to refuse, in the loader, with both paths in the report, because a silent winner is the collision the plugin registry already avoids by refusing to be quiet about a replaced name.
Nothing refuses it today: the executable one loads and the reference one only appears in the generation report.

## Read versus executable invocation

|                    | Executable skill                     | Reference skill                        |
| ------------------ | ------------------------------------ | -------------------------------------- |
| Reached by         | A tool call the model makes          | A file read                            |
| Costs a schema     | Yes, on every turn, inside the budget | No                                     |
| Runs where         | The broker child, as the agent user  | Nowhere: it is text                    |
| Failure mode       | A warning, a failed self-test, a refused generation | Too large, not UTF-8, metadata that does not parse |
| Rolled back by a reload | Yes, the generation and its tools | Only the generation report that names it |

A reference skill is read the way any other file is read: `read-file` with a line range, or the agent's own reading of it.
An index in the prompt, a `read-skill` tool, or an automatic inclusion by trigger is a product decision below, and no code in this tree makes that choice.

## Authority and trust

An executable skill runs with the authority of the agent: the same user, the same filesystem, the same tools, and the same turn budget.
Verification compiles it at `(safety 3)` and runs its self-test, and that is a check on a broken file, not a sandbox: a handler in a verified generation can still delete the agent directory.
The boundary that contains it is the process and uid split in [Deployment](deployment.md), and it is containment of the whole child, not of one handler.

A reference skill has no authority at all, because nothing runs it, and that is also its one risk: text an agent reads is a way to tell it what to do.
A reference skill from an untrusted source is a prompt-injection channel, so it belongs to the operator who wrote it, and a prompt that quotes one should label it as data rather than as an instruction.

Neither kind reads the private configuration or the secrets file.
That is policy and not enforcement: a handler runs as the agent user, and [Plugins and self-modification](plugins.md) says what the agent user can reach.

## Authoring and listing

An author writes the file with the file tools and asks for a reload:

```sh
enchiridion skills list
enchiridion skills show 2
```

`skills list` numbers the `.cl` skills and prints each one's `+trigger+` line, and `skills show NUMBER` prints the file.
`skills list` reads only `.cl` files, so a reference skill exists on disk and is invisible to the operator's listing today.

The planned listing shows both kinds, with the trigger or `when` line beside each, and `skills show` on a Markdown skill prints its body rather than compiling it.

## Reload, validation, and rollback

An executable skill is part of the reload transaction: the source snapshot digests it, the verification child compiles it, the loader refuses a tree that changed under it, and a refused generation leaves the live registry and the previous tools exactly as they were.
An empty `skills/` and `tools/` is not a no-op either: the next reload publishes an empty generation, so deleting the last skill unloads its tool on both sides of the broker boundary.
[Plugins and self-modification](plugins.md) owns that contract.

A reference skill is not compiled and cannot fail verification.
Its validation is size, encoding, and the metadata reader once that exists, and the failure it can cause is a refused listing rather than a refused generation.

A reference skill is also not in the source snapshot.
The snapshot covers the compiled sources, so a Markdown edit between the manifest read and the load is not detected, and a prose edit cannot refuse a reload.
Whether it should is an open decision: the change is one extension in the snapshot's file list, and the consequence is that editing a paragraph could refuse a generation whose code is fine.

## Size bounds

| Bound                                  | Value     | Enforced by                  |
| -------------------------------------- | --------- | ---------------------------- |
| One agent file, for its manifest       | 256 KiB   | `+manifest-file-limit+`      |
| One agent file, for the snapshot       | 1 MiB     | `+source-file-limit+`        |
| One reference skill                    | 64 KiB    | Proposed, not enforced       |
| Files in one `skills/` directory       | 256       | Proposed, not enforced       |
| The trigger or `when` line             | Short     | Convention, not enforced     |
| The schema budget, executable skills   | 2000 tokens | `+schema-budget+`          |

The manifest limit is the one that binds in practice: every `skills/*.cl` file is read for its manifest, so a file above 256 KiB is refused before its snapshot matters.
The schema budget is shared by every tool, and a plugin whose schema is too large makes every turn fail with a budget error, which [Tools](tools.md) covers.

## What is implemented today

| Piece                                   | State                                                        |
| --------------------------------------- | ------------------------------------------------------------ |
| `agent-source-files`                    | Implemented: `skills/*.cl` then `tools/*.cl`, each sorted      |
| `skill-files`                           | Implemented: the `.cl` and `.md` files under `skills/`, no caller |
| `reference-skill-files`                 | Implemented: the `.md` files, reported in both result structs  |
| `read-reference-skill`                  | Implemented and tested: one Markdown file as UTF-8 text, no caller |
| `:reference-skills` on both results     | Implemented: filled in, and read by nothing yet                |
| Markdown metadata reader                | Planned                                                       |
| Reference skill in a prompt             | Planned, and undecided                                        |
| Listing a reference skill               | Planned                                                       |
| Cross-kind id collision                 | Planned: refuses nothing today                                |
| Reference skill in the source snapshot  | Not included, and undecided                                   |

A helper that is exported and tested but has no caller is deliberate: it is the shape the design needs, and it does nothing until something asks it to.
Nothing in this tree silently activates a Markdown skill, and a page that claimed otherwise would be describing code that does not exist.

## Open decisions

1. Does a reference skill reach the model at all, and how: an index line per skill with its `when` line, a tool that reads one, or nothing but an operator listing?
2. Does the id collision between `deploy.cl` and `deploy.md` refuse the generation or namespace the reference one?
3. Do reference skills join the source snapshot, so that editing prose can refuse a reload?
4. Which front matter is required: is `name` optional, is `when` required, and are unknown keys refused or ignored?

Each of these changes behaviour an author can see, so the loader does not guess one.

## See also

- [Plugins and self-modification](plugins.md) for the plugin, the manifest, verification, and the reload transaction.
- [Tools](tools.md) for the registry, the schema budget, and the handler contract.
- [Memory](memory.md) for the seed files, which are identity files and not skills.
- [Commands](commands.md) for the command table that carries `skills` and `reload`.
