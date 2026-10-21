# Testing

The tests live in two systems defined by Another System Definition Facility (ASDF).
`enchiridion-tests` is the unit suite, and `enchiridion-tests/property` holds the slower property tests separately.
Both systems turn a compile warning into an error and both run through the bridge in `t/support/rove-bridge.cl`.
A developer can run the gate, add a test to it, and read which source file each module covers.

## Two test systems

`t/enchiridion-tests.asd` defines both systems, and every module declares `:default-component-class "cl-source-file.cl"`, which is how ASDF is told the extension is `.cl`.
Each module is serial, so the load order is the order of the `:file` entries.

| System                       | Sources                                      | Depends on                           |
| ---------------------------- | -------------------------------------------- | ------------------------------------ |
| `enchiridion-tests`          | `t/support/rove-bridge.cl` and `t/core/*.cl` | `enchiridion`, `rove`                |
| `enchiridion-tests/property` | `t/property/*.cl`                            | `enchiridion-tests`, `cl-quickcheck` |

The core system wires the unit suite in with `:in-order-to ((test-op (test-op "enchiridion-tests")))`, so `(asdf:test-system "enchiridion")` runs it.
The property system is not in that chain, so the gate asks for it by name, and a property run loads both suites because it depends on the unit system.
Each test system has a `test-op` method that calls `uiop:symbol-call :enchiridion-rove-bridge 'run-suites` and prints one count line.
The property system prints its own name in place of `enchiridion-tests`, and a failure signals from `run-suites` so the gate's SBCL process exits non-zero.

## Running the tests

| Command               | Effect                                                           |
| --------------------- | ---------------------------------------------------------------- |
| `nix run .#check`     | Compiles every system file and both entry scripts. Runs no test. |
| `nix run .#test`      | Runs the check, then both test systems.                          |
| `nix build .#check`   | Builds the check gate as a derivation.                           |
| `nix build .#default` | Builds the test gate as a derivation.                            |

`nix run .#check` exits 0 and prints `enchiridion-check passed.`, and `nix run .#test` exits 0 and prints the two count lines then `enchiridion-test passed.`
The flake exposes apps `default`, `check`, and `test`, and checks `flake`, `enchiridion`, `check`, and `default`, where the `default` check is the test gate.
The test gate runs `asdf:test-system` in two SBCL processes, one per system, and the second process holds both suites because the property system depends on the unit system.

Inside `nix develop`, the same call works with SBCL directly:

```sh
sbcl --non-interactive --no-userinit --no-sysinit \
  --eval '(require :asdf)' \
  --eval '(asdf:test-system "enchiridion-tests")'
```

A passing system prints one line from the bridge and one from the `test-op` method:

```text
Running N tests in M suites.
enchiridion-tests: N tests passed.
```

The counts depend on the files the system names, and a test failure signals so the gate exits non-zero.

## The gate

Both gates come from one function and differ by one flag, and both compile the core system, then compile the two entry scripts with `compile-file` and check the failure flag:

| File                 | Why the gate compiles it                                                    |
| -------------------- | --------------------------------------------------------------------------- |
| `src/main.cl`        | The wrapper runs it with `--script`, and it is not a system component.      |
| `src/broker-exec.cl` | The broker child runs it with `--script`, and it is not a system component. |

Loading a system must never start an agent, so neither script is a component, and `compile-file` returns a failure flag on a read error instead of signalling.
The gate loads the dependencies from the store, and it sends the test sources from the read-only store to a writable cache in the build directory through `ASDF_OUTPUT_TRANSLATIONS`.

## Warnings as errors

The core system and both test systems carry the same `:around-compile` hook, and three parts make a warning fatal.
The handler catches a warning raised while the file compiles, and the binding makes `uiop:compile-file*` treat a file's warnings as fatal.
`:override` catches a warning that SBCL defers to the end of the outermost compilation unit, because without it an undefined function is reported after the hook returns and no handler remains.
The hook is scoped to one system, so a dependency that compiles with its own warning does not stop this build.

## The bridge to rove

Running a test system through `rove:run` finds nothing: rove maps source files back to packages by the `.lisp` extension, these files use `.cl`, and a run started that way reports success after zero tests.
A green suite that ran nothing hides the next real failure, so the bridge runs what rove collected instead.

| Function                | Result                                                                        |
| ----------------------- | ----------------------------------------------------------------------------- |
| `run-suites`            | Runs every registered suite, signals on a failure, and returns the test count |
| `suite-count`           | The number of suites rove registered                                          |
| `test-count`            | The number of `deftest` forms across every suite                              |
| `missing-bridge-symbol` | True when rove no longer exports a name the bridge needs                      |

`run-suites` reads `rove:all-suites` and the `suite-tests` accessor, prints the test and suite counts, and calls `rove:run-tests` on the collected names.
It signals an error when rove collected no tests, with the message `rove collected no tests. Every suite file defines no deftest, or the suite was never compiled.`
It signals `Tests failed.` when any test fails, and otherwise returns the number of tests.
The bridge resolves the `suite-tests` accessor by name from `:rove/core/suite/package`, so a library rename produces a clear error rather than a reader error at load time.

## Module coverage

