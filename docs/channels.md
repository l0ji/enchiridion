# Channels

A channel turns one surface into the one message shape and hands that message to
the agent. The supervisor starts every channel on its own thread and restarts a
channel that stops. Nothing above the channel files learns which surface a turn
came from. A new channel is a new file and not a branch in the kernel. Three
channels ship today: `cli`, `http`, and `fluxer`.

## The message shape

`normalize` builds one `msg` struct. It accepts keyword arguments or one plist.
A caller that holds a plist from a queue and a caller that writes a call site
are both normal.

| Slot | Type | Default | Meaning |
| --- | --- | --- | --- |
| `id` | string | `""` | The channel's own id for this message |
| `channel` | keyword | `:cli` | The surface that received it |
| `target` | string | `""` | Where a reply goes |
| `thread` | string | `""` | A thread id, or empty |
| `author` | string | `""` | Who sent it |
| `text` | string | `""` | The body |
| `ts` | fixnum | `0` | A time value |
| `reply-to` | string | `""` | The message this one answers |

The struct carries no `:documentation` option. A trailing documentation string
would read as a ninth slot, so each slot keeps a comment instead.

`normalize` fills a missing or empty id through `next-message-id`. That function
returns a short name such as `cli-1`, with the channel name and a number. One
counter, `*message-counter*`, numbers every channel, so two channels cannot mint
the same id. A missing or zero timestamp comes from `get-universal-time`. Every
other absent slot keeps the empty string.

```lisp
(normalize :author "sam" :text "hello")
(normalize '(:channel :http :author "webhook" :text "hello"))
```

## Digests

`message-digest` returns one short line for the ledger and the log. The line
names the channel, the author, and the first part of the body. The function
`digest-text` cuts the first line at `+message-digest-length+`, which is 60
characters, and adds an ellipsis when it cut. A full body would bury the next
log line.

```text
cli/sam: hello
```

## The channel class

`channel` is a CLOS class and not a structure, because there is one subclass per
channel. The slot accessor is `channel-state`, and `channel-status` is the
protocol method that asks a channel how it does.

| Slot | Accessor | Default | Meaning |
| --- | --- | --- | --- |
| `name` | `channel-name` | `""` | The name config and the status file use |
| `live-p` | `channel-live-p` | `nil` | True while the channel accepts traffic |
| `state` | `channel-state` | `:stopped` | Where the channel is |
| `thread` | `channel-thread` | `nil` | The thread it runs on, or `nil` |

`define-channel` defines the subclass and its constructor in one step. The
constructor name defaults to `make-<name>` in the package that reads the name.
A subclass declares only the slots it adds, and the constructor still takes the
four base slots.

## The protocol

Four generic functions carry every channel. Each one has a default method, so a
channel that implements nothing says so by name instead of dropping a send.

| Function | Arguments | What it does |
| --- | --- | --- |
| `channel-start` | channel, `:config` | Starts the channel and returns it |
| `channel-stop` | channel | Stops the channel and releases what it holds |
| `channel-send` | channel, target, text, `:reply-to` | Sends text to a target |
| `channel-status` | channel | Returns the state keyword |

The default method calls `unimplemented-channel-operation`. That function
signals a `configuration-error` with the channel name in `:key` and the
operation in `:detail`. The report names the key, so the one line a person reads
carries the channel.

`deliver` is the one function a caller needs for a reply. It calls
`channel-send` with `:reply-to` and returns what that call returns. The caller
does not need to know whether a send is a websocket frame, an HTTP response, or
a line on a terminal.

## Channel states

| State | Set by | Meaning |
| --- | --- | --- |
| `:stopped` | The class default, and every stop method | The channel does no work |
| `:running` | `start-channel` in the supervisor | The channel thread runs |
| `:live` | `channel-start` of `cli`, `http` and `fluxer` | The channel accepts traffic |
| `:failed` | The `fluxer` channel | A refused start, or a spent reconnect budget |

The slot documentation in `protocol.cl` also names `:starting`. No method
assigns that keyword now.

## What the supervisor expects

`start-channel` sets the state to `:running` and runs the channel on a thread
named `enchiridion channel <name>`. `restart-channel-loop` calls
`channel-start` again when that call returns or signals. It sleeps one second
before the next attempt, so a channel that fails at once cannot become a busy
loop. The agent keeps running while one channel restarts, because a channel is
one surface and not the process.

A channel therefore blocks for as long as it is live. A `channel-start` that
returns at once makes the supervisor run it again every second.

`channel-stop` runs at shutdown and on a `channels disable` request. A stop
marks the channel stopped and releases its resources. The supervisor then
destroys the channel thread.

The status file holds one row per channel with the keys `name`, `state`, and
`enabled`. The key `enabled` is true when the configuration enables the channel
or when the serving process runs it.

## The cli channel

