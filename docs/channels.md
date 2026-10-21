# Channels

A channel is a surface that receives outside traffic and returns replies to it.
Every channel normalizes inbound traffic into one message structure and is driven by four generic functions.
The kernel therefore answers a turn without learning which surface delivered it.
Three channels ship: the terminal, the HTTP (Hypertext Transfer Protocol) webhook, and Fluxer.

## The message

One structure carries every inbound message, and one function fills it.
A channel sets the fields it knows, and the normalizer supplies the rest.

| Slot       | Type    | Default | Contents                                                  |
| ---------- | ------- | ------- | --------------------------------------------------------- |
| `id`       | string  | `""`    | The channel's own identifier for the message              |
| `channel`  | keyword | `:cli`  | The surface that delivered the message                    |
| `target`   | string  | `""`    | Where the reply goes                                      |
| `thread`   | string  | `""`    | A thread identifier, empty when the conversation has none |
| `author`   | string  | `""`    | The sender                                                |
| `text`     | string  | `""`    | The body                                                  |
| `ts`       | fixnum  | `0`     | A Unix time, filled when the message is normalized        |
| `reply-to` | string  | `""`    | The message this one answers                              |

`normalize` accepts one property list or keyword arguments, and both spellings reach the same slots.

```lisp
(enchiridion.channel:normalize '(:channel :http :author "sama" :text "List the open ports."))
(enchiridion.channel:normalize :channel :http :author "sama" :text "List the open ports.")
```

A missing, empty, or non-string `id` is minted as `<channel>-<n>`, for example `cli-1`, from one counter shared by every channel.
A missing or zero `ts` comes from `get-universal-time`.
Every other absent slot keeps its default.

`message-digest` returns one line for a log or a ledger row: the lower-case channel, `/`, the author, `: `, and the first line of the body.
`digest-text` cuts that line at 60 characters and appends an ellipsis when it cut.

## The channel protocol

`channel` is a Common Lisp Object System (CLOS) class.
Each shipped channel is one subclass, and a subclass declares only the slots it adds.

| Slot     | Accessor         | Default    | Contents                                       |
| -------- | ---------------- | ---------- | ---------------------------------------------- |
| `name`   | `channel-name`   | `""`       | The name configuration and the status file use |
| `live-p` | `channel-live-p` | `nil`      | True while the channel accepts traffic         |
| `state`  | `channel-state`  | `:stopped` | Where the channel is                           |
| `thread` | `channel-thread` | `nil`      | The thread the supervisor runs it on, or `nil` |

The slot documents four state keywords, and the supervisor uses a fifth.

| Keyword     | Set by                                      | Meaning                                                    |
| ----------- | ------------------------------------------- | ---------------------------------------------------------- |
| `:stopped`  | The class default and every stop            | The channel does no work                                   |
| `:starting` | Nothing in the shipped channels             | The start is in progress                                   |
| `:live`     | A channel start                             | The channel accepts traffic                                |
| `:failed`   | A refused start or a spent reconnect budget | The channel gave up, and the supervisor may start it again |
| `:running`  | `start-channel` in the supervisor           | The supervisor owns a thread for the channel               |

Four generic functions carry every channel.
Each has a default method, so a channel that implements nothing refuses by name instead of dropping traffic.

| Function         | Arguments                                    | Returns                                     |
| ---------------- | -------------------------------------------- | ------------------------------------------- |
| `channel-start`  | `channel`, `&key config`                     | The channel, after it stops                 |
| `channel-stop`   | `channel`                                    | The channel                                 |
| `channel-send`   | `channel`, `target`, `text`, `&key reply-to` | What the surface returns for a sent message |
| `channel-status` | `channel`                                    | The state keyword                           |

A default method signals a `configuration-error` whose key is the channel name, and its detail reads `<class> does not implement <operation>.`
The report reads `Configuration is wrong at <name>.`
A surface with nothing to send to, such as the webhook, leaves `channel-send` unimplemented and inherits that refusal.

`deliver` sends text to a target through a channel, passes `:reply-to`, and returns what `channel-send` returns.
`channel-start` blocks until the channel stops and returns it, and `channel-stop` returns the channel.
`channel-send` returns what the surface returns, and `channel-status` returns the state keyword.
`define-channel` defines a subclass and a constructor in one form.

```lisp
(enchiridion.channel:define-channel relay)
```

