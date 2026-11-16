# Tools

A tool is a name, a description, one schema declaration, and one handler.
The schema becomes the JSON Schema the model reads and validates the arguments the model returns.

## The tool model

A tool is one `tool` structure.

| Field                | Type               | Default | Meaning                                                         |
| -------------------- | ------------------ | ------- | --------------------------------------------------------------- |
| `tool-name`          | string             | `""`    | The name the model sees, lowercased by the registration helpers |
| `tool-description`   | string             | `""`    | The one line the model reads                                    |
| `tool-schema`        | Lisp form          | `nil`   | The declaration described below                                 |
| `tool-handler`       | function           | `nil`   | A function of one argument table                                |
| `tool-self-test`     | function or `nil`  | `nil`   | A slot `define-tool` fills; no current code reads it             |
| `tool-generation`    | integer at least 0 | `0`     | The generation that installed the tool                          |
| `tool-broker-side-p` | boolean            | `nil`   | True when the handler lives in the broker child                 |

`make-tool` builds one, and `define-tool` registers one with its schema kept as a Lisp form.
One registry holds every built-in tool, authored tool, and agent proxy.
A later registration replaces an earlier tool, so a reload can replace a name.
[Plugins and self-modification](plugins.md) owns the plugin declaration format.

`registry-tool-definitions` returns every tool as `name`, `description`, and `parameters`, sorted by name, after the schema budget check.
The kernel calls it once per turn and passes the list to `complete` as `tools`.

## Schema declarations

A schema is a Lisp form, not a JSON string.
A keyword is a type, and a list is a compound form whose head names the type and whose tail is keyword arguments.

```lisp
(:object
 :required (:path)
 :properties ((:path :string)
              (:from :integer)
              (:to :integer)))
```

| Form                  | JSON Schema output                                           |
| --------------------- | ------------------------------------------------------------ |
| `:string`             | `{"type": "string"}`, any keyword becomes its lowercase name |
| `(:object ...)`       | `{"type": "object", "additionalProperties": false, ...}`     |
| `:required (a b)`     | `"required": ["a", "b"]`, names lowercased                   |
| `:properties ((k f))` | `"properties": {"k": <f as a schema object>}`                |
| `(:array :items f)`   | `{"type": "array", "items": <f as a schema object>}`         |

An object form always writes a `properties` key, empty when the form names none, and sets `additionalProperties` false, so a misspelled argument fails at the boundary.

The schema functions are these.

| Function               | Result                                                        |
| ---------------------- | ------------------------------------------------------------- |
| `schema-to-json`       | The schema as a hash table the JSON writer emits as an object |
| `schema-json-string`   | The schema as JSON text                                       |
| `schema-tokens`        | A token estimate, one token per four JSON characters          |
| `validate-arguments`   | True, or a `schema-error`                                     |
| `schema-error-message` | The free-form detail of a `schema-error`, or `nil`            |

Four malformed declarations signal `schema-error`.

| Condition                            | Detail                                     |
| ------------------------------------ | ------------------------------------------ |
| An unknown key under `:object`       | `Unknown object schema key ~S.`            |
| An unknown key under `:array`        | `Unknown array schema key ~S.`             |
| A list whose head is not a type      | `Unknown schema form ~S.`                  |
| A schema that is not keyword or list | `A schema is a keyword or a list, not ~S.` |

`arguments-to-json` normalizes a property list to a hash table with string keys; an absent argument object becomes an empty table; any other value signals `schema-error` with `Tool arguments must be a plist or a hash table, not ~S.`
`validate-arguments` delegates to `cl-jschema` and joins every reason with `; `.
An object schema with no properties and no required keys takes no arguments, and a call that passes one fails with `This tool takes no arguments, but it was given KEYS.`

## The schema budget

| Name                     | Value    | Meaning                                             |
| ------------------------ | -------- | --------------------------------------------------- |
| `*schema-budget*`        | 2000     | The token budget for all tool schemas in one prompt |
| `schema-tokens`          | computed | One token per four characters of the schema JSON    |
| `registry-schema-tokens` | computed | The sum over every registered tool                  |
| `schema-budget-report`   | plist    | `:used`, `:budget`, and `:remaining`                |

