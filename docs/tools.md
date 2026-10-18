# Tools

A tool is a name, a description, one schema, and one handler. The kernel sends
every registered tool to the model as JSON. When the model asks for a call, the
kernel runs that call through the broker or through the registry. The builtin
tools live under `src/enchiridion/tools/builtin/`. One registry holds every
tool for the whole process, so a builtin and an agent tool share one namespace.

## The tool declaration

`make-tool` builds a tool struct. `define-tool` registers one and keeps the
schema as a Lisp form.

| Field           | Type     | Meaning                                   |
| --------------- | -------- | ----------------------------------------- |
| `name`          | string   | The lookup key, in lowercase.             |
| `description`   | string   | The one line the model reads.             |
| `schema`        | form     | The declaration below.                    |
| `handler`       | function | The function that dispatch calls.         |
| `self-test`     | function | The function that verification calls.     |
| `generation`    | integer  | The generation that installed the tool.   |
| `broker-side-p` | boolean  | True when the handler lives in the child. |

The plugin loader builds the same struct, so an agent tool and a builtin tool
are the same object to the registry.

## The schema

The schema is a small Lisp form, not a JSON string. The same form builds the
JSON Schema for the model and validates the arguments that come back. One
source means the two cannot drift.

```lisp
(:object :required (:path)
 :properties ((:path :string)
              (:from :integer)
              (:to :integer)))
```

| Form                  | JSON Schema        | Note                               |
| --------------------- | ------------------ | ---------------------------------- |
| `:string`             | `"type": "string"` | A keyword is a type.               |
| `(:object ...)`       | `"type": "object"` | Adds `additionalProperties` false. |
| `(:array :items F)`   | `"type": "array"`  | Items holds one schema form.       |
| `:required (a b)`     | `"required"`       | Names sit in a list.               |
| `:properties ((k F))` | `"properties"`     | Each pair is a name and a form.    |

An unknown object key, an unknown array key, and a form that is not a keyword
or a list all signal `schema-error`. The object form sets
`additionalProperties` false, because a tool that ignores a misspelled
argument runs with the wrong argument and reports success.

| Function               | Result                                     |
| ---------------------- | ------------------------------------------ |
| `schema-to-json`       | The schema as a hash table.                |
| `schema-json-string`   | The schema as JSON text.                   |
| `schema-tokens`        | A token estimate, one per four characters. |
| `arguments-to-json`    | The arguments as a hash table.             |
| `validate-arguments`   | True, or `schema-error` with the reasons.  |
| `schema-error-message` | The detail string of a `schema-error`.     |

`validate-arguments` passes the JSON text to `cl-jschema`. A failure carries
the JSON pointer and the reason, so the model can correct the call.

## The schema budget

`*schema-budget*` is 2000 tokens. The budget is a soft cap for a report and a
hard cap at the model boundary.

| Function                    | Result                                          |
| --------------------------- | ----------------------------------------------- |
| `registry-schema-tokens`    | The estimate for every tool.                    |
| `schema-budget-report`      | A plist of `:used`, `:budget`, `:remaining`.    |
| `registry-tool-definitions` | Every tool for the model, or `budget-exceeded`. |
| `registry-schema`           | Every tool as one JSON array.                   |

`registry-tool-definitions` checks the budget. A registry over the cap signals
`budget-exceeded` with `:cap` and `:window :schema`, and the turn stops there.

## How a tool is called

1. `run-turn` asks `registry-tool-definitions` for the tool list.
2. The backend answers with a completion that holds tool calls.
3. `execute-tool` parses the JSON arguments of one call.
4. A broker sends the call over the socket. No broker means local dispatch.
5. The result becomes scrubbed text in a tool message.
6. The kernel sends the message back and lets the model answer again.

The loop stops after `tool-rounds`, which defaults to 8. An agent with
`tools-p` false sends no tool list at all.

A tool error becomes text in the transcript, not a broken turn. The text
starts with `error: `, and the model can correct the call.

`dispatch` fails in four named ways.

| Failure                    | Condition                                       |
| -------------------------- | ----------------------------------------------- |
| The name is unknown        | `not-found`, with `:kind "tool"`.               |
| The generation is wrong    | `configuration-error`, with `:key :generation`. |
| The arguments do not match | `schema-error`.                                 |
| The handler signals        | `tool-error`, with `:tool`.                     |

A handler that signals an `enchiridion-error` keeps its own condition. Any
other error becomes `tool-error`, so the caller never guesses which layer
failed.

## The registry

