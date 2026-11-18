# Commands

Run `enchiridion help` for the command list and `enchiridion help COMMAND` for
one command's arguments. The `chat` REPL accepts the same commands with a slash.
The shell adds `chat` and `serve`; the REPL adds `/stop`, `/quit` and `/who`.

## Running commands

The examples use an installed `enchiridion`. From a checkout, put the program
after `nix run .#enchiridion --`, as in
`nix run .#enchiridion -- ask "Which port does the webhook use?"`.

In the Compose container, the first `enchiridion` is the service and the second
is the program. A command that loads `config.lsp` needs the path, because the
entrypoint exports `ENCHIRIDION_CONFIG` only into the main process:

```sh
docker compose exec -e ENCHIRIDION_CONFIG=/etc/enchiridion/config.lsp \
  enchiridion enchiridion health
```

`health` reads only the status file. The same prefix runs `tasks`, `usage` and
`memory`.

## Exit statuses

| Status | Meaning |
| --- | --- |
| 0 | The command completed |
| 1 | The command refused its situation, a turn failed, or a build failed |
| 2 | Unknown name, wrong argument count, bad flag, or refused configuration |
| 130 | A signal stopped the process |

An unknown name prints ``There is no command called NAME. Try `help`.`` A
wrong argument count prints `COMMAND takes ARGUMENTS; got N.`.

## Flags

| Flag | Value | Effect |
| --- | --- | --- |
| `--channel NAME` | `cli`, `http` or `fluxer` | Start `http` or `fluxer`; `serve` already builds `cli` |
| `--bind ADDRESS` | An address | Webhook bind address |
| `--port NUMBER` | 1 to 65535 | Webhook port |
| `--token-env NAME` | A variable name | Variable holding the webhook token |

The flags belong to `chat` and `serve` and may come before or after the command.
`--bind`, `--port` and `--token-env` require `--channel http`. A valid flag
before another command is accepted and has no effect, and a flag never writes
`config.lsp`. A refused value for one of these flags prints one `enchiridion: `
line and exits 2. A flag with no command runs `serve` once the agent is seeded;
before that it writes the seed files.

## Command table