`registry-tool-definitions` and `registry-schema` signal `budget-exceeded` with `:spent`, `:cap`, and `:window :schema` when the sum exceeds the cap.
`schema-budget-report` returns the numbers without applying the check.

## The call path

1. `run-turn` asks `registry-tool-definitions` for the tool list when the agent holds tools.
2. The backend receives the list and the conversation in one `complete` call.
3. The completion returns text and, when the model asked, a list of tool calls.
4. `execute-tool` parses the arguments of one call as JSON.
5. A broker sends the call to the child, or `dispatch` runs it in this process when there is no broker.
6. The result becomes scrubbed text in a tool message with the call id.
7. The kernel appends the assistant message and one tool message per call, then asks the backend again.
8. The loop stops when a completion carries no calls or when `tool-rounds` is reached, which defaults to 8.

At the cap the pending calls are dropped, the turn adds a user message saying no more tools will run, and the model's next completion is the reply.
A reply with no text prints a note on standard error instead of an empty line.

A failed call becomes `error: <report> <detail>`, so the model sees why the call failed.
The kernel reports each step through `enchiridion.kernel:*turn-progress-function*`: `:request` and `:response` around each model call, `:tool-start` and `:tool-end` around each tool call, and `:round-limit` at the cap.
The CLI renders them on standard error, and an error inside the hook never fails the turn.
A string result is used as it stands, `nil` becomes the empty string, and any other value becomes JSON text when possible.

`dispatch` checks the tool name, the generation when the caller passes one, the arguments, and then the handler.
A missing name signals `not-found` with `:kind "tool"`, reported as `No tool called NAME.`
A generation mismatch is `configuration-error` at `:generation`.
A handler condition is re-signalled for an `enchiridion-error`, otherwise wrapped in `tool-error` with `:tool` and the printed condition.

## The broker

The supervisor holds the keys and the model, and agent code runs in a child process.
In a split run the child runs as the agent user; a checkout started as the operator has no split (see [Deployment](deployment.md)).
One length-prefixed JSON request and its reply cross the socket, and the process that holds the secrets never compiles or runs agent code.

| Item               | Value                                                                         |
| ------------------ | ----------------------------------------------------------------------------- |
| Default socket     | `/run/enchiridion/broker.sock`                                                |
| Child uid and gid  | 1000 and 1000                                                                 |
| Start timeout      | 30 seconds                                                                    |
| Call timeout       | 660 seconds                                                                   |
| Frame              | Four-byte big-endian length, then UTF-8 bytes                                 |
| Frame cap          | 16 MiB                                                                        |
| Request operations | `ping`, `load-generation`, and any registered tool name                       |
| Response envelope  | `{"ok": true, "result": ...}` or `{"ok": false, "error": ..., "detail": ...}` |

`make-broker` returns a descriptor with a socket, a uid, a gid, a start timeout, a call timeout, an optional log file, and a call lock; nothing starts until `broker-start`.
The daemon logs the child to `broker.log` in the run directory.
It uses `$ENCHIRIDION_HOME/run/broker.sock` when the variable is set, and `broker.sock` inside the agent directory otherwise.
`:in-process t` starts a server thread in the current process for tests and is not the security boundary.

The child runs the SBCL named by `ENCHIRIDION_SBCL`, or the supervisor's own SBCL, with `--script` on `src/broker-exec.cl`, then `--socket PATH`, `--uid N`, and `--gid N`.
Its environment carries `PATH`, `HOME`, `SBCL_HOME`, the source registry, the output translations, and the `ENCHIRIDION_*` variables the child needs. No secret is inherited.

`src/broker-exec.cl` loads the system, registers the built-in tools, installs the plugin loader as `*load-generation-function*`, and serves the socket.
It clears supplementary groups, sets the gid, then the uid, when it runs as root.
`ping` answers `ok`, `load-generation` calls the loader and answers its report, and every other operation is a tool name dispatched through `dispatch`.
A result is scrubbed before it returns.

`broker-verify-plugin` runs the same child with `--verify-plugin DIRECTORY --uid N --gid N` and returns whether it exited zero plus its output.
The main mode requires `--socket` and prints `broker-exec: --socket PATH is required.` with exit 2 when it is absent.

