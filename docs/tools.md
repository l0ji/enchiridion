# Tools

A tool is a name, a description, one schema declaration, and one handler.
The schema does two jobs: it becomes the JSON Schema the model reads, and it validates the arguments the model returns.
An operator can read every argument, result, and error of the built-in tools.
A developer can declare a tool, register it, run it, and reload an agent generation that contains it.

## The tool model

A tool is one `tool` structure.

| Field                | Type               | Default | Meaning                                                         |
| -------------------- | ------------------ | ------- | --------------------------------------------------------------- |
| `tool-name`          | string             | `""`    | the name the model sees, lowercased by the registration helpers |
| `tool-description`   | string             | `""`    | the one line the model reads                                    |
| `tool-schema`        | Lisp form          | nil     | the declaration described below                                 |
| `tool-handler`       | function           | nil     | a function of one argument table                                |
| `tool-self-test`     | function or nil    | nil     | a slot `define-tool` can fill and no current code reads         |
| `tool-generation`    | integer at least 0 | 0       | the generation that installed the tool                          |
| `tool-broker-side-p` | boolean            | nil     | true when the handler lives in the broker child                 |

`make-tool` builds one, and `define-tool` registers one with its schema kept as a Lisp form.
One registry holds every tool in the process.
A later registration replaces an earlier tool, so a reload can replace a name.
Built-in tools, authored tools, and agent proxies share that one registry.
`plugins.md` owns the plugin declaration format.

### How the model sees a tool

`registry-tool-definitions` returns every tool as a definition object with `name`, `description`, and `parameters`, sorted by name, after the schema budget check.
The kernel calls it once per turn and passes the list to `complete` as the `tools` keyword.
The OpenAI wire wraps each definition as `{"type": "function", "function": {...}}`.
The Messages wire flattens it and renames `parameters` to `input_schema`, and `llm.md` owns both shapes.

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

An object form sets `additionalProperties` to false, so a misspelled argument fails at the boundary.
A `:properties` value of nil writes no properties key, and an empty parts list is still an object schema.

The schema functions are these.

| Function               | Result                                                        |
| ---------------------- | ------------------------------------------------------------- |
| `schema-to-json`       | the schema as a hash table the JSON writer emits as an object |
| `schema-json-string`   | the schema as JSON text                                       |
| `schema-tokens`        | a token estimate, one token per four JSON characters          |
| `validate-arguments`   | true, or a `schema-error` with every reason                   |
| `schema-error-message` | the free-form detail of a `schema-error`, or nil              |

Four malformed declarations signal `schema-error` with these details.

| Condition                            | Detail                                     |
| ------------------------------------ | ------------------------------------------ |
| An unknown key under `:object`       | `Unknown object schema key ~S.`            |
| An unknown key under `:array`        | `Unknown array schema key ~S.`             |
| A list whose head is not a type      | `Unknown schema form ~S.`                  |
| A schema that is not keyword or list | `A schema is a keyword or a list, not ~S.` |

### Argument validation

`arguments-to-json` normalizes JSON arguments and a Lisp property list to a hash table with string keys.
An absent argument object becomes an empty table.
A value that is neither a list nor a table signals `schema-error` with the detail `Tool arguments must be a plist or a hash table, not ~S.`

`validate-arguments` parses the schema's JSON text and delegates the check to `cl-jschema`.
A failure becomes a `schema-error` whose detail joins every reported reason with `; `.
Each reason carries its JSON pointer, so the model can correct the call.

## The schema budget

| Name                     | Value    | Meaning                                             |
| ------------------------ | -------- | --------------------------------------------------- |
| `*schema-budget*`        | 2000     | the token budget for all tool schemas in one prompt |
| `schema-tokens`          | computed | one token per four characters of the schema JSON    |
| `registry-schema-tokens` | computed | the sum over every registered tool                  |
| `schema-budget-report`   | plist    | `:used`, `:budget`, and `:remaining`                |

`registry-tool-definitions` signals `budget-exceeded` with `:spent`, `:cap`, and `:window :schema` when the sum exceeds the cap, and the report is `The ~A budget is spent: ~D of ~D tokens.`
`registry-schema` returns every definition as one JSON array and applies the same check.
`schema-budget-report` returns the numbers without applying the check, so its report can exceed the cap.

