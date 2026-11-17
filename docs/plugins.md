# Plugins and skills

A plugin is a Lisp file under `agents/default/tools/` or
`agents/default/skills/` that adds a tool. A skill is a file under
`agents/default/skills/`: a Lisp file adds a tool, and a Markdown file is
reference text. A plugin runs in the broker child as the agent user. A reload
verifies a new generation in a separate child and adopts it only when that
child exits zero, so a broken file leaves the last good generation serving.

## The file

A plugin file calls `define-plugin` for each tool it adds, with a `tool` form,
a handler, and usually a self-test:

```lisp
(defpackage #:echo
  (:use #:cl)
  (:export #:echo-run #:echo-self-test))

(in-package #:echo)

(defun echo-run (arguments)
  "Return the :text field of a validated call."
  (let ((text (gethash "text" arguments)))
    (format nil "echo: ~A ~D characters" text (length text))))

(defun echo-self-test ()
  "Return true when the handler still round trips a string."
  (let ((arguments (make-hash-table :test #'equal)))
    (setf (gethash "text" arguments) "hi")
    (equal (echo-run arguments) "echo: hi 2 characters")))

(enchiridion.plugin:define-plugin echo
  :tool (enchiridion.plugin:tool
         "echo"
         "Return the text it was given, with its length."
         (:object :required (:text) :properties ((:text :string))))
  :handler #'echo-run
  :self-test #'echo-self-test)
```

The plugin name is lowercased. The tool name comes from the `tool` form, or
from the plugin name when the form is absent. The handler receives the
arguments the schema validated, as a hash table with string keys. The
self-test takes no arguments and returns true when the file still works.

Write the `(tool ...)` form literally. The supervisor reads it as data to build
the manifest the model sees, without evaluating the file. A computed value
still loads in the broker, but its name and schema reach the model wrong. A
plugin with no `tool` form has a manifest with its name and an empty schema,
and no tool is registered.

## Install and reload

1. Write the file directly under `agents/default/tools/` or
   `agents/default/skills/`. A subdirectory is not read, and the extension
   must be `.cl`.
2. Verify the directory:

   ```sh
   nix run .#enchiridion -- --verify-plugin agents/default
   ```

   With `ENCHIRIDION_HOME` set, pass `$ENCHIRIDION_HOME/agents/default`.
3. Reload the running supervisor:

   ```sh
   nix run .#enchiridion -- reload
   ```

   A refused generation prints `reload refused: REPORT` and exits 1. The
   previous generation keeps serving. With no supervisor, the command prints
   `reload: no supervisor is running, so nothing was asked.` and exits 1; the
   next `ask`, `chat` or `serve` loads the files.

The model sees the new tool on the next turn after a successful reload.

## What verification checks

`--verify-plugin` starts a one-shot child, compiles and loads every `.cl` file
under `skills/` and `tools/`, and runs every plugin self-test. The child drops
to the configured agent uid and gid before it reads a file when the parent runs
as root. A passing report reads:

```text
2 files compiled, 2 self-tests ran
```

A warning during the load is a failure, as is a file that will not compile, a
self-test that returns nil, and a self-test that signals. A failure line reads
`FILE: WARNING`, `NAME self-test returned NIL` or `NAME self-test signalled:
CONDITION`.

The command exits 0 on success, 1 on failure, and 2 when the directory argument
is missing. It does not touch a running supervisor.

## Reload

A reload is a request in the supervisor's control file, not a second
supervisor. The supervisor verifies the directory, asks the broker child to
load the generation, and installs the new tool proxies only when both agree on
the source snapshot. An edit during the reload is refused with `the agent
source changed since it was read: FILE changed`, and the previous generation
stays live. A failed reload does not undo a top-level side effect from a file
that did load, such as a `defvar`, a written file, or a started thread.

## Skills

A skill is a file under `agents/default/skills/`. A `.cl` file is an executable
plugin; a `.md` file is reference text. Only the Lisp file is compiled.

| Path | Kind | Compiled | Use |
| --- | --- | --- | --- |
| `skills/*.cl` | executable | yes | Registers a tool and loads with a generation |
| `skills/*.md` | reference | no | Text the agent reads with `read-file` or `search` |
| `tools/*.cl` | tool | yes | A plugin that is not a skill |