A start waits until the socket answers, a child that exits first stops the wait, and either failure names the last 20 log lines.
`broker-call` holds the call lock for the write and the read, so two callers cannot interleave frames.
`broker-health` is true when a `ping` answers `ok`.
See [Plugins and self-modification](plugins.md) for the reload path that uses `load-generation`.

## Built-in tools

`register-builtin-tools` calls seven registrars and registers eleven tools.

| Tool         | Required             | Optional                                                                  |
| ------------ | -------------------- | ------------------------------------------------------------------------- |
| `index`      | `path`               | none                                                                      |
| `read-file`  | `path`               | `from`, `to`                                                              |
| `write-file` | `path`, `text`       | none                                                                      |
| `edit-file`  | `path`, `old`, `new` | none                                                                      |
| `glob`       | `pattern`            | none                                                                      |
| `shell`      | `command`            | `timeout`                                                                 |
| `search`     | `query`              | `scope`, `path`, `limit`                                                  |
| `blockops`   | none                 | `action`, `label`, `old`, `new`, `text`, `directory`                      |
| `memory`     | `name`, `text`       | none                                                                      |
| `meta`       | none                 | `action`, `directory`, `limit`, `name`, `kind`, `text`, `confirm`, `step` |
| `web`        | none                 | `action`, `url`, `query`, `limit`                                         |

### The result cap

Eight of the eleven tools pass at least one result through `cap-result`.
The tools that never cap are `write-file`, `edit-file`, and `memory`, whose results are short by construction.

| Name              | Value                                                                   |
| ----------------- | ----------------------------------------------------------------------- |
| `+result-cap+`    | 8000 characters                                                         |
| Spill directory   | `$ENCHIRIDION_HOME/tmp/` when that state root exists, otherwise `/tmp/`  |
| Spill file name   | `spill-N.txt` for a random integer N                                    |
| Truncation marker | `[truncated N characters; full result at PATH]` appended after the head |

A result at or under the cap is returned unchanged; a longer result is cut to the cap and the model receives the head plus a path to the whole text.

### index

`index` lists the top-level forms of a Lisp file with the line range of each.
`path` is required.
The result starts with `PATH: N top level form` with the plural when the count is not one, then one line per form as `START-END SKELETON`.
A definition form prints its head and name, as `(defun name ...)`; any other list prints its head, as `(let ...)`; a non-list prints its value.
The reader binds `*read-eval*` to nil and uses a throwaway package, so an evaluated reader macro in an agent file cannot execute code.
A file that cannot be read becomes a `tool-error`.

### read-file

`read-file` returns a 1-based, inclusive line range.
`path` is required, `from` defaults to 1, and `to` defaults to the last line.
A range outside the file signals `schema-error` with `Line range ~D..~D is outside ~D lines.`
The result is the selected lines joined by newlines and capped.

### write-file

`write-file` writes text to a file and creates the parent directories.
`path` and `text` are required; a non-string `text` signals `schema-error` with `text must be a string.`
The result is `wrote N characters to PATH`.

### edit-file

`edit-file` replaces one unique occurrence of a string.
`path`, `old`, and `new` are required.
An empty `old` signals `schema-error` with `old must be a non-empty string.`
`old` that does not occur signals `tool-error` with `The old text does not occur in the file.`
`old` that occurs twice or more signals `tool-error` with `The old text occurs more than once; make it unique.`
The result is `edited PATH`.

### glob

`glob` lists the paths that match a wildcard pattern.
`pattern` is required; a non-string signals `schema-error` with `pattern must be a string.`
The result is one path per line, and a pattern that matches nothing returns the empty string.

### shell

`shell` runs a command through `/bin/sh -c` under a time limit.
`command` is required, and `timeout` defaults to 30 seconds and is clamped to 1 through 600.
A non-string command signals `schema-error` with `command must be a string.`
A normal exit ends the result with `[exit N]`; a command past the deadline ends it with `[timed out after N seconds]` after the child and everything it started is ended.
The result is the combined output, the status line, and the cap.
The broker child runs this tool, not the supervisor.

### search

`search` reads the memory store or walks the agent's text files.
`query` is required; an empty query signals `schema-error` with `query must be a non-empty string.`
`limit` defaults to 20 for the store and 40 for files; a non-positive or non-integer limit signals `limit must be a positive integer.`
`scope` defaults to `memory`; `files` selects the walk, and an unknown scope signals `Unknown search scope ~A.`
A `path` argument selects the file walk whatever `scope` says.

