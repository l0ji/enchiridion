# Deployment

The deployment unit is one container image. Root runs the supervisor and holds
the secrets. The agent user, uid 1000, runs every tool and every piece of agent
code. The image exposes the webhook port 8787. The shipped configuration leaves
the webhook off, so `serve --channel http` starts it, or `:http :enabled t` in
`config.cl` does. This page covers the image, the two users, the secret file,
the volumes, the isolation test, and the flags for `serve`.

## The image and the Linux-only build

The flake builds the image with `pkgs.dockerTools.buildImage`. The image has the
name `enchiridion` and the tag `0.1.0`.

| Item          | Value                         |
| ------------- | ----------------------------- |
| Attribute     | `packages.<system>.container` |
| Build command | `nix build .#container`       |
| Load command  | `docker image load -i result` |
| Platform      | Linux only                    |

The attribute exists under `lib.optionalAttrs` for a Linux host platform. An
image needs a Linux builder, and a darwin host reaches one through Colima rather
than by accident. Every other package and app in the flake evaluates on every
supported system.

Nix performs every install inside the image, so the result is a self contained
closure. The image starts from scratch and carries no Quicklisp and no host
files. SBCL is a runtime reference, because `/bin/enchiridion` is a wrapper
around `${sbcl}/bin/sbcl`.

## What the image contains

| Path                               | Contents                            |
| ---------------------------------- | ----------------------------------- |
| `/bin/enchiridion`                 | The installed program               |
| `/usr/local/bin/entrypoint.sh`     | The entry script from `docker/`     |
| `/usr/local/bin/isolation-test.sh` | The isolation test                  |
| `/usr/local/bin/enchiridion`       | A symlink to `/bin/enchiridion`     |
| `/bin/sh`                          | A symlink to the Nix bash           |
| `/etc/ssl/certs/ca-bundle.crt`     | The trust anchor from `pkgs.cacert` |

The image also carries `bash`, `coreutils`, `gnugrep`, `findutils`,
`util-linux`, and `git`. The agent directory is a git repository, so `journey`
and `undo` need git inside the image. The certificate bundle matters because the
image inherits no `/etc` from the host. The TLS handshake needs a trust anchor
for the model call and the Fluxer gateway.

The image sets these values:

| Setting            | Value                          |
| ------------------ | ------------------------------ |
| `User`             | `0:0`                          |
| `Entrypoint`       | `/usr/local/bin/entrypoint.sh` |
| `PATH`             | `/usr/local/bin:/usr/bin:/bin` |
| `ENCHIRIDION_HOME` | `/var/lib/enchiridion`         |
| `SSL_CERT_FILE`    | `/etc/ssl/certs/ca-bundle.crt` |
| `ExposedPorts`     | `8787/tcp`                     |
| `Volumes`          | `/var/lib/enchiridion`         |
| `WorkingDir`       | `/var/lib/enchiridion`         |

## The two users and the uid split

| User  | uid  | Job                                                |
| ----- | ---- | -------------------------------------------------- |
| root  | 0    | The supervisor, the secrets, and the broker socket |
| agent | 1000 | Agent code, tools, and the model client            |

The `:sandbox` section names the split. `:agent-uid` holds 1000 and
`:proc-hidepid` holds 2. Every child process that runs agent code drops to uid 1000.

The entrypoint creates the agent user when the image does not hold one:

```text
agent:x:1000:1000:agent:/home/agent:/bin/sh
agent:x:1000:
```

It then creates the state directory, `agents/default` inside it, and
`/run/enchiridion`. It gives the state tree to the agent user and sets mode 700
on `/run/enchiridion`. The state tree must belong to uid 1000, because the
broker runs as that user and must write the files it acts on.

The script builds `PATH` itself instead of inheriting it. Nothing reaches the
process environment and then travels on to a child by default. The script ends
in `exec`, so pid 1 is the supervisor and not a shell that wraps it.

## The secret file and its tmpfs

