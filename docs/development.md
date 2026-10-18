# Development

This page covers the source tree, the load order, the style rules, and the
commit policy. [Testing](testing.md) covers the suite and the build gate.

## Repository layout

| Path                       | Holds                                             |
| -------------------------- | ------------------------------------------------- |
| `enchiridion.asd`          | The core system and its load order                |
| `src/main.cl`              | The entry script. ASDF does not load it           |
| `src/broker-exec.cl`       | The agent-side half of the broker                 |
| `src/enchiridion/`         | The core, one file or one directory per subsystem |
| `t/`                       | The test systems and the suites                   |
| `config.example.cl`        | The tracked template for the configuration        |
| `flake.nix`                | Build, check, test, and the container image       |
| `docker/entrypoint.sh`     | The two users, then the supervisor                |
| `docker/isolation-test.sh` | The isolation checks, run by hand in the image    |
| `docs/`                    | This documentation                                |
| `LICENSE`                  | The BSD Zero Clause License                       |

`src/main.cl` is not a system component on purpose. Loading a system must never
start an agent, and the top level form of this file is the program. The check
gate compiles it explicitly, so the file is still covered.

### Generated and ignored paths

These live beside the source. `.gitignore` excludes all of them:

| Path                                 | Holds                                                           |
| ------------------------------------ | --------------------------------------------------------------- |
| `config.cl`                          | Your configuration. The tracked template is `config.example.cl` |
| `.env`                               | Secret values, mode 600                                         |
| `agents/`                            | The agent directory, written on first launch                    |
| `run/`                               | The control file and the status file of a running supervisor    |
| `PLAN.md`                            | The design record. It holds rationale, not instructions         |
| `research/`, `enchiridion-property/` | Local working directories                                       |

## Packages

One package per subsystem, and the package name mirrors the directory:

```text
enchiridion              enchiridion.llm          enchiridion.memory
enchiridion.compat       enchiridion.llm.secrets  enchiridion.memory.store
enchiridion.errors       enchiridion.tools        enchiridion.channel
enchiridion.git          enchiridion.tools.pipe   enchiridion.channel.cli
enchiridion.kernel       enchiridion.tools.broker enchiridion.channel.http
enchiridion.plugin       enchiridion.tools.builtin enchiridion.channel.fluxer
enchiridion.supervisor   enchiridion.user
```

`src/enchiridion/packages.cl` holds every definition. No package uses another
package in full. Each one names what it imports with `:import-from`, so a call
reads as `enchiridion.llm:complete` and the reader knows where it lives.

`enchiridion.user` is the package the configuration file is read in. A
`config.cl` starts with `(in-package #:enchiridion.user)`.

## Load order

`enchiridion.asd` is `:serial t`, so the order is fixed and deliberate.

1. `packages` and `compat`. The package definitions come before every file that
   uses them, and `compat` is the only file with implementation extensions.
2. `config`, `git`, `errors`.
3. `llm`: `secrets`, `protocol`, `openai`.
4. `memory`: `blocks`, `store`, `tiers`, `seed`, `state`.
5. `tools`: `schema`, `registry`, `pipe`, `broker`, then the builtins `file`,
   `shell`, `search`, `blockops`, `meta`, `web`, `register`.
6. `plugin`: `loader`, `verify`, `manifest`.
7. `channel`: `protocol`, `http`, `fluxer`.
8. `supervisor`, `kernel`, `sleep`, then `channel/cli`.

Two orderings carry a reason. `channel/protocol` loads before the supervisor
because the supervisor speaks it. `channel/cli` loads last, because the command
table calls both the supervisor and the kernel. Forward declarations for nine
signatures would only make a second copy of those signatures.

## Style

The code follows the lisp-lang.org style guide. The rules below are the ones a
reviewer checks first.

### Naming

Lowercase, single dashes, complete words. `user-count`, never `user-cnt`.
Specials take `*earmuffs*` and constants take `+constants+`. A predicate on one
word ends in `p`, and a predicate on several words ends in `-p`.

### Formatting

Two spaces per form. Both branches of an `if` stay on one line. The limit is 100
columns. `;;;;` states the purpose at the top of a file, and `;;;` separates
regions. `;;` marks a region inside a form, and `;` is a short note at the end
of a line.

### Types

Every function carries an `ftype` declaration before its `defun`. Every CLOS
slot carries `:type`, in the order `:accessor`, `:initarg`, `:initform`,
`:type`, `:documentation`. The types are documentation the compiler enforces.

### Conditions

Conditions, not formatted strings. A `define-condition` carries the data and a
`:report` method, so a caller can inspect the condition and a reader gets a
sentence.

### Flow

`when` and `unless` in place of a bare `if`. A long condition moves into a named
predicate.

### Portability

`src/enchiridion/compat.cl` is the only file that contains implementation
extensions, such as `sb-ext:run-program`, `sb-ext:posix-getenv`, and reader
conditionals. Everything above it is standard Common Lisp.

## The validation stack

| Layer                 | Tool                                                                                          |
| --------------------- | --------------------------------------------------------------------------------------------- |
| Compile-time types    | SBCL `declaim` specifiers                                                                     |
| Warnings as errors    | The `:around-compile` hook in each `.asd` file                                                |
| Tool argument schemas | `cl-jschema`                                                                                  |
| Unit tests            | `rove`                                                                                        |
| Property tests        | `rove` loops and `random`. The system declares `cl-quickcheck`, and no property file calls it |

`plugin/verify.cl` proclaims `(optimize (safety 3) (debug 3))` while it loads
one plugin file. A bad plugin therefore hits a bounds check or a slot type
error. No other file proclaims an optimization level.

### The build gate

A compile warning is a failure. Both `enchiridion.asd` and
`t/enchiridion-tests.asd` install an `:around-compile` hook that binds
`asdf:*compile-file-warnings-behaviour*` to `:error` and catches warnings while
the file compiles. The hook is scoped to the system, so a warning from a
dependency does not stop the build.

Run the gate with:

```sh
nix run .#check
```

## Tests

The suite lives in `t/`, and it mirrors the source tree. Two systems exist:
`enchiridion-tests` is the suite every commit passes, and
`enchiridion-tests/property` is slower and separate. [Testing](testing.md)
covers both, the rove bridge, and the coverage of each file.

## Commit policy

- The branch is `main`.
- One commit per logical unit. A unit is a testable increment, not a timer.
- The subject is in the imperative mood.
- The design record asks for a body that states why and names the invariant.
  The commits in this repository carry a title only.
- Every commit is signed. The global configuration sets `commit.gpgsign` to
  true, `gpg.format` to `ssh`, and `user.signingkey` to the operator's key.
- Signature verification needs an allowed signers file. Without one, `git log
--show-signature` reports `N` even when the signature is present. Set it with:

```sh
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
```

The file holds one line, the signing identity and the public key:

```text
you@example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
```

## Related

- [Documentation index](index.md)
- [Testing](testing.md)
- [Configuration](configuration.md)
- [Deployment](deployment.md)