## The call path

The kernel runs a call in a fixed order.

1. `run-turn` asks `registry-tool-definitions` for the tool list when the agent holds tools.
2. The backend receives the list and the conversation in one `complete` call.
3. The completion returns text and, when the model asked, a list of tool calls.
4. `execute-tool` parses the arguments of one call as JSON.
5. A broker sends the call to the child, or `dispatch` runs it in this process when there is no broker.
6. The result becomes scrubbed text in a tool message with the call id.
7. The kernel appends the assistant message and one tool message per call, then asks the backend again.
8. The loop stops when a completion carries no calls or when `tool-rounds` is reached, which defaults to 8.

A string result is used as it stands, nil becomes the empty string, and any other value becomes JSON text when possible.
A handler error becomes text that starts with `error: `, so one bad call costs one round and not the turn.

### Dispatch failures

`dispatch` checks four things in order and signals a named condition for each.

| Condition                              | Signal                                                                                                         |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| The tool name is unknown               | `not-found` with `:kind "tool"`, reported as `No tool called NAME.`                                            |
| The generation is not the expected one | `configuration-error` at `:generation`, detail `Tool ~A is generation ~D, not ~D.`                             |
| The arguments do not match the schema  | `schema-error` with the validation reasons                                                                     |
| The handler signals                    | the condition itself for an `enchiridion-error`, otherwise `tool-error` with `:tool` and the printed condition |

The generation check runs only when a caller passes the `generation` keyword, and no call path in this tree passes it.

## The broker and the sandbox boundary

The supervisor holds the keys and the model, and agent code runs in a child process.
In the container deployment the child runs as the agent user, uid 1000.
A checkout has no uid split: the child runs as the operator's user and keeps that user's file rights (see [Deployment](deployment.md)).
Only one length-prefixed JSON request and its reply cross the line, and the process that holds the secrets never compiles or runs agent code.

| Item               | Value                                                                         |
| ------------------ | ----------------------------------------------------------------------------- |
| Default socket     | `/run/enchiridion/broker.sock`                                                |
| Default child uid  | 1000                                                                          |
| Frame              | four-byte big-endian length, then UTF-8 bytes                                 |
| Frame cap          | 16 MiB                                                                        |
| Request operations | `ping`, `load-generation`, and any registered tool name                       |
| `ping` reply       | the string `ok`                                                               |
| Response envelope  | `{"ok": true, "result": ...}` or `{"ok": false, "error": ..., "detail": ...}` |

`make-broker` returns a descriptor with a socket, a uid, a timeout of 30 seconds, and a call lock, and nothing starts until `broker-start`.
The daemon passes its own socket path: `$ENCHIRIDION_HOME/run/broker.sock` when the variable is set, and `broker.sock` inside the agent directory when it is not.

`broker-start` starts the child by default.
`:in-process t` starts a server thread in the current process for tests, and it is not the security boundary.

The child runs the SBCL named by `ENCHIRIDION_SBCL`, or `sbcl`, with `--script` on the installed `src/broker-exec.cl`, then `--socket PATH` and `--uid N`.
Its environment holds `PATH` as `/usr/local/bin:/usr/bin:/bin` and `HOME` as `ENCHIRIDION_HOME` or `/tmp`, plus `SBCL_HOME`, `CL_SOURCE_REGISTRY`, `ENCHIRIDION_HOME`, `ENCHIRIDION_SOURCE`, `ENCHIRIDION_SBCL`, `LD_LIBRARY_PATH`, `XDG_CACHE_HOME`, and `XDG_CONFIG_HOME` when they are set.
No other variable is inherited, so a key in the supervisor's environment cannot reach the child, and `broker-verify-plugin` uses the same environment for its one-shot child.

### The broker functions

