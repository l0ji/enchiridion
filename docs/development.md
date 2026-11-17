# Development

enchiridion is a Common Lisp program built by a Nix flake. Agent skills and
tools can be hot-reloaded; core changes need a restart or rebuild. This is not
a file-access restriction: tools can write anything their UNIX user can.

## Repository layout

| Path | Contents |
| --- | --- |
| `enchiridion.asd` | The core system and its load order |
| `src/main.lsp` | The program: argument handling and the entry point |
| `src/broker-exec.lsp` | The agent side of the broker, run as a child process |
| `src/git-exec.lsp` | Drops to the agent identity before Git touches the agent repository |
| `src/enchiridion/` | The core, one file or directory per subsystem |
| `t/` | The two test systems and the suites |
| `flake.nix` | The build, the checks, the shells and the package |
| `docker/` | The image, the entrypoint, the wrapper and the isolation test |
| `docs/` | This documentation |

`src/main.lsp`, `src/broker-exec.lsp` and `src/git-exec.lsp` are programs, not system
components. Loading a system must never start an agent, so the gate compiles all
three explicitly.

## Build

```sh
nix develop                      # SBCL, SQLite, Git and the Lisp dependencies
nix develop .#full               # adds the C toolchain, full Git, colima and clang-tools
nix run .#check                  # compile every system file and the three programs
nix run .#test                   # the check, then both test systems
nix run .#enchiridion -- help    # run the program from the flake
nix build                        # the package
```

The default shell carries no C toolchain, because Nix builds the C dependencies.
A new C-backed Lisp dependency compiled by hand needs `.#full`.

The package installs `src/` and `enchiridion.asd` under `$out/lib` and the
wrapper at `$out/bin/enchiridion`. The wrapper puts the package Git on `PATH` and
in `ENCHIRIDION_GIT`, because Git is a runtime dependency. `t/`, `docs/`,
`docker/`, `compose.yml`, `flake.nix`, `README.md` and `LICENSE` are not runtime
inputs.

The flake pins `nixpkgs` by branch and records the commit in `flake.lock`.
Updating the lock also updates SBCL and its Lisp package set:

```sh
nix flake update nixpkgs
nix run .#check
nix run .#test
```

Commit `flake.lock` with the update.

## Packages

Each subsystem owns a package, and every package is declared in
`src/enchiridion/packages.lsp`. A symbol carries the name of its thing, so a call
reads as `enchiridion.llm:complete` and the source of the symbol is visible at the
call site. Imports are explicit; no file uses another package wholesale.

A configuration file is read in `enchiridion.user`, so every `config.lsp` begins
with `(in-package #:enchiridion.user)`.

## Code style

