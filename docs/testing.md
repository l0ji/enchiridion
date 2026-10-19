# Testing

Two ASDF systems hold the tests. `enchiridion-tests` is the unit suite, and
every commit passes it. `enchiridion-tests/property` is slower and separate,
so a short check does not become a long one. The unit suite lives in `t/core/`
and the property suite lives in `t/property/`. Both systems turn a compile
warning into an error, and both run through the rove bridge in
`t/support/rove-bridge.cl`.

## The two systems

| System                       | Files             | Depends on                           |
| ---------------------------- | ----------------- | ------------------------------------ |
| `enchiridion-tests`          | `t/core/*.cl`     | `enchiridion`, `rove`                |
| `enchiridion-tests/property` | `t/property/*.cl` | `enchiridion-tests`, `cl-quickcheck` |

`t/enchiridion-tests.asd` names every file. The core module lists 26 files and
the property module lists 2. Both modules are `:serial t`, so the load order
is the order in the file.

The core system wires the unit suite in.

```lisp
:in-order-to ((test-op (test-op "enchiridion-tests")))
```

`(asdf:test-system "enchiridion")` therefore runs the unit suite. The property
system is not in that chain, so the gate asks for it by name.

## How to run the suite

| Command               | Effect                             |
| --------------------- | ---------------------------------- |
| `nix run .#check`     | Compiles every file. Runs no test. |
| `nix run .#test`      | Compiles and runs both systems.    |
| `nix build .#check`   | The same gate as a derivation.     |
| `nix build .#default` | The test gate as a derivation.     |

`nix run .#test` runs two commands in order.

```sh
# inside the gate
run_sbcl '(asdf:test-system "enchiridion-tests")'
run_sbcl '(asdf:test-system "enchiridion-tests/property")'
```

Inside `nix develop`, the same call works with SBCL directly.

```sh
sbcl --non-interactive --no-userinit --no-sysinit \
  --eval '(require :asdf)' \
  --eval '(asdf:test-system "enchiridion-tests")'
```

Each system prints its own name, the count of tests that ran, and the words
`tests passed`. The `:perform` method of each system calls
`enchiridion-rove-bridge:run-suites` and prints that line. A failure in any
test signals, and ASDF exits non-zero.

`nix run .#check` compiles the system and also compiles two files by hand.

| File                 | Why                                                |
| -------------------- | -------------------------------------------------- |
| `src/main.cl`        | The wrapper runs it. It is not a system component. |
| `src/broker-exec.cl` | The broker child runs it. It is not a component.   |

Neither file is a system component, because loading a system must never start
an agent. The gate compiles both and checks `failure-p`, because
`compile-file` returns a failure flag on a read error instead of signalling.

The gate loads every dependency from the fasl that Nix built beside its source,
so it compiles only this project's files. The flake sets
`ASDF_OUTPUT_TRANSLATIONS` so the dependencies resolve to the store and the test
sources resolve to the gate's writable cache. A gate log with a dependency's
source file under a `compiling file` line means that setting stopped working.

## The warning gate

The core system and both test systems carry the same `:around-compile` hook.

```lisp
(lambda (compile-function)
  (handler-bind ((warning #'error))
    (let ((asdf:*compile-file-warnings-behaviour* :error))
      (with-compilation-unit (:override t)
        (funcall compile-function)))))
```

Three parts make a warning fatal.

- The handler catches a warning raised while the file compiles.
- The binding makes `uiop:compile-file*` treat file warnings as fatal.
- `:override` catches a warning that SBCL defers to the end of the unit.

ASDF keeps one compilation unit open for the whole plan. Without `:override`,
an undefined function in a file is reported after the hook returns, and no
handler is left to see it. The binding is scoped to one system, so a
dependency with its own warning does not stop the build.

## The rove bridge

`(rove:run "enchiridion-tests")` does not work here. Rove maps source files
back to packages by the `.lisp` extension, and this project uses `.cl`. The
mapping finds nothing, and the run reports success after zero tests. A green
suite that ran nothing hides the next real failure.

The bridge runs what rove collected instead.

| Function                | Result                                             |
| ----------------------- | -------------------------------------------------- |
| `run-suites`            | Runs every registered suite and returns the count. |
| `suite-count`           | How many suites rove registered.                   |
| `test-count`            | How many `deftest` forms rove registered.          |
| `missing-bridge-symbol` | True when rove no longer exports a name.           |

`run-suites` reads `rove:all-suites` and the `suite-tests` accessor, then
calls `rove:run-tests` on the collected names. It signals an error when rove
collected no tests, and it signals when any test fails. A run that finds no
tests fails the build.