Only files directly in `skills/` are read. A subdirectory is not a skill, a
dot-file is skipped, and the extension is matched case-insensitively.

### Executable skills

An executable skill is a plugin under `skills/` instead of `tools/`. It uses
the same `define-plugin` form, is verified the same way, and is reloaded with
the same generation. Skills load before tools, so a skill can define a function
that a tool file calls.

A `+trigger+` line records when the skill applies:

```lisp
(defparameter +trigger+ "welcome, hello, introduce yourself")
```

`enchiridion skills list` reads the first such form as data, numbers the `.cl`
files, and prints the trigger beside each name:

```text
1. example-welcome.cl -- welcome, hello, introduce yourself
```

`skills show N` prints the file. No prompt includes the trigger today, so the
line is a listing aid and costs no tokens.

### Reference skills

A reference skill is Markdown the agent reads with `read-file` or `search`.
Nothing compiles it, indexes it, or puts it in a prompt. `skills list` shows
only `.cl` files, so a reference skill is invisible to the listing. The loader
reports the `.md` files in the generation result, but no command prints them.

There is no front matter format. A `---` block is ordinary text.

`meta author` with `:kind "skill"` writes `skills/NAME.md`, so the agent's own
authoring produces a reference skill. An executable skill must be written with
the file tools.

Markdown from an untrusted source is a way to tell the agent what to do. Read a
reference skill as data, and keep the ones you trust.

### File names

Name a skill file after the skill, in lowercase, so the listing reads as an
index. `deploy.cl` and `deploy.md` under `skills/` can coexist; nothing refuses
the pair and nothing gives one precedence.

### Skills commands

```sh
nix run .#enchiridion -- skills list
nix run .#enchiridion -- skills show 1
```

`skills list` prints `no skills yet.` when no `.cl` file exists.

## Shadowing

The registry is keyed by the lowercased tool name. A plugin whose tool name is
`read-file` replaces the built-in for the generation that loaded it. Removing
that plugin later unregisters the name without restoring the built-in in that
process; a restart brings it back. Two files that define the same name leave
the later one in the registry: `skills/` loads before `tools/`, and file names
sort within each directory.

## Limits

| Bound | Value |
| --- | --- |
| One executable file, for its manifest | 256 KiB |
| One executable file, for the source snapshot | 1 MiB |
| Verification timeout | 120 seconds |
| All tool schemas in one prompt | 2000 estimated tokens |
| One file `read-file` decodes | 1 MiB |

An oversized schema makes every turn fail with `The SCHEMA budget is spent: N
of 2000 tokens.` See [Tools](tools.md#the-schema-budget).

## What verification does not prove

- A file compiles and its self-test passes. It does not prove the handler is
  correct, and top-level forms run once in verification and again in the load.
- The handler runs as the agent user. In a checkout started as your own user,
  it can write your source tree, `.env`, and the agent directory. The container
  split limits it to the agent user; the loader does not.
- A plugin that needs a secret cannot have one in its self-test, because the
  verification child holds no secret.
- A reference skill is not compiled, so verification says nothing about it and
  it cannot refuse a reload.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `reload refused: FILE: WARNING` | the file compiles with a warning | fix the warning, then reload |
| `reload refused: NAME self-test returned NIL` | the self-test catches a broken file | repair the handler or the self-test |
| `reload refused: NAME self-test signalled: CONDITION` | the self-test raised a condition | read the condition and repair the file |
| `reload: no supervisor is running, so nothing was asked.` | no live supervisor | start `serve` or `chat` |
| A tool from the new file is absent | the file is in a subdirectory, has the wrong extension, or names a computed tool | move the file, fix the name, and reload |
| The tool runs but the model never sees it | the `tool` argument is computed, so the manifest is wrong | write the literal `(tool ...)` form |
| A Markdown skill is not listed | `skills list` reads `.cl` files only | read the file with `read-file`; there is no listing |
| A trigger is absent from the listing | the file has no top-level `(defparameter +trigger+ "...")` | add the form; the listing reads the file directly |
