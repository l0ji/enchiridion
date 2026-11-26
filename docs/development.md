# Development

Enchiridion is a Common Lisp project built with a Nix flake. Agent plugins and
skills hot-reload via `enchiridion reload`; changes to core Lisp files require a
restart or rebuild.

## Repository layout

| Path | Contents |
| --- | --- |
| `enchiridion.asd` | Core ASDF system and load order |
| `src/main.lsp` | CLI entry point (`sbcl --script`) |
| `src/broker-exec.lsp` | Broker child process (runs agent tools/plugins) |
| `src/git-exec.lsp` | Helper that drops to agent UID before running `git` |
| `src/enchiridion/` | Core subsystems (`channel/`, `llm/`, `memory/`, `plugin/`, `tools/`) |
| `t/` | Unit (`t/core/`) and property (`t/property/`) test suites |
| `flake.nix` | Build, checks, dev shells, and package |
| `docker/` | Dockerfile, entrypoint, wrapper, and `isolation-test.sh` |

`src/main.lsp`, `src/broker-exec.lsp`, and `src/git-exec.lsp` are standalone
entry scripts, not ASDF system components, so loading the system never starts an
agent. The compile gate compiles all three explicitly.

## Build and test

```sh
nix develop                    # SBCL, SQLite, Git, Lisp deps (no C compiler)
nix develop .#full             # adds C toolchain, full Git, colima, clang-tools
nix run .#check                # compile core and entry scripts (warnings fail)
nix run .#test                 # run .#check, then unit and property tests
nix run .#enchiridion -- help  # run from the flake
nix build                      # build the package
```

Inside `nix develop`, run the test systems directly with SBCL:

```sh
sbcl --non-interactive --no-userinit --no-sysinit \
  --eval '(require :asdf)' \
  --eval '(asdf:test-system "enchiridion-tests")'
```

Use `"enchiridion-tests/property"` for the property suite (note: its total count
includes unit tests because it depends on `enchiridion-tests`).

To update `nixpkgs` (including SBCL and Lisp packages): `nix flake update
nixpkgs && nix run .#test`, then commit `flake.lock`.

## Conventions

- **Packages:** all packages are declared in `src/enchiridion/packages.lsp`. Use
  explicit imports or package-qualified calls (`enchiridion.llm:complete`); do
  not `:use` internal packages wholesale. `config.lsp` is read in
  `enchiridion.user`.
- **Style:** follow the [lisp-lang.org style
  guide](https://lisp-lang.org/style-guide/)—kebab-case full words, `*earmuffs*`
  for specials, `+plus-signs+` for constants, `p` / `-p` predicates, 2-space
  indent, ~100-column lines.
- **Types & conditions:** add `(declaim (ftype ...))` before exported/cross-file
  functions, `:type` on CLOS slots, and signal conditions from
  `enchiridion.errors` with `:report` methods instead of raw error strings.
- **Portability:** keep SBCL-specific code in `src/enchiridion/compat.lsp` (and
  the three `--script` entrypoints).
- **Commits:** commit to `main` in logical, independently testable units with
  imperative commit subjects.

## Writing tests

Both `enchiridion.asd` and `t/enchiridion-tests.asd` treat **every compile
warning as a fatal error** (including deferred SBCL warnings via
`with-compilation-unit :override`).

Because source files use `.lsp` instead of `.lisp`, `rove:run` does not
auto-discover them. `t/support/rove-bridge.lsp` runs all suites rove collected
and fails if zero tests were registered.

To add a test:

1. Create `t/core/<name>-test.lsp` (or `t/property/`), define a package
   importing `deftest`, `ok`, `ng`, and `testing` from `#:rove`, and write your
   `deftest` forms.
2. Add `(:file "<name>-test")` to `t/enchiridion-tests.asd` (unlisted files are
   never compiled or run).
3. Run `nix run .#test`.

Two Nix-sandbox gotchas for tests:

- **Temp files:** create scratch directories under `*default-pathname-defaults*`
  (cleaned up in `unwind-protect`), not `TMPDIR`, which may not be writable in
  the Nix build sandbox.
- **Git calls:** pass `enchiridion.git:git-test-environment` as the child
  environment, since the build sandbox has no global Git identity.