The store scope opens the store only when the file already has the SQLite header, so a search never creates one.
It returns one line per hit as `session SESSION ROLE: TEXT` or `memory NAME: TEXT`, flattens the body to one line, and cuts it to 400 characters with ` ...` when longer.
No match returns `no matches`.

The file scope visits `md`, `txt`, `cl`, `lisp`, `json`, and `org` files, skips `.git`, `node_modules`, `run`, and `cache`, and visits at most 2000 files.
It matches each line case-insensitively as `PATH:LINE: TEXT` and skips a file that raises a file error.
The default root is `path`, then `$ENCHIRIDION_HOME/agents/default/`, then the default pathname.

### memory

`memory` saves one named memory in the store that `search` reads.
`name` and `text` are required; an empty name signals `name must be a non-empty string.`, and a non-string text signals `text must be a string.`
The result is `saved memory NAME as ID`.
The store's own empty and duplicate refusals belong to [Memory](memory.md).

### blockops

`blockops` reads and changes the Markdown memory blocks.
`action` defaults to `list`, and `directory` defaults to the agent directory.
`label` is required for `read`, `patch`, and `add`; `old` and `new` are required for `patch`; `text` is required for `add`.

| Label      | File          |
| ---------- | ------------- |
| `soul`     | `SOUL.md`     |
| `persona`  | `SOUL.md`     |
| `operator` | `OPERATOR.md` |
| `world`    | `WORLD.md`    |

`list` prints one line per label as `LABEL SIZE/LIMIT PATH`.
`read` returns the block text, or the empty string when the file is absent.
`patch` replaces one unique occurrence and answers `patched PATH`.
`add` appends a newline and the text, or writes the text when the block is empty, and answers `added to PATH`.

| Condition                          | Signal                                                                                    |
| ---------------------------------- | ----------------------------------------------------------------------------------------- |
| Unknown action                     | `schema-error`, detail `Unknown block action ~A.`                                         |
| Unknown label                      | `schema-error`, detail `Unknown block label ~A.`                                          |
| A missing `label`                  | `schema-error`, detail `label is required.`                                               |
| An empty or non-string `old`       | `schema-error`, detail `old must be a non-empty string.`                                  |
| A missing `new` for `patch`        | `tool-error` for `blockops` with the printed type condition                               |
| `old` does not occur in the block  | `tool-error` for `blockops`, detail `The old text does not occur in the block.`           |
| `old` occurs more than once        | `tool-error` for `blockops`, detail `The old text occurs more than once; make it unique.` |
| `text` is not a string             | `schema-error`, detail `text must be a string.`                                           |
| The text exceeds the label's limit | `block-overflow` with `:label`, `:current`, and `:wanted`                                 |
| The text fails the injection scan  | The condition the scan signals                                                            |
| Bootstrap still owns a seed file   | `bootstrap-pending` with `:label`                                                         |

The scan, the limit, and the bootstrap check run before the file is written, and the write happens last.
The CLI writes seed files directly and does not pass through this gate.

> **Important:** The block and file tools honour the bootstrap gate.
> `write-file` and `edit-file` refuse the three identity paths while it is pending.
> `shell` does not check it, and the gate reads the `directory` argument, so a caller that names another directory is not gated by the agent's bootstrap.
> The gate is a rule the agent follows, not a sandbox boundary.

### meta

`meta` acts on the agent repository.
`action` defaults to `journey`; `directory` defaults to the agent directory; `limit` defaults to 20; `kind` defaults to `tool`.
`name` and `text` are required for `author`, `confirm` for `undo`, and `step` for `bootstrap-step`.

`journey` returns `git log --oneline -n LIMIT`, with a 20 second limit, capped.
`author` writes one file and commits it when the directory is a repository: `tool` writes `tools/NAME.cl`, `skill` writes `skills/NAME.md`.
The result is `wrote PATH`, `wrote PATH and committed NONE`, or `wrote PATH and committed HASH`.
`bootstrap-step` records one step and answers `bootstrap step N recorded. STATUS.`
`undo` reverts the last commit with `git revert --no-edit HEAD` and returns the capped output.
`reload` appends one line to the control file and answers `reload requested in PATH`.