| Function                 | Result                                                                             |
| ------------------------ | ---------------------------------------------------------------------------------- |
| `make-broker`            | a descriptor, with nothing started                                                 |
| `broker-start`           | starts the child or the in-process server and returns the descriptor               |
| `broker-stop`            | closes the stream, the server, the thread, and the child, and removes the socket   |
| `broker-call`            | sends one operation and returns its result                                         |
| `broker-running-p`       | true after a successful start                                                      |
| `broker-health`          | true when a `ping` answers `ok`                                                    |
| `broker-verify-plugin`   | verifies a directory in a one-shot child, returning a boolean and the child output |
| `broker-load-generation` | asks the child to load a generation and returns the child's report                 |
| `serve-broker`           | binds a socket and serves until killed, the child entry point                      |

`broker-call` writes one frame and reads one frame while holding the call lock, so two callers cannot interleave the writes.
A closed stream before a reply signals `transport-error` with the detail `The broker closed without a response.`
An `ok` value of false becomes `tool-error` with the operation as its tool, and the detail is the child's detail, its error, or `The broker reported an error.` when neither exists.
The function accepts a `timeout` keyword and does not enforce it on the socket read, so the caller sets a process deadline around the call instead.

### The child

`src/broker-exec.cl` loads the system, registers the built-in tools, installs the plugin loader as `*load-generation-function*`, and serves the socket.
It drops to the requested uid when it runs as root and the uid is positive, and a non-root process stays where it is.
Each frame is answered by operation: `ping` answers the string `ok`, `load-generation` calls the plugin loader with the directory and generation and answers `{"ok": ..., "report": ...}`, and every other operation is a tool name dispatched through `dispatch`.
A success is scrubbed and returned under `result`, because a tool result is the last place a secret can enter a transcript.
A tool request runs in the child, not in the supervisor.
In the container the child runs as the agent user.
On a checkout it runs as the operator's user, so the shell tool and every agent-authored handler have that user's file rights.

`--verify-plugin DIRECTORY --uid N` verifies every agent file in the directory and prints the report, exiting 0 when the generation is good and 1 when it is not.
The main mode requires `--socket`, prints `broker-exec: --socket PATH is required.` on standard error and exits 2 when it is absent.
A startup failure exits 1 and an interrupt exits 130.
A smoke test runs `sbcl --script src/broker-exec.cl --socket /tmp/enchiridion-broker.sock` from a development shell, so that ASDF can find the system.

### Frames and their failures

`write-frame` writes the length and the UTF-8 bytes and flushes.
`read-frame` answers nil at a clean end of stream and signals `transport-error` in three cases.

| Condition                                | Detail                                     |
| ---------------------------------------- | ------------------------------------------ |
| The stream ends inside a header          | `The broker closed during a frame header.` |
| The body is shorter than the header says | `The broker closed during a frame body.`   |
| The length exceeds 16 MiB                | `The broker frame is larger than 16 MiB.`  |

`broker-start` tries to connect until the socket answers or the timeout expires, then signals `transport-error` with the detail `The broker did not start before the timeout.`
A failed start kills the child with SIGTERM before the error propagates.

## The reload path

A reload replaces the agent's code without stopping the process, and the supervisor loads no agent file itself.

1. Author or edit a tool or skill file under the agent directory.
2. Ask for a reload, which appends a request.
   The `reload` command and the meta tool both do this.
3. The supervisor verifies the new generation in a one-shot child and refuses the generation when verification exits nonzero.
4. The supervisor registers one proxy tool per verified manifest, with the new generation and `broker-side-p` true.
5. The supervisor asks the broker child to load the generation.
   In the container the child compiles it as the agent user. On a checkout the child runs as the operator's user.

The command is `nix run .#enchiridion -- reload`.
It needs a running supervisor, which `serve` starts.
It exits 0 when the supervisor accepted the generation and 1 when it refused it, and a refused generation leaves the last good one serving.
With no running supervisor it prints `reload: no supervisor is running, so nothing was asked.` and exits 1.

The meta tool's `reload` action appends one line to `run/enchiridion.control`, and the supervisor consumes the line on its next poll.
The model sees a proxy tool for each manifest, and its handler refuses with `configuration-error` at `:broker` and the detail `This tool runs in the broker.`
A call whose operation reaches the child goes through the real handler there.

Verification is a separate process, so a file that kills the compiler cannot take the running generation with it.
In the container the verifier runs as the agent user with the minimal environment.
On a checkout it runs as the operator's user.
Its combined output returns to the supervisor.
`plugins.md` owns the manifest and the verification report.

