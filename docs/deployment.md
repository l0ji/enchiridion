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

   > [!warning]
   > The `ports` mapping publishes plain HTTP on every host interface. For a
   > private server, change it to
   > `"127.0.0.1:${ENCHIRIDION_PORT:-8787}:8787"` and put a TLS reverse proxy in
   > front, or restrict the port with a firewall or VPN. The bearer token
   > authenticates callers; it does not encrypt traffic.

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
   paths.

7. Check health and send one message.

   ```sh
   token=$(sed -n 's/^ENCHIRIDION_HTTP_TOKEN=//p' .env)
   curl -fsS -H "Authorization: Bearer $token" http://127.0.0.1:8787/health
   curl -fsS -X POST http://127.0.0.1:8787/message \
     -H "Authorization: Bearer $token" \
     -H "Content-Type: application/json" \
     -d '{"text":"Say hello."}'
   ```

   `/health` answers with `ok`, `uptime`, and one row per channel. If
   `ENCHIRIDION_PORT` is set, use that port instead of 8787.

8. Stop the service with `docker compose stop`. The volume remains;
   `docker compose down -v` deletes it. After editing `config.lsp` or `.env`, run
   `docker compose up -d --force-recreate`.

## State and backups

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
file is live: `running` is true and `updated` is at most 10 seconds old. A
process that ends without a clean stop can leave an old file, so age matters as
much as the flag. `GET /health` reads the live process instead. A tick still
running prints its age, which is how a stuck tick becomes visible. The status
file is world readable, and its reports are scrubbed.

`reload`, `channels` and `heartbeat` publish a request under `run/control/` and
wait up to five seconds. Reload and channel requests are handled even during
a tick; `heartbeat run` queues another tick until the current one finishes. A
request older than 60 seconds gets `control request expired.` Applying a
request and publishing its response are separate steps, so a crash between them leaves an
uncertain outcome. `run/enchiridion.control` is the legacy input and is
deprecated.

A refused reload keeps the last good generation serving. `channels replace`
waits up to 20 seconds for a fresh channel and stops the old one only after the
new one is live; a failure leaves the old channel running. A replacement
listener on the same address and port can fail with address in use. A channel
whose start returns is restarted after one second; one that reports
`:unavailable` is not.

### Unattended work

`:sleep :enabled` defaults to true and `:sleep :interval-seconds` to 900. A tick
runs when the interval elapses or when `heartbeat run` asks for one. The first
tick waits one interval. `last-tick` is measured from the end of a tick, so a
pass longer than the interval does not overlap itself. `heartbeat off` stops the
schedule, not a forced tick.

Each tick runs seven phases in order:

| Order | Phase | Work |
| --- | --- | --- |
| 1 | Task recovery | Marks every `running` task `failed` |
| 2 | Memory maintenance | Copies new turns into the episodic log and derives scalars |
| 3 | Memory embedding | Embeds pending episodes when configured and the budget has room |
| 4 | Memory T2 | Runs a due candidate build or gate pass under the day cap |
| 5 | Harness blocks | Writes the ledger block and the session fallback |
| 6 | Sleep agent | Claims one task, or runs one maintenance pass, or does nothing |
| 7 | Compaction | Rewrites the session block when four turns are due |

Every phase is guarded on its own. A failed phase adds a note and the later
phases still run. The notes are joined with `;`, and a tick with no notes reports
`idle`. A refusal reads `sleep skipped: <reason>`, `memory embedding skipped:
<reason>`, `T2 skipped: <reason>`, or `compaction skipped: <reason>`. The sleep
agent refuses with `no memory store is open`, `no agent is attached`, `no model
backend is configured`, or `bootstrap has not handed over, so the identity files
are still the operator's`.

The sleep agent claims the oldest pending task and runs one pass, or runs one
maintenance pass when a turn newer than its last pass exists. A task body reaches
the prompt cut at 4000 characters; the stored row keeps the whole body and the
report says when it was cut. Compaction uses the cheap model and rewrites the
session block when four eligible turns are past the last compacted turn;
sleep-agent turns do not count. A pass that returns no text spends the call,
reports `compaction produced no text`, and does not move the cursor.

`:budget :max-tokens-per-tick` defaults to 4000 and bounds spend since the tick
started over the `sleep` and `embed` channels. `:budget :max-tokens-per-day`
defaults to 400000 and bounds the rolling 24 hours the ledger uses. Leaving a key
out keeps its default; an explicit `nil` removes that cap. A phase stops when its
window is spent, so an in-flight phase can finish over the cap. The caps do not
limit chat or provider charges; use the provider's spending controls for money.

The task queue is a table in the memory store, so a task survives a restart. One
task runs per tick. A task is `pending`, `running`, `done` or `failed`. A failed
task is not requeued: unattended work is at-most-once. Phase 1 fails every task a
dead process left running.

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

## Host checkout

Running `nix run` or the binary from a checkout as your own user does not split
users. The supervisor, broker, tools and agent code all run as you, and agent
code can read `.env`. The container is the deployment that separates them.

A root-started checkout can use the same split: set `ENCHIRIDION_HOME` to a state
root the agent uid can reach, install a root-owned `config.lsp`, keep secrets in a
root-owned file at mode 600, and run `init` and `serve` as root.