The `cli-channel` class adds two slots. The `context` slot holds the command
context the REPL reads, and `output` holds the stream for command output and the
prompt. The function `make-cli-channel` returns a stopped channel over a
context.

| Method | Behavior |
| --- | --- |
| `channel-start` | Runs the REPL to completion |
| `channel-stop` | Marks the channel stopped |
| `channel-send` | Prints the text and returns it |
| `channel-status` | Returns `channel-state` |

A terminal makes this channel real. `channel-start` checks
`interactive-stream-p` on `*standard-input*` before it starts the REPL. Without
a terminal the channel writes one line to `*error-output*` and returns without
running the REPL:

```text
enchiridion: stdin is not a terminal, so the cli channel stays down.
```

That one line matters under `serve` in a container. Under `serve`, a process
with no terminal repeats that line about once per second. The terminal channel
returns at once. The supervisor waits one second, then starts the channel again,
for as long as the process runs.

`channel-send` prints the text on the output stream. A `:reply-to` argument adds
a second line:

```text
hello
  (reply to cli-1)
```

The supervisor owns this channel under `serve` only. The `chat` command runs the
REPL in the foreground itself. The function `build-channels` adds the cli
channel for `serve` and not for `chat`.

## The http channel

The webhook answers three routes and no more. The reply to a turn is the
response body, so this channel implements no `channel-send`. The protocol
default refuses a send from it with a `configuration-error`, which is the right
answer for a surface that has nothing to send to.

| Method | Path | What it does |
| --- | --- | --- |
| POST | `/message` | Runs one turn and returns the reply |
| GET | `/health` | Reports the live supervisor |
| GET | `/usage` | Returns rows from the token ledger |

A request to a known path with the wrong method answers 405 and an `Allow`
header. Any other path answers 404.

`POST /message` needs `Content-Type: application/json`. The body is a JSON
object, and the `text` field must hold a non-empty string after a trim. The
`author` field is optional and defaults to `webhook`. A missing or wrong
content type answers 415, a body that is not a JSON object answers 400, and an
empty `text` answers 400.

| Status | Body |
| --- | --- |
| 200 | A `reply` string and a `usage` object |
| 400 | A bad object, or an empty `text` field |
| 401 | A missing or wrong bearer token |
| 404 | A path with no route |
| 405 | A known path with the wrong method |
| 413 | A body larger than the limit |
| 415 | A content type that is not JSON |
| 502 | A turn that failed |
| 503 | The agent answers another turn, with `Retry-After: 1` |

The `usage` object carries `model`, `input`, `output`, `cache-read`,
`cache-write`, `rounds`, and `total`. The object sums the turn's rows and not
the last completion, because one turn with tools makes several model calls.

`GET /health` reads the live supervisor and not the status file. A file from a
stopped process reports an uptime that grows forever. The answer is 200 with
`ok`, `uptime`, and `channels`, or 503 when no supervisor runs. `GET /usage`
reads the ledger with `?limit=`. The default is 50 rows and the largest accepted
value is 1000.

### Authentication

Every route needs `Authorization: Bearer <token>` when the service holds a
token. A missing header and a wrong token both answer 401. A 403 that means "the
token was right" is an oracle for guessing tokens. The comparison folds every
character and adds the length difference, so it leaks only the length.

A service with no token accepts every caller. `check-http-policy` is what keeps
that case local. It refuses a bind that is not loopback when the service holds
no token, and the refusal is a `configuration-error` with `:key :http-token`.
The check runs before a socket opens, so the process exits 2 instead of serving
the network without a token.

| Bind | Loopback |
| --- | --- |
| The empty string, `localhost`, `::1`, `::ffff:127.0.0.1` | Yes |
| `127.` with a dotted quad of ASCII digits | Yes |
| `0.0.0.0`, `::`, a hostname, or `nil` | No |

The token comes from the `:http` channel entry. `:token-env` names the variable
and defaults to `ENCHIRIDION_HTTP_TOKEN`. The code accepts a literal `:token`
value for a loopback bind and for tests. Every token goes through the secret
loader, so the scrubber knows the value.

### Limits and timeouts

| Limit | Default | Source |
| --- | --- | --- |
| Body size | 65536 bytes | `+http-body-limit+`, overridden by `:max-body-bytes` |
| Read and write timeout | 5 seconds | `+http-read-timeout+` |
| Handler threads | 8 | The taskmaster |
| Waiting connections | 16 | The taskmaster |
| Stop drain | 30 seconds | `+http-drain-seconds+` |

The code checks the declared `Content-Length` before it reads one byte, because
the server allocates what the header claims. A chunked body declares nothing, so
the code counts bytes as they arrive. A body over the limit answers 413. A body
that is not UTF-8 answers 400.

`channel-stop` stops the acceptor and waits for the turns in flight. The wait
covers a turn that already read its body and now waits on a model. Hunchentoot
counts only the request inside its handler. A turn that outlasts the drain
prints one line and may miss its ledger row.

