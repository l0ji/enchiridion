# Tools

A tool has a name, a one-line description, a schema and a handler. The model
sees the name, description and schema, and the schema validates the arguments
the model sends back. The eleven built-in tools are registered in every command
process. Tools written under `agents/default/tools/` load with a generation;
see [Plugins](plugins.md).

## Built-in tools

| Tool | Required | Optional | Use |
| --- | --- | --- | --- |
| `index` | `path` | | Top-level forms of a Lisp file with line ranges |
| `read-file` | `path` | `from`, `to` | Lines, 1-based and inclusive |
| `write-file` | `path`, `text` | | Create or replace a file, making parents |
| `edit-file` | `path`, `old`, `new` | | Replace one unique occurrence |
| `glob` | `pattern` | | Paths matching a wildcard |
| `shell` | `command` | `timeout` | Run `/bin/sh -c`, default 30 seconds |
| `search` | `query` | `scope`, `path`, `limit` | Search the memory store or text files |
| `blockops` | | `action`, `label`, `old`, `new`, `text`, `directory` | Read or change a memory block |
| `memory` | `name`, `text` | | Save one named memory |
| `meta` | | `action`, `directory`, `limit`, `name`, `kind`, `text`, `confirm`, `step` | Read the journey, author a file, reload, undo |
| `web` | | `action`, `url`, `query`, `limit` | Fetch a URL or search the web |

`index` reads with `*read-eval*` off, so a reader macro in the file cannot run.
`read-file` refuses a range outside the file.

### blockops

Reads and changes the Markdown memory blocks.

| Label | File |
| --- | --- |
| `soul`, `persona` | `SOUL.md` |
| `operator` | `OPERATOR.md` |
| `world` | `WORLD.md` |

`action` defaults to `list`, which prints `LABEL SIZE/LIMIT PATH`. `read`
returns the block text, `patch` replaces one unique `old` with `new`, and `add`
appends `text`. The limits come from `:memory :block-limits`; a label that the
section does not name uses `:unlisted-block-limit` (see the
[settings reference](config-reference.md#memory)).

For write restrictions during setup, see [Bootstrap](memory.md#the-bootstrap).

### meta

| Action | Arguments | Effect |
| --- | --- | --- |
| `journey` | `limit` | Last commits in the agent repository |
| `author` | `name`, `kind`, `text` | Write `tools/NAME.cl` or `skills/NAME.md`; commit when the directory is a repository |
| `bootstrap-step` | `step` | Record one bootstrap step |
| `undo` | `confirm` equal to `yes` | Revert the last commit |
| `reload` | | Ask the running supervisor to reload |

`author` takes `kind` `tool` (the default) or `skill` and refuses a file that
already exists. A commit failure is silent, so a host with no Git identity does
not lose the reply. The directory defaults to `:directory`, then
`$ENCHIRIDION_HOME/agents/default/`, then the current directory.

### shell

`/bin/sh -c` with a timeout of 30 seconds by default and 600 at most. The
result is the combined output and `[exit N]`, or `[timed out after N seconds]`
after the child and everything it started is stopped. The command runs in the
broker child as the agent user, and it can read and write whatever that user
can.

### search

`scope` is `memory` by default. `files`, or any `path`, walks text files
instead. `limit` defaults to 20 for the store and 40 for the walk. A store hit
prints as `session SESSION ROLE: TEXT` or `memory NAME: TEXT`, flattened to one
line and cut at 400 characters. The file walk visits `md`, `txt`, `cl`, `lisp`,
`json` and `org` files, skips `.git`, `node_modules`, the state directory and
`cache`, and visits at most 2000 files. No match prints `no matches`.

### web

`action` is `fetch` by default. `fetch` requires an `http://` or `https://`
URL and returns the capped reply text. `search` reads DuckDuckGo's JSON
endpoint and returns related topics and an abstract, up to `limit`, which
defaults to 10. It is not a web index. Both actions time out after 20 seconds.

### Result cap

A result over 8000 characters is cut to the cap and the model receives the
head plus `[truncated N characters; full result at PATH]`. The whole text is
spilled to a temporary directory under the state root when it exists, or to
`/tmp/` otherwise. `write-file`, `edit-file` and `memory` never cap their
results.

## Schemas

A schema is a Lisp form, not a JSON string. A keyword is a type, and these two
compound forms are the whole vocabulary:

```lisp
(:object
 :required (:path)
 :properties ((:path :string)
              (:from :integer)
              (:to :integer)))

(:array :items :string)
```

An object always writes `additionalProperties: false`, so an argument the
schema does not name fails the call. `:required` and `:properties` are the only
keys under `:object`; `:items` is the only key under `:array`. A malformed
declaration fails when the schema is converted, which `tools show` and the next
turn do.

`tools show NAME` prints one schema as JSON. `tools list` prints
`NAME TOKENS tokens - DESCRIPTION` for every tool registered in that process.
A command process registers the built-ins; agent tools exist in the running
supervisor, which is where the model sees them.

## The schema budget

All tool schemas in one prompt share a budget of 2000 estimated tokens, at one
token per four JSON characters. `tools list` shows each tool's estimate. Over
budget, every turn fails with `The SCHEMA budget is spent: N of 2000 tokens.`
Remove a tool, shorten a description, or shorten a schema.

## Adding a tool

For a tool the agent keeps, write a plugin under `agents/default/tools/`,
verify it, and reload; [Plugins](plugins.md) covers the rest. For an experiment
in a running image, `define-tool` registers a tool until exit and quotes the
schema, so write it unquoted.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `No tool called X.` | the name is not registered in this process | check the spelling, `tools list`, and the reload |
| `The SCHEMA budget is spent: N of 2000 tokens.` | the schemas exceed the shared budget | remove a tool or shorten its schema |
| `This tool runs in the broker.` | a proxy handler was called in the supervisor | call it through the broker, as the kernel does |
| `The broker is not running.` | a tool call before the broker started | start `serve` or `chat` |
| `Unknown block action`, `Unknown block label`, `Unknown search scope` | an argument outside the documented values | use one of the documented values |
| A bootstrap write is refused | the identity files still belong to the operator | finish the bootstrap, or edit them with the CLI |