## Adding a tool

A tool can be added to a running Lisp image for development, or to the source tree as a built-in.

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
A call with no arguments signals `schema-error`, because `path` is required, and a call with an unknown argument also fails, because the object schema sets `additionalProperties` false.
A tool registered this way lives until the image exits, does not reach another process, and does not survive a restart.

### As a built-in

1. Create the file under `src/enchiridion/tools/builtin/` and add it to `enchiridion.asd`.
2. Write one handler function that takes the argument table and returns a string.
3. Build each tool with `enchiridion.tools:make-tool` and a quoted schema, and collect them in a list.
4. Write a `register-NAME-tools` function that calls `register-tool` for each, and return the count.
5. Add that function to `register-builtin-tools` in `register.cl`.
6. Compile and run the suite with `nix run .#check` and `nix run .#test`.
7. Run `nix run .#enchiridion -- tools list` and confirm the name, the token estimate, and the description.

The handler receives a hash table with string keys, because `dispatch` normalizes the arguments before it calls the handler.
The helper `argument` in `file.cl` reads a key from a table or a property list, so a handler is usable from a test that holds the plist directly.
A built-in is registered in the supervisor and in the broker child, which calls `register-builtin-tools` before it serves its first request, so the same eleven names exist on both sides of the socket.

## The registry reference

These functions form the registry surface of `enchiridion.tools`.

| Name                        | Result                                                    |
| --------------------------- | --------------------------------------------------------- |
| `registry`                  | the live hash table                                       |
| `register-tool`             | adds a tool and returns it                                |
| `find-tool`                 | the tool with that name, or nil                           |
| `tool-names`                | every name, sorted                                        |
| `list-tools`                | every tool, sorted by name                                |
| `unregister-tool`           | true when the name was present                            |
| `clear-registry`            | removes every tool, for tests                             |
| `dispatch`                  | validates the arguments and calls one handler             |
| `registry-schema`           | every tool as one JSON array                              |
| `registry-tool-definitions` | every tool as a definition object, after the budget check |
| `schema-budget-report`      | the `:used`, `:budget`, and `:remaining` plist            |
| `define-tool`               | registers a tool and keeps a quoted schema                |
| `make-tool`                 | builds a tool structure                                   |

`tools list` prints the name, the token estimate, and the description of every registered tool, and `tools show NAME` prints the schema of one tool as JSON text.
Run them as `nix run .#enchiridion -- tools list` and `nix run .#enchiridion -- tools show read-file`.

`tool-definition`, `normalize-tool-name`, `arguments-to-json`, and `registry-schema-tokens` are internal helpers.
A caller that needs a definition uses `registry-schema` or `registry-tool-definitions`, and a caller that needs a normalized name uses `find-tool`.

The registry is a hash table with `equal` test, so a tool name is a lowercase string and two spellings of one name cannot coexist.

## Built-in tools

`register-builtin-tools` calls seven registrars and registers eleven tools.

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
| `memory`     | `name`, `text`       | none                                                              |
| `meta`       | none                 | `action`, `directory`, `limit`, `name`, `kind`, `text`, `confirm`, `step` |
| `web`        | none                 | `action`, `url`, `query`, `limit`                                 |

### The result cap

Eight of the eleven tools pass at least one result through `cap-result`.
The tools that never cap a result are `write-file`, `edit-file`, and `memory`, whose results are short by construction.

| Name              | Value                                                                   |
| ----------------- | ----------------------------------------------------------------------- |
| `+result-cap+`    | 8000 characters                                                         |
| spill directory   | `$ENCHIRIDION_HOME/tmp/`, or `/tmp/` when the variable is unset         |
| spill file name   | `spill-N.txt` for a random integer N                                    |
| truncation marker | `[truncated N characters; full result at PATH]` appended after the head |

A result at or under the cap is returned unchanged, and a longer result is cut to the cap so the model receives the head and a path to a file that holds the whole text.

### `index`

`index` lists the top-level forms of a Lisp file with the line range of each.

The only argument is `path` (string, required).

