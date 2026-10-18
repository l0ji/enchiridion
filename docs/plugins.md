# Plugins and self-modification

The agent writes Lisp files in the `skills/` and `tools/` directories of its
own directory under `agents/`. Each file is a plugin: a name, a tool, a
handler, and an optional self-test. The core under `src/` stays frozen, and
the agent never rewrites it. A reload verifies the new files in a child
process, then loads them into a package of their own generation. A bad edit
costs one turn and the last good generation keeps serving.

## The manifest

A manifest is the part of a plugin that the model sees: a name, a description,
and a schema. The supervisor reads the manifest as data. It never evaluates
the file, so a file cannot run by being read.

```lisp
(defpackage #:example-echo
  (:use #:cl)
  (:export #:echo-run #:echo-self-test))

(in-package #:example-echo)

(defun echo-run (arguments)
  (gethash "text" arguments))

(defun echo-self-test ()
  (let ((arguments (make-hash-table :test #'equal)))
    (setf (gethash "text" arguments) "hi")
    (equal (echo-run arguments) "hi")))

(enchiridion.plugin:define-plugin echo
  :tool (enchiridion.plugin:tool
         "echo"
         "Return the text it was given."
         (:object :properties ((:text :string))))
  :handler #'echo-run
  :self-test #'echo-self-test)
```

`define-plugin` builds a plugin struct, registers the tool, and records the
plugin.

| Field        | Type     | Meaning                                   |
| ------------ | -------- | ----------------------------------------- |
| `name`       | string   | The tool name, in lowercase.              |
| `tool`       | tool     | The descriptor the model sees.            |
| `handler`    | function | The function that runs.                   |
| `self-test`  | function | The function that verification calls.     |
| `generation` | integer  | The generation that installed the plugin. |

The tool form accepts two spellings. The first is `(tool "name" "description"
schema)`. The second is a plain plist with `:name`, `:description`, and
`:schema`. `tool-form-parts` and `normalize-plugin-tool` reduce both to one
shape. A plugin with no tool form still has a name and an empty object schema.

| Function               | Result                                         |
| ---------------------- | ---------------------------------------------- |
| `plugin-manifests`     | The manifest of every file in a list of paths. |
| `file-manifests`       | The manifests in one file, in order.           |
| `plugin-form-p`        | True for a `(define-plugin ...)` form.         |
| `manifest-name`        | The name a manifest declares.                  |
| `manifest-description` | The one line description.                      |
| `manifest-schema`      | The schema form, exactly as the file wrote it. |

`file-manifests` reads with `*read-eval*` bound to NIL and the package bound
to `enchiridion.plugin`. A file that will not read signals
`configuration-error` with `:key :plugin`. A silent empty list would report a
broken plugin as an absent one.

## The loader

A generation is one load of the agent directory. Generation 0 is the builtins,
so a fresh process holds only builtins.

| Function                      | Result                                             |
| ----------------------------- | -------------------------------------------------- |
| `agent-source-files`          | The skills, then the tools, each sorted by name.   |
| `files-under`                 | The `.cl` files directly in one directory, sorted. |
| `package-name-for-generation` | `ENCHIRIDION.DYN.` plus the generation.            |
| `ensure-generation-package`   | The package for a generation, made when absent.    |
| `load-agent-code`             | Loads every file and returns the pathnames.        |
| `current-generation`          | The live generation, or 0.                         |
| `discard-generation`          | Removes the tools and plugins of one generation.   |
| `load-generation`             | Verifies and loads the next generation.            |
| `reload`                      | Loads the generation after the current one.        |
| `plugin-registry`             | The plugins this process loaded, newest first.     |
| `generation-history`          | Every load attempt, newest first.                  |

Order matters in three places. `agent-source-files` reads skills before tools,
so one directory always produces the same generation. The file name decides
the order inside each directory. Each generation loads into a package of its
own, so a rename leaves no stale symbol behind. SBCL never uninterns a symbol
while its package exists.

`load-agent-code` binds `*package*` to the generation package and
`*read-eval*` to NIL for the whole load. A file with no `in-package` form
interns into the package of its own generation.

`load-generation` returns a `generation-result`.

| Field        | Meaning                            |
| ------------ | ---------------------------------- |
| `ok-p`       | True when the generation loaded.   |
| `report`     | Why it loaded or did not.          |
| `generation` | The number live after the call.    |
| `loaded`     | The pathnames that arrived.        |
| `manifests`  | The manifests of the loaded files. |