| Item                  | Path                                           |
| --------------------- | ---------------------------------------------- |
| The secrets directory | `/run/secrets`                                 |
| The secret file       | `/run/secrets/.env`                            |
| The state directory   | `$ENCHIRIDION_HOME`, or `/var/lib/enchiridion` |

The secrets directory must be a tmpfs, and the entrypoint refuses to continue
without one:

```text
entrypoint: /run/secrets is not a mount. Run with --tmpfs /run/secrets:mode=0700
entrypoint: A plain directory here is not isolation, it is a folder with a lock on it.
```

The run line supplies that mount. The entrypoint then sets mode 700 on the
directory. Mode 700 alone is weak, because a plain directory is the only thing
between the agent and the key. The tmpfs is the point.

The host `.env` goes in as a copy. A bind mount would put the operator's file at
its host path inside the container, where the source tree makes it easy to find.
The entrypoint logs a warning when the file ownership is not `600:0`.

`load-configured-secrets` reads every configured name through `load-secrets`,
and the loader holds each pair in memory. It then unsets those names from its own
process environment. A name that survives in the environment is a name a child
process would inherit.

Nothing in this code deletes `/run/secrets/.env`. The only `delete-file` calls
under `src/` remove the broker socket in `tools/broker.cl` and a temporary
capture in `compat.cl`. The entrypoint does not delete the file either. A
docstring in `llm/secrets.cl` says the supervisor deletes the file once loaded,
and no code performs that delete. The file therefore stays in the tmpfs for the
life of the container.

## proc and hidepid

The sandbox must not read the supervisor's memory. A readable `/proc` lets uid
1000 read the cmdline, the file descriptors, and the memory maps of the
supervisor. The supervisor holds the secrets, so that read is the whole risk.

```sh
--cap-add SYS_ADMIN          # then: mount -o remount,hidepid=2 /proc
```

Docker has no proc mount type, so the run line adds the capability and the
remount is the operator's next step. The entrypoint does not do the remount, and
it does not pretend to. The isolation test fails when uid 1000 can read
`/proc/1/environ`, so the check covers this guarantee with or without hidepid.

## The volumes

| Path                   | Kind                         | Contents                                          |
| ---------------------- | ---------------------------- | ------------------------------------------------- |
| `/var/lib/enchiridion` | A named volume               | The agent directory, the memory store, and `run/` |
| `/run/enchiridion`     | A directory in the container | Mode 700, and the agent user owns it              |

The state volume is the writable tree. It holds `agents/default`, the seed
Markdown files, the SQLite database, and the `run/` directory with the control
and status files. A named volume keeps that state across a container restart.

The broker socket path follows `ENCHIRIDION_HOME`. With the variable set, the
socket lives at `$ENCHIRIDION_HOME/run/broker.sock`, which puts it on the state
volume. Without the variable, a checkout keeps the socket in the agent
directory.

## The isolation test

`docker/isolation-test.sh` checks the security model from inside the container.
Nothing in the image runs it for the operator. The variable `ISOLATION_PHASE`
selects a phase, and the default `all` runs the present and absent phases in one
pass. The two phases exist because test 1 needs the secret file, and test 6
needs the file gone.

```sh
# The agent's view, with the secret file still in the tmpfs
docker exec -u agent -e ISOLATION_PHASE=present enchiridion \
  /usr/local/bin/isolation-test.sh

# The agent's view at steady state, after the supervisor read the file
docker exec -u agent -e ISOLATION_PHASE=absent enchiridion \
  /usr/local/bin/isolation-test.sh

# The supervisor's view, as uid 0
docker exec -u 0 enchiridion /usr/local/bin/isolation-test.sh
```

The script reads seven guarantees. Tests 1 to 4 and 7 live in this script. Test
5 is the scrubber unit test. Test 6 checks the missing file at steady state.

