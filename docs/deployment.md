# Deployment

One Docker image holds the program, its Lisp dependencies, and the scripts that start it.
Root runs the supervisor, which holds the secrets and the model client.
Uid 1000 runs every tool and every line of agent code, and the state volume is the only writable tree that survives the container.
An operator can build the image, supply the secret file, start the webhook, and prove the split with the isolation test.

The two users and the unlinked secret file are properties of the image.
A checkout has no uid split: the supervisor, the broker child, and agent code run as the operator's user.
The loader leaves the checkout `.env` in place, so agent code can read it.
Use the image when the secret must stay out of the agent's reach.

## The container image

`docker/Dockerfile` builds in two stages on the `clfoundation/sbcl` image on Debian bookworm.
The build stage installs the C build libraries, installs Quicklisp, and downloads the dependencies.
It compiles the core into a fasl cache, so a missing dependency or compile error stops the build.
The runtime stage installs the runtime libraries and copies the compiled dependency tree, the core, and the source the cache is keyed on.
The runtime image carries Steel Bank Common Lisp (SBCL), because the program and the broker child run as `--script` processes.

The build context is the repository root.
`.dockerignore` keeps `.git`, `docs/`, `t/`, `config.cl`, `.env`, and `.env.*` out, among other paths.
The image carries no `config.cl` and no secret file, so configuration comes from the environment and the defaults in [Configuration](configuration.md).

| Item              | Value                                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------ |
| File              | `docker/Dockerfile`                                                                                                      |
| Build command     | `docker build -t enchiridion:0.1.0 -f docker/Dockerfile .`                                                               |
| Compose build     | `docker compose build`                                                                                                   |
| Base image        | `clfoundation/sbcl` on Debian bookworm                                                                                   |
| Exposed port      | 8787                                                                                                                     |
| Volume            | `/var/lib/enchiridion`                                                                                                   |
| Working directory | `/var/lib/enchiridion`                                                                                                   |
| User              | `0:0`                                                                                                                    |
| Entrypoint        | `/usr/local/bin/entrypoint.sh`                                                                                           |
| Runtime packages  | `ca-certificates`, `git`, `libssl3`, `libsqlite3-0`, `zlib1g`, `libffi8`, `coreutils`, `grep`, `findutils`, `util-linux` |

The image installs these paths.
`/usr/local/bin` holds `enchiridion`, `entrypoint.sh`, and `isolation-test.sh`.
`/opt/enchiridion` is the source tree the fasl cache is keyed on.
`/opt/quicklisp` holds the dependency sources, `/opt/enchiridion-cache` holds the compiled files from the build stage, and `/etc/ssl/certs/ca-certificates.crt` is Debian's certificate bundle.
The image sets `PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin`, `ENCHIRIDION_HOME=/var/lib/enchiridion`, `ENCHIRIDION_SOURCE=/opt/enchiridion`, and `ENCHIRIDION_SBCL=/usr/local/bin/sbcl`.
It also sets `SBCL_HOME=/usr/local/lib/sbcl`, `XDG_CACHE_HOME=/opt/enchiridion-cache`, `CL_SOURCE_REGISTRY=/opt/enchiridion//:/opt/quicklisp/dists/quicklisp/software//`, and `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`.

The fasl cache lives outside `/root`, because the broker child runs as uid 1000 and must read the compiled files.
The wrapper in `docker/enchiridion.sh` sets the same paths with fallbacks and runs `sbcl --script /opt/enchiridion/src/main.cl`.

## Root and the agent user

The supervisor starts as uid 0 and keeps the secrets in its own memory.
Every child that runs agent code drops to uid 1000 before reading an agent file.
The `:sandbox :agent-uid` key names that uid and defaults to 1000, and [Configuration](configuration.md) lists it.

| User  | uid  | Job                                                       |
| ----- | ---- | --------------------------------------------------------- |
| root  | 0    | The supervisor, the secrets, and the control and status files |
| agent | 1000 | Agent code, tools, the broker process and socket, and the state volume |

The entrypoint creates the agent user when the image does not hold one, appending these two lines:

```text
agent:x:1000:1000:agent:/home/agent:/bin/sh
agent:x:1000:
```

It then creates the state tree, its `agents/default`, `run`, and `tmp` directories, and `/run/enchiridion`.
It gives the state tree to the agent user, because the broker child writes the files it acts on.
It gives `/run/enchiridion` to the agent user with mode 700.
It sets `PATH` itself rather than inheriting the image value, and the supervisor builds the broker child a minimal environment.
No secret reaches that child.
The script ends in `exec`, so pid 1 is the supervisor.

