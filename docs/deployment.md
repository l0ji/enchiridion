# Deployment

`docker compose` is the supported server deployment. It runs one container as
root, runs tools and agent code as uid 1000, and keeps state in a named volume.
The host needs Linux, Docker Engine and Compose v2. A checkout started as your
own user has no split; see [Host checkout](#host-checkout).

## Docker Compose

1. Copy the examples and restrict the secret file.

   ```sh
   cp config.example.lsp config.lsp
   cp .env.example .env
   chmod 600 .env
   ```

2. In `.env`, uncomment one provider line and the token line, then fill them in.

   ```text
   ENCHIRIDION_HTTP_TOKEN=<token>
   OPENAI_API_KEY=<key>
   ```

   Generate the token with `openssl rand -hex 32`. Use `OPENCODE_API_KEY` or
   `ANTHROPIC_API_KEY` for those providers. With `:provider nil`, the API key
   selects the provider, and `config.lsp` chooses the models. If more than one
   provider key is available, including one exported in your shell, set
   `:provider` explicitly. [Configuration](configuration.md) lists the entries.

3. Edit `config.lsp`. The Compose command passes `serve --channel http --bind
   0.0.0.0 --port 8787`, so it overrides the bind and port in the `:http`
   section and starts the webhook even when `:enabled` is `nil`.
   [Channels](channels.md) covers the request format.

   Compose publishes HTTP on host loopback only. Use Tailscale Serve or a TLS
   proxy for remote access. The bearer token does not encrypt traffic.

4. Build the image and create the seed files.

   ```sh
   docker compose build
   docker compose run --rm enchiridion init
   ```

   `init` prints `No agent directory found. Creating ...`, then one
   `  created NAME` line for each seed file, and exits 0.

5. Run `docker compose create enchiridion`, then edit `SOUL.md`, `OPERATOR.md`
   and `WORLD.md` before the first conversation.
   [Commands](commands.md#identity-files) has the stopped-container `docker cp`
   loop. [Getting started](getting-started.md) describes what belongs in each
   file.

6. Start the service.

   ```sh
   docker compose up -d
   docker compose logs enchiridion
   ```

   A healthy start logs `entrypoint: /proc remounted with hidepid=2`,
   `entrypoint: supervisor uid 0, agent uid 1000`, and the state and secrets
   paths. The HTTP channel logs `enchiridion: webhook listening on
   0.0.0.0:8787.` when it binds.

7. Check readiness and send one message.

   ```sh
   token=$(sed -n 's/^ENCHIRIDION_HTTP_TOKEN=//p' .env)
   curl -sS -H "Authorization: Bearer $token" http://127.0.0.1:8787/health
   curl -fsS -X POST http://127.0.0.1:8787/message \
     -H "Authorization: Bearer $token" \
     -H "Content-Type: application/json" \
     -d '{"text":"Say hello."}'
   ```

   Retry if the listener is still starting. `/health` returns 200 when ready
   and 503 otherwise. See [response fields](channels.md#responses). Replace
   8787 with `ENCHIRIDION_PORT` if set.

8. Stop the service with `docker compose stop`. The volume remains;
   `docker compose down -v` deletes it. After editing `config.lsp` or `.env`, run
   `docker compose up -d --force-recreate`.

## Private access with Tailscale Serve

[Install Tailscale](https://tailscale.com/download) on the Docker host and join
the host to the tailnet. Serve terminates TLS on the host's tailnet name and
proxies to the loopback port:

```sh
tailscale serve --bg 8787
tailscale serve status
```

Use `https://<host>.<tailnet>.ts.net/` and the same bearer token from other
tailnet devices. Enable tailnet HTTPS certificates if prompted. Use the published
port if it differs from 8787. Restrict access with [Tailscale grants](https://tailscale.com/kb/1623/grants).
Do not use Funnel for private access. `tailscale serve reset` removes the proxy.

## State and backups

The image declares no anonymous volume, so a bare `docker run` without `-v`
writes state into the container layer and loses it with the container. The
Compose named volume is the supported route.

The volume holds `agents/default` (seed files, `memory.db`, `skills/`, `tools/`,
`state.json`), `run` (control and status files, broker socket), and `tmp`. Stop
the service before copying, so the store and run files do not change. Compose
prefixes the volume with the project name `enchiridion`, so the volume is
`enchiridion_enchiridion-state`.

```sh
docker compose stop
docker run --rm \
  -v enchiridion_enchiridion-state:/state:ro \
  -v "$PWD":/backup \
  alpine tar czf /backup/enchiridion-state.tgz -C /state .
docker compose up -d
```

A restore replaces the whole state tree. Check the archive first:

```sh
docker compose stop
test -s enchiridion-state.tgz
tar tzf enchiridion-state.tgz >/dev/null
docker run --rm \
  -v enchiridion_enchiridion-state:/state \
  -v "$PWD":/backup \
  alpine sh -c 'rm -rf /state/* /state/.[!.]* /state/..?* && tar xzf /backup/enchiridion-state.tgz -C /state'
docker compose up -d
```

To upgrade, back up first, then run `docker compose build` and `docker compose
up -d`. The memory store migrates an older schema when it opens. The Dockerfile
pins the base image, Debian snapshot and Quicklisp distribution; a built image
records them in `/opt/enchiridion/dist-lock.txt`.

## Supervisor and schedule

`serve` runs one supervisor process. It owns the agent, the memory store, the
channels, and the schedule for unattended work. `chat` starts one with the REPL
in front. [Commands](commands.md#the-live-supervisor) lists the commands; this
section covers what to expect from them.

`enchiridion health` reads `run/enchiridion.status` and exits 0 only when the
file says `running` and was updated within 10 seconds. It reports the age of
an active tick. The file is world readable and reports are scrubbed.
[HTTP readiness](channels.md#responses) reads the live supervisor instead.

Control commands queue under `run/control/`. Pending requests expire after
15 minutes. A timeout does not cancel the request. See
[Commands](commands.md#the-live-supervisor) for reload and channel behavior.
`run/enchiridion.control` is deprecated.

A channel whose start returns retries after one second unless it reports
`:unavailable`.

### Unattended work

`:sleep :enabled` defaults to true and `:sleep :interval-seconds` to 900. A tick
runs when the interval elapses or when `heartbeat run` asks for one. The first
tick waits one interval. `last-tick` is measured from the end of a tick, so a
pass longer than the interval does not overlap itself. `heartbeat off` stops the
schedule, not a forced tick.

A tick runs memory maintenance and at most one queued task. Pending tasks
survive restart. An interrupted task is marked failed and is not retried.
Only the first 4000 characters of a task are sent to the sleep model.

After four eligible turns, the cheap model compacts the session before other
model work in the tick. An inherited summary with no recorded compaction is
rebuilt from raw turns. An unusable summary leaves the session unchanged. After
two failed attempts, compaction waits for another eligible turn.

| Setting under `:budget` | Default | Applies to |
| --- | --- | --- |
| `:max-tokens-per-tick` | 400000 | Sleep and embedding calls in one tick |
| `:max-tokens-per-day` | 40000000 | All recorded usage over 24 hours, checked before background work |

Set either cap to `nil` to disable it. An in-flight request can overshoot a cap.
The caps do not stop chat or limit provider charges.

### Canary approvals in Compose

Run operator commands as root in the container, with the same config path as
`serve`. The `enchiridion-canary-approvals` volume keeps approvals across container
replacement and is separate from the agent's memory volume.

```sh
docker compose exec -e ENCHIRIDION_CONFIG=/etc/enchiridion/config.lsp enchiridion \
  enchiridion memory canaries
```

## Container requirements

| Requirement | Why | If missing |
| --- | --- | --- |
| Start as uid 0 | The supervisor holds the secrets and drops every child to the agent uid | The entrypoint exits 1 |
| A tmpfs at `/run/secrets`, mode 0700 | The secret file is read once and unlinked | The entrypoint exits 1 |
| `SYS_ADMIN` and `ENCHIRIDION_REQUIRE_HIDEPID=1` | The entrypoint remounts `/proc` with `hidepid=2` | The entrypoint exits 1 |
| A root-owned `config.lsp` | The supervisor refuses a configuration the agent uid can replace | The command exits 2 |

Do not set `user:` in the Compose service or pass `--user` to `docker run`; a
non-root start fails the first check. The entrypoint creates the `agent` user
with uid and gid 1000 when the image does not hold one and drops every child to
it.

`ENCHIRIDION_HIDEPID` defaults to `2`; `0` skips the remount. Compose sets
`ENCHIRIDION_REQUIRE_HIDEPID=1`, so a kernel that refuses the remount stops the
container. Set `ENCHIRIDION_HIDEPID=0` only when you accept that uid 1000 can
read the supervisor's process details.

The Compose file mounts `config.lsp` read-only at `/opt/enchiridion/config.lsp`.
The entrypoint copies it to a root-owned `/etc/enchiridion/config.lsp` and points
`ENCHIRIDION_CONFIG` there, so a host file owned by your user still passes the
root path check.

## Secrets and the environment

Compose passes `.env` into the container with `env_file`. This is the shortest
route. The supervisor reads the values and removes them from its own process,
but Docker keeps the container environment for the life of the container, so
`docker exec` processes see the names. The isolation test's environment check
fails on this route.

For the stricter route, remove the `env_file` entry and bind the file instead:

```yaml
    volumes:
      - ./.env:/run/secrets/.env:ro
```

Compose still reads `.env` for `${ENCHIRIDION_PORT}` and `${ENCHIRIDION_IMAGE}`,
but the names no longer enter the container environment. The supervisor unlinks
the container copy after reading it; a read-only mount cannot be unlinked, so it
logs one warning and continues.

The loader refuses a secret file that any uid can read and exits 2 with
`Configuration is wrong at SECRETS.` and the path and mode. A group-readable
file passes. An absent file also passes; the provider key check fails later.

## Isolation check

The image carries `docker/isolation-test.sh` and never runs it automatically.

```sh
docker exec -u 0 -e ISOLATION_PHASE=present enchiridion /usr/local/bin/isolation-test.sh
docker exec -u 0 -e ISOLATION_PHASE=absent enchiridion /usr/local/bin/isolation-test.sh
docker exec -u agent enchiridion /usr/local/bin/isolation-test.sh
```

Each command exits 0 and its last line says `passed`; a failure prints `FAIL:
...` and exits 1. The uid 0 phases check the secret file and the `/proc` mount.
The uid 1000 phase checks that the directory is closed, the file and
`/proc/1/environ` cannot be read, and no `.env` copy is reachable. With the
`env_file` route, the uid 0 `present` phase says that route is in use, and the
uid 1000 phase fails at the environment check.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `entrypoint: /run/secrets is not a mount` | No tmpfs at `/run/secrets` | Add `--tmpfs /run/secrets:mode=0700` |
| `entrypoint: the supervisor must start as root` | The container runs with `--user` | Remove `--user` |
| `entrypoint: cannot remount /proc with hidepid=2` | No `SYS_ADMIN`, or the kernel refuses | Add the capability, or set `ENCHIRIDION_HIDEPID=0` |
| `Configuration is wrong at CONFIG` | No `config.lsp` mount, or a path the agent can write | Mount `config.lsp` and recreate |
| `Configuration is wrong at HTTP-TOKEN` | The bind is not loopback and no token is set | Set the token, or bind `127.0.0.1` |
| `Configuration is wrong at SECRETS` | The secret file is world readable | Run `chmod 600 .env` |
| `/health` answers 401 | The bearer token is missing or wrong | Send `Authorization: Bearer <token>` |
| `/health` answers 503 | A wanted channel is failed or stopped, or the heartbeat thread is gone | Read `reasons`, then `docker compose logs enchiridion` |
| `curl` from another host times out | The published port is on loopback | Use Tailscale Serve, an SSH tunnel, or change the mapping |

## Host checkout

Running `nix run` or the binary from a checkout as your own user does not split
users. The supervisor, broker, tools and agent code all run as you, and agent
code can read `.env`. The container is the deployment that separates them.

A root-started checkout can use the same split: set `ENCHIRIDION_HOME` to a state
root the agent uid can reach, install a root-owned `config.lsp`, keep secrets in a
root-owned file at mode 600, and run `init` and `serve` as root.
