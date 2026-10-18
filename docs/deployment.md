# Deployment

The deployment unit is one container image. Root runs the supervisor and holds
the secrets. The agent user, uid 1000, runs every tool and every piece of agent
code. The image exposes the webhook port 8787. The shipped configuration leaves
the webhook off, so `serve --channel http` starts it, or `:http :enabled t` in
`config.cl` does. This page covers the image, the two users, the secret file,
the volumes, the isolation test, and the flags for `serve`.

## The image

`docker/Dockerfile` builds the image in two stages. The build stage installs
SBCL and Quicklisp, downloads the Lisp dependencies, and compiles the core. The
runtime stage copies the compiled result and keeps the C toolchain and the
development headers out. The SBCL image carries the Lisp compiler itself. The
image has the name `enchiridion` and the tag `0.1.0`.

| Item          | Value                                   |
| ------------- | --------------------------------------- |
| File          | `docker/Dockerfile`                     |
| Build command | `docker build -t enchiridion:0.1.0 -f docker/Dockerfile .` |
| Compose       | `docker compose build`                  |
| Base image    | `clfoundation/sbcl:2.6.9-bookworm-slim` |
| Platform      | amd64 and arm64                         |

The base image is Debian bookworm with SBCL 2.6.9. Both stages use the same
base, so the compiled files the build stage writes stay valid at run time.
Quicklisp lives at `/opt/quicklisp`, the source tree at `/opt/enchiridion`, and
the program starts through `/usr/local/bin/enchiridion`, the wrapper script in
`docker/`.

The image holds no `.env` and no host file. The `Dockerfile` copies the system
file, the source tree, and the container scripts, and nothing else. Build it
from the repository root, because the build context is the root.

## What the image contains

| Path                                 | Contents                                    |
| ------------------------------------ | ------------------------------------------- |
| `/usr/local/bin/enchiridion`         | The wrapper that starts the program         |
| `/usr/local/bin/entrypoint.sh`       | The entry script from `docker/`             |
| `/usr/local/bin/isolation-test.sh`   | The isolation test                          |
| `/opt/enchiridion`                   | The source tree the fasl cache is keyed on  |
| `/opt/quicklisp`                     | The Lisp dependency sources                 |
| `/opt/enchiridion-cache`             | The compiled files from the build stage     |
| `/etc/ssl/certs/ca-certificates.crt` | The trust anchor from Debian                |

The image also carries `git`, `coreutils`, `grep`, `findutils`, `util-linux`,
and the shell. The agent directory is a git repository, so `journey` and `undo`
need git inside the image. The certificate bundle matters because the image
does not inherit `/etc` from the host. The TLS handshake needs a trust anchor
for the model call and the Fluxer gateway.

The image sets these values:

| Setting            | Value                          |
| ------------------ | ------------------------------ |
| `User`             | `0:0`                          |
| `Entrypoint`       | `/usr/local/bin/entrypoint.sh` |
| `PATH`             | `/usr/local/bin:/usr/local/sbin:/usr/bin:/bin` |
| `ENCHIRIDION_HOME` | `/var/lib/enchiridion`         |
| `SSL_CERT_FILE`    | `/etc/ssl/certs/ca-certificates.crt` |
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

It then creates the state directory, `agents/default`, `run`, and `tmp` inside
it, and `/run/enchiridion`. It gives the state tree to the agent user and sets
mode 700 on `/run/enchiridion`. The state tree must belong to uid 1000, because
the broker runs as that user and must write the files it acts on. `run` exists
before the chown on purpose: the broker child drops to uid 1000 and binds the
socket there, and a root-owned directory refuses that bind.

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

