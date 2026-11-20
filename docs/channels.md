# Channels

Channels connect the agent to a terminal, an HTTP webhook, or Fluxer direct
messages. The supervisor starts each enabled channel on its own thread and
restarts it after one second if it stops.

## Selecting channels

A channel in the `:channels` section starts with `serve` when its `:enabled`
value is true. The `--channel` flag starts one for the current process without
changing `config.lsp`. [Commands](commands.md#flags) lists the flags and their
error messages.

`serve` always builds the terminal channel; `chat` runs the REPL in the
foreground instead. A channel that cannot run here, such as the terminal without
a TTY, reports `:unavailable` and is not restarted.

## Terminal

`enchiridion chat` starts the REPL. The prompt is `enchiridion> `. A line that
starts with a slash is a command; any other line is one turn. `/quit` or end of
input leaves. Ctrl-C aborts the line or the turn and returns to the prompt.
[Commands](commands.md#the-repl) lists the REPL commands.

Under `serve` without a terminal, the channel reports `:unavailable` and logs
`enchiridion: stdin is not a terminal, so the cli channel stays down.`

## HTTP webhook

Enable it in `config.lsp`:

```lisp
(:http
 (:enabled t)
 (:bind "127.0.0.1")
 (:port 8787)
 (:token-env "ENCHIRIDION_HTTP_TOKEN"))
```

The defaults are loopback, port 8787, and the token variable
`ENCHIRIDION_HTTP_TOKEN`. A bind that is not loopback refuses to start without
a token. Generate one with `openssl rand -hex 32` and put it in `.env`. The
`--channel`, `--bind` and `--port` flags override the section for one process,
as in `enchiridion serve --channel http --bind 0.0.0.0 --port 8787`.

Provider discovery runs in the background. `/health` reports its status.

### Routes

| Method | Path | Status | Answers |
| --- | --- | --- | --- |
| `POST` | `/message` | 200 | One synchronous turn |
| `GET` | `/health` | 200, or 503 when not ready | The live process, its readiness, and why not |
| `GET` | `/usage` | 200 | Ledger rows, oldest first, at most `?limit=` |

A known path with the wrong method answers 405 with an `Allow` header; any
other path answers 404. Every answer is JSON.

### Send a message

Set `token` in your shell to the value you put in `.env`; the file is not
loaded into your shell automatically.

```sh
token='<the token from .env>'
curl -sS -X POST http://127.0.0.1:8787/message \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  -d '{"text":"List the open ports.","author":"sama"}'
```

The body is a JSON object. `text` must be non-empty after trimming, and
`author` is optional and defaults to `webhook`. The content type must contain
`application/json`, or the route answers 415. A body over the 65536-byte
default answers 413; a chunked body is counted as it arrives, and a request
that declares both a `Content-Length` and a chunked encoding answers 400.

The server closes connections with unread request bodies without draining them.

A missing or incorrect bearer token returns 401 with
`WWW-Authenticate: Bearer`. A loopback listener may omit the token. A
non-loopback listener requires it to start.

### Responses

`POST /message` answers the reply and the usage of the whole turn:

```json
{"reply":"...","usage":{"model":"deepseek-v4.1-flash","input":10,"output":5,"cache-read":0,"cache-write":0,"rounds":2,"total":15}}
```

`usage` sums every model call in the turn, so `rounds` can be greater than one.

`GET /health` returns readiness and diagnostics:

```json
{"ok":true,"ready":true,"uptime":812,"reasons":[],
 "channels":[{"name":"http","state":"live","enabled":true}],
 "heartbeat":{"enabled":true,"alive":true,"requested":false,"ticks":3,
              "last-tick":1794966000,"ok":true,"running":false,"report":"idle"},
 "persistence":{"failures":0,"last":null},
 "providers":{"state":"done","report":""},
 "writes":{"ok":true,"report":"","age":0}}
```

`ok` and `ready` match. A failed or stopped enabled channel, a dead enabled
heartbeat, or a missing supervisor returns 503. Disabled and unavailable
channels do not count. `reasons` lists readiness failures when the supervisor
is running.

`persistence` counts failed transcript and ledger writes in this process.
`providers.state` is `pending`, `done`, `failed`, or `skipped`. `writes` reports
status-file errors. These fields do not change readiness.

`GET /usage` answers `count` and `rows` of `id`, `session`, `model`, `input`,
`output`, `cache-read`, `cache-write`, `channel` and `ts`, oldest first.
`?limit=` defaults to 50 and caps at 1000.

An error body is `{"ok":false,"error":"..."}`. The two `/usage` refusals carry
only `error`; a degraded `/health` carries the full report with `ok:false`.

| Status | Cause | Error text |
| --- | --- | --- |
| 400 | The body is not UTF-8, not JSON, not a JSON object, has blank `text`, or declares both a length and chunked encoding | `The body is not UTF-8 text.`, `The body is not JSON.`, `The body must be a JSON object.`, `The body needs a non-empty text field.`, or `The body declares both a length and a chunked encoding.` |
| 401 | The token is missing or wrong | `A bearer token is required.` |
| 404 | The path has no route | `There is no route <path>.` |
| 405 | The method is wrong | `<path> takes POST.` or `GET.` |
| 413 | The body is over the limit | `The body is larger than 65536 bytes.` |
| 415 | `/message` has no JSON content type | `POST /message needs a JSON body.` |
| 502 | The turn failed, or no turn function is attached | The condition text, or `no agent is attached to this webhook.` |
| 503 | A turn is running, `/usage` has no store or an unreadable ledger, or `/health` has no supervisor or is not ready | The busy text with `Retry-After: 1`, `no memory store is open`, `the ledger is unreadable`, `the supervisor is not running`, or a health report with `ok:false` and `reasons` |

The body limit is 65536 bytes, the read and write timeout is 5 seconds, and a
stop drains for 6 seconds. A turn that outlasts the drain says so in one line.

## Fluxer

The Fluxer channel answers direct messages only. It connects to the Fluxer
gateway and sends each message piece with one REST call. One worker thread runs
every turn, so a slow turn queues instead of blocking the heartbeat.

1. Create a bot, put its token in `.env` under `FLUXER_BOT_TOKEN`, and add your
   Fluxer user id, not username, to `:allowed-users`:

   ```lisp
   (:fluxer (:enabled t) (:allowed-users ("123456789012345678")))
   ```

2. Start `enchiridion serve --channel fluxer`, send a direct message from an
   allowed account, and run `enchiridion health` to see the channel state.

The allowlist denies by default. A missing, empty or non-list allowlist admits
nobody, and every entry must be a string user id. The channel accepts an event
only when it is a `MESSAGE_CREATE`, the channel type is a one-to-one direct
message, the event has no guild id, the author is not a bot or the agent, and
the author id is on the allowlist. Every other event is dropped.

A reply is cut into pieces of at most 2000 characters, one message per piece.
A 429 retries up to three times. It resumes a session that ended less than 60
seconds ago, and otherwise identifies again. Reconnects stop after five
attempts. Close codes 4002, 4004 and 4012 end the session without a retry, and
the supervisor starts it again one second later.

An accepted direct message carries a marker until its turn finishes: ⏳ while it
waits for the worker, 🔧 while the turn runs, and ⚠️ when the turn fails, when
any piece of the reply cannot be delivered, or when the message is evicted from
the full queue. A delivered reply removes the marker. The markers are the bot's
own reactions, sent by one thread from a queue that coalesces a message's
states, so neither the gateway nor the turn waits on a reaction call.

The queue holds 32 messages, and a message dropped from it is marked ⚠️. A
missing token logs one line per second:
`enchiridion fluxer: no bot token: set FLUXER_BOT_TOKEN, or :token-env in the
:fluxer section.`

### Custom status

The agent can show one short, public line on its Fluxer profile. It is off by
default; turn it on in the `:fluxer` section:

```lisp
(:fluxer
 (:enabled t)
 (:allowed-users ("123456789012345678"))
 (:custom-status t)
 (:custom-status-ttl-seconds 300)
 (:custom-status-cooldown-seconds 60))
```

The agent proposes the text with its `presence` tool, in a field separate from
its reply and from its reasoning. The channel owns the last word: the text is
trimmed, must be one line of at most 128 characters, and is refused if it
contains a control character or anything the secret scrubber would redact.
Proposing the text already showing sends nothing. A different text waits for
the cooldown, 60 seconds by default; `0` disables it. A status is temporary:
the channel clears it after the TTL, 300 seconds by default, and forgets it if
it ends while the channel is disconnected. A status still current is reapplied
after a reconnect. An out-of-range TTL or cooldown falls back to its default.

Only the bot token and the gateway are used. The channel never edits the bot's
bio and never needs an owner credential. The gateway does not acknowledge a
presence update, so the Fluxer client is the only confirmation that a status
rendered.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Start fails with `Configuration is wrong at HTTP-TOKEN` | A non-loopback bind has no token | Set the token, or bind `127.0.0.1` |
| `/message` answers 401 | Missing or wrong bearer token | Send `Authorization: Bearer <token>` |
| `/message` answers 415 | No `Content-Type: application/json` | Set the content type |
| `/message` answers 413 | The body is over 65536 bytes | Send less, or raise `:max-body-bytes` |
| `/message` answers 503 with `Retry-After: 1` | Another turn is running | Retry after one second |
| `/health` answers 503 | A channel the process wants on is failed or stopped, the heartbeat thread is gone, or no supervisor runs | Read `reasons`, then `docker compose logs` |
| Fluxer answers no direct message | The sender is not on the allowlist, or the event is not a direct message | Add the user id; check the channel type |