The result starts with `PATH: N top level form` with the plural when the count is not one, then one line per form, as `START-END SKELETON`.
A definition form prints its head and name, as in `(defun name ...)`.
Any other list prints its head, as in `(let ...)`, and a non-list prints its value.
The reader binds `*read-eval*` to nil and uses a throwaway package, because an evaluated reader macro in an agent-authored file would be code execution.
A file that cannot be read becomes a `tool-error`.

### `read-file`

`read-file` returns a 1-based, inclusive line range.

`path` is a required string, `from` is an optional integer defaulting to 1, and `to` is an optional integer defaulting to the last line.

A range outside the file signals `schema-error` with the detail `Line range ~D..~D is outside ~D lines.`, and the result is the selected lines joined by newlines and capped.

### `write-file`

`write-file` writes text to a file and creates the parent directories.

`path` and `text` are required strings.

A `text` that is not a string signals `schema-error` with the detail `text must be a string.`
The result is `wrote N characters to PATH`.

### `edit-file`

`edit-file` replaces one unique occurrence of a string.

`path`, `old`, and `new` are required strings.

An empty `old` signals `schema-error` with the detail `old must be a non-empty string.`
An `old` that does not occur in the file signals `tool-error` for `edit-file` with the detail `The old text does not occur in the file.`
An `old` that occurs twice or more signals the same condition with the detail `The old text occurs more than once; make it unique.`
The result is `edited PATH`.

### `glob`

`glob` lists the paths that match a wildcard pattern.

`pattern` is a required string.

A pattern that is not a string signals `schema-error` with the detail `pattern must be a string.`
The result is one path per line, and a pattern that matches nothing returns the empty string.

### `shell`

`shell` runs a command through `/bin/sh -c` under a time limit.

`command` is a required string, and `timeout` is an optional integer defaulting to 30 seconds.

A command that is not a string signals `schema-error` with the detail `command must be a string.`
A normal exit ends the result with `[exit N]`, and a command that runs past the deadline ends it with `[timed out after N seconds]` after the child is ended.
The result is the combined output, followed by the status line, and capped.

The shell tool is the broker's most direct escape hatch, which is why the broker child runs it and not the supervisor.

### `search`

`search` reads the memory store or walks the agent's text files.

`query` is a required string, `scope` is an optional string defaulting to `memory`, `path` is an optional string, and `limit` is an optional integer defaulting to 20 for the store and 40 for the files.

An empty `query` signals `schema-error` with the detail `query must be a non-empty string.`
A `limit` that is not a positive integer signals the same condition with the detail `limit must be a positive integer.`
An unknown scope signals it with the detail `Unknown search scope ~A.`

A `path` argument selects the file walk whatever `scope` says.

The store scope opens the store only when the file is already a database, so a search never creates one.
It returns one line per hit with the prefix `session SESSION ROLE` or `memory NAME`, and the body is flattened to one line and cut to 400 characters with ` ...` when it was longer.
No match returns `no matches`, and `memory.md` owns the store and its search rules.

The file scope visits files with the extensions `md`, `txt`, `cl`, `lisp`, `json`, and `org`.
It skips the directories `.git`, `node_modules`, `run`, and `cache`, visits at most 2000 files, and matches each line case-insensitively as `PATH:LINE: TEXT`.
A file that raises a file error is skipped, and the default root is the `path` argument, then `$ENCHIRIDION_HOME/agents/default/`, then the default pathname.

### `memory`

`memory` saves one named memory in the store that `search` reads.

`name` and `text` are required strings.
The result is `saved memory NAME as ID`.
An empty name signals `schema-error` with the detail `name must be a non-empty string.`, and a non-string text signals it with `text must be a string.`
The store's own empty and duplicate refusals belong to `memory.md`.

### `blockops`

`blockops` reads and changes the Markdown memory blocks.

`action` is an optional string defaulting to `list`, and `directory` is an optional string defaulting to the agent directory.
`label` is required for `read`, `patch`, and `add`, `old` and `new` are required for `patch`, and `text` is required for `add`.

| Label      | File          |
| ---------- | ------------- |
| `soul`     | `SOUL.md`     |
| `persona`  | `SOUL.md`     |
| `operator` | `OPERATOR.md` |
| `world`    | `WORLD.md`    |