The code follows the [lisp-lang.org style guide](https://lisp-lang.org/style-guide/).

- Lowercase words separated by single dashes, spelled in full: `user-count`, not
  `user-cnt`.
- A special variable takes `*earmuffs*`, and a constant takes `+plus-signs+`.
- A predicate on one word ends in `p`, and on several words in `-p`.
- Indent by two spaces and keep lines near 100 columns.
- `;;;;` states the purpose of a file, `;;;` separates regions, `;;` marks a
  region inside a form, and `;` adds a note at the end of a line.
- A function another file calls gets a `declaim (ftype ...)` before its `defun`.
  A CLOS slot gets a `:type`, and its options read `:accessor`, `:initarg`,
  `:initform`, `:type`, `:documentation`.
- A failure is a condition with a `:report` method, not a formatted string.
- `src/enchiridion/compat.lsp` is the only core file with implementation-specific
  code. The three entry scripts run under `--script`, before the system loads,
  so they may call SBCL directly.

Tool argument schemas are checked by `cl-jschema`, and the type declarations are
SBCL's.

## Tests

The tests are two ASDF systems. `enchiridion-tests` is the unit suite, and
`enchiridion-tests/property` holds the slower property tests. Both turn a compile
warning into an error, and both run every suite rove collected through a small
bridge.

| Command | Effect |
| --- | --- |
| `nix run .#check` | Compiles the system and the three entry scripts. Runs no test |
| `nix run .#test` | Runs the check, then both test systems |
| `nix build .#checks.<system>.check` | Builds the compile gate as a derivation |
| `nix build .#checks.<system>.default` | Builds the test gate |

Replace `<system>` with `aarch64-darwin`, `aarch64-linux` or `x86_64-linux`. A
passing check ends with `enchiridion-check passed.` A passing test run prints one
count line per system, in this shape, then `enchiridion-test passed.`:

```text
Running N tests in M suites.
enchiridion-tests: N tests passed.
```

The property count includes the unit tests, because the property system depends
on the unit system and the process registers both.

Inside `nix develop` the same systems run under SBCL directly:

```sh
sbcl --non-interactive --no-userinit --no-sysinit \
  --eval '(require :asdf)' \
  --eval '(asdf:test-system "enchiridion-tests")'
```

Use `"enchiridion-tests/property"` for the property system. `(asdf:test-system
"enchiridion")` runs only the unit suite.

### Warnings are errors

Both `.asd` files install the same `:around-compile` hook, and three parts make
a warning fatal: a handler turns it into an error during compilation,
`asdf:*compile-file-warnings-behaviour*` makes `uiop:compile-file*` treat file
warnings as fatal, and `with-compilation-unit :override` catches a warning SBCL
defers to the end of the outermost unit, after the hook has returned. The hook is
scoped to one system, so a dependency's warning does not stop this build.

### The bridge

Running a test system through `rove:run` would find nothing. rove maps source
files to packages by the `.lisp` extension, these files use `.lsp`, and a run
started that way reports success after zero tests. `t/support/rove-bridge.lsp`
runs what rove collected instead, and fails when it collected nothing. A count
comes from `run-suites`; a failure signals, so the SBCL process exits non-zero.

### Writing a test

1. Create a file under `t/core/` whose name ends in `-test.lsp`. Define a package
   that uses `#:cl`, imports `deftest`, `ok`, `ng` and `testing` from `#:rove`,
   and exports `run`; then `(in-package #:enchiridion-example-test)`.

2. Write at least one `deftest` form. The `run` export is convention; the
   `deftest` is what registers the test.

   ```lisp
   (deftest a-keyword-becomes-a-json-type ()
     (ok (equal "string"
                (gethash "type"
                         (enchiridion.tools:schema-to-json :string)))))
   ```

3. Add `(:file "example-test")` to the core module of `t/enchiridion-tests.asd`.
   A file no system names is never compiled, and rove never sees it.

4. Run `nix run .#test`. The gate compiles the file with warnings as errors and
   the count rises by the tests it defines.

A test that writes to disk creates its own directory under
`*default-pathname-defaults*` and removes it in an `unwind-protect`. That is the
build directory, which the gate can write; a path from `TMPDIR` may not be
writable there.

A test that calls Git passes `enchiridion.git:git-test-environment` as the
child's environment, because the build sandbox has no global Git identity and no
signing key.

A property test follows the same steps under `t/property/`, with its `(:file ...)`
entry in the property module.

### Test troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The gate fails on a warning from a new file | Every compile warning is an error | Fix the warning and run it again |
| `rove collected no tests.` | No `deftest` was compiled, or the file is not in a system | Add the `deftest` and the `(:file ...)` entry |
| The suite passes but a new test never runs | The file is absent from `t/enchiridion-tests.asd` | Add it to the right module |
| A Git test fails for a missing identity | The sandbox has no global Git configuration | Pass `git-test-environment` to the call |
| A file test fails only in the gate | It wrote outside the build directory | Write under `*default-pathname-defaults*` and clean up |

## Commits

- The branch is `main`.
- One commit per logical unit, where a unit can be tested on its own.
- The subject is in the imperative mood; a body is optional.

## Writing documentation

- State current behavior only. No change history and no reference to the plan
  that produced the code.
- Put a fact on one page and link to the page that owns it.
- Open a section with a sentence that says what the subject is, then give the
  common case, then the reference detail.
- Do not pin a tool version in prose; the build files record it.
- Define an acronym at its first use, then use the acronym.
- Give a tested example.