| File                                                     | Subject                                                                |
| -------------------------------------------------------- | ---------------------------------------------------------------------- |
| `errors-test.cl`, `compat-test.cl`                       | The condition hierarchy and reports, and the implementation extensions |
| `config-test.cl`                                         | The sectioned and the flat configuration readers                       |
| `llm-test.cl`, `anthropic-test.cl`                       | The protocol, the OpenAI wire format, and the Messages API shapes      |
| `dialect-test.cl`, `catalog-test.cl`, `provider-test.cl` | The quirk profiles, the models.dev catalog, and the provider rows      |
| `aws-sigv4-test.cl`, `bedrock-test.cl`                   | Signature Version 4 and the two Bedrock Anthropic shapes               |
| `gcp-oauth-test.cl`, `vertex-test.cl`                    | The service-account JWT and the Vertex `:rawPredict` path              |
| `blocks-test.cl`, `tiers-test.cl`                        | The block limits, the write scan, and the three read tiers             |
| `store-test.cl`                                          | SQLite, FTS5, sessions, memories, and the token ledger                 |
| `kernel-test.cl`, `tool-loop-test.cl`                    | The prompt compiler, the frozen snapshot, and the tool loop            |
| `schema-test.cl`, `registry-test.cl`                     | The schema as JSON and as a check, registration, and dispatch          |
| `pipe-test.cl`, `file-test.cl`, `builtin-test.cl`        | The filter sandbox, the file tools, and the remaining built-ins        |
| `broker-test.cl`, `git-test.cl`, `loader-test.cl`        | The broker transport, the agent repository, and the loader             |
| `channel-test.cl`, `cli-test.cl`, `supervisor-test.cl`   | The channel protocol, the command table, and the control files         |
| `seed-test.cl`, `secrets-test.cl`                        | The seed files, the first launch, the bootstrap, and the secrets rules |
| `http-test.cl`, `fluxer-test.cl`                         | The webhook routes and the Fluxer direct-message rules                 |
| `sleep-test.cl`                                          | The heartbeat, the sleep agent, and compaction                         |
| `seed-property.cl`, `prompt-property.cl`                 | Seed round trips and byte-stable prompts                               |

The container isolation test needs uid 1000 and a real secret tmpfs, so it does not run in this suite.
[Deployment](deployment.md) covers that test.

## Generated-input tests

The property files drive the code over generated input rather than one fixture, with explicit loops and `random`.

`seed-property.cl` checks four properties:

- A seed template survives a write and a read with its text intact.
- A block value under its limit keeps every character, including whitespace and Unicode text.
- `init-agent` never overwrites a seed file, however many times it runs.
- The bootstrap is complete exactly when every step is done.

`prompt-property.cl` checks two properties:

- The same blocks compile to identical bytes twice.
- A write after compilation changes the block and leaves the snapshot alone.

The first prompt property is what keeps the prefix cache valid.
The property system declares `cl-quickcheck`, and the property files do not call it.

The count line for `enchiridion-tests/property` includes the unit tests as well, because the property process registers both suites, and the line names the system that asked for the run.

The property tests write under `*default-pathname-defaults*` and not under `TMPDIR`.

## Registering a new test

1. Create a file under `t/core/` whose name ends in `-test.cl`.

2. Define a package that uses `#:cl`, imports the rove names, and exports `run`:

   ```lisp
   (defpackage #:enchiridion-example-test
     (:use #:cl)
     (:import-from #:rove #:deftest #:ok #:ng #:testing)
     (:export #:run))

   (in-package #:enchiridion-example-test)
   ```

   The `run` export is convention.
   The `deftest` form is what registers the test.

3. Write at least one `deftest` form.
   This test checks that a keyword schema becomes a JSON type:

   ```lisp
   (deftest a-keyword-becomes-a-json-type ()
     (ok (equal "string"
                (gethash "type"
                         (enchiridion.tools:schema-to-json :string)))))
   ```

4. Add a `(:file "example-test")` entry to the core module of `t/enchiridion-tests.asd`.
   A file that no system names is never compiled, and rove never sees it.
   Add the entry at the end of the module unless the test must load after another one, because the module is serial.

5. Run the gate:

   ```sh
   nix run .#test
   ```

   The gate exits 0, and the unit count in `enchiridion-tests: N tests passed.` increases by the number of tests the new file defines.

A test that writes to disk makes its own scratch directory under `*default-pathname-defaults*` and removes it in an `unwind-protect`.
A test that touches git binds `enchiridion.git:git-test-environment`, because the build sandbox has no global git identity.

A property test follows the same steps in `t/property/`, and its `(:file ...)` entry goes in the property module.
The property system prints its own count line.

## Troubleshooting

| Symptom                                                  | Cause                                                            | Fix                                                                        |
| -------------------------------------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------- |
| The gate fails with a warning from a new file            | The warning gate treats every compile warning as an error        | Correct the warning, then run the gate again                               |
| `rove collected no tests.`                               | No `deftest` form was compiled, or the file is not in the system | Add the `(:file ...)` entry and a `deftest` form                           |
| The suite passes but the new test never runs             | The file is absent from `t/enchiridion-tests.asd`                | Add the entry to the right module                                          |
| The count line is absent                                 | The test system did not reach its `test-op`                      | Read the gate output for the failure that stopped it                       |
| A property test fails in the gate and passes outside it  | The test writes outside the build directory                      | Write under `*default-pathname-defaults*` and clean up in `unwind-protect` |
| A git test fails for a missing identity                  | The build sandbox has no global git configuration                | Bind `enchiridion.git:git-test-environment` around the call                |
| `(asdf:test-system "enchiridion")` runs no property test | The property system is not in the core test chain                | Run `(asdf:test-system "enchiridion-tests/property")` by name              |

## See also

- [Development](development.md) for the build, the shells, and the source layout.
- [Plugins and self-modification](plugins.md) for the loader and verification under test.
- [Tools](tools.md) for the schema and dispatch under test.
- [Deployment](deployment.md) for the isolation test that runs outside this suite.
