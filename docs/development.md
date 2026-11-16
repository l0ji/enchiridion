# Development

This chapter covers the source tree, the build, the package layout, the load order, the code style, the validation stack, and the commit policy.

## Repository layout

| Path                 | Contents                                                                   |
| -------------------- | -------------------------------------------------------------------------- |
| `enchiridion.asd`    | The core system and its load order.                                        |
| `src/main.cl`        | The program: argument handling and the entry point. ASDF does not load it. |
| `src/broker-exec.cl` | The agent side of the broker, run as a child process.                      |
| `src/git-exec.cl`    | Drops to the agent identity before Git reads the agent repository.          |
| `src/enchiridion/`   | The core, one file or one directory per subsystem.                         |
| `t/`                 | The test systems and the suites.                                           |
| `config.example.cl`  | The tracked template for `config.cl`.                                      |
| `flake.nix`          | The build, the checks, the shells, and the test run.                       |
| `flake.lock`         | The pinned `nixpkgs` revision.                                             |
| `docker/`            | The image, the entrypoint, the wrapper, and the isolation test.            |
| `compose.yml`        | The server deployment for the image.                                       |
| `docs/`              | This documentation.                                                        |

`src/main.cl`, `src/broker-exec.cl`, and `src/git-exec.cl` are programs, not system components.
Loading a system must never start an agent, so no entry script is a component of `enchiridion.asd`.
The gate compiles all three explicitly, so they are still checked.

## Build

The build is a Nix flake.
The flake pins `nixpkgs` by branch and records the commit in `flake.lock`.
SBCL and every Lisp dependency in the development shell and the Nix build come from the locked `nixpkgs` package set, and the gate loads the compiled dependencies from the store.

```sh
nix develop                      # the development shell
nix develop .#full               # with the C toolchain, full git, colima, and clang-tools
nix run .#check                  # compile every system file and the three programs
nix run .#test                   # check, then run both test systems
nix run .#enchiridion -- help    # run the program from the flake
nix build                        # the package
```

The default shell carries no C toolchain.
Nix builds the C dependencies, so a toolchain is necessary only when a new C-backed Lisp dependency is compiled by hand.

The flake uses the standard `nixpkgs` SBCL package without compiler source overrides or Darwin-specific patches.
The package installs `src/` and `enchiridion.asd` under `$out/lib` and the wrapper as `$out/bin/enchiridion`.
The wrapper puts the package Git on `PATH` and in `ENCHIRIDION_GIT`, because Git is a runtime dependency.
`t/`, `docs/`, `docker/`, `compose.yml`, `flake.nix`, `README.md`, and `LICENSE` are not runtime inputs.

### Updating nixpkgs

A checkout keeps the commit in its lock, so a build is reproducible until someone updates it.

```sh
nix flake update nixpkgs
nix run .#check
nix run .#test
```

Updating the lock also updates SBCL and its Lisp package set.
Commit `flake.lock` with the update.

## Packages

Each subsystem owns one package, and the package name follows the directory:

```text
enchiridion              enchiridion.llm          enchiridion.memory
enchiridion.compat       enchiridion.llm.secrets  enchiridion.memory.store
enchiridion.errors       enchiridion.tools        enchiridion.channel
enchiridion.git          enchiridion.tools.pipe   enchiridion.channel.cli
enchiridion.kernel       enchiridion.tools.broker enchiridion.channel.http
enchiridion.plugin       enchiridion.tools.builtin enchiridion.channel.fluxer
enchiridion.supervisor   enchiridion.user
```

`src/enchiridion/packages.cl` holds every definition.
Each definition names its imports with `:import-from`, so a call reads as `enchiridion.llm:complete` and the source of the symbol is visible at the call site.
`enchiridion.user` is the package a configuration file is read in, and every `config.cl` begins with `(in-package #:enchiridion.user)`.

## Load order

`enchiridion.asd` is `:serial t`, so the load order is fixed.

1. `packages` and `compat`. The definitions come before every file that uses them, and `compat` is the only file with implementation-specific code.
2. `config`, `git`, `errors`.
3. `llm`: `secrets`, `protocol`, `json`, `http`, `registry`, `dialects`, `auth`, `openai`, `anthropic`, `aws-sigv4`, `bedrock`, `gcp-oauth`, `vertex`, `catalog`, `providers`.
4. `memory`: `settings`, `blocks`, `episodic-ddl`, `store`, `tiers`, `episodic`, `vectors`, `cue`, `episodic-hooks`, `generations`, `gates`, `derive`, `seed`, `state`.
   The DDL file is data only and loads before the store so `open-store` can create the whole schema in one transaction.
   The memory model loads after the store and before the kernel, which is its caller.