The state tree and `/run/enchiridion` are owned `1000:1000`.
The state tree keeps the image default mode, and `/run/enchiridion` is 700.
The run line mounts `/run/secrets` as `0:0` mode 700, and the operator supplies `/run/secrets/.env` at `600:0` when correct.
The entrypoint logs the supervisor uid, the agent uid, the state directory, and the secrets directory before it hands over.

## Supplying the secrets

The secrets live at `/run/secrets/.env` on a tmpfs that the run line mounts, and the entrypoint refuses a plain directory:

```text
entrypoint: /run/secrets is not a mount. Run with --tmpfs /run/secrets:mode=0700
entrypoint: A plain directory here is not isolation, it is a folder with a lock on it.
```

The check runs after the root check and exits 1 on failure, and the entrypoint then sets mode 700 on `/run/secrets`.
The supervisor reads the file once, holds the values in memory, and unlinks the container copy, so the operator's checkout `.env` is never deleted.

The loader refuses a file that any uid can read before it reads a value, and it ends the process with exit status 2:

```text
Configuration is wrong at SECRETS.
/run/secrets/.env is mode #o644 and every uid can read it.
Run chmod 600 /run/secrets/.env.
```

A group-readable file and an absent file pass the mode check.
The loader resolves `/run/secrets/.env` first, then `.env` in the current directory, then `.env` at the checkout root.

A deployment has three ways to supply the values:

| Route                 | How                                                   | Trade-off                                                                                                                              |
| --------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Read-only bind mount  | `-v "$PWD/.env":/run/secrets/.env:ro`                 | The file is present at start and stays off the environment. The unlink fails because a mount cannot be removed.                        |
| Copy after start      | `docker cp` or a shell write into `/run/secrets/.env` | The next process that loads secrets reads the file and unlinks it. The running supervisor keeps the values it read at start.           |
| Container environment | `env_file` in `compose.yml`                           | The names remain in the container environment for the life of the container. The loader removes them from the supervisor process only. |

When both the file and the environment supply a name, the environment value is the one the loader holds last.

The read-only bind mount cannot be unlinked, and the supervisor reports one warning line without stopping.
The warning is `enchiridion: could not unlink /run/secrets/.env; the secrets file is still on disk.`
The mounted file remains, and uid 1000 cannot see it because `/run/secrets` is mode 700 root.
The entrypoint reports a secret file whose mode and owner are not `600:0` and continues.
The warning is `entrypoint: /run/secrets/.env has unexpected ownership; continuing`.
The loader, not the entrypoint, decides whether to refuse the file.

## The process view

A readable `/proc` gives uid 1000 the supervisor's cmdline, working directory, and memory maps, and the supervisor holds the secrets.
Docker offers no proc mount type, so the run line supplies the capability and the entrypoint remounts `/proc`.

`ENCHIRIDION_HIDEPID` defaults to `2`, and `0` skips the remount.
`ENCHIRIDION_REQUIRE_HIDEPID` defaults to `0`.
`1` makes a failed remount fatal, and any other value logs a failed remount as a warning and serves on.

A successful remount logs `entrypoint: /proc remounted with hidepid=2`.
A failed remount with `ENCHIRIDION_REQUIRE_HIDEPID=1` exits 1.
The message is `entrypoint: cannot remount /proc with hidepid=2; add --cap-add SYS_ADMIN, or set ENCHIRIDION_HIDEPID=0 to opt out`.
A failed remount without that setting logs `entrypoint: could not remount /proc with hidepid=2; uid 1000 can see the supervisor's process` and continues.

`SYS_ADMIN` is the capability the remount needs.
Keeping the capability and the require setting gains the proc guarantee, and dropping both loses it while keeping the other checks.

## The state volume

The state volume is the writable tree.
It holds the agent directory, the memory store, and the run files, and it outlives a container restart.
`/var/lib/enchiridion/agents/default` holds the seed Markdown files, `skills/`, `tools/`, `state.json`, and the memory store.
`/var/lib/enchiridion/run` holds `enchiridion.control`, `enchiridion.status`, and the broker socket, and `/var/lib/enchiridion/tmp` is the agent user's scratch space.

The broker socket is `$ENCHIRIDION_HOME/run/broker.sock` when the variable is set, which puts it on the volume.
A checkout without the variable keeps it in the agent directory.
`/run/enchiridion` is created by the entrypoint for the agent user with mode 700.

A named volume keeps the tree across `docker stop` and `docker compose down`.
`docker compose down -v` or `docker volume rm` removes it.

## Backup, restore, and upgrade