| Condition                               | Signal                                                                                     |
| --------------------------------------- | ------------------------------------------------------------------------------------------ |
| Unknown action                          | `schema-error`, detail `Unknown meta action ~A.`                                           |
| A name outside `[A-Za-z0-9_-]+`         | `schema-error`, detail `name must be one segment of letters, digits, dash, or underscore.` |
| A kind other than `tool` or `skill`     | `schema-error`, detail `kind must be tool or skill.`                                       |
| A missing or unknown bootstrap step     | `schema-error`, detail `step must be a positive integer.` or `There is no bootstrap step N.` |
| `text` is not a string                  | `schema-error`, detail `text must be a string.`                                            |
| The authored file already exists        | `tool-error` for `meta`, detail `PATH already exists.`                                     |
| `undo` without `confirm` equal to `yes` | `schema-error`, detail `undo requires confirm yes.`                                        |
| A Git command times out                 | `tool-error` for `meta`, detail `git log timed out.` or `git revert timed out.`            |
| A Git command fails                     | `tool-error` for `meta` with the command output                                            |

A directory that is not a repository is not an error for `author`: the file is written and the commit is skipped.
A commit failure is silent, so a host with no identity cannot cost the operator the reply.

### web

`web` fetches a URL or searches the web.
`action` defaults to `fetch`; `url` is required for `fetch`, `query` for `search`, and `limit` defaults to 10.

`fetch` requires a `url` that starts with `http://` or `https://`, or signals `url must start with http:// or https://.`
`search` requires a non-empty `query`, or signals `query must be a non-empty string.`
An unknown action signals `schema-error` with `Unknown web action ~A.`
Both actions use a 20 second timeout.
`fetch` returns the capped reply text.
`search` reads the DuckDuckGo JSON endpoint and returns related topics and an abstract, one per line, up to the limit; it is not a full search index.
No result returns `no results`.
An HTTP failure becomes `tool-error` for `web` with `HTTP STATUS: BODY`, and any other transport failure becomes the same condition with the printed condition.

## Adding a tool

### In a running image

Start `nix develop`, start `sbcl`, and load the system with `(asdf:load-system "enchiridion")`.
Define the handler, register the tool with `define-tool`, and exercise it.
The schema argument is unquoted, because the macro quotes it.

```lisp
(defun count-words (arguments)
  (let ((count 0)
        (in-word nil))
    (with-open-file (stream (gethash "path" arguments)
                            :direction :input
                            :external-format :utf-8)
      (loop for character = (read-char stream nil nil)
            while character
            do (cond ((member character '(#\Space #\Tab #\Newline #\Return))
                      (setf in-word nil))
                     ((not in-word)
                      (incf count)
                      (setf in-word t)))))
    (format nil "~D words" count)))

(enchiridion.tools:define-tool "word-count"
  :description "Count the words in a file."
  :schema (:object
           :required (:path)
           :properties ((:path :string)))
  :handler #'count-words)
```

`(enchiridion.tools:dispatch "word-count" '(:path "README.md"))` runs one call.
A call with no arguments signals `schema-error`, because `path` is required, and an unknown argument also fails.
A tool registered this way lives until the image exits and does not reach another process.

### As a built-in

1. Create the file under `src/enchiridion/tools/builtin/` and add it to `enchiridion.asd`.
2. Write one handler that takes the argument table and returns a string.
3. Build each tool with `enchiridion.tools:make-tool` and a quoted schema, and collect them in a list.
4. Write a `register-NAME-tools` function that registers each and returns the count.
5. Add that function to `register-builtin-tools` in `register.cl`.
6. Run `nix run .#check` and `nix run .#test`.
7. Run `nix run .#enchiridion -- tools list` and confirm the name, token estimate, and description.

The handler receives a hash table with string keys.
The helper `argument` in `file.cl` reads a key from a table or a property list, so a handler is usable from a test that holds the plist directly.
A built-in is registered in the supervisor and in the broker child, which calls `register-builtin-tools` before it serves its first request.

## The registry reference