| Function              | Result                                 |
| --------------------- | -------------------------------------- |
| `registry`            | The live hash table.                   |
| `register-tool`       | Adds a tool and returns it.            |
| `find-tool`           | The tool, or NIL.                      |
| `tool-names`          | Every name, sorted.                    |
| `list-tools`          | Every tool, sorted by name.            |
| `unregister-tool`     | True when the name was there.          |
| `clear-registry`      | Removes every tool. Tests use this.    |
| `normalize-tool-name` | The lowercase string form of a name.   |
| `tool-definition`     | One tool as a model definition object. |
| `dispatch`            | Validates and calls one tool.          |

A later registration with the same name replaces the earlier tool. That is
what a reload needs, and it is also how a plugin shadows a builtin.

## The pipe and the filter language

A filter keeps or drops lines of shell output. The filter is one Lisp
expression, so the same work costs no tokens and no model call.

`pipe-eval` returns the lines for which the filter is true, with one newline
after each.

The line variable is `$`. The helper `NTH4` returns the fifth whitespace
field, as an integer when it parses.

```lisp
(> (length $) 20)
(search "error" $)
(string= (nth4 $) "200")
```

A form may use only these names.

```text
$ FILTER NTH4 NTH FIRST SECOND THIRD LENGTH SUBSEQ SEARCH PARSE-INTEGER
STRING-UPCASE STRING-DOWNCASE STRING= STRING< STRING> PRINC-TO-STRING
FORMAT LIST IDENTITY IF AND OR NOT NULL T NIL
= /= > < >= <= + - * /
```

| Function           | Result                                          |
| ------------------ | ----------------------------------------------- |
| `read-filter`      | One checked form, or `schema-error`.            |
| `check-form`       | Walks a form and rejects a foreign symbol.      |
| `allowed-symbol-p` | True for the line variable and the names above. |
| `filter-form`      | The expression inside `(filter ...)`.           |
| `make-sandbox`     | A fresh package that holds `$` and `NTH4`.      |
| `pipe-safe-eval`   | One form with `$` bound to one line.            |
| `pipe-eval`        | The text with only the kept lines.              |

`read-filter` binds `*read-eval*` to NIL. An empty filter and a string with
two forms both fail.

`check-form` runs before `eval`, so a form that names `system` or `load` fails
even though the sandbox package uses CL.

`make-sandbox` makes one package per filter. A later filter cannot see a
binding from an earlier one.

Limit: no builtin tool takes a filter argument in this version. The pipe
module is exported and `t/core/pipe-test.cl` covers it. A caller reaches it
from Lisp.

## The broker and the sandbox boundary

The supervisor holds the secrets and the model. Agent code runs in a child
process as uid 1000. Only a length prefixed JSON request and its response
cross the line. The supervisor never loads the code of the child and never
sends a secret in a request.

| Item           | Value                                          |
| -------------- | ---------------------------------------------- |
| Default socket | `/run/enchiridion/broker.sock`                 |
| Child uid      | 1000                                           |
| Frame          | Four byte big endian length, then UTF-8 bytes. |
| Frame cap      | 16 MiB                                         |
| Operations     | `ping`, `load-generation`, and any tool name.  |
| `ping` reply   | The string `ok`.                               |

`make-broker` accepts a `:socket` argument, and the daemon passes its own
path. The daemon uses `$ENCHIRIDION_HOME/run/broker.sock` when that variable
is set, and `broker.sock` inside the agent directory when it is not.

`broker-exec.cl` is the child. It drops the uid when it runs as root, registers
the builtin tools, sets `*load-generation-function*`, and serves the socket.
The environment of the child comes from `child-environment`, which sets `PATH`
and `HOME` and copies a short list of names. Nothing else is inherited.

| Function                    | Result                                         |
| --------------------------- | ---------------------------------------------- |
| `make-broker`               | A descriptor. Nothing starts yet.              |
| `broker-start`              | Starts the child, or a test server in process. |
| `broker-stop`               | Closes the socket, the thread, and the child.  |
| `broker-call`               | Sends one operation and returns its result.    |
| `broker-health`             | True when a ping answers.                      |
| `broker-verify-plugin`      | Verifies a directory in a one-shot child.      |
| `broker-load-generation`    | Asks the child to load a generation.           |
| `serve-broker`              | Binds a socket and serves. Child entry point.  |
| `write-frame`, `read-frame` | The wire format.                               |

`broker-call` holds one lock, because a request is one frame out and one frame
back on one stream. Two callers at once would interleave and one would read
the wrong answer. The broker scrubs every string in a result before it writes
the response.

Limit: `broker-call` accepts `:timeout` and does not enforce it on the socket
read. The caller sets a process deadline around the call instead.