`list` prints one line per label as `LABEL SIZE/LIMIT PATH`, so `soul` and `persona` both name `SOUL.md`.
`read` returns the block text, or the empty string when the file is absent.
`patch` replaces one unique occurrence and answers `patched PATH`.
`add` appends a newline and the text, or writes the text when the block is empty, and answers `added to PATH`.

The refusals are these.

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
| The text fails the injection scan  | the condition the scan signals                                                            |
| Bootstrap still owns a seed file   | `bootstrap-pending` with `:label`                                                         |

The last three checks run before the file is written, and the write happens last, so a refused write leaves the old text in place.
The limits and the scan belong to the memory module, and `memory.md` owns them.
The CLI writes the seed files directly and does not pass through this gate, because the rule protects the operator from the agent.

> **Important:** The block and file tools honour the bootstrap gate.
> `write-file` and `edit-file` refuse the three identity paths while it is pending.
> `shell` does not check it, and the gate reads the `directory` argument, so a caller that names another directory is not gated by the agent's bootstrap.
> The gate is a rule that the agent follows, not a sandbox boundary.

### `meta`

`meta` acts on the agent repository.

`action` defaults to `journey`, `directory` defaults to the agent directory, `limit` defaults to 20, and `kind` defaults to `tool`.
`name` is required for `author`, `text` is required for `author`, `confirm` is required for `undo`, and `step` is required for `bootstrap-step`.

`journey` returns the last commits from `git log --oneline -n LIMIT`, with a 20 second limit, and the result is capped.
`author` writes one file and commits it when the directory is a repository.
A `tool` writes `tools/NAME.cl`, and a `skill` writes `skills/NAME.md`.
The result is `wrote PATH` when no commit was attempted, `wrote PATH and committed NONE` when the repository had nothing to commit, or `wrote PATH and committed HASH` when it committed.
`bootstrap-step` records one step with `mark-bootstrap-step` and answers `bootstrap step N recorded. STATUS`.
`undo` reverts the last commit with `git revert --no-edit HEAD` and returns the capped output.
`reload` appends one line to the control file and answers `reload requested in PATH`.

The refusals are these.

| Condition                               | Signal                                                                                     |
| --------------------------------------- | ------------------------------------------------------------------------------------------ |
| Unknown action                          | `schema-error`, detail `Unknown meta action ~A.`                                           |
| A name outside `[A-Za-z0-9_-]+`         | `schema-error`, detail `name must be one segment of letters, digits, dash, or underscore.` |
| A kind other than `tool` or `skill`     | `schema-error`, detail `kind must be tool or skill.`                                       |
| A missing or unknown bootstrap step     | `schema-error`, detail `step must be a positive integer.` or `There is no bootstrap step N.` |
| `text` is not a string                  | `schema-error`, detail `text must be a string.`                                            |
| The authored file already exists        | `tool-error` for `meta`, detail `PATH already exists.`                                     |
| `undo` without `confirm` equal to `yes` | `schema-error`, detail `undo requires confirm yes.`                                        |
| A git command times out                 | `tool-error` for `meta`, detail `git log timed out.` or `git revert timed out.`            |
| A git command fails                     | `tool-error` for `meta` with the command output                                            |

A directory that is not a git repository is not an error for `author`.
The file is written, and the commit is skipped.
A commit failure is silent for the same reason: a host with no identity or no git must not cost the operator the reply.

### `web`

`web` fetches a URL or searches the web.

`action` is an optional string defaulting to `fetch`, `url` is required for `fetch`, `query` is required for `search`, and `limit` is an optional integer defaulting to 10.

`fetch` requires a `url` that starts with `http://` or `https://`, and the refusal detail is `url must start with http:// or https://.`
`search` requires a non-empty `query`, and the refusal detail is `query must be a non-empty string.`
An unknown action signals `schema-error` with the detail `Unknown web action ~A.`

Both actions use a 20 second timeout.
`fetch` returns the capped reply text.
`search` reads the DuckDuckGo JSON endpoint and returns related topics and an abstract, one per line, up to the limit, and it is not a full search index.
No result returns `no results`.

An HTTP failure becomes `tool-error` for `web` with the detail `HTTP STATUS: BODY`, and any other transport failure becomes the same condition with the printed condition.

