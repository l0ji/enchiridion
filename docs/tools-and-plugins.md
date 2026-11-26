# Tools and plugins

Tools are functions the model can call during a turn. Enchiridion ships with 12
built-in tools and lets you (or the agent) add more as Lisp plugins under
`agents/default/tools/` or `agents/default/skills/`.

Plugins run inside the broker child process as the agent user. Reloading
verifies the new generation in a separate child first—if anything warns, fails
to compile, or fails a self-test, the previous generation stays live.

## Built-in tools

Run `enchiridion tools list` to see token costs and descriptions, or
`enchiridion tools show <name>` for a tool's JSON schema.

| Tool | What it does |
| --- | --- |
| `index` | Lists top-level forms and line ranges of a Lisp file (`*read-eval*` off) |
| `read-file` | Reads a file (optional 1-based inclusive `from`/`to` lines, max 1 MiB) |
| `write-file` | Creates or overwrites a file (refuses `ADAPT.md`) |
| `edit-file` | Replaces one unique occurrence in a file (refuses `ADAPT.md`) |
| `glob` | Matches paths by wildcard |
| `shell` | Runs `/bin/sh -c` in the broker child (30s default timeout, 600s max; disabled until bootstrap handover) |
| `search` | Searches `memory` (default), `sessions`, `memories`, or `files` (walks up to 2,000 text files) |
| `blockops` | Lists, reads, patches, or appends to `SOUL.md`, `OPERATOR.md`, or `WORLD.md` |
| `memory` | Saves a named memory to the store |
| `canary` | Proposes a shadow T2 retrieval canary check |
| `meta` | Reads `journey`, authors `tools/NAME.lsp` or `skills/NAME.md`, records bootstrap steps, undoes last commit, or triggers `reload` |
| `web` | Fetches an `http(s)://` URL or queries DuckDuckGo's JSON API (20s timeout) |

Tool results over 8,000 characters are truncated in the prompt, with the full
output spilled to `$ENCHIRIDION_HOME/tmp/` (or `/tmp/`). `write-file`,
`edit-file`, and `memory` are never truncated.

## Writing a plugin

Put a `.lsp` file directly in `agents/default/tools/` or
`agents/default/skills/` (subdirectories are ignored) and call `define-plugin`:

```lisp
(defpackage #:echo
  (:use #:cl)
  (:export #:echo-run #:echo-self-test))

(in-package #:echo)

(defun echo-run (arguments)
  (let ((text (gethash "text" arguments)))
    (format nil "echo: ~A (~D chars)" text (length text))))

(defun echo-self-test ()
  (let ((args (make-hash-table :test #'equal)))
    (setf (gethash "text" args) "hi")
    (equal (echo-run args) "echo: hi (2 chars)")))

(enchiridion.plugin:define-plugin echo
  :tool (enchiridion.plugin:tool
         "echo"
         "Return the text it was given, with its length."
         (:object :required (:text) :properties ((:text :string))))
  :handler #'echo-run
  :self-test #'echo-self-test)
```

- **Handler:** receives validated arguments as a hash table with string keys.
- **Self-test:** takes no arguments and returns true on success. Verification
  runs without secrets, so self-tests cannot rely on API keys.
- **Literal `(tool ...)` form:** the supervisor reads `(tool ...)` as data
  *without evaluating the file* to build the manifest the model sees. Do not
  compute the tool name or schema dynamically.

### Schema syntax

Schemas are Lisp forms, not JSON strings—keywords for primitive types, plus
`:object` and `:array`:

```lisp
(:object
 :required (:path)
 :properties ((:path :string)
              (:from :integer)
              (:to :integer)))

(:array :items :string)
```

Objects always emit `additionalProperties: false`. All tool schemas in a prompt
share a **2,000-token budget** (~4 JSON chars/token). If you exceed it, turns
fail with `The SCHEMA budget is spent`—remove a tool or trim
descriptions/schemas.

## Verifying and reloading

```sh
nix run .#enchiridion -- --verify-plugin agents/default
nix run .#enchiridion -- reload
```

`--verify-plugin` compiles and loads every `.lsp` file under `skills/` and
`tools/` in an isolated child (dropping to the agent UID when run as root) and
runs all self-tests. Any compile warning, error, `nil` return, or signalled
condition fails verification (exit `1`, 120s timeout).

`reload` asks the running supervisor to verify and swap in the new generation.
If a file changes mid-reload or verification fails, the previous generation
stays active. Note that a failed reload cannot undo top-level side effects from
files that already loaded.

## Skills

Files directly inside `agents/default/skills/` fall into two categories:

- **Executable skills (`skills/*.lsp`):** normal plugins that load *before*
  `tools/*.lsp` (so tools can call helper functions defined in skills). Add
  `(defparameter +trigger+ "keyword, phrase")` at top level to show a hint in
  `enchiridion skills list` (this is a listing aid only and is not injected into
  prompts).
- **Reference skills (`skills/*.md`):** plain Markdown the agent reads with
  `read-file` or `search`. Not compiled, not verified, not shown in `skills
  list`, and no special front matter format. Treat untrusted `.md` skills as
  prompt-injection risk.

## Shadowing and limits

- Tools are keyed by lowercased name. A plugin named `read-file` shadows the
  built-in for that generation (removing it later unregisters the name until
  restart). Within a generation, `skills/` loads before `tools/`, sorted
  alphabetically; the last definition wins.
- File size caps: **256 KiB** per `.lsp` file for manifest reading, **1 MiB**
  for source snapshots and `read-file`.