5. `tools`: `schema`, `registry`, `pipe`, `broker`, then the builtins `file`, `shell`, `search`, `blockops`, `memory`, `meta`, `web`, `register`.
6. `plugin`: `loader`, `verify`, `manifest`.
7. `channel`: `protocol`, `http`, `fluxer`.
8. `supervisor`, `kernel`, `sleep`, then `channel/cli`.

Two positions are deliberate: `channel/protocol` loads before the supervisor because the supervisor speaks the protocol, and `channel/cli` loads last because the command table calls both the supervisor and the kernel.

## Code style

The code follows the [lisp-lang.org style guide](https://lisp-lang.org/style-guide/).

- Lowercase words separated by single dashes. Spell a word in full: `user-count`, never `user-cnt`.
- A special variable takes `*earmuffs*`, and a constant takes `+plus-signs+`.
- A predicate on one word ends in `p`, and a predicate on several words ends in `-p`.
- Indent by two spaces, keep both branches of an `if` on one line, and limit a line to 100 columns.
- `;;;;` states the purpose of a file, `;;;` separates regions, `;;` marks a region inside a form, and `;` adds a note at the end of a line.
- Declare an `ftype` before every `defun`; give every CLOS slot a `:type` and write slots in the order `:accessor`, `:initarg`, `:initform`, `:type`, `:documentation`.
- Use a condition and a `:report` method instead of a formatted string.
- Use `when` or `unless` in place of a bare `if`, and move a long condition into a named predicate.
- `src/enchiridion/compat.cl` is the only file with implementation-specific code; every file above it is standard Common Lisp.

## Validation

| Layer                 | Tool                                                                                            |
| --------------------- | ----------------------------------------------------------------------------------------------- |
| Compile-time types    | SBCL `declaim` specifiers                                                                       |
| Warnings as errors    | The `:around-compile` hook in each `.asd` file                                                  |
| Tool argument schemas | `cl-jschema`                                                                                    |
| Unit tests            | `rove`                                                                                          |
| Property tests        | `rove` loops with `random`. The system declares `cl-quickcheck`, and no property file calls it. |

A compile warning is a failure.
`enchiridion.asd` and `t/enchiridion-tests.asd` install an `:around-compile` hook that binds `asdf:*compile-file-warnings-behaviour*` to `:error`, catches a warning raised while the file compiles, and uses `with-compilation-unit :override` to catch a warning SBCL defers to the end of the outermost unit.
The hook is scoped to the system, so a warning from a dependency does not stop the build.

`plugin/verify.cl` proclaims `(optimize (safety 3) (debug 3))` while it loads one plugin file, so a bad plugin stops at a bounds check or a slot type error.
No other file proclaims an optimization level; the `check` gate compiles with the default safety settings.

## Tests

The suite lives in `t/` and mirrors the source tree.
`enchiridion-tests` is the system every commit passes, and `enchiridion-tests/property` is the slower property system.
[Testing](testing.md) covers both systems, the bridge, and module coverage.

## Commit policy

- The branch is `main`.
- One commit per logical unit. A unit is a change that can be tested on its own, not a measure of time.
- The subject is in the imperative mood, and a body is optional.
- Every commit is signed. The global Git configuration sets `commit.gpgsign` to true, `gpg.format` to `ssh`, and `user.signingkey` to the operator's key.

Signature verification needs an allowed signers file.
Without one, `git log --show-signature` reports `N` even when the signature is present.

```sh
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
```

The file holds one line for each signing identity:

```text
you@example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
```

## Writing the documentation

- State current behavior only. No change history and no reference to the plan that produced the code.
- Put a fact on one page and link to the page that owns it.
- Open a section with one sentence that says what the subject is, then give the common case, then the reference detail.
- Do not pin a compiler or tool version in prose; the build files record it.
- Define an acronym at its first use on the page, then use the acronym.
- Give a tested example.

## See also

- [Testing](testing.md)
- [Documentation index](index.md)