The form defines the class `relay` and the constructor `make-relay`, whose arguments are `:name`, `:live-p`, `:state`, and `:thread`.
`:name` defaults to the lower-case class name.
A channel that adds slots uses `defclass` directly.

## How a channel starts and restarts

The supervisor owns one thread per channel and restarts a channel that returns or signals.
`channel-start` blocks while the channel is live, and `channel-stop` must make that call return.

The process builds a channel when the configuration enables it, or when a `--channel` flag names it.
The terminal channel is built under `serve` only.
`chat` runs the REPL in its foreground instead.
A channel start that returns at once makes the supervisor call it again one second later.
A start that signals is logged as `enchiridion: channel <name> stopped: <condition>` and restarted the same way.
A stop destroys the channel thread, and one surface restarting does not stop the process.

### Channel selection flags

The command line selects a channel for one process.
The flags belong to the supervisor commands, `chat` and `serve`, and a flag with no command runs `serve`.

| Flag          | Value              | Effect                                                        |
| ------------- | ------------------ | ------------------------------------------------------------- |
| `--channel`   | `cli`, `http`, or `fluxer` | Build the named channel; `cli` adds nothing because `serve` builds it |
| `--bind`      | An address         | The webhook bind, as the `:http` entry would set it           |
| `--port`      | A number           | The webhook port, as the `:http` entry would set it           |
| `--token-env` | A variable name    | The webhook token variable, as the `:http` entry would set it |

`--bind`, `--port`, and `--token-env` are accepted only with `--channel http`.
`--channel cli` passes validation, and `serve` builds the terminal channel regardless.
A flag without a value is refused with `The --<flag> flag needs a value.`
An unknown channel is refused with `There is no channel called <name>. The channels are cli, http and fluxer.`
A port outside 1 to 65535 is refused with `The port must be a number between 1 and 65535, not <value>.`
Each refusal is exit status 2 and starts nothing.

## The terminal channel

The terminal channel, `cli-channel`, runs the read-eval-print loop (REPL) as its start.
It adds `context`, the command context the REPL reads, and `output`, the stream for command output and the prompt.
`make-cli-channel` returns a stopped channel, and `start-cli` creates one and starts it.
`channel-start` runs the REPL to completion and returns the channel.
`channel-stop` clears the live flag and sets `:stopped`.
`channel-send` prints the text and returns it, and `channel-status` returns the state keyword.

`channel-start` checks `interactive-stream-p` on `*standard-input*` first.
Without one it writes one line to the error stream, sets `:stopped`, and returns without running the REPL.

```text
enchiridion: stdin is not a terminal, so the cli channel stays down.
```

Under `serve` without a terminal the supervisor starts the channel again after one second, so the line repeats for the life of the process.
A send prints the text and a newline, and a `reply-to` adds an indented `(reply to <id>)` line.

Start a session with `enchiridion chat`.
The prompt is `enchiridion> `.
A line that begins with a slash is a command, and a line that does not is one turn.
A bare word that names a command prints `Commands start with a slash: try` followed by its slash form and costs no turn.
The REPL adds `/stop`, `/quit`, and `/who`.
`Ctrl-C` aborts the current line or turn and prints `interrupted.`, while `SIGTERM` and `SIGHUP` end the process.
`/quit` and end of input end the REPL.
The command list belongs to [Commands](commands.md).

## The HTTP webhook

The webhook turns one request into one turn and one response body into the reply.
It therefore implements no `channel-send`, and a send through it is refused by the protocol default.
It has three routes, binds to loopback by default, and refuses a reachable bind that carries no token before it opens a socket.

The service is a value.
It holds the turn function, the health function, the ledger reader, the token, the bind, the port, the body limit, and the in-flight turn count.
`make-http-service` trims the bind and the token, and an empty bind becomes `127.0.0.1`.
A route runs without a socket, and a test builds a request value instead of a client.

1. Choose a bind and port.
   The defaults are `127.0.0.1` and `8787`.
2. Choose the token variable.
   Its default is `ENCHIRIDION_HTTP_TOKEN`, and a bind that is not loopback requires a token.
3. Start the supervisor and send one message.

   ```sh
   export ENCHIRIDION_HTTP_TOKEN="$(openssl rand -hex 32)"
   enchiridion serve --channel http --bind 0.0.0.0 --port 8787
   ```

   ```sh
   curl -sS -X POST http://127.0.0.1:8787/message \
     -H 'Content-Type: application/json' \
     -H "Authorization: Bearer $ENCHIRIDION_HTTP_TOKEN" \
     -d '{"text":"List the open ports.","author":"sama"}'
   ```