A directory with no agent files is not a failure. The result says `no agent
files to load`, and the generation stays where it was.

`discard-generation` touches only agent tools. A builtin carries generation 0,
and the guard spares it, so a reload never unregisters `read-file`.

## What a plugin may replace

A plugin adds a tool under a new name. It may also replace a builtin by name,
because the registry is a hash table and `register-tool` replaces the earlier
entry. Nothing in the loader refuses that collision.

| Surface                             | Change allowed                                  |
| ----------------------------------- | ----------------------------------------------- |
| A tool name                         | Yes. A new name, or one that shadows a builtin. |
| The tool schema of an agent plugin  | Yes. The manifest carries it.                   |
| The tool handler of an agent plugin | Yes. The broker child runs it.                  |
| The core system under `src/`        | No. The loader reads only agent files.          |
| The channel set                     | No. A plugin cannot add a channel.              |
| The supervisor process              | No. The supervisor holds no agent handler.      |
| The memory engine and the store     | No. A handler may call it, not replace it.      |

The shadow rule is worth care. A plugin named `read-file` replaces the builtin
in the registry for that process. A later `discard-generation` then removes
the name, and the builtin does not come back.

## The proxy in the supervisor

The supervisor must show the model each authored schema, and it must not hold
the handler. `install-agent-proxies` reads the manifests and registers one
proxy tool per plugin.

A proxy carries the authored name, description, and schema. It carries
`:broker-side-p` true. Its handler refuses with `configuration-error` and
`:key :broker`, because every call goes to the broker before dispatch reaches
it. `execute-tool` sends the call to the broker whenever the agent has one.

## Verification

Verification proves a generation before it loads. `verify-directory` compiles
and loads every agent file, then runs each self-test. The result is a
`verify-result`.

| Field       | Meaning                                             |
| ----------- | --------------------------------------------------- |
| `ok-p`      | True when every file and self-test passed.          |
| `report`    | The failure lines, or the count of files and tests. |
| `tests`     | The names of the plugins that ran a self-test.      |
| `failures`  | The failure lines.                                  |
| `directory` | The directory under test.                           |

`verify-file` loads one file at `(safety 3) (debug 3)`. It collects warnings
and muffles them. A file that does not compile, and a file that warns, both
fail the same way. The policy is strict on purpose, and the warning gate of
the core system agrees with it.

`run-self-tests` calls each self-test with no arguments. A self-test that
returns NIL fails. A self-test that signals fails. A plugin with no self-test
passes, because the extension surface makes the self-test optional.

Verification registers the tools it loads, and then removes them with
`discard-generation`. Without that step, the real load would record every
plugin twice, and a verify-only caller would leave tools behind for a
generation that never loaded.

## The verify command

The command verifies one directory in a one-shot child and prints the report.

```sh
nix run .#enchiridion -- --verify-plugin agents/default
```

`--verify-plugin` takes a directory. A missing directory argument is exit 2.
The command runs `sbcl --script src/broker-exec.cl --verify-plugin DIR --uid
1000` in a child, with `DIR` set to the directory argument and a 120 second
timeout. The child drops to uid 1000 before it reads one agent file, so a file
that runs away runs as the agent. Exit 0 means the generation is good. Exit 1
means it is not.

A separate process is the point. A file that kills the compiler must not take
the running generation with it.

## Honest limits

- Verification proves that a file compiles, loads without a warning, and
  passes its own self-test. It does not prove behavior.
- The self-test is optional. A plugin with no self-test passes. A trivial
  self-test proves only what its author wrote.
- Top level forms run during verification and again during the real load.
- Agent code runs with the rights of the agent user. A plugin that deletes a
  file succeeds.
- The schema budget is shared. A large plugin schema can push the registry
  over 2000 tokens, and then `registry-tool-definitions` signals
  `budget-exceeded` and every turn stops.
- The supervisor reads only the manifest of an agent file. It cannot see a
  handler before the load.
- A generation that fails verification changes nothing. The last good code
  keeps serving.

## Related

- [Tools](tools.md)
- [Development](development.md)
- [Commands](commands.md)
- [Deployment](deployment.md)
- [Configuration](configuration.md)
