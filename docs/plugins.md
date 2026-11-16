# Plugins and self-modification

The agent extends itself by writing Lisp files under `skills/` and `tools/`.
Each file is a plugin: a tool the model can choose, a handler that runs in a broker child, and an optional self-test.
A reload verifies a new generation in a child process and adopts it only when the child exits zero, so a refused edit leaves the last good generation serving.

## The plugin

A plugin file is ordinary Common Lisp that calls `enchiridion.plugin:define-plugin` once or more.
The macro builds a plugin structure, registers its tool, and records the plugin for the generation that is loading.
The name is required, and the three keyword arguments are optional.

| Field        | Type            | Meaning                                    |
| ------------ | --------------- | ------------------------------------------ |
| `name`       | String          | The tool name, lowercased                  |
| `tool`       | Tool or nil     | The descriptor the model sees              |
| `handler`    | Function or nil | The function that runs in the broker child |
| `self-test`  | Function or nil | The function that verification calls       |
| `generation` | Integer         | The generation that defined the plugin     |

The generation is stamped at definition time, so a discarded generation takes its tools with it.

The tool argument accepts the `tool` macro, a tool struct, or a property list, and all three become one tool struct.
A file that the supervisor must read uses the `tool` form, because the manifest reader does not evaluate the file, and [the model-facing manifest](#the-model-facing-manifest) gives the rule.

A schema is one Lisp form that becomes the JavaScript Object Notation (JSON) Schema the model reads and validates the arguments the model sends back.
[Tools](tools.md) owns its shape and the handler contract.
A plugin with no tool form still has a manifest with its name and an empty object schema, and a missing handler leaves a tool that the model can call and no code can answer.

## The model-facing manifest

The manifest is the name, description, and schema that the supervisor reads without running the file, because it must show the model a tool it has not compiled.
`plugin-manifests` walks the top-level forms with `*read-eval*` bound to nil and takes each `define-plugin` form as data.
Nothing in the file is evaluated, compiled, or called by the read, and a file with several `define-plugin` forms contributes several manifests.

| Function               | Result                                                                     |
| ---------------------- | -------------------------------------------------------------------------- |
| `plugin-manifests`     | The manifest of every plugin in one path or a list of paths, in file order |
| `manifest-name`        | The tool name a manifest declares                                          |
| `manifest-description` | The one-line description                                                   |
| `manifest-schema`      | The schema form, exactly as the file wrote it                              |

A manifest is a property list of `:name`, `:description`, and `:schema`, and a file that will not read signals `configuration-error` with `:key :plugin` and a detail naming the file and the reader condition.
A computed tool value loads, but the manifest reader takes the form as data and produces a wrong name and schema, so a file the supervisor must see uses the `(tool ...)` form.

## What a plugin can extend

The loader reads two directories and writes one registry, and that surface is the whole extension point.

| Surface                         | Change                                        | Mechanism                                                                  |
| ------------------------------- | --------------------------------------------- | -------------------------------------------------------------------------- |
| A tool name                     | Add a name, or replace one already registered | `register-tool` overwrites the hash table entry by lowercased name         |
| A tool description and schema   | Yes                                           | The manifest carries both to the model-facing proxy                        |
| A tool handler                  | Yes                                           | The handler runs in the broker child. In a split run that child is the agent user |
| A skill                         | Yes                                           | A file under `skills/` loads before the files under `tools/`               |
| The core system                 | No                                            | The loader reads only the agent directory                                  |
| A channel                       | No                                            | The command builds the channel list before the supervisor starts           |
| The supervisor process          | No                                            | It holds proxies only, and the daemon never loads agent code               |
| The memory engine and the store | No                                            | The loader reads only agent files, and the core is compiled before it runs |

[Tools](tools.md) owns the registry, the schema budget, and the dispatch rules.

## The loader and generations

A generation is one load of the agent directory, and generation 0 is the built-in tools.

| Function                      | Result                                                                     |
| ----------------------------- | -------------------------------------------------------------------------- |
| `current-generation`          | The live generation, or 0                                                  |
| `package-name-for-generation` | `ENCHIRIDION.DYN.` and the generation number                               |
| `agent-source-files`          | The skills first, then the tools, each sorted                              |
| `load-agent-code`             | Loads every agent file into a generation package and returns the pathnames |
| `load-generation`             | Verifies and loads the next generation, and returns a result               |
| `reload`                      | Loads the generation after the current one                                 |
| `discard-generation`          | Removes the tools and plugins of one generation                            |
| `plugin-registry`             | The plugins this process loaded, newest first                              |
| `generation-history`          | Every load attempt this process made, newest first                         |
| `snapshot-sources`            | The SHA-256 of every compiled source, in load order                        |
| `source-changes`              | The files that differ between two snapshots                                |
| `source-mismatch`             | Why two snapshots disagree, or nil when they agree                         |

`agent-source-files` reads `skills/` before `tools/`, and the file name orders each directory, so a skill can define a function that a tool file calls.
Each generation loads into a package of its own, named `ENCHIRIDION.DYN.N`, so a rename leaves no stale symbol behind.
`load-agent-code` binds `*package*` to that package and `*read-eval*` to nil, so a file with no `in-package` form interns into its own generation package.

`load-generation` returns a `generation-result`:

| Field        | Meaning                                          |
| ------------ | ------------------------------------------------ |
| `ok-p`       | True when the generation was verified and loaded |
| `report`     | Why it loaded or did not                         |
| `generation` | The number live after the call                   |
| `loaded`     | The pathnames that arrived                       |
| `manifests`  | The manifests the files declare                  |
| `reference-skills` | The markdown skills beside the Lisp ones   |
| `digests`    | The source snapshot the attempt read             |

A good generation reports `generation N loaded, M file` with the plural when needed.
A refused generation reports the failure lines and leaves `current-generation` where it was.
A directory with no agent files is not a failure and it is not a no-op: the loader publishes the generation it was asked for with no agent code, which reports `generation N loaded, 0 files` and leaves the builtins in place.
An agent that deleted its last plugin therefore stops serving the tools of the previous generation, and a supervisor that asked for that generation and dropped the proxies of the old one stays in step with the child.
`discard-generation` touches only tools whose generation is positive and equal to its argument, so a built-in at generation 0 survives a reload.

## Verification in a child process

Verification proves a generation before the process adopts it, and the daemon does not compile agent code: the process that holds the secrets must not run what the agent wrote.
`broker-verify-plugin` starts the SBCL named by `ENCHIRIDION_SBCL`, or the SBCL running the supervisor, on the installed `src/broker-exec.cl` with `--verify-plugin DIRECTORY --uid UID --gid GID` as a one-shot child, and the child clears its groups and drops to the uid and gid before it reads one agent file.
The caller receives whether the child exited zero and the child's combined output, and the timeout is 120 seconds.

Inside the child, `verify-directory` compiles and loads every agent file at `(safety 3)` and `(debug 3)`, runs the self-test of every plugin the load added, and discards the tools and plugins that verification registered.
A warning during the compile counts as a failure, a file that will not compile and a self-test that returns nil or signals fail the same way, and the warnings are collected and muffled so the report names the file and each warning.

The result is a `verify-result`:

| Field       | Meaning                                            |
| ----------- | -------------------------------------------------- |
| `ok-p`      | True when every file and every self-test passed    |
| `report`    | The failure lines, or the count of files and tests |
| `tests`     | The plugin names whose self-tests ran              |
| `failures`  | The failure lines                                  |
| `reference-skills` | The markdown skills under the directory     |
| `digests`   | The source snapshot that was compiled              |
| `directory` | The directory under test                           |

A passing report reads `N file compiled, M self-test ran`, with each noun in the plural when the count is not one.
A failing report holds one line per failure: `FILE: WARNING`, `NAME self-test returned VALUE`, or `NAME self-test signalled: CONDITION`.
The discard at the end prevents a real load from recording every plugin twice and prevents a verify-only caller from leaving tools in the registry.

## Verifying a directory

`--verify-plugin` verifies one directory in a child and prints its report.

```sh
nix run .#enchiridion -- --verify-plugin agents/default
```

The command passes the directory to a one-shot child with `:sandbox :agent-uid` and `:agent-gid`.
The child drops before it reads a file, so a runaway file runs as the agent user, and an ordinary user skips the drop (see [Configuration](configuration.md)).

| Condition                               | Exit status | Output                               |
| --------------------------------------- | ----------- | ------------------------------------ |
| Every file and self-test passes         | 0           | The passing report                   |
| A file, a warning, or a self-test fails | 1           | The failure lines                    |
| The directory argument is absent        | 2           | `--verify-plugin takes a directory.` |

The command does not load anything into a running supervisor, and a reload or a restart performs the load.

## The self-test contract

A self-test is a function of no arguments that returns true when the file still does what its tool description says.
A self-test that returns nil or signals fails the generation with the value or condition in the report.
The self-test is optional: a plugin with no self-test passes, and a trivial self-test proves only what its author wrote.
Verification calls it in the child after the file compiles and before the real load, and the child environment holds paths and no secret, so a self-test must not need a key.

## Installing a plugin

**Step 1. Create the directory for the new tool.**

```sh
mkdir -p agents/default/tools
```

The command exits 0.

**Step 2. Write the plugin file.**

```sh
cat > agents/default/tools/word-count.cl <<'LISP'
(defpackage #:word-count
  (:use #:cl)
  (:export #:count-words #:count-words-self-test))

(in-package #:word-count)

(defun split-words (text)
  "Return the words in TEXT, separated by whitespace."
  (remove "" (cl-ppcre:split "\\s+" text) :test #'string=))

(defun count-words (arguments)
  "Return the number of words in the :text field of ARGUMENTS."
  (let ((text (if (hash-table-p arguments)
                  (gethash "text" arguments)
                  (getf arguments :text))))
    (format nil "~D word~:P" (length (split-words (or text ""))))))

(defun count-words-self-test ()
  "Return T when the handler still counts words."
  (let ((arguments (make-hash-table :test #'equal)))
    (setf (gethash "text" arguments) "one two three")
    (equal (count-words arguments) "3 words")))

(enchiridion.plugin:define-plugin word-count
  :tool (enchiridion.plugin:tool
         "word-count"
         "Return the number of words in a text."
         (:object :required (:text) :properties ((:text :string))))
  :handler #'count-words
  :self-test #'count-words-self-test)
LISP
```

The shell exits 0, and the file holds a tool, a handler, and a self-test, with the `tool` form that the manifest reader understands.

**Step 3. Verify the agent directory.**

```sh
nix run .#enchiridion -- --verify-plugin agents/default
```

The command exits 0 and prints the passing report.
With the two seed example files still present, the report is `3 files compiled, 3 self-tests ran`.
Inside the deployed container, the same check runs as `docker exec enchiridion enchiridion --verify-plugin /var/lib/enchiridion/agents/default`.

**Step 4. Ask the running supervisor to load the next generation.**

```sh
nix run .#enchiridion -- reload
```

The command exits 0 and prints two lines:

```text
reload done, generation N.
generation N.
```

A supervisor that has loaded its first generation reports generation 2 here.
The model sees the manifest of `word-count` on the next turn, and a call to that name runs `count-words` in the broker child.

A supervisor that is not running loads the file on the next `ask`, `chat`, or `serve`, and inside the container the reload command runs as `docker exec enchiridion enchiridion reload`.
[Deployment](deployment.md) covers the container and its state volume.

## The shadow rule

The registry is a hash table keyed by the lowercased tool name, and `register-tool` replaces an existing entry, so the loader does not refuse a collision.
Two files that define the same name leave the later one in the registry, and both plugins stay in the plugin registry.
A plugin named `read-file` therefore replaces the built-in in the broker child, and a later `discard-generation` removes the name without bringing the built-in back in that process.

The supervisor registers one proxy per manifest in a private copy of the registry, discarding the previous generation in that copy and not in the live table.
A proxy carries the authored name, description, and schema, and `:broker-side-p` true, and its handler refuses with `configuration-error` at `:broker` because every call is routed to the broker first.
The copy becomes the live registry by one assignment, and only after the child's reply has agreed on the digest and the generation, so a failed staging or a refused load leaves the previous proxies in place.

## Reload

Reload is a control request, not a second supervisor.
`enchiridion reload` appends one line to the control file and waits up to five seconds for the supervisor to answer, then exits with this status.

| Situation                  | Output                                                    | Exit status |
| -------------------------- | --------------------------------------------------------- | ----------- |
| The generation loaded      | `reload done, generation N.` and `generation N.`          | 0           |
| The generation was refused | `reload refused: REPORT` and `generation N.`              | 1           |
| No supervisor answered     | `reload: no supervisor is running, so nothing was asked.` | 1           |

The supervisor consumes the line, runs its reload hook, and records the new generation only when the hook reports success.
The daemon hook reads one source snapshot, stages the complete proxy registry in a private copy, verifies in a one-shot child, and asks the broker child to load with verification off, because the one-shot child already verified the files.
Both children are handed the same digest string, and the load reply carries the digest the child published and the generation that is live after the call.
The supervisor installs the staged registry only when the reply agrees on both, and the install is a pointer swap: no proxy is built or registered after the child is live.

| Field                    | Where                             | Meaning                                                     |
| ------------------------ | --------------------------------- | ----------------------------------------------------------- |
| `--digests STRING`       | The verification child's argv     | The snapshot to hold the directory to; a mismatch exits 1    |
| `digests` in the request | The `load-generation` call        | The same string, bound for the child's hook as `*load-source-digests*` |
| `digests` in the reply   | The child's answer                | The digest the child published, or null when it reports none |
| `generation` in the reply| The child's answer                | The generation live after the call, or null                 |
| `report` in the reply    | The child's answer                | The refusal lines, or what loaded                           |

The child's hook reads the digest from `enchiridion.tools.broker::*load-source-digests*` rather than from a third argument, so a hook that takes `(directory generation)` keeps working.
A hook returns `(values ok-p report)`, and optionally the digest it published and the generation it left live; a hook that returns only two values reports neither, and the supervisor's two checks then fail rather than pass by default.
A refused generation is a report and not a crash: the last good generation keeps serving, and the next attempt computes the same next number.
The same control file carries the channel and heartbeat requests, and [Supervisor and heartbeat](supervisor.md) owns it.

## The reload transaction

A reload reads one directory three times: for manifests, in the verification child, and in the child that loads. Those reads are seconds apart, and a file that changes between them would install a proxy for a handler the child never loaded.
The snapshot closes that window as far as a file system allows, and the publication point decides what a reader can see.

`snapshot-sources` reads every compiled source once, in load order, and returns a `source-snapshot`: a relative path and a SHA-256 per file, plus one digest string over the list.
The digest string is the whole snapshot in a form that crosses a process boundary, `sha256:` and 64 lowercase hex characters.

| Function                      | Result                                                              |
| ----------------------------- | ------------------------------------------------------------------- |
| `snapshot-sources`            | The snapshot of a directory, or a `configuration-error` above the size bound |
| `snapshot-sources` on an empty tree | A snapshot with no files and the digest of the empty list     |
| `source-snapshot-files`       | The relative path and digest pairs, in load order                    |
| `source-snapshot-digest`      | The one digest string that names the whole snapshot                  |
| `source-changes`              | One line per file added, removed, or changed between two snapshots    |
| `source-mismatch`             | Why a snapshot and a directory disagree, or nil                      |

`load-generation` accepts `:source-digests`, which is a snapshot or that one string, and it refuses before anything becomes visible in four cases:

| Case                                  | Report                                                     |
| ------------------------------------- | ---------------------------------------------------------- |
| The tree no longer matches the caller | `the agent source changed since it was read: FILE changed` |
| A file changed after verification     | The same line, naming each file                            |
| A file changed during the load        | `the agent source changed while it loaded: FILE changed`   |
| A file above the snapshot size bound  | `Configuration is wrong at PLUGIN. FILE is larger than N bytes.` |

`verify-directory` takes the same keyword and refuses without compiling a file when the tree moved, so the child that compiles and the child that loads are held to one snapshot.
A refusal carries `:ok-p nil`, the generation that is still live, and the snapshot it read.

Publication is one function and one place. `load-generation` holds the reload lock from the snapshot to the publication, builds the new registry and plugin list as private copies, checks the snapshot once more, and only then calls `publish-generation`, which sets the registry, the plugins, and the generation counter.
The registry is a complete table that no reader has seen before, so a dispatch sees every tool of the old generation or every tool of the new one, and never a half filled table.
The three setfs are sequential, and a reader of two of them could see one new value beside one old one, so no reader does that: dispatch reads the registry, the status reads the generation, and the reload itself is what needs all three, which is why it holds the lock.

Rollback covers the registry entries, the plugin records, the generation counter, and dispatch in this process.
It does not undo a global side effect that a top-level form performed while it loaded, such as a `defvar`, a package it created, a file it wrote, or a thread it started.
The isolation for code that must not do that is the process and uid boundary, not a transaction, and this page says so instead of promising more.

> **Important:** a failed activation keeps both sides only when each side refuses before it publishes.
> The loader refuses before its setf. The supervisor's proxies are a second registry in a second process, and a proxy install that signals after a successful load leaves the supervisor a generation behind the child. Building every proxy before registering any of them, and installing only after the child answers, is what narrows that to a failed construction with nothing installed.

> **Note:** the digest is a change detector for source bytes and not a proof that the loaded code was the verified code. The loader digests a file and then reads it to load, so a writer that swaps a file between those two operations is not detected, and a digest says nothing about what a top-level form does while it runs: writing files, starting threads, and mutating globals are outside what any recheck can see. What the digest buys is that an ordinary edit between the manifest read, the verification child, and the load no longer installs a proxy for a handler the child did not compile, and that the reader is told which file moved.

## Limits of verification

- Verification proves that a file compiles, loads without a warning, and passes its own self-test, and it does not prove that the handler behaves correctly.
- Top-level forms run once in the verification child and again in the load that follows, so a file with a load-time side effect performs it twice.
- A handler runs in the broker child, and it can change any file that child's user can write.
  In a split run that user is the configured agent uid, and the core is protected by file ownership and not by the loader.
  In a checkout started as the operator the child runs as that user, so it can change the source tree, the agent directory, and `.env`.
  The broker boundary keeps secrets out of the child environment. It does not restrict the agent to its directory.
- The schema budget is shared by every tool and is 2000 estimated tokens.
  An oversized plugin schema makes `registry-tool-definitions` signal `budget-exceeded`, and every turn then fails with the message `The SCHEMA budget is spent: N of 2000 tokens.`
- The supervisor reads only the manifest of an agent file, so it cannot see a handler before the load.
- A source that changes between the manifest read, the verification child, and the load is refused only when the caller passes `:source-digests`.
  The daemon path in `src/main.cl` takes one snapshot, hands its digest to both children, and refuses a reply that reports another one; a caller of `load-generation` that passes nothing can only check the load-time window.
- The snapshot covers the compiled sources under `skills/` and `tools/`, and not the markdown reference skills, which are read on demand and never loaded.

## Troubleshooting

| Symptom                                                   | Cause                                                                    | Fix                                                           |
| --------------------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------- |
| `reload refused: FILE: WARNING`                           | The file compiles with a warning                                         | Correct the warning, then reload again                        |
| `reload refused: NAME self-test returned NIL`             | The self-test reports a broken file                                      | Repair the handler or the self-test                           |
| `reload refused: NAME self-test signalled: CONDITION`     | The self-test raised a condition                                         | Read the condition and repair the file                        |
| `reload refused: FILE: CONDITION`                         | The child cannot read or compile the file                                | Balance the forms and the parentheses, then reload            |
| `reload: no supervisor is running, so nothing was asked.` | No fresh status file, or verification outlasted the five second wait     | Start `serve` or `chat`, or read `enchiridion health` and wait |
| `The SCHEMA budget is spent: N of 2000 tokens.`           | The tool schemas exceed the shared budget                                | Remove a tool or shorten its schema                           |
| A tool from the new file is absent                        | The file is not directly under `skills/` or `tools/`, or does not end in `.cl` | Move the file and reload                                      |
| The tool runs but the model never sees it                 | The tool argument is computed, so the manifest reader finds no name      | Write the `(tool ...)` form in the file                       |
| A reload is refused with no failure line                  | The verification child exceeded its 120 second timeout                   | Reduce the work the top-level forms do                        |

## See also

- [Tools](tools.md) for the registry, the schema budget, and the handler contract.
- [Commands](commands.md) for the command table that carries `reload`.
- [Supervisor and heartbeat](supervisor.md) for the control file and the process that owns the generations.
- [Deployment](deployment.md) for the container and the uid split that makes the broker boundary real.
- [Skills](skills.md) for the two kinds of skill and what the tree implements of each.
- [Testing](testing.md) for the loader and verification tests.
