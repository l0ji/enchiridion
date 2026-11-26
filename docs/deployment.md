# Deployment

Docker Compose is the supported server deployment. It runs the supervisor as
`root` (holding secrets in memory), drops the broker, tools, and agent code to
`uid 1000`, and keeps state in a named volume. Requirements: Linux with Docker
Engine and Compose v2.

## Docker Compose setup

1. Copy the config and secret templates:

   ```sh
   cp config.example.lsp config.lsp
   cp .env.example .env
   chmod 600 .env
   ```

2. Edit `.env` and set `ENCHIRIDION_HTTP_TOKEN` (generate with `openssl rand
   -hex 32`) plus one provider API key (`OPENAI_API_KEY`, `OPENCODE_API_KEY`, or
   `ANTHROPIC_API_KEY`).

3. Edit `config.lsp` if you want a specific `:provider` or model. Compose starts
   `serve --channel http --bind 0.0.0.0 --port 8787`, which enables the HTTP
   webhook and binds it to host loopback (`127.0.0.1:8787`) regardless of
   `:http` in `config.lsp`.

4. Build the image and initialize the agent directory on the volume:

   ```sh
   docker compose build
   docker compose run --rm enchiridion init
   ```

5. Edit `SOUL.md`, `OPERATOR.md`, and `WORLD.md` inside the volume before
   starting:

   ```sh
   docker compose create enchiridion
   for file in SOUL.md OPERATOR.md WORLD.md; do
     docker cp "enchiridion:/var/lib/enchiridion/agents/default/$file" .
     ${EDITOR:-vi} "$file"
     docker cp "$file" "enchiridion:/var/lib/enchiridion/agents/default/$file"
   done
   ```

   *(The entrypoint runs `chown -R` on start, so host UIDs from `docker cp` are
   fixed automatically.)*

6. Start the service and check logs:

   ```sh
   docker compose up -d
   docker compose logs enchiridion
   ```

7. Verify `/health` and send a test message:

   ```sh
   token=$(sed -n 's/^ENCHIRIDION_HTTP_TOKEN=//p' .env)
   curl -sS -H "Authorization: Bearer $token" http://127.0.0.1:8787/health
   curl -fsS -X POST http://127.0.0.1:8787/message \
     -H "Authorization: Bearer $token" \
     -H "Content-Type: application/json" \
     -d '{"text":"Say hello."}'
   ```

After editing `config.lsp` or `.env`, run `docker compose up -d
--force-recreate`. Use `docker compose stop` to stop without losing state
(`docker compose down -v` deletes the volume).

### Running CLI commands inside the container

Commands that load `config.lsp` need `ENCHIRIDION_CONFIG` passed explicitly,
because the entrypoint only exports it into the main process:

```sh
docker compose exec -e ENCHIRIDION_CONFIG=/etc/enchiridion/config.lsp \
  enchiridion enchiridion health
```

Use the same prefix for `tasks`, `usage`, `memory`, `reload`, `channels`, and
`heartbeat`.

## Private remote access (Tailscale Serve)

Compose binds HTTP to loopback only, and bearer tokens do not encrypt traffic.
For private TLS access across your tailnet, use [Tailscale
Serve](https://tailscale.com/download) (do not use Funnel):

```sh
tailscale serve --bg 8787
tailscale serve status
```

Then reach the webhook at `https://<host>.<tailnet>.ts.net/` with your bearer
token. Remove with `tailscale serve reset`.

## State and backups

The named volume (`enchiridion_enchiridion-state`) holds root-owned
`canary-approvals/` plus agent-owned `agents/`, `run/`, and `tmp/`. Stop the
service before backing up so SQLite and approvals stay consistent:

```sh
# Backup
docker compose stop
docker run --rm \
  -v enchiridion_enchiridion-state:/state:ro \
  -v "$PWD":/backup \
  alpine tar czf /backup/enchiridion-state.tgz -C /state .
docker compose up -d

# Restore (replaces the entire state tree)
docker compose stop
tar tzf enchiridion-state.tgz >/dev/null
docker run --rm \
  -v enchiridion_enchiridion-state:/state \
  -v "$PWD":/backup \
  alpine sh -c 'rm -rf /state/* /state/.[!.]* /state/..?* && \
    tar xzf /backup/enchiridion-state.tgz -C /state'
docker compose up -d
```

To upgrade, back up first, then run `docker compose build && docker compose up
-d`. The SQLite schema migrates automatically on open.

## Supervisor and background schedule

`serve` runs one supervisor owning the agent, memory store, channels, and sleep
timer:

- **Status & control:** `enchiridion health` reads `run/enchiridion.status`
  (fresh within 10s). Control commands (`reload`, `channels`, `heartbeat`) queue
  under `run/control/`, wait up to 5 seconds for an answer, and expire after 15
  minutes. A 5-second timeout exits `1`, but the request may still
  complete—check `health`.
- **Ticks:** Every `:sleep :interval-seconds` (default 900s, measured from the
  end of the previous tick so passes never overlap), a tick compacts the session
  if ≥4 eligible turns passed, runs episodic maintenance + T2 if due, and
  executes at most one pending background task (first 4,000 chars sent to
  `:model-sleep`). Pending tasks survive restarts; an interrupted task is marked
  `failed`.

## Security model and isolation

The container relies on four entrypoint checks (do not set `user:` or `--user`):

1. **Starts as `uid 0`:** the supervisor holds secrets and drops every child
   process to `uid 1000` (`agent`).
2. **`/run/secrets` tmpfs (`mode=0700`):** secrets are read once into memory and
   unlinked from disk.
3. **`/proc` remounted `hidepid=2`** (requires `SYS_ADMIN`, enforced by
   `ENCHIRIDION_REQUIRE_HIDEPID=1`): prevents `uid 1000` from inspecting
   `/proc/1/environ`. Set `ENCHIRIDION_HIDEPID=0` only if you accept that
   tradeoff.
4. **Root-owned `config.lsp`:** Compose mounts your host `config.lsp` read-only
   and the entrypoint copies it to `/etc/enchiridion/config.lsp` so `uid 1000`
   cannot modify it.

### Stricter secret handling

By default, `compose.yml` uses `env_file: .env`, which is convenient but leaves
variable names visible to `docker exec` (causing the isolation test's
environment check to fail). For stricter isolation, remove `env_file` and
bind-mount `.env` directly:

```yaml
volumes:
  - ./.env:/run/secrets/.env:ro
```

*(The supervisor logs one warning because a read-only mount cannot be unlinked,
then continues.)*

### Running the isolation check

Verify container boundaries at any time with the bundled test script:

```sh
docker exec -u 0 -e ISOLATION_PHASE=present enchiridion \
  /usr/local/bin/isolation-test.sh
docker exec -u 0 -e ISOLATION_PHASE=absent enchiridion \
  /usr/local/bin/isolation-test.sh
docker exec -u agent enchiridion /usr/local/bin/isolation-test.sh
```

Each exits `0` with `passed` on the last line, or `1` with `FAIL: ...`.

## Host checkout (without Docker)

Running `nix run` as your normal user has **no user separation**—the agent and
its tools run as you and can read `.env`. If you want the split on bare metal
without Docker, set `ENCHIRIDION_HOME` to a path `uid 1000` can traverse,
install a root-owned `config.lsp` and mode-`600` `.env`, and run `init` and
`serve` as root.