The request body is a JSON (JavaScript Object Notation) object with a non-empty `text` field, trimmed, and an optional `author` field that defaults to `webhook`.
A successful message answers with a reply and the usage of the turn.

Authentication comes before the body read.
A missing or wrong token answers 401 with `WWW-Authenticate: Bearer`, and the body is never read.
Only the `Bearer` scheme is accepted, and the comparison folds every character and adds the length difference, so it leaks only the length.
A service with no token accepts every caller, and the policy check keeps that case on loopback.
A bind that is not loopback with no token makes `channel-start` signal a `configuration-error` with `:key :http-token` and the detail below.
The process also accepts a literal `:token` value for a test or for a service whose token is written in the configuration.
It registers the value with the scrubber.

```text
A webhook bound to <bind> answers the network, so it needs a token. Set the variable the :http channel names, or bind 127.0.0.1.
```

The policy check runs before a socket opens, so a bad bind on the command line is one line and exit status 2.
The channel checks again before starting the acceptor.
`start-http` blocks until `stop-http` stops it, and `http-running-p` reports whether the channel is live.

The declared `Content-Length` is checked before one byte is read, and a chunked body is counted as it arrives.
A body over the limit answers 413, and a body that is not UTF-8 answers 400.
`POST /message` requires a JSON content type, so a missing or wrong `Content-Type` answers 415.
A stop closes the listener and waits up to 30 seconds for handlers and turns in flight.
The supervisor closes the store as soon as the stop returns.
A turn that outlasts the drain writes one line on the error stream.

```text
enchiridion: a webhook turn outlasted the 30 second drain; it may not reach the ledger.
```

## Fluxer

The Fluxer channel answers direct messages only.
It receives events on a WebSocket connection to the Fluxer gateway and sends each reply as one REST (Representational State Transfer) call.
One worker thread runs every turn, so a slow turn queues instead of starving the heartbeat socket.

It answers a `MESSAGE_CREATE` event only when four conditions hold.
The channel type is a direct message, and the event carries no guild identifier.
The author is not a bot, and the author is not the agent itself.
Every other event is dropped.

The allowlist denies by default.
A missing, empty, or non-list allowlist admits nobody, and a missing or non-string sender identifier is refused.
It holds user identifiers, never usernames, because a username can change.

1. Register a bot and obtain its token, or obtain one from the operator.
2. Put the token where the loader finds it, under the name the `:fluxer` entry names.
3. Add the operator's Fluxer user identifier to `:allowed-users` in the `:fluxer` entry.
4. Start the supervisor, send a direct message from an allowed account, and read the state with `enchiridion health`.

   ```sh
   enchiridion serve --channel fluxer
   ```

The default name is `FLUXER_BOT_TOKEN`.
[Large language model backends](llm.md) documents the loader, and [Configuration](configuration.md) documents the entry.

A missing token and a missing turn function each write one line and set `:failed` without signaling.
A mis-set variable does not stop the supervisor.
The channel asks the loaded secret first and the environment second, and registers an environment token with the scrubber.

```text
enchiridion fluxer: no bot token: set FLUXER_BOT_TOKEN, or :token-env in the :fluxer section.
enchiridion fluxer: no turn function is injected, so there is nothing to answer with.
```

The channel discovers the gateway with `GET /gateway/bot` under `https://api.fluxer.app/v1`, with `Authorization: Bot <token>`.
The advertised WebSocket URL keeps its scheme and gains `?v=1&encoding=json` when it carries no query string.

After the handshake it waits up to ten seconds for `Hello`, which names the heartbeat interval in milliseconds.
A session that ended within 60 seconds is resumed, and a later one identifies again.
The Identify frame carries the token and a properties object, and the gateway closes with 4002 without it.
The frame carries no intents or shard field, because direct messages are account scoped.
A heartbeat reports the last processed dispatch sequence, and the first beat waits a random part of one interval.

Reconnects are counted and backed off from one second, doubling to 60 seconds, and `READY` resets the count.
After five reconnects, or a close code of 4002, 4004, or 4012, the loop ends with `:failed` and one line.
The supervisor starts the channel again one second later.

The read thread parses frames and hands payloads to the worker without running a turn.
The queue holds 32 messages and drops the oldest when full, and it counts the drop.

