# Development

This chapter covers the source tree, the build, the package layout, the load order, the code style, the validation stack, and the commit policy.
It is written for a developer who will change the code.

## Repository layout

| Path                 | Contents                                                                   |
| -------------------- | -------------------------------------------------------------------------- |
| `enchiridion.asd`    | The core system and its load order.                                        |
| `src/main.cl`        | The program: the command table and the entry point. ASDF does not load it. |
| `src/broker-exec.cl` | The agent side of the broker, run as a child process.                      |
| `src/enchiridion/`   | The core, one file or one directory per subsystem.                         |
| `t/`                 | The test systems and the suites.                                           |
| `config.example.cl`  | The tracked template for `config.cl`.                                      |
| `flake.nix`          | The build, the checks, the shells, and the test run.                       |
| `flake.lock`         | The pinned `nixpkgs` revision.                                             |
| `docker/`            | The image, the entrypoint, the wrapper, and the isolation test.            |
| `compose.yml`        | The server deployment for the image.                                       |
| `docs/`              | This documentation.                                                        |

`src/main.cl` and `src/broker-exec.cl` are programs, not system components.
Loading a system must never start an agent, so neither file is a component of `enchiridion.asd`.
The gate compiles both files explicitly, so they are still checked.

## Build

The build is a Nix flake.
The flake pins `nixpkgs` by branch and records the commit in `flake.lock`.
Every Lisp dependency comes from `nixpkgs`, built with the SBCL that the flake builds from the release tarball, so the Nix build and the container image use one compiler.
The gate loads the compiled dependencies from the store and does not compile them again.

```sh
nix develop                      # the development shell
nix develop .#full               # the shell with the C toolchain, full git, colima, and clang-tools
nix run .#check                  # compile every system file and both programs
nix run .#test                   # check, then run both test systems
nix run .#enchiridion -- help    # run the program from the flake
nix build                        # the package
```

The default shell carries no C toolchain.
Nix builds the C dependencies, so a toolchain is necessary only when a new C-backed Lisp dependency is compiled by hand, and `nix develop .#full` is the shell for that work.

The flake rewrites the interpreter path inside SBCL's sources to `coreutils`, which keeps the Darwin runtime dependencies and the package closure small.
`nixpkgs` can rename the phase that carries the rewrite, and the rewrite then stops matching without a warning.
After an update of `nixpkgs`, run this command and expect `0`:

```sh
nix path-info -r .#packages.<system>.enchiridion | grep -cE 'shell_cmds|bootstrap-tools'
```

The package installs `src/` and `enchiridion.asd` under `$out/lib` and the wrapper as `$out/bin/enchiridion`.
`t/`, `docs/`, `docker/`, `compose.yml`, `flake.nix`, `README.md`, and `LICENSE` are not runtime inputs.

### Updating nixpkgs

The input does not update by itself.
A checkout keeps the commit in its lock, so a build is reproducible until someone updates it.

```sh
nix flake update nixpkgs
nix run .#check
nix run .#test
nix path-info -r .#packages.<system>.enchiridion | grep -cE 'shell_cmds|bootstrap-tools'
```

The last command must print `0`.
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
No package uses another package in full.
Each definition names its imports with `:import-from`, so a call reads as `enchiridion.llm:complete` and the source of the symbol is visible at the call site.

`enchiridion.user` is the package that a configuration file is read in.
Every `config.cl` begins with `(in-package #:enchiridion.user)`.

## Load order

`enchiridion.asd` is `:serial t`, so the load order is fixed.

1. `packages` and `compat`. The definitions come before every file that uses them, and `compat` is the only file with implementation-specific code.
2. `config`, `git`, `errors`.
3. `llm`: `secrets`, `protocol`, `json`, `http`, `registry`, `dialects`, `auth`, `openai`, `anthropic`, `aws-sigv4`, `bedrock`, `gcp-oauth`, `vertex`, `catalog`, `providers`.
4. `memory`: `blocks`, `store`, `tiers`, `seed`, `state`.
5. `tools`: `schema`, `registry`, `pipe`, `broker`, then the builtins `file`, `shell`, `search`, `blockops`, `memory`, `meta`, `web`, `register`.
6. `plugin`: `loader`, `verify`, `manifest`.
7. `channel`: `protocol`, `http`, `fluxer`.
8. `supervisor`, `kernel`, `sleep`, then `channel/cli`.