The operator supplies `.env` as a read-only bind mount at `/run/secrets/.env`,
or copies the file in after start. The file lands at `/run/secrets/.env` and not
at its host path, and the entrypoint logs a warning when its ownership is not
`600:0`. The two routes and their trade-offs are in [The .env
file](#the-env-file) below.

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

Test 6 does not detect the leftover file in practice. The file arrives as root
with mode 600 inside a directory with mode 700, so uid 1000 cannot stat it and
the absent phase reads the check as passed. The uid 0 view checks the supervisor
environment and not the file. Nothing deletes `/run/secrets/.env`, so it stays
for the life of the container, and the agent still cannot read it. The present
phase is the one that proves the two permissions.

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
docker build -t enchiridion:0.1.0 -f docker/Dockerfile .

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

## Compose

`compose.yml` describes the container. It mirrors the run line above, and the
run line stays the alternative when Compose is not installed. It needs Compose
2.24 or newer, for the `required: false` env file form.

| File          | What it does                                                                             |
| ------------- | ---------------------------------------------------------------------------------------- |
| `compose.yml` | The server. `restart: unless-stopped`, the port on every interface, and the named volume |

Compose builds the image from the same Dockerfile. There is no registry, so
`docker compose pull` has nothing to fetch:

```sh
docker compose build    # the image
docker compose up -d    # the server
```

A source change means a new build and a second `up`, which recreates the
container on the new image:

```sh
docker compose build
docker compose up -d
```

### The .env file

`compose.yml` names `.env` through `env_file`, with `required: false`, so a
checkout without the file is not a configuration error. Compose reads the same
file for interpolation, which is where `ENCHIRIDION_IMAGE` and
`ENCHIRIDION_PORT` go.

| Name                                   | Needed because                                                                                                          |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `ENCHIRIDION_HTTP_TOKEN`               | A bind other than loopback makes `check-http-policy` refuse the combination, and the process exits 2 without this token |
| `OPENAI_API_KEY` or `OPENCODE_API_KEY` | The model call. The loader picks the provider from the key it finds                                                     |
| `FLUXER_BOT_TOKEN`                     | Only for `--channel fluxer`                                                                                             |
| `ENCHIRIDION_IMAGE`                    | Optional. Defaults to `enchiridion:0.1.0`                                                                               |
| `ENCHIRIDION_PORT`                     | Optional. Defaults to 8787                                                                                              |

`env_file` puts the values in the container environment. The loader reads the
configured names, holds the values in memory, and unsets each name from its own
environment, so a child the supervisor starts inherits nothing. The names stay
in the container environment for the life of the container, because Docker fixes
that environment at start. `docker inspect` and `docker exec` still see the
token, so the isolation test's check of the agent environment fails on this
route. The model key is the smaller risk, because only the supervisor reads it.

The hardened route mounts the file into the tmpfs instead, and it passes that
check:

```sh
docker run -d --name enchiridion \
  --tmpfs /run/secrets:mode=0700 \
  -v "$PWD/.env":/run/secrets/.env:ro \
  -v enchiridion-state:/var/lib/enchiridion \
  enchiridion:0.1.0 \
  serve --channel http --bind 127.0.0.1 --port 8787
```

Do not add both routes. `env_file` wins the same names into the environment and
the tmpfs file changes nothing then.

The tmpfs is still required, with or without `.env`: the entrypoint checks
`/proc/mounts` before anything else and exits 1 when `/run/secrets` is not a
mount. The loader prefers `/run/secrets/.env` when it exists, so an operator who
wants the file route can also copy it in after start:

```sh
docker cp .env enchiridion:/run/secrets/.env
```

The copy route runs after the container starts, so the first moments have no
secret, and it leaves the file in the tmpfs, because no code deletes it. The
bind mount at the start is the better route of the two: the file is there before
the first turn, and the secret stays out of the environment. Its one cost is
that the file is a mount and cannot be unlinked, so test 6 above stays blind to
it either way.

### State, logs, and stop

The state volume holds `agents/default`, the seed files, the SQLite database,
and `run/`. `docker compose down` keeps the named volume, and only
`docker compose down -v` removes it. The container writes the tree as root and
as uid 1000, so it does not belong to the operator's user.

```sh
docker compose logs -f enchiridion            # follow the supervisor
docker compose logs --tail 100 enchiridion
docker compose stop                           # stop, and keep the volume
docker compose down                           # remove the container and network
docker compose down -v                        # also remove enchiridion-state
```

The logging driver is `json-file`, capped at 10 MB per file and three files.
`stop_grace_period` is 30 seconds: `docker stop` sends SIGTERM, the interrupt
handler unwinds the supervisor, stops its channels, and writes the last status
file, and Docker kills the container if that somehow takes longer. The process
leaves with status 130. The container keeps the name `enchiridion`, so the
`docker exec` lines in the isolation test above work unchanged.

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

Both gates compile the entry script as well as the system, and a compile warning
fails the gate. The image build is separate: `docker compose build` compiles the
core inside the image, and it fails on a missing dependency or a compile error.

## Related

- [Channels](channels.md)
- [Supervisor and heartbeat](supervisor.md)
- [Configuration](configuration.md)
- [Getting started](getting-started.md)
- [Development](development.md)