## Builtin tools

`register-builtin-tools` calls six registrars. It registers ten tools.

| Tool         | Required             | Optional                                                          |
| ------------ | -------------------- | ----------------------------------------------------------------- |
| `index`      | `path`               | none                                                              |
| `read-file`  | `path`               | `from`, `to`                                                      |
| `write-file` | `path`, `text`       | none                                                              |
| `edit-file`  | `path`, `old`, `new` | none                                                              |
| `glob`       | `pattern`            | none                                                              |
| `shell`      | `command`            | `timeout`                                                         |
| `search`     | `query`              | `scope`, `path`, `limit`                                          |
| `blockops`   | none                 | `action`, `label`, `old`, `new`, `text`, `directory`              |
| `meta`       | none                 | `action`, `directory`, `limit`, `name`, `kind`, `text`, `confirm` |
| `web`        | none                 | `action`, `url`, `query`, `limit`                                 |

Most results pass through `cap-result`. `+result-cap+` is 8000 characters. A
larger result spills to a file, and the model gets the head and the path.

### index

Reads the top level forms of a Lisp file with the line range of each. The
reader binds `*read-eval*` to NIL and uses a throwaway package. A path that
will not read becomes a tool error.

### read-file

Reads a 1-based inclusive line range. `from` defaults to 1 and `to` defaults
to the last line. A range outside the file signals `schema-error`.

### write-file

Writes `text` to `path` and creates the parent directories. `text` must be a
string. The result names the character count and the path.

### edit-file

Replaces one occurrence of `old` with `new`. An empty `old` is a schema error.
An `old` that is absent, or that occurs more than once, is a tool error.

### glob

Returns the paths that match `pattern`, one per line. A pattern with no match
returns an empty string. `pattern` must be a string.

### shell

Runs `command` through `/bin/sh -c`. `timeout` defaults to 30 seconds. The
result holds the combined output and the exit status in brackets, or a timeout
line that names the number of seconds.

### search

Searches the store or the agent's text files. `scope` is `memory` by default
and accepts `files`. A `path` argument selects the files scope. `limit`
defaults to 20 for the store and 40 for the files.

The store scope reads the sessions and the memories, and it opens the store
only when the file is already a database. A store hit is one line, cut at 400
characters. The files scope reads `.md`, `.txt`, `.cl`, `.lisp`, `.json`, and
`.org` files. It skips `.git`, `node_modules`, `run`, and `cache`, and it
visits at most 2000 files. Each file hit is one line with its path and line
number.

Refusals: an empty `query`, a `limit` that is not a positive integer, and an
unknown scope.

### blockops

Reads and edits the memory blocks. `action` is `list` by default and accepts
`read`, `patch`, and `add`.

| Label      | File          |
| ---------- | ------------- |
| `soul`     | `SOUL.md`     |
| `persona`  | `SOUL.md`     |
| `operator` | `OPERATOR.md` |
| `world`    | `WORLD.md`    |

`list` shows each block with its size and limit. `read` returns the text.
`patch` replaces one unique occurrence. `add` appends a line.

Refusals: an unknown action, a missing `label`, an unknown label, an empty
`old`, and an `old` that is absent or not unique. A `text` that is not a
string also fails.

A write fails in three more cases. The text is over the limit for the label.
The block scan rejects the text. Bootstrap still owns a seed file.

### meta

Acts on the agent repository. `action` is `journey` by default and accepts
`author`, `undo`, and `reload`. `limit` defaults to 20.

`journey` returns the last commits from `git log --oneline`.

`author` writes a `.cl` file under `tools/` or a `.md` file under `skills/`.
It commits the file when the directory is a repository.

`undo` reverts the last commit. `reload` appends one line to the control file.

Refusals: an unknown action, a `name` outside `[A-Za-z0-9_-]+`, a `kind`
that is not `tool` or `skill`, and a file that exists.

An `undo` also needs `confirm` set to `yes`. A git command that fails or times
out is a tool error.

### web

Fetches a URL or searches. `action` is `fetch` by default and accepts
`search`. `limit` defaults to 10.

`fetch` requires a `url` that starts with `http://` or `https://`. `search`
requires a non-empty `query`. Both use a 20 second timeout. An unknown action
signals `schema-error`. The search reads the DuckDuckGo JSON endpoint, so it
returns related topics and an abstract, not a full index.

## Related

- [Plugins and self-modification](plugins.md)
- [Configuration](configuration.md)
- [Commands](commands.md)
- [Memory](memory.md)
- [Development](development.md)