Two positions in that order are deliberate.
`channel/protocol` loads before the supervisor because the supervisor speaks the protocol.
`channel/cli` loads last because the command table calls both the supervisor and the kernel, and a forward declaration for each signature would be a second copy that can drift.

## Code style

The code follows the [lisp-lang.org style guide](https://lisp-lang.org/style-guide/).
The rules below are the ones a review checks first.

### Naming

Lowercase words separated by single dashes.
Spell a word in full: `user-count`, never `user-cnt`.
A special variable takes `*earmuffs*`, and a constant takes `+plus-signs+`.
A predicate on one word ends in `p`, and a predicate on several words ends in `-p`.

### Formatting

Indent by two spaces.
Keep both branches of an `if` on one line.
Limit a line to 100 columns.
`;;;;` states the purpose of a file at the top, `;;;` separates regions, `;;` marks a region inside a form, and `;` adds a note at the end of a line.

### Types

Declare an `ftype` before every `defun`.
Give every CLOS slot a `:type`, and write the slots in the order `:accessor`, `:initarg`, `:initform`, `:type`, `:documentation`.
The declarations are documentation that the compiler checks.

### Conditions

Use a condition and a `:report` method instead of a formatted string.
The condition carries the data for a caller, and the report gives a reader one sentence.

### Control flow

Use `when` or `unless` in place of a bare `if`.
Move a long condition into a named predicate.

### Portability

`src/enchiridion/compat.cl` is the only file with implementation-specific code, such as `sb-ext:run-program`, `sb-ext:posix-getenv`, and reader conditionals.
Every file above it is standard Common Lisp.

## Validation

| Layer                 | Tool                                                                                            |
| --------------------- | ----------------------------------------------------------------------------------------------- |
| Compile-time types    | SBCL `declaim` specifiers                                                                       |
| Warnings as errors    | The `:around-compile` hook in each `.asd` file                                                  |
| Tool argument schemas | `cl-jschema`                                                                                    |
| Unit tests            | `rove`                                                                                          |
| Property tests        | `rove` loops with `random`. The system declares `cl-quickcheck`, and no property file calls it. |

`plugin/verify.cl` proclaims `(optimize (safety 3) (debug 3))` while it loads one plugin file, so a bad plugin stops at a bounds check or a slot type error.
No other file proclaims an optimization level.
The `check` gate compiles with the default safety settings. Only plugin verification uses safety 3.

### The build gate

A compile warning is a failure.
`enchiridion.asd` and `t/enchiridion-tests.asd` install an `:around-compile` hook that binds `asdf:*compile-file-warnings-behaviour*` to `:error` and collects the warnings while a file compiles.
The hook is scoped to the system, so a warning from a dependency does not stop the build.

```sh
nix run .#check
```

## Tests

The suite lives in `t/` and mirrors the source tree.
`enchiridion-tests` is the system that every commit passes, and `enchiridion-tests/property` is the slower property system.
[Testing](testing.md) covers both systems, the rove bridge, and the coverage of each module.

## Commit policy

- The branch is `main`.
- One commit per logical unit. A unit is a change that can be tested on its own, not a measure of time.
- The subject is in the imperative mood.
- A commit body is optional. Every commit in this repository carries a title only.
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

The pages follow the shape of the BSD handbooks, and the [FreeBSD Documentation Project Primer](https://docs.freebsd.org/en/books/fdp-primer/writing-style/) is the reference for the style.

- State current behaviour only. No change history, no measurement taken during a change, and no reference to the plan that produced the code.
- Put a fact on one page. Link to the page that owns the fact instead of restating it.
- Open a section with one sentence that says what the subject is, then give the common case, then the reference detail.
- Do not pin a compiler or a tool version in prose. The build files record the version.
- Define an acronym at its first use on the page, then use the acronym.
- Give a tested example. A trivial working example is better than no example.
- Use the formal register: imperative steps, no contractions, one sentence per line.

## See also

- [Testing](testing.md)
- [Documentation index](index.md)