| Command | Arguments | Use |
| --- | --- | --- |
| `init` | 0 or 1 | Create the agent directory and seed files |
| `ask` | 1 or more | One turn in a short-lived session |
| `check` | none | Compile every system file and the three entry scripts; requires Nix and a checkout |
| `skills` | `list`, `show N` | List or show skills |
| `tools` | `list`, `show NAME` | List or show tools |
| `blocks` | `show`, `edit N` | Memory blocks with counts and limits |
| `persona` | `show`, `edit` | `SOUL.md` |
| `operator` | `show`, `edit` | `OPERATOR.md` |
| `world` | `show`, `edit` | `WORLD.md` |
| `memory` | a query or an action | Search memory or [manage the episodic log](episodic-memory.md#commands) |
| `sessions` | none | Stored sessions with turn counts |
| `journey` | `list`, `show REV`, `edit REV`, `rm REV` | The agent directory's history |
| `undo` | exactly 1 | Roll back the nth change in the agent directory |
| `usage` | none | Token ledger by model, channel and day |
| `budget` | none | Configured caps and whether each window is spent |
| `tasks` | `list [STATUS]`, `add TEXT`, `rm ID` | The background task queue |
| `secrets` | none | Loaded names and sources, never values |
| `providers` | `list`, `show ID`, `models ID`, `refresh` | Provider rows, models, or a catalog refresh |
| `version` | none | Version and build provenance |
| `help` | 0 or 1 | The command list, or one command's details |
| `bootstrap` | `status`, `run`, `step N`, `reset` | Bootstrap state and steps |
| `doctor` | none | Check local dependencies and the broker |
| `health` | none | Read the running supervisor's status |
| `reload` | none | Ask the supervisor to reload its code |
| `channels` | `list`, `enable NAME`, `replace NAME`, `disable NAME` | Manage supervised channels |
| `heartbeat` | `on`, `off`, `run` | Manage the sleep schedule |
| `chat` | none | Start the REPL |
| `serve` | none | Start the supervisor and its channels |

An absent action takes the default: `list` for `skills`, `tools`, `channels`,
`journey` and `tasks`; `show` for `blocks`, `persona`, `operator` and `world`;
`status` for `bootstrap`; `on` for `heartbeat`.

## Common tasks

First run:

```sh
cp config.example.lsp config.lsp
cp .env.example .env && chmod 600 .env
enchiridion init
enchiridion chat
```

Uncomment one provider key in `.env` before `chat`. `init` keeps an existing
seed file and prints `created`, `kept` or `problem` for each. Edit `SOUL.md`,
`OPERATOR.md` and `WORLD.md` before chatting.

```sh
enchiridion ask "Which port does the webhook use?"
enchiridion tasks add "Review the open issues"
enchiridion tasks list pending
enchiridion tasks rm 3
```

The reply goes to standard output; progress goes to standard error. `usage` and
`budget` report spend, and the caps bound background work, not chat.

`memory QUERY` searches the transcript. `journey` revisions are 1-based
positions or revision strings. `providers models` and `refresh` reach the
network even with `:offline`. [Episodic memory](episodic-memory.md) and [Large
language model backends](llm.md) cover the details.

### bootstrap

```sh
enchiridion bootstrap status
enchiridion bootstrap step 1
```

`bootstrap reset` restores `BOOTSTRAP.md` from `BOOTSTRAP.done.md` when the live
file is absent. If a session cannot record a step, rename the file by hand:
`mv agents/default/BOOTSTRAP.md agents/default/BOOTSTRAP.done.md`. The state
machine belongs to [Memory](memory.md#the-bootstrap).

## The live supervisor

`health` reads `run/enchiridion.status`. `reload`, `channels` and `heartbeat`
send a request and wait up to five seconds. Without a live supervisor they print
one line and exit 1.

```sh
enchiridion health
enchiridion reload
enchiridion channels list
enchiridion heartbeat run
```

After five seconds the command exits 1 if no answer has arrived. The request
may still run. Check `health` for the latest result.

`health` reports channels, heartbeat and status-file writes. A refused `reload`
keeps the previous generation. If a replacement cannot start beside the old
channel, `channels replace NAME` stops the old one and retries. If that fails,
it attempts to restore the old channel.
[Deployment](deployment.md#supervisor-and-schedule) covers the schedule and the queue.

## The REPL

`chat` starts the REPL with the prompt `enchiridion> `.

| Line | Behavior |
| --- | --- |
| `/help` | The command list in slash form, with `/stop`, `/quit` and `/who` |
| `/stop` | Ask the turn in flight to stop |
| `/quit` | Leave the session |
| `/who` | Print the attached channel and the supervisor state |
| `/NAME ARGS` | Run the command table row `NAME` |
| any other line | Send the line to the agent as one turn |

An empty line does nothing, and end of input leaves. A single word that names a
REPL command prints the command's slash form and sends no turn, as in
``Commands start with a slash: try `/help`.`` Two or more words are always a
turn. Ctrl-C aborts the line or the turn,
prints `interrupted.`, and returns to the prompt.

## Identity files

In a container, the seed files live on the named volume. After
`docker compose run --rm enchiridion init`, create the stopped service container
if it does not exist yet:

```sh
docker compose create enchiridion
```

Then copy each file out, edit it, and copy it back:

```sh
for file in SOUL.md OPERATOR.md WORLD.md; do
  docker cp "enchiridion:/var/lib/enchiridion/agents/default/$file" .
  ${EDITOR:-vi} "$file"
  docker cp "$file" "enchiridion:/var/lib/enchiridion/agents/default/$file"
done
```

`docker cp` works on a stopped container and keeps the host uid on the copy. The
entrypoint runs `chown -R` at the next start, so no manual `chown` is needed.
Start with `docker compose up -d`. Outside a container, the files are under
`agents/default/` beside `config.lsp`.

`enchiridion --verify-plugin DIRECTORY` verifies the files under `skills/` and
`tools/`, and exits 1 on a compile error, a warning or a failing self-test.
[Plugins and self-modification](plugins.md) covers the manifest.
