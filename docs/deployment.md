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

`load-configured-secrets` resolves the file through `operator-secrets-file`,
which is the one function that decides which `.env` the operator means. The
loader and the `secrets` command both call it, so the file that is read and the
file that is reported cannot become two different files. It then works in this
order: refuse a world-readable file, read every configured name plus every
provider key name, unset what it read, and unlink the container copy.

The mode gate fails closed. A file with `(logand mode #o004)` set is a
configuration error that names the path and the mode, and the process exits 2:

```text
Configuration is wrong at SECRETS.
/run/secrets/.env is mode #o644 and every uid can read it.
Run chmod 600 /run/secrets/.env.
```

Mode 600 is what this page and the image ask for, but the file cannot keep that
contract on its own: an operator's umask writes what it likes and a `cp`
preserves what it was given. A group-readable file passes, because a group-shared
file is a normal deployment and the world read bit is the one that admits uid
1000. A missing file passes too, and the loader reports that on its own terms.

The unset sweep covers the configured names and every credential-shaped variable
in the environment, so an exported credential the configuration never heard of
goes with them. The predicate that decides which names those are never selects
`PATH`, `HOME`, `TERM`, `SBCL_HOME`, `CL_SOURCE_REGISTRY`, the loader paths, or
an `XDG_` name, so the process keeps everything it needs to run.

`discard-secrets-file` unlinks `/run/secrets/.env` once its values are in memory,
which is guarantee 6 of section 5.5: without it the file outlives the read by the
life of the container. It refuses every path but `/run/secrets/.env`, so the
operator's checkout `.env` is never deleted. A read-only bind mount refuses the
unlink, which is a route this page supports, so the supervisor prints one scrubbed
warning line and carries on rather than stopping:

```text
enchiridion: could not unlink /run/secrets/.env; the secrets file is still on disk.
```

## proc and hidepid

The sandbox must not read the supervisor's process. A readable `/proc` lets uid
1000 read the cmdline, the working directory, and the memory maps of the
supervisor. The supervisor holds the secrets, so that read is the whole risk.

Docker has no proc mount type, so the capability comes from the run line and the
entrypoint does the remount:

```sh
--cap-add SYS_ADMIN          # the entrypoint remounts /proc with hidepid
```

`ENCHIRIDION_HIDEPID` selects the level and defaults to 2. After the tmpfs check,
the entrypoint remounts `/proc` with that level. When the remount fails,
`ENCHIRIDION_REQUIRE_HIDEPID` decides what happens: `1` exits 1 before the
supervisor starts, anything else logs one warning line and serves on.
`ENCHIRIDION_HIDEPID=0` skips the remount without a warning. Compose sets the
requirement, so the Compose deployment keeps the guarantee; the full run line
below adds `-e ENCHIRIDION_REQUIRE_HIDEPID=1` to match it.

`SYS_ADMIN` is a broad capability, wider than a `/proc` remount needs, and
Docker offers nothing narrower that can reach `mount`. The trade is one of two:

- Keep `--cap-add SYS_ADMIN` and `ENCHIRIDION_REQUIRE_HIDEPID=1`. The
  supervisor's container then holds a capability that a container escape could
  use, and in exchange uid 1000 cannot read the supervisor's process view.
- Drop both flags. The entrypoint warns that `/proc` could not be remounted and
  serves on. Every other guarantee below still holds, and the isolation script's
  checks of the secret file, the environment, and the missing file still pass.
  The proc guarantee is the one that is gone.

The isolation test reads `/proc/1/environ` as uid 1000. That file belongs to the
root supervisor with mode 0400, so the read is denied whether or not hidepid is
mounted: the check is a regression guard, not proof that the remount happened.
What hidepid adds is the rest of the supervisor's process view, the cmdline and
the working directory among it, and only hidepid removes those.

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

Test 6 used to be blind. The file arrived as root with mode 600 inside a
directory with mode 700, so uid 1000 could not stat it, and the absent phase read
the check as passed whether the file was there or not. The supervisor now unlinks
`/run/secrets/.env` after the load, so on the tmpfs routes the file really is
gone and test 6 checks a fact. The read-only bind mount is still invisible to it:
the unlink fails with the warning above, the file stays because a mount is not a
directory entry that can be removed, and uid 1000 cannot stat `/run/secrets`
either way.

Test 7 runs `find` from two roots, because `-xdev` stops at a filesystem
boundary and the state volume is one boundary:

```sh
find / -xdev -path /run/secrets -prune -o -name .env -print
find "$STATE_DIR" -path /run/secrets -prune -o -name .env -print
```