Stop the Compose service, or the standalone container, before a backup, so the store and the run files do not change during the copy.
The volume name depends on the deployment.
The standalone run line below uses `enchiridion-state`. Compose prefixes its project name, so its volume is `enchiridion_enchiridion-state`.
`docker volume ls` lists the actual name when the project was renamed.

```sh
volume=enchiridion-state   # or enchiridion_enchiridion-state for Compose
docker compose stop        # or: docker stop enchiridion
docker run --rm \
  -v "$volume":/state:ro \
  -v "$PWD":/backup \
  alpine tar czf /backup/enchiridion-state.tgz -C /state .
```

Restore into a stopped service with the same volume:

```sh
volume=enchiridion-state   # or enchiridion_enchiridion-state for Compose
docker run --rm \
  -v "$volume":/state \
  -v "$PWD":/backup \
  alpine sh -c 'rm -rf /state/* && tar xzf /backup/enchiridion-state.tgz -C /state'
```

The archive holds the agent directory, the memory store, and the run files.
A restore replaces the whole tree, so back up before it and stop the service first.

An upgrade rebuilds the image and starts the service on the same volume:

```sh
docker compose build
docker compose up -d
```

The state volume survives the replacement.
The store schema creates missing tables and has no migration code, so a schema change that adds a column needs a manual migration.

## Deploying the container

1. Build the image from the repository root:

   ```sh
   docker build -t enchiridion:0.1.0 -f docker/Dockerfile .
   ```

2. Create `.env` at the repository root with the webhook token and the selected provider key, then restrict it:

   ```text
   ENCHIRIDION_HTTP_TOKEN=replace-with-a-token
   OPENAI_API_KEY=replace-with-the-provider-key
   ```

   ```sh
   chmod 600 .env
   ```

   A bind that answers the network needs the token, and the model call needs the provider key.
   [Configuration](configuration.md) names the provider key variables.

3. Create the seed files on the state volume before the server starts:

   ```sh
   docker run --rm \
     --tmpfs /run/secrets:mode=0700 \
     --cap-add SYS_ADMIN \
     -e ENCHIRIDION_REQUIRE_HIDEPID=1 \
     -v enchiridion-state:/var/lib/enchiridion \
     enchiridion:0.1.0 \
     init
   ```

   The command prints `No agent directory found. Creating /var/lib/enchiridion/agents/default/.`, then one `  created NAME` line per seed file, and exits 0.
   [Getting started](getting-started.md) names the files.

4. Start the container:

   ```sh
   docker run -d --name enchiridion \
     -p 8787:8787 \
     --tmpfs /run/secrets:mode=0700 \
     --cap-add SYS_ADMIN \
     -e ENCHIRIDION_REQUIRE_HIDEPID=1 \
     -v "$PWD/.env":/run/secrets/.env:ro \
     -v enchiridion-state:/var/lib/enchiridion \
     enchiridion:0.1.0 \
     serve --channel http --bind 0.0.0.0 --port 8787
   ```

   The webhook answers on port 8787, and the file route keeps the secret out of the container environment.

5. Read the entrypoint log with `docker logs enchiridion`; a correct start prints these four lines before the supervisor serves:

   ```text
   entrypoint: /proc remounted with hidepid=2
   entrypoint: supervisor uid 0, agent uid 1000
   entrypoint: state   /var/lib/enchiridion
   entrypoint: secrets /run/secrets
   ```