A reply is scrubbed and cut into pieces of at most 2000 characters on whitespace.
Each piece is posted to `POST /channels/<channel-id>/messages` with a body of one `content` field, and the channel returns the accepted message identifiers.
A long reply becomes several messages.
An empty reply sends nothing, and a 429 repeats after the wait its body names, up to three times.

A send through a channel that never started signals `configuration-error` with `:key "fluxer"` and detail `the channel is not started, so there is no token to send with.`
`start-fluxer` blocks while the channel runs, `stop-fluxer` stops it, and `fluxer-running-p` reports whether it is live.

## Adding a channel

A channel is a class and four methods.
Follow the shipped files for the surface the new channel resembles.

1. Define a subclass of `enchiridion.channel:channel`, or call `define-channel` when it adds no slots.
2. Implement `channel-start`, `channel-stop`, `channel-send`, and `channel-status`.
3. Give the class a constructor with a fixed `:name`.
4. Add the constructor to `build-channels` in `src/main.cl`.
5. Add the name to the `--channel` list in `validate-options` when the channel takes flags.
6. Inject functions rather than live objects, so a test needs no socket.

`channel-start` validates the configuration, opens the surface, sets `channel-live-p` and `:live`, and blocks until the channel stops.
`channel-stop` closes the surface, clears the live flag, and sets `:stopped`.
`channel-send` sends the text and returns the surface's result, or is left out when the surface has nothing to send to.
`channel-status` returns `channel-state`.

## Reference

### The shipped channels

| Name     | Class            | Configuration entry         | Start behavior                                            |
| -------- | ---------------- | --------------------------- | --------------------------------------------------------- |
| `cli`    | `cli-channel`    | Not read, built for `serve` | Runs the REPL to completion, and needs a terminal         |
| `http`   | `http-channel`   | `:channels :http`           | Starts the acceptor and blocks until the channel stops    |
| `fluxer` | `fluxer-channel` | `:channels :fluxer`         | Runs a gateway session and blocks until the channel stops |

### HTTP routes

| Method | Path       | Success | Runs                                           |
| ------ | ---------- | ------- | ---------------------------------------------- |
| POST   | `/message` | 200     | One synchronous turn                           |
| GET    | `/health`  | 200     | The live process, its uptime, and its channels |
| GET    | `/usage`   | 200     | Ledger rows, newest last, at most `?limit=`    |

A known path with the wrong method answers 405 and an `Allow` header naming the method it takes.
Any other path answers 404.

### HTTP statuses

| Status | Cause                                                                                                        |
| ------ | ------------------------------------------------------------------------------------------------------------ |
| 200    | Success                                                                                                      |
| 400    | A body that is not JSON, not a JSON object, not UTF-8, or has empty `text`                                   |
| 401    | A missing or wrong bearer token                                                                              |
| 404    | A path with no route                                                                                         |
| 405    | A known path with the wrong method                                                                           |
| 413    | A body larger than the limit                                                                                 |
| 415    | `POST /message` without a JSON content type                                                                  |
| 500    | A condition the webhook did not catch                                                                        |
| 502    | A turn that failed, or a webhook with no turn function attached                                              |
| 503    | A turn in flight with `Retry-After: 1`, a health reader with no supervisor, or a ledger reader with no store or an unreadable ledger |

### HTTP error strings

| Status | Error text                               |
| ------ | ---------------------------------------- |
| 400    | `The body is not UTF-8 text.`            |
| 400    | `The body is not JSON.`                  |
| 400    | `The body must be a JSON object.`        |
| 400    | `The body needs a non-empty text field.` |
| 401    | `A bearer token is required.`            |
| 404    | `There is no route <path>.`              |
| 405    | `<path> takes <METHOD>.`                 |
| 413    | `The body is larger than <limit> bytes.` |
| 415    | `POST /message needs a JSON body.`       |
| 500    | `the webhook failed to answer.`          |
| 502    | `the turn failed.`                       |
| 502    | `no agent is attached to this webhook.`  |
| 503    | `the agent is answering another turn.`   |
| 503    | `the supervisor is not running`          |
| 503    | `no memory store is open`                |
| 503    | `the ledger is unreadable`               |

### HTTP response bodies

`POST /message` answers `reply` and a `usage` object with `model`, `input`, `output`, `cache-read`, `cache-write`, `rounds`, and `total`.
The usage sums every model call of the turn, so `rounds` counts the calls.