The bridge resolves the `suite-tests` accessor by name, not by import. A rove
upgrade that renames it produces a clear error in one function instead of a
reader error at load time.

## What each test file covers

| File              | Subject                                                  |
| ----------------- | -------------------------------------------------------- |
| `errors-test`     | The condition hierarchy and every report.                |
| `compat-test`     | The implementation extensions in `compat.cl`.            |
| `config-test`     | The sectioned and flat configuration readers.            |
| `llm-test`        | Protocol shapes, the OpenAI wire format, backend choice. |
| `anthropic-test`  | The Messages API wire format and provider choice.        |
| `blocks-test`     | Block limits, the write scan, prompt stability.          |
| `store-test`      | SQLite, FTS5, sessions, memories, and the ledger.        |
| `tiers-test`      | L0, L1, L2, and the two miss rule.                       |
| `kernel-test`     | The prompt compiler, the snapshot, and one turn.         |
| `schema-test`     | The tool schema as JSON and as a check.                  |
| `registry-test`   | Registration, the schema budget, and dispatch.           |
| `pipe-test`       | The filter sandbox and its refusals.                     |
| `file-test`       | The file tools, starting with the index.                 |
| `broker-test`     | The frame format and the in-process transport.           |
| `builtin-test`    | Search, blockops, meta, and web.                         |
| `git-test`        | The nested agent repository.                             |
| `loader-test`     | Generations, verification, and manifests.                |
| `channel-test`    | The message shape and the channel protocol.              |
| `cli-test`        | The shared command table and the REPL.                   |
| `supervisor-test` | The control file, the status file, and channels.         |
| `tool-loop-test`  | The model asks, the kernel runs, the model answers.      |
| `seed-test`       | The seed files, the first launch, and bootstrap.         |
| `secrets-test`    | The scrubber and the file-mode, discard, and name rules. |
| `http-test`       | The webhook routes, the token, and the limits.           |
| `fluxer-test`     | The Fluxer direct-message rules.                         |
| `sleep-test`      | The heartbeat, the sleep agent, and compaction.          |
| `seed-property`   | Seed round trips and bootstrap completeness.             |
| `prompt-property` | Byte stable prompts and the frozen snapshot.             |

The container isolation test is separate. `docker/isolation-test.sh` needs
uid 1000 and a real secret tmpfs, so it does not run in this suite.

## The property tests

The property system holds two files. Both drive the code over generated input
rather than one fixture.

`seed-property.cl` checks four properties. A seed template survives a write
and a read with its text intact. A block value under its limit keeps every
character. `init-agent` never overwrites a file. Bootstrap is complete when
every step is done, and at no other time.

`prompt-property.cl` checks two properties. The same blocks compile to
identical bytes twice. A write after compilation changes the block and leaves
the snapshot alone. The first property is what makes the prefix cache work,
and a silent break there costs money on every turn.

Both files use `rove` with loops and `random`. The system declares
`cl-quickcheck`, and neither property file calls it.

Note on scratch files. A property test writes under
`*default-pathname-defaults*`, not under `TMPDIR`. A nix build sandbox has no
writable `/tmp`, so a test that asks for one fails before it reaches the code
under test.

## How to add a test

1. Make a file under `t/core/` whose name ends in `-test.cl`.
2. Define a package that uses `#:cl` and imports the rove names.
3. Write one `(deftest ...)` form with `(ok ...)` checks.
4. Add a `(:file ...)` entry for the file to the core module of the `.asd`.
5. Run `nix run .#test`.

A new unit file starts like this.

```lisp
(defpackage #:enchiridion-example-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:testing)
  (:export #:run))

(in-package #:enchiridion-example-test)

(deftest a-keyword-becomes-a-json-type ()
  (ok (equal "string"
             (gethash "type"
                      (enchiridion.tools:schema-to-json :string)))))
```

Every existing file exports `#:run`. The bridge collects the suites that rove
registered, so `deftest` is the form that registers a test. The export is
convention, not the mechanism.

The file must be in the `.asd`. A file that no system names is never compiled,
and rove never sees it. Add it at the end of the core module list, unless the
test must load after another one. Both modules are `:serial t`, so order is
real.

A test that writes to disk makes its own scratch directory and removes it in
an `unwind-protect`. A test that touches git binds
`enchiridion.git:git-test-environment`, because the build sandbox has no
global git identity.

## Related

- [Development](development.md)
- [Tools](tools.md)
- [Plugins and self-modification](plugins.md)
- [Getting started](getting-started.md)
- [Deployment](deployment.md)