## The pipe sandbox

The pipe module filters lines of text with one Lisp expression, so a filter costs no tokens and no model call.
A filter can keep or drop each line of command output.

The line variable is `$`.
The helper `NTH4` returns the fifth whitespace-separated field, as an integer when that field parses as one.

A filter form may use only these names.

```text
$ FILTER NTH4 NTH FIRST SECOND THIRD LENGTH SUBSEQ SEARCH PARSE-INTEGER
STRING-UPCASE STRING-DOWNCASE STRING= STRING< STRING> PRINC-TO-STRING
FORMAT LIST IDENTITY IF AND OR NOT NULL T NIL
= /= > < >= <= + - * /
```

The sandbox package uses `common-lisp`, so the walker is the boundary.
`check-form` walks the whole form before any evaluation, and a symbol outside the list signals `schema-error` with the detail `Filter symbol ~A is not allowed.`
A form that names `system`, `load`, or `eval` therefore fails even though the package holds those functions.

`make-sandbox` creates a fresh package for one filter, with `$` as a special variable and `NTH4` as a function, so a later filter cannot see a binding or a helper left by an earlier one.

| Function         | Result                                                    |
| ---------------- | --------------------------------------------------------- |
| `read-filter`    | one checked form, reading with `*read-eval*` bound to nil |
| `filter-form`    | the expression inside `(filter ...)`, or the form itself  |
| `make-sandbox`   | a fresh package holding `$` and `NTH4`                    |
| `pipe-safe-eval` | the value of one form with `$` bound to one line          |
| `pipe-eval`      | the lines whose filter value is true                      |

`read-filter` accepts exactly one form.
An empty string signals `schema-error` with the detail `The filter is empty.`
A string that holds a second form signals the same condition with the detail `The filter has more than one form.`

`pipe-eval` accepts a filter string, a form read by `read-filter`, or a function of one line.
It splits the text on newlines, skips empty lines, evaluates the filter for each line, and writes each kept line followed by one newline.

```lisp
(enchiridion.tools.pipe:pipe-eval
 "a b c d 100
a b c d 500"
 "(filter (> (nth4 $) 200))")
```

The result is the second line and its newline.
The module is exported and covered by the test suite.
No built-in tool takes a filter argument and no production code calls the module, so an authored tool can reach it from Lisp.

## Troubleshooting

| Symptom                                                                  | Cause                                         | Fix                                                        |
| ------------------------------------------------------------------------ | --------------------------------------------- | ---------------------------------------------------------- |
| `No tool called X.`                                                      | the name is not registered in this process    | check the spelling, `tools list`, and the reload           |
| `This tool runs in the broker.`                                          | a proxy handler was called in the supervisor  | call the tool through `broker-call`, which the kernel does |
| `The SCHEMA budget is spent: ...`                                        | the schemas exceed `*schema-budget*`          | remove a tool, shorten a description, or raise the budget  |
| `The broker is not running.`                                             | the call was made before `broker-start`       | start the broker or the supervisor                         |
| `The broker frame is larger than 16 MiB.`                                | a result exceeded the frame cap               | cap or spill the result in the tool                        |
| `The broker closed during a frame body.`                                 | the child died mid-reply                      | check the child output and restart the broker              |
| `The broker did not start before the timeout.`                           | the child never bound the socket              | check `ENCHIRIDION_SBCL` and the source registry           |
| `There is no tool called X.` from `tools show`                           | the tool is not a built-in in a fresh process | add it under `builtin/`, or use the REPL that holds it     |
| `Unknown block action`, `Unknown block label`, or `Unknown search scope` | an argument outside the documented values     | use one of the documented values                           |

## See also

- [Plugins and self-modification](plugins.md) for the manifest, the verification report, and the loader behind the reload path.
- [Commands](commands.md) for `tools`, `reload`, and the exit statuses of each command.
- [Configuration](configuration.md) for the sandbox uid and the memory paths the tools read.
- [Memory](memory.md) for the store behind `search`, the block limits behind `blockops`, and the bootstrap gate.
- [Large language model backends](llm.md) for the request shape that carries the tool definitions and the tool calls that come back.