`GET /health` answers `ok`, `uptime` in seconds, and `channels` rows of `name`, `state`, and `enabled`, from the live process and never from the status file.
`GET /usage` answers `count` and `rows` of `id`, `session`, `model`, `input`, `output`, `cache-read`, `cache-write`, `channel`, and `ts`.
A non-positive or non-numeric limit is the default, and a limit above 1000 is 1000.
An error body holds an `error` string.
On every route but `/usage` it also holds `ok` false.

### HTTP limits

HTTP limits are a `127.0.0.1` bind and port `8787`, overridden by the `:http` entry.
The body limit is 65536 bytes (`+http-body-limit+`, overridden by `:max-body-bytes`), and the read and write timeout is 5 seconds (`+http-read-timeout+`).
The acceptor allows 8 handler threads and 16 waiting connections, and a stop drains for 30 seconds (`+http-drain-seconds+`).
Usage returns 50 rows (`+http-usage-limit+`, at most `+http-max-usage-limit+`).

### Loopback binds

A loopback bind is the empty string, `localhost`, `::1`, `::ffff:127.0.0.1`, or a `127.` address with exactly three dots and ASCII digits.
`0.0.0.0`, `::`, another hostname, and `nil` are not loopback.

### Fluxer protocol

Gateway opcodes are 0 dispatch, 1 heartbeat, 2 identify, 6 resume, 7 reconnect, 9 invalid session, 10 hello, and 11 heartbeat acknowledgement.

Fluxer limits are 2000 characters per message (`+message-limit+`), 32 queued messages (`+max-pending-messages+`), and 5 reconnect attempts (`+max-reconnect-attempts+`).
The reconnect backoff runs from 1 to 60 seconds (`+reconnect-base-seconds+`, `+reconnect-max-seconds+`), and the resume window is 60 seconds (`+resume-window-seconds+`).
The identify wait is 10 seconds (`+identify-wait-seconds+`).
The REST timeout is 15 seconds (`+http-timeout-seconds+`), and rate-limit retries are 3 (`+rate-limit-attempts+`).
The worker join is 5 seconds (`+stop-join-seconds+`), and the default heartbeat before `Hello` is 41250 ms (`+default-heartbeat-interval+`).

Close code notes are 1000 normal closure, 1001 going away, 1006 abnormal closure, 4000 unknown error, and 4001 unknown opcode.
Four-thousand codes read 4002 decode error, 4003 not authenticated, 4004 authentication failed, 4005 already authenticated, 4007 invalid sequence, 4008 rate limited, and 4009 heartbeat timeout.
The remaining codes are 4010 invalid shard, 4011 sharding required, 4012 invalid API version, 4013 invalid intents, and 4014 disallowed intents.
Codes 4002, 4004, and 4012 are fatal and not retried.
Every other code is retried.

## Troubleshooting

| Symptom                                                  | Cause                                                                  | Fix                                                    |
| -------------------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------ |
| Start fails with `Configuration is wrong at HTTP-TOKEN.` | A bind that is not loopback, and no token                              | Set the token variable, or bind `127.0.0.1`            |
| `POST /message` answers 401                              | A missing or wrong bearer token                                        | Send `Authorization: Bearer <token>`                   |
| `POST /message` answers 415                              | A missing `Content-Type: application/json`                             | Set the content type                                   |
| `POST /message` answers 413                              | The body exceeds the limit                                             | Send less than 65536 bytes, or raise `:max-body-bytes` |
| `POST /message` answers 503 with `Retry-After: 1`        | The agent is answering another turn                                    | Send the message again after one second                |
| `GET /health` answers 503                                | No supervisor runs in the process that serves the route                | Start the webhook under `serve`                        |
| The terminal channel stays down                          | `stdin` is not a terminal                                              | Run `enchiridion chat` in a terminal                   |
| Fluxer sets `:failed` with `no bot token`                | The token variable is unset, or the secret file is unreadable          | Set the variable the `:token-env` names                |
| Fluxer answers no direct message                         | The sender is not on `:allowed-users`, or the event is a guild message | Add the user identifier to the allowlist               |
| A channel restarts every second                          | `channel-start` returned instead of blocking                           | Make the start block until `channel-stop`              |

## See also

- [Configuration](configuration.md) for the `:channels` entries, the token variable names, and the bind and port keys.
- [Supervisor and heartbeat](supervisor.md) for the process that starts a channel on a thread and restarts it.
- [Commands](commands.md) for `chat`, `serve`, `channels`, and `health`.
- [Large language model backends](llm.md) for the loader that registers a channel token with the scrubber.
- [Deployment](deployment.md) for the container that runs the supervisor without a terminal.