As uid 0 the script checks the supervisor instead. It requires pid 1 to be the
supervisor and requires `/proc/1/environ` to be readable as root. It then checks
the shipped names, and then every credential-shaped name, using the same
vocabulary `credential-variable-p` uses. The second check is the one that does
not have to keep up with a list:

```text
OPENCODE_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY FLUXER_BOT_TOKEN ENCHIRIDION_HTTP_TOKEN
```

A `config.cl` that renames one of the shipped names, or exports a credential of
its own, is caught by shape rather than by a list somebody has to remember to
edit. The closing line names the phase that ran, so a log says which checks ran.

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

The full run line, with the tmpfs, the capability, and the state volume:

```sh
docker build -t enchiridion:0.1.0 -f docker/Dockerfile .

docker run -d --name enchiridion \
  -p 8787:8787 \
  --tmpfs /run/secrets:mode=0700 \
  --cap-add SYS_ADMIN \
  -e ENCHIRIDION_REQUIRE_HIDEPID=1 \
  -v enchiridion-state:/var/lib/enchiridion \
  enchiridion:0.1.0 \
  serve --channel http --bind 0.0.0.0 --port 8787
```

That bind answers the network, so `/run/secrets/.env` must hold
`ENCHIRIDION_HTTP_TOKEN`. The `-p` flag publishes the webhook port. The
capability and the environment entry are the pair that makes the entrypoint's
`/proc` remount mandatory; drop both to run without `SYS_ADMIN` and lose the proc
guarantee. [proc and hidepid](#proc-and-hidepid) covers the trade.

## Compose

`compose.yml` describes the container. It mirrors the run line above, and the
run line stays the alternative when Compose is not installed. It needs Compose
2.24 or newer, for the `required: false` env file form.

| File          | What it does                                                                             |
| ------------- | ---------------------------------------------------------------------------------------- |
| `compose.yml` | The server. `restart: unless-stopped`, the port on every interface, and the named volume |

`compose.yml` also adds `cap_add: [SYS_ADMIN]` and sets
`ENCHIRIDION_REQUIRE_HIDEPID=1`, so the entrypoint's `/proc` remount is mandatory
on that route. To run Compose without the capability, drop both of those lines;
see [proc and hidepid](#proc-and-hidepid) for what that costs.

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

| Name                                                         | Needed because                                                                                                                                                                                              |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ENCHIRIDION_HTTP_TOKEN`                                     | A bind other than loopback makes `check-http-policy` refuse the combination, and the process exits 2 without this token                                                                                     |
| `OPENAI_API_KEY`, `OPENCODE_API_KEY`, or `ANTHROPIC_API_KEY` | The model call. The loader reads every provider key name, and the provider is the configured one, else the one the base URL names, else the first key present of OpenAI, OpenCode, Anthropic, in that order |
| `FLUXER_BOT_TOKEN`                                           | Only for `--channel fluxer`                                                                                                                                                                                 |
| `ENCHIRIDION_IMAGE`                                          | Optional. Defaults to `enchiridion:0.1.0`                                                                                                                                                                   |
| `ENCHIRIDION_PORT`                                           | Optional. Defaults to 8787                                                                                                                                                                                  |

`env_file` puts the values in the container environment. The loader refuses a
world-readable file before it reads a value; reads the configured names and the
provider key names; holds the values in memory; and unsets each name from its own
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
  --cap-add SYS_ADMIN \
  -e ENCHIRIDION_REQUIRE_HIDEPID=1 \
  -v "$PWD/.env":/run/secrets/.env:ro \
  -v enchiridion-state:/var/lib/enchiridion \
  enchiridion:0.1.0 \
  serve --channel http --bind 127.0.0.1 --port 8787
```

The host file must be mode 600, or group-readable, for that route too: a
read-only mount does not change the mode, and the loader refuses a world-readable
file before it reads a value.

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
secret, and the running supervisor has already read the file it started with.
The copy waits in the tmpfs until the next process loads secrets, which unlinks
it then.

`docker cp` into a path that a tmpfs covers does not always land in the mount:
Docker 28.0.1 accepts the copy, exits 0, and leaves `/run/secrets` empty. Check
after the copy, and write the file through the container when it is empty:

```sh
docker exec enchiridion ls -A /run/secrets
docker exec -i enchiridion sh -c 'cat > /run/secrets/.env && chmod 600 /run/secrets/.env' < .env
```

The bind mount at the start is the better route of the two: the file is there
before the first turn, and the secret stays out of the environment. Its one cost
is that the file is a mount and cannot be unlinked, so the supervisor warns and
test 6 above stays blind to it either way.

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