6. Prove the split with the three commands in [The isolation check](#the-isolation-check), and compare each line with the expected line.
   Each command exits 0 when every check in its pass succeeds.

7. Stop the container with `docker stop enchiridion`.
   The supervisor answers `SIGTERM` through the same path as `Ctrl-C`, unwinds, and exits 130, and the named volume remains.

## The isolation check

`docker/isolation-test.sh` checks the security model from inside the container, and nothing in the image runs it automatically.
One pass runs as uid 1000 and reads what the agent can reach, and the other runs as uid 0 and reads the supervisor environment.
`ISOLATION_PHASE` selects the agent pass and defaults to `all`.
`present` runs the checks that need the secret file, `absent` the checks that need it gone, and `all` runs both.

```sh
# The agent view, with the secret file still in place
docker exec -u agent -e ISOLATION_PHASE=present enchiridion /usr/local/bin/isolation-test.sh

# The agent view at steady state, after the supervisor read the file
docker exec -u agent -e ISOLATION_PHASE=absent enchiridion /usr/local/bin/isolation-test.sh

# The supervisor view
docker exec -u 0 enchiridion /usr/local/bin/isolation-test.sh
```

Each passing command prints one line and exits 0:

```text
isolation: phase present passed as uid 1000
isolation: phase absent passed as uid 1000
isolation: phase all passed as uid 0; supervisor env is clean
```

A failing check prints `FAIL: <message>` to the error stream and exits 1.
In those messages `NAME` is the environment variable the check found, and `PATH` is the path `find` reported.

The agent pass runs these checks:

| Check | Test                                                        | Failure message                                             |
| ----- | ----------------------------------------------------------- | ----------------------------------------------------------- |
| 1     | Uid 1000 cannot read `/run/secrets/.env` with `cat`         | `the agent can read /run/secrets/.env`                      |
| 2     | A shell started by uid 1000 cannot read `/run/secrets/.env` | `a shell can read /run/secrets/.env`                        |
| 3     | `/proc/1/environ` is not readable by uid 1000               | `/proc/1/environ is readable; hidepid is not active`        |
| 4     | The agent environment holds no configured secret name       | `NAME is in the agent environment`                          |
| 4     | The agent environment holds no credential-shaped name       | `NAME is credential shaped and is in the agent environment` |
| 6     | `/run/secrets/.env` does not exist at steady state          | `/run/secrets/.env still exists at steady state`            |
| 7     | No `.env` file exists outside `/run/secrets`                | `a .env exists outside /run/secrets: PATH`                  |

Check 5 is the scrubber test in the unit suite, covered by [Testing](testing.md).
The script refuses any uid other than 0 and 1000 with `run this as uid 1000 or uid 0, not N`.

The supervisor pass runs as uid 0 and checks these conditions:

| Test                                                            | Failure message                                                            |
| --------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Pid 1 is the supervisor                                         | `pid 1 is not the supervisor; run this in the image the entrypoint starts` |
| `/proc/1/environ` is readable as uid 0                          | `/proc/1/environ is not readable as uid 0; nothing was checked`            |
| No configured secret name remains in the supervisor environment | `NAME is still in the supervisor environment`                              |
| No credential-shaped name remains in the supervisor environment | `NAME is credential shaped and is still in the supervisor environment`     |

The configured names are `OPENCODE_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `FLUXER_BOT_TOKEN`, and `ENCHIRIDION_HTTP_TOKEN`.
The shape check uses the same vocabulary as `credential-variable-p`, so a name a `config.cl` adds is caught without a second list.

Check 7 runs `find` from two roots, because `-xdev` stops at a filesystem boundary:

```sh
find / -xdev -path /run/secrets -prune -o -name .env -print
find "$STATE_DIR" -path /run/secrets -prune -o -name .env -print
```

`STATE_DIR` is `ENCHIRIDION_HOME`, or `/var/lib/enchiridion` when that variable is unset.

## The serve flags

For `chat` and `serve`, flags may come before or after the command, and `--bind`, `--port`, and `--token-env` require `--channel http`.

| Flag          | Value                                     | Default                                                      |
| ------------- | ----------------------------------------- | ------------------------------------------------------------ |
| `--channel`   | `cli`, `http`, or `fluxer`                | None; enabled channels are built, and `serve` builds the terminal channel |
| `--bind`      | An address for the webhook                | The `:http` entry, shipped as `127.0.0.1`                    |
| `--port`      | A number from 1 to 65535                  | The `:http` entry, shipped as `8787`                         |
| `--token-env` | The variable that names the webhook token | The `:http` entry, shipped as `ENCHIRIDION_HTTP_TOKEN`       |

A flag with no value prints `enchiridion: The --FLAG flag needs a value.` and exits 2, with `FLAG` replaced by the flag name.
An unknown channel prints `enchiridion: There is no channel called NAME. The channels are cli, http and fluxer.` and exits 2.
A webhook flag without `--channel http` prints `enchiridion: The --bind, --port and --token-env flags belong to --channel http.` and exits 2.
A port outside the range prints `enchiridion: The port must be a number between 1 and 65535, not VALUE.` and exits 2.

A bind other than loopback needs a token.
The policy check runs before a socket opens, and the process exits 2 with two lines:

```text
Configuration is wrong at HTTP-TOKEN.
A webhook bound to 0.0.0.0 answers the network, so it needs a token. Set the variable the :http channel names, or bind 127.0.0.1.
```

A loopback bind needs no token.
The run line in [Deploying the container](#deploying-the-container) binds `0.0.0.0`, so `.env` must hold the token.
A loopback deployment replaces the bind with `127.0.0.1` and may omit it.

## The Compose deployment

`compose.yml` describes one service and one named volume, and it mirrors the run line.
The image is `${ENCHIRIDION_IMAGE:-enchiridion:0.1.0}`, the container is `enchiridion`, the restart policy is `unless-stopped`, and the command is `serve --channel http --bind 0.0.0.0 --port 8787`.
It publishes `${ENCHIRIDION_PORT:-8787}:8787`, mounts a tmpfs at `/run/secrets` with mode 0700 and the `enchiridion-state` volume at `/var/lib/enchiridion`, and sets a 30-second stop grace period.
Logging uses the `json-file` driver with 10 MB per file and three files.
The service adds `SYS_ADMIN`, sets `ENCHIRIDION_REQUIRE_HIDEPID=1`, and reads `env_file: .env` as not required.

The Compose file starts the server on a fresh volume without seed files.
The command binds `0.0.0.0`, so `ENCHIRIDION_HTTP_TOKEN` must be set or the policy check exits 2.

1. Build the image with `docker compose build`.

2. Write `.env` at the repository root with the token and the provider key, then run `chmod 600 .env`.
   The `env_file` entry supplies the names, and Compose reads the same file for `ENCHIRIDION_IMAGE` and `ENCHIRIDION_PORT`.

3. Create the seed files with `docker compose run --rm enchiridion init`.
   The command prints one `  created NAME` line per seed file and exits 0.

4. Start the service with `docker compose up -d`.
   `docker compose logs enchiridion` prints the entrypoint lines in [Deploying the container](#deploying-the-container).

5. Stop the service with `docker compose stop`.
   The volume remains, and `docker compose down -v` removes it.

The `env_file` route puts the token and the provider key into the container environment, and the loader removes each name from the supervisor process only.
Docker keeps the container environment for the life of the container, so a `docker exec` process sees those names.
Check 4 of the isolation test therefore fails on this route.
The read-only bind mount in [Deploying the container](#deploying-the-container) keeps the names out of the environment and passes the environment check.

## Troubleshooting

| Symptom                                                               | Cause                                                                   | Fix                                                                                              |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `entrypoint: /run/secrets is not a mount.`                            | The run line has no tmpfs at `/run/secrets`                             | Add `--tmpfs /run/secrets:mode=0700`                                                             |
| `entrypoint: the supervisor must start as root; it holds the secrets` | The container runs with `--user`                                        | Remove `--user` and start as root                                                                |
| `entrypoint: cannot remount /proc with hidepid=2`                     | No `SYS_ADMIN`, or the kernel refuses the remount                       | Add `--cap-add SYS_ADMIN`, or set `ENCHIRIDION_HIDEPID=0`                                        |
| `entrypoint: could not remount /proc with hidepid=2`                  | The remount failed and the deployment does not require it               | Add the capability and set `ENCHIRIDION_REQUIRE_HIDEPID=1`, or accept the missing proc guarantee |
| `Configuration is wrong at SECRETS.` and a mode line                  | The secret file is world readable                                       | Run `chmod 600` on the file                                                                      |
| `Configuration is wrong at HTTP-TOKEN.`                               | A non-loopback bind has no token                                        | Set `ENCHIRIDION_HTTP_TOKEN`, or bind `127.0.0.1`                                                |
| `FAIL: /proc/1/environ is readable; hidepid is not active`            | Uid 1000 can read the supervisor's environment                          | Add the capability and restart the container                                                     |
| `FAIL: NAME is in the agent environment`                              | `env_file` or `-e` put the name in the container environment            | Use the read-only bind mount and remove the `-e` entry                                           |
| `FAIL: NAME is credential shaped and is in the agent environment`     | The container environment holds a name this configuration does not know | Remove the variable from the environment                                                         |
| `FAIL: /run/secrets/.env still exists at steady state`                | Uid 1000 can reach `/run/secrets`, which is not mode 700                | Restart the container so the entrypoint resets the mode, and find what changed it                |
| `FAIL: a .env exists outside /run/secrets: PATH`                      | A copy of the secret file is on the volume or elsewhere                 | Delete the copy, and keep only the tmpfs file                                                    |
| `FAIL: pid 1 is not the supervisor`                                   | The test ran outside the image the entrypoint starts                    | Run it in the deployed container                                                                 |
| `entrypoint: /run/secrets/.env has unexpected ownership; continuing`  | The bind-mounted file carries the host owner                            | Accept the warning, or chown the file to 0:0                                                     |

## See also

- [Getting started](getting-started.md) for the seed files and the first turn.
- [Configuration](configuration.md) for the `:sandbox` keys, the `:channels` entries, and the secret names.
- [Channels](channels.md) for the webhook routes, the token check, and the request limit.
- [Supervisor and heartbeat](supervisor.md) for the control file and the status file on the state volume.
- [Development](development.md) for the build gate that checks the same source.