### Routes and the service

The service is a value, not the server. `http-service` holds `turn`, `health`,
`usage`, `token`, `bind`, `port`, `body-limit`, and the in-flight counter. The
default bind is `127.0.0.1` and the default port is 8787. The function
`make-http-service` trims the bind and the token, because a person edited the
configuration file.

A route needs three functions and nothing else. `turn` runs one message,
`health` reports the process, and `usage` reads the ledger. That is what keeps
the channel above the kernel. The function `handle-http-request` returns a
status and a body, so the whole routing table is testable without a socket.

## The fluxer channel

The `fluxer` channel answers direct messages only. It reaches the gateway over a
websocket, and it sends replies over REST. One worker thread runs every turn, so
a slow turn queues instead of starving the socket.

### The gateway

The channel discovers the gateway with `GET /gateway/bot` under
`https://api.fluxer.app/v1`. The request carries `Authorization: Bot <token>`.
The channel appends `?v=1&encoding=json` to the advertised URL when that URL
carries no query string. The scheme stays as advertised, because a self-hosted
deployment may advertise `ws://`.

| Opcode | Name | Meaning |
| --- | --- | --- |
| 0 | Dispatch | An event, such as `READY` or `MESSAGE_CREATE` |
| 1 | Heartbeat | The client reports its last processed sequence |
| 2 | Identify | The first frame after Hello |
| 6 | Resume | Rejoins a session the gateway still holds |
| 7 | Reconnect | The gateway asks for a reconnect |
| 9 | Invalid session | The session is gone |
| 10 | Hello | Names the heartbeat interval |
| 11 | Heartbeat ack | Confirms a heartbeat |

Identify carries the token and a properties object with `os`, `browser`, and
`device`. The gateway closes the socket with 4002 when the properties object is
missing. The frame carries no intents field and no shard field, because direct
messages are account scoped.

The heartbeat interval comes from Hello, in milliseconds. The default is 41250.
A heartbeat reports the last processed sequence and not the last seen one. A
replayed dispatch is not reported twice. Send a resume frame only inside the 60
second window `+resume-window-seconds+` names. Send it with a session id the
gateway gave.

`READY` says who the agent is and which session the socket belongs to. That
identity is what the echo guard compares against.

### Direct messages and the allowlist

One `MESSAGE_CREATE` dispatch becomes a message when four rules all hold. The
event is a direct message, which means `channel_type` is 1. The event carries no
guild id. The author is not a bot, because two bots that answer each other make
a loop. The author is not the agent itself. The channel drops every other
event.

The allowlist is the `:allowed-users` key of the `:fluxer` entry. The list holds
user ids. The function `allowed-p` denies by default in four ways. A `nil` or
empty list admits nobody. The function refuses a missing or non-string id, and a
non-string entry cannot match. A non-list value is no allowlist at all.

The comparison is against a user id and never a username, because a username is
a string its owner can change.

A refusal writes one log line and sends no answer, because an answer is a reply
to whoever asked. A sender the allowlist does not name signals `unauthorized`,
and the channel logs that condition.

The token comes from the loaded secret first and from the environment second.
`:token-env` names the variable and defaults to `FLUXER_BOT_TOKEN`. A missing
token and a missing turn function each write one line and set the state to
`:failed`. Neither signals, because a mis-set variable must not take the
supervisor down.

### Queues, replies, and reconnects

| Limit | Value | Source |
| --- | --- | --- |
| Queued messages | 32 | `+max-pending-messages+` |
| Reply piece | 2000 characters | `+message-limit+` |
| Reconnect attempts | 5 | `+max-reconnect-attempts+` |
| Backoff | 1 to 60 seconds | `+reconnect-base-seconds+`, `+reconnect-max-seconds+` |
| Worker join | 5 seconds | `+stop-join-seconds+` |

The read thread parses a frame, notes what the channel needs, and hands a
payload to the worker. It never runs a turn and never waits, because a read
thread inside a model call stops the heartbeats. The queue has a bound. A full
queue drops the oldest waiting message and counts the drop.

`channel-send` scrubs the text and cuts it into pieces at 2000 characters. The
cut lands on whitespace when it can, so a reply keeps its line breaks. Each
piece goes to `POST /channels/<channel-id>/messages` with a body of one
`content` field. The return value is the list of message ids the gateway
accepted. A 429 repeats after the wait its own body names, up to three times.

`channel-start` blocks while the channel is live. It reconnects after a close
with an increasing backoff, and it resumes inside the resume window. A close
code of 4002, 4004, or 4012 is fatal, and the channel stops retrying. After five
failed attempts it writes one line and sets the state to `:failed`, which lets
the supervisor try again one second later.

## Related

- [Supervisor and heartbeat](supervisor.md)
- [Configuration](configuration.md)
- [Commands](commands.md)
- [Models and secrets](llm.md)
- [Deployment](deployment.md)