| Test | What it checks                                         |
| ---- | ------------------------------------------------------ |
| 1    | The agent user cannot read `/run/secrets/.env`         |
| 2    | A shell cannot read `/run/secrets/.env`                |
| 3    | `/proc/1/environ` is not readable, so hidepid works    |
| 4    | The agent environment holds no secret name             |
| 5    | The scrubber unit test, which runs outside this script |
| 6    | `/run/secrets/.env` is gone at steady state            |
| 7    | No `.env` copy exists anywhere else                    |

Test 6 and the absent phase cannot pass on this code. The check fails when
`/run/secrets/.env` exists, and nothing deletes that file. The present phase
still passes, because it skips test 6 and test 7. In the absent phase the script
stops at test 6 and never reaches test 7. The default `all` phase runs tests 1
to 4, then stops at test 6.

Test 7 runs `find` from two roots, because `-xdev` stops at a filesystem
boundary and the state volume is one boundary:

```sh
find / -xdev -path /run/secrets -prune -o -name .env -print
find "$STATE_DIR" -path /run/secrets -prune -o -name .env -print
```

As uid 0 the script checks the supervisor instead. It requires pid 1 to be the
supervisor and requires `/proc/1/environ` to be readable as root. It then checks
that no configured secret name survives in that environment. The names come from
the shipped configuration:

```text
OPENCODE_API_KEY OPENAI_API_KEY FLUXER_BOT_TOKEN ENCHIRIDION_HTTP_TOKEN
```

A `config.cl` that renames one of those names must add the new name to
`SECRET_NAMES`, or the hole this test closes opens again.

## The run flags for serve

`serve` starts the supervisor and its channels. The flags come before the
command or after it, because `serve --channel http` is what a person types.

| Flag          | Value                                     | Default                  |
| ------------- | ----------------------------------------- | ------------------------ |
| `--channel`   | `cli`, `http`, or `fluxer`                | The configuration        |
| `--bind`      | An address for the webhook                | `127.0.0.1`              |
| `--port`      | A number from 1 to 65535                  | 8787                     |
| `--token-env` | The variable that names the webhook token | `ENCHIRIDION_HTTP_TOKEN` |

The `--bind`, `--port`, and `--token-env` flags belong to `--channel http`. Any
other combination ends the process with exit 2. A flag with no value, an unknown
channel name, and a port outside the range are all exit 2 as well. A channel
flag with no command is a request to `serve`.

A bind other than loopback needs a token. The function `check-http-policy`
refuses the combination before a socket opens, and the process exits 2 with one
line. The refusal exists so that a bad flag is one line and an exit status. The
alternative is a channel that dies and restarts every second.

The full run line, with the tmpfs and the state volume:

```sh
nix build .#container                # Linux builder only
docker image load -i result

docker run -d --name enchiridion \
  -p 8787:8787 \
  --tmpfs /run/secrets:mode=0700 \
  -v enchiridion-state:/var/lib/enchiridion \
  enchiridion:0.1.0 \
  serve --channel http --bind 0.0.0.0 --port 8787
```

That bind answers the network, so `/run/secrets/.env` must hold
`ENCHIRIDION_HTTP_TOKEN`. The `-p` flag publishes the webhook port. Add
`--cap-add SYS_ADMIN` and remount `/proc` with `hidepid=2` when the operator
wants the proc guarantee.

## The checks

The flake exposes four checks and three apps:

| Name          | Kind  | What it does                             |
| ------------- | ----- | ---------------------------------------- |
| `flake`       | Check | Evaluates the flake for the system       |
| `enchiridion` | Check | Builds the package                       |
| `check`       | Check | Compiles every file, and a warning fails |
| `default`     | Check | Runs the test suite                      |
| `default`     | App   | Runs the program                         |
| `check`       | App   | Runs the compile gate                    |
| `test`        | App   | Runs the suite                           |

The container attribute stays out of the checks, because it needs a Linux
builder. Both gates compile the entry script as well as the system, and a
compile warning fails the gate.

## Related

- [Channels](channels.md)
- [Supervisor and heartbeat](supervisor.md)
- [Configuration](configuration.md)
- [Getting started](getting-started.md)
- [Development](development.md)
