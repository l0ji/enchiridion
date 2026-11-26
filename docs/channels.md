# Channels

Channels are how messages reach the agent: the terminal REPL, an HTTP webhook,
or Fluxer direct messages. Under `serve`, the supervisor runs each enabled
channel on its own thread and restarts it after 1 second if it exits (unless it
reports `:unavailable`, like the terminal channel without a TTY).

Enable channels in `config.lsp` under `:channels` (see
[Configuration](configuration.md#channels)), or turn one on for a single run
with `--channel http` or `--channel fluxer`.

## Terminal

`enchiridion chat` runs the interactive REPL (`enchiridion>`).

- Slash lines (`/help`, `/stop`, `/quit`, `/who`, or `/<command>`) run commands.
- A single bare word that matches a command prints a slash hint instead of
  sending a turn to the model. Two or more words are always sent to the agent.
- `Ctrl-C` cancels the current line or turn and returns to the prompt. `Ctrl-D`
  or `/quit` exits.

When `serve` runs without a TTY (for example, in Docker), the terminal channel
marks itself `:unavailable` and stays down.

## HTTP webhook

Enable `:http` in `config.lsp` or pass `--channel http --bind 0.0.0.0 --port
8787` to `serve`. Defaults are `127.0.0.1:8787` and token variable
`ENCHIRIDION_HTTP_TOKEN`.

Loopback listeners do not require a bearer token; non-loopback listeners refuse
to start without one. Generate a token with `openssl rand -hex 32` and put it in
`.env`.

### Routes

All responses are JSON. Errors return `{"ok":false,"error":"..."}` (except
degraded `/health`, which returns the full health object with `ok:false`).

| Method & Path | What it does |
| --- | --- |
| `POST /message` | Runs one synchronous turn. Body: `{"text": "...", "author": "optional"}` (`author` defaults to `"webhook"`). Requires `Content-Type: application/json`, max 64 KiB (configurable via `:max-body-bytes`). Returns `503` with `Retry-After: 1` if another turn is in flight. |
| `GET /health` | Returns `200` when ready, `503` if an enabled channel is down, an enabled heartbeat died, or no supervisor is running. |
| `GET /usage` | Returns token ledger rows (`count`, `rows`), oldest first. Optional `?limit=N` (default `50`, max `1000`). |

### Example

```sh
token=$(sed -n 's/^ENCHIRIDION_HTTP_TOKEN=//p' .env)
curl -sS -X POST http://127.0.0.1:8787/message \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  -d '{"text":"List the open ports.","author":"sama"}'
```

`POST /message` returns the reply and summed token usage across all tool rounds:

```json
{
  "reply": "...",
  "usage": {
    "model": "deepseek-v4.1-flash",
    "input": 10,
    "output": 5,
    "cache-read": 0,
    "cache-write": 0,
    "rounds": 2,
    "total": 15
  }
}
```

`GET /health` returns readiness and diagnostics:

```json
{
  "ok": true,
  "ready": true,
  "uptime": 812,
  "reasons": [],
  "channels": [{"name": "http", "state": "live", "enabled": true}],
  "heartbeat": {
    "enabled": true,
    "alive": true,
    "requested": false,
    "ticks": 3,
    "last-tick": 1794966000,
    "ok": true,
    "running": false,
    "report": "idle"
  },
  "persistence": {"failures": 0, "last": null},
  "providers": {"state": "done", "report": ""},
  "writes": {"ok": true, "report": "", "age": 0}
}
```

*(Read/write socket timeout is 5 seconds; shutdown drains in-flight turns for up
to 6 seconds.)*

## Fluxer

The Fluxer channel answers **1-on-1 direct messages only** from users on
`:allowed-users`. Everything else (guild messages, bots, unlisted users) is
dropped.

### Setup

1. Create a bot and put `FLUXER_BOT_TOKEN=...` in `.env`.
2. Add your numeric Fluxer user ID (not username) to `config.lsp`:

   ```lisp
   (:fluxer
    (:enabled t)
    (:allowed-users ("123456789012345678")))
   ```

3. Start `enchiridion serve --channel fluxer` and send the bot a direct message.

### Behavior

- **Queue and reactions:** Incoming DMs queue on a single worker thread
  (capacity 32) so turns never block the heartbeat. The bot reacts with ⏳ while
  queued, 🔧 while running, removes the reaction on delivery, and marks ⚠️ on
  failure or queue eviction.
- **Chunking:** Long replies split cleanly at paragraph/line breaks to stay
  within 2,000 UTF-16 code units, repeating fenced code block markers across
  chunks.

### Custom status

Optionally let the agent set a short temporary status on its Fluxer profile:

```lisp
(:fluxer
 (:enabled t)
 (:allowed-users ("123456789012345678"))
 (:custom-status t)
 (:custom-status-user "123456789012345678") ; required if >1 allowed user
 (:custom-status-ttl-seconds 300)
 (:custom-status-cooldown-seconds 60))
```

The agent proposes status text via its `presence` tool; the channel publishes it
*after* delivering the reply, enforces a single line of ≤128 characters
(scrubbed for secrets and control characters), and clears it after the TTL. Only
the named operator's turns can change the status; permission to send direct
messages does not grant permission to set the profile status.