| Name                        | Result                                                    |
| --------------------------- | --------------------------------------------------------- |
| `registry`                  | The live hash table                                       |
| `register-tool`             | Adds a tool and returns it                                |
| `find-tool`                 | The tool with that name, or nil                           |
| `tool-names`                | Every name, sorted                                        |
| `list-tools`                | Every tool, sorted by name                                |
| `unregister-tool`           | True when the name was present                            |
| `clear-registry`            | Removes every tool, for tests                             |
| `dispatch`                  | Validates the arguments and calls one handler             |
| `registry-schema`           | Every tool as one JSON array                              |
| `registry-tool-definitions` | Every tool as a definition object, after the budget check |
| `schema-budget-report`      | The `:used`, `:budget`, and `:remaining` plist            |
| `define-tool`               | Registers a tool and keeps a quoted schema                |
| `make-tool`                 | Builds a tool structure                                   |

`tools list` prints the name, token estimate, and description of every registered tool; `tools show NAME` prints one schema as JSON (see [Commands](commands.md)).
`tool-definition`, `normalize-tool-name`, `arguments-to-json`, and `registry-schema-tokens` are internal helpers.
The registry uses `equal`, so a name is a lowercase string and two spellings cannot coexist.

## The pipe sandbox

The pipe module filters lines of text with one Lisp expression, so a filter costs no tokens and no model call.

The line variable is `$`, and `NTH4` returns the fifth whitespace-separated field, as an integer when it parses as one.
A filter may use only these names:

```text
$ FILTER NTH4 NTH FIRST SECOND THIRD LENGTH SUBSEQ SEARCH PARSE-INTEGER
STRING-UPCASE STRING-DOWNCASE STRING= STRING< STRING> PRINC-TO-STRING
FORMAT LIST IDENTITY IF AND OR NOT NULL T NIL
= /= > < >= <= + - * /
```

The sandbox package uses `common-lisp`, so the walker is the boundary.
`check-form` walks the whole form before any evaluation, and a symbol outside the list signals `schema-error` with `Filter symbol ~A is not allowed.`
A form that names `system`, `load`, or `eval` fails even though the package holds those functions.
`make-sandbox` creates a fresh package for one filter, with `$` as a special variable and `NTH4` as a function.

| Function         | Result                                                    |
| ---------------- | --------------------------------------------------------- |
| `read-filter`    | One checked form, reading with `*read-eval*` bound to nil |
| `filter-form`    | The expression inside `(filter ...)`, or the form itself  |
| `make-sandbox`   | A fresh package holding `$` and `NTH4`                    |
| `pipe-safe-eval` | The value of one form with `$` bound to one line          |
| `pipe-eval`      | The lines whose filter value is true                      |

`read-filter` accepts exactly one form; an empty string signals `The filter is empty.` and a second form signals `The filter has more than one form.`
`pipe-eval` accepts a filter string, a form, or a function of one line; it splits on newlines, skips empty lines, and writes each kept line with its newline.
No built-in tool takes a filter argument and no production code calls the module, so an authored tool can reach it from Lisp.

## Troubleshooting

| Symptom                                                 | Cause                                         | Fix                                                        |
| ------------------------------------------------------- | --------------------------------------------- | ---------------------------------------------------------- |
| `No tool called X.`                                     | The name is not registered in this process    | Check the spelling, `tools list`, and the reload           |
| `This tool runs in the broker.`                         | A proxy handler was called in the supervisor  | Call the tool through `broker-call`, which the kernel does |
| `The SCHEMA budget is spent: ...`                       | The schemas exceed `*schema-budget*`          | Remove a tool, shorten a description, or raise the budget  |
| `The broker is not running.`                            | The call was made before `broker-start`       | Start the broker or the supervisor                         |
| `The broker did not start before the timeout.`          | The child never bound the socket              | Read `run/broker.log`, and check `ENCHIRIDION_SBCL`        |
| `Unknown block action`, `Unknown block label`, or `Unknown search scope` | An argument outside the documented values | Use one of the documented values                           |

## See also

- [Plugins and self-modification](plugins.md): the manifest, the verification report, and the loader behind a reload.
- [Commands](commands.md): `tools`, `reload`, and exit statuses.
- [Configuration](configuration.md): the sandbox uid and the memory paths the tools read.
- [Memory](memory.md): the store behind `search`, the block limits behind `blockops`, and the bootstrap gate.
