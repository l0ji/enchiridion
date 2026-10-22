# Getting started

The procedure below builds the harness from a checkout, writes the agent directory, and starts the first conversation.
A reader who completes it has a working agent directory, a provider credential, and a session that answers.

## How the pieces fit

The checkout holds the source, the Nix flake, `config.cl`, and `.env`.
The agent directory holds one agent's files, memory, and history.
Its location is `<home>/agents/default/`, where `<home>` is the current directory or `ENCHIRIDION_HOME`.
The supervisor process holds the model client, the secrets, the store, and the channels.
Agent code runs in a child process.
In the container it runs under a separate uid. A checkout has no uid split, so the supervisor, the broker child, and agent code run as the operator's user (see [Deployment](deployment.md)).
`chat` and `serve` start a supervisor, and inspection commands do not.
The first launch writes the seed files and stops.

> **Warning:** A checkout has no uid split.
> The checkout `.env` stays on disk, and agent code runs as the same user, so its file and shell tools can read the key.
> Use the container when the key must stay out of the agent's reach.

## Requirements

- Nix with flakes enabled. The flake supplies the Lisp implementation and every library.
- A host on `x86_64-linux`, `aarch64-linux`, or `aarch64-darwin`.
- Git, for the history of the agent directory. The harness writes the files without Git and skips only the commit.
- A provider credential. Without `config.cl`, the shipped default selects OpenAI and reads `OPENAI_API_KEY` (see [Large language model backends](llm.md)).
- A terminal, for the terminal channel.

## Obtain the source

Place a checkout of the repository on the local disk.
Run every command in this chapter from the checkout root, which holds `enchiridion.asd` and `flake.nix`.

## Build and test

1. Compile every file and the two entry scripts:

   ```sh
   nix run .#check
   ```

2. Run the unit suite and the property suite:

   ```sh
   nix run .#test
   ```

`nix run .#check` prints `enchiridion-check passed.` and exits 0 on success.
`nix run .#test` prints `enchiridion-test passed.` and exits 0 on success.
A compile error stops either gate with a non-zero status.
The `check` command in the program runs the same gate in the checkout (see [Commands](commands.md#check)).

The development shell supplies a Lisp REPL and a source run.
The heavier shell adds the C toolchain and the container workflow.

```sh
nix develop          # the development shell
nix develop .#full   # the heavier shell
```

## Perform the first launch

The first launch writes the agent directory and exits.
It starts no supervisor.

1. Run the program with no command and no flags:

   ```sh
   nix run .#enchiridion
   ```

2. Read the printed path and the file list.
   The path is absolute.

The output names every seed file it wrote:

```text
No agent directory found. Creating /path/to/checkout/agents/default/.
  GUIDE.md
  SOUL.md
  OPERATOR.md
  WORLD.md
  BOOTSTRAP.md
  skills/example-welcome.cl
  tools/example-echo.cl
  state.json
Bootstrap has not started. Edit SOUL.md, OPERATOR.md, and WORLD.md first,
then run `enchiridion chat`. See agents/default/GUIDE.md for the walkthrough.
```

The command exits 0 when every seed file is written.
A write problem prints the failures and exits 1.

A later launch with no command and an agent directory in place prints one line:

```text
Agent directory is ready. Run `enchiridion chat`, or `enchiridion help`.
```

A seed file is created when absent and never overwritten.
A rerun reports the files it kept and writes only the missing ones.
`enchiridion init` performs the same work on demand (see [Commands](commands.md#init)).

The launch also creates a nested `.git/` repository and its `.gitignore` when Git is available.
`GUIDE.md` is the walkthrough and `BOOTSTRAP.md` holds the first steps.
The other three Markdown files hold the agent's identity, its operator context, and its environment.

## Edit the seed files

Edit three files before the first session:

1. Edit `SOUL.md`. State the agent's name, voice, values, and refusals.

2. Edit `OPERATOR.md`. State who the operator is, what a good answer looks like, and when the agent may act or interrupt.

3. Edit `WORLD.md`. State the real paths, commands, and conventions on this machine.

Leave `BOOTSTRAP.md` in place.
While it is present and its steps are not all done, the block and file tools refuse a write to `SOUL.md`, `OPERATOR.md`, or `WORLD.md`.

> **Important:** The block and file tools honour the gate.
> `shell` does not check it.
> The gate is a rule the agent follows, not a sandbox boundary (see [Tools](tools.md#blockops)).

### Hand over the bootstrap

The agent works the numbered list and records each step with the meta tool action `bootstrap-step`.
The operator can record one step from the shell:

```sh
enchiridion bootstrap step 1
enchiridion bootstrap status
```

After the last step, the status prints the line `Bootstrap complete.` The handover archives `BOOTSTRAP.md` as `BOOTSTRAP.done.md`, and the block and file tools accept writes.
The handover commits the agent directory.

If a session cannot record a step, renaming the file is the manual fallback:

```sh
mv agents/default/BOOTSTRAP.md agents/default/BOOTSTRAP.done.md
```

A manual rename opens the gate but leaves the state record and the commit alone.

`enchiridion bootstrap reset` restores `BOOTSTRAP.md` and clears the record.
[Memory](memory.md#the-bootstrap) covers the state machine, and [Commands](commands.md#bootstrap) covers the command.

## Add the provider credential

`config.cl` holds paths and behavior, never a secret value.
The credential comes from `.env` beside the checkout or from the process environment.

1. Create `.env` in the checkout root:

   ```sh
   cat > .env <<'EOF'
   OPENAI_API_KEY=replace-with-the-provider-key
   EOF
   chmod 600 .env
   ```

2. Confirm the name, the source, and the mode:

   ```sh
   nix run .#enchiridion -- secrets
   ```

The `secrets` command prints one line per loaded name and then the file it read:

```text
OPENAI_API_KEY from file
secrets file /path/to/checkout/.env mode #o600 present
```

The loader refuses a world-readable file before it reads one pair, with the path, the mode, and the `chmod` needed to fix it.

The shipped default selects OpenAI when no `config.cl` exists.
The tracked template pins no provider, so a copied `config.example.cl` selects the provider whose key is in `.env`.
Copy it when changing a model, an endpoint, a channel, or a budget (see [Configuration](configuration.md)).

## Start the first conversation

`chat` runs the read-eval-print loop (REPL) in the foreground, and `ask` runs one turn and exits.

1. Enter the development shell, name the Lisp implementation for child processes, and start the REPL:

   ```sh
   nix develop
   export ENCHIRIDION_SBCL=$(command -v sbcl)
   sbcl --script src/main.cl chat
   ```

2. Type a message at the `enchiridion>` prompt, `/help` for the command list, and `/quit` to leave.

For one turn without a session, run:

```sh
sbcl --script src/main.cl ask "What can you do?"
```

The reply goes to standard output.
The token line goes to standard error, as `<model>  in <input>  out <output>`.
The line adds `  cached <N>` and `  wrote <N>` when the provider reports cache tokens.
The session loads `SOUL.md`, `OPERATOR.md`, and `WORLD.md` as memory blocks.
Writes to those blocks stay refused while `BOOTSTRAP.md` is pending (see [Memory](memory.md)).

### Shell and REPL

A shell command is one program invocation that prints and exits with a status.
`chat` and `serve` are shell-only commands.
The REPL holds one process.
A line without a slash is a turn, and a line with a slash is a command.
Every command except `chat` and `serve` is available in the REPL.
`/stop`, `/quit`, and `/who` exist only in the REPL.
Ctrl-C interrupts the line or the turn and returns to the prompt.
`/quit`, end of input, SIGTERM, and SIGHUP leave the session (see [Commands](commands.md)).

## Where state lives

| Path                                | Holds                                               |
| ----------------------------------- | --------------------------------------------------- |
| `<checkout>/config.cl`              | Operator configuration, optional and gitignored     |
| `<checkout>/.env`                   | Credentials, optional, mode 600                     |
| `<home>/agents/default/`            | Seed files, skills, tools, `state.json`, store      |
| `<home>/run/enchiridion.control`    | Control requests, one per line                      |
| `<home>/run/enchiridion.status`     | Status file the supervisor rewrites                 |
| `<home>/run/broker.sock`            | Broker socket, when `ENCHIRIDION_HOME` is set       |
| `<home>/agents/default/broker.sock` | Broker socket, when `ENCHIRIDION_HOME` is unset     |
| `agents/default/memory.db`          | Default memory store, unless `:memory :db` sets one |

`<home>` is the current directory at launch.
Set `ENCHIRIDION_HOME` to move both `agents/default/` and `run/` under one other directory.
Set `ENCHIRIDION_SOURCE` to name the project root for an installed copy with no checkout above it.
The store path, the block limits, and the run files are described in [Memory](memory.md) and [Supervisor and heartbeat](supervisor.md).

## Troubleshooting

| Symptom                                                       | Cause                                                             | Fix                                                                                       |
| ------------------------------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `Could not write:` after the first launch                     | The home root is not writable                                     | Create a writable directory, then set `ENCHIRIDION_HOME` to it                            |
| `No API key. Put OPENAI_API_KEY in .env or the environment.`  | No credential was loaded for the selected provider                | Write the key to `.env` or export the variable, then retry                                |
| `.env is mode #o644 and every uid can read it.`               | The world read bit is set on the secret file                      | Run `chmod 600 .env`                                                                      |
| `not keeping a transcript: Configuration is wrong at MEMORY.` | The memory store cannot be opened at the configured path          | Make the home root writable, or set `:memory :db` (see [Configuration](configuration.md)) |
| `There is no command called ...`                              | An unknown command, or a flag read as a command                   | Run `help`, and put flags before the command                                              |
| `The broker did not start before the timeout.`                | The child Lisp is missing, or its cache directory is not writable | Run from `nix develop` with `ENCHIRIDION_SBCL` set (see [Commands](commands.md))          |
| `stdin is not a terminal, so the cli channel stays down.`     | `serve` owns the terminal channel without a terminal              | Run in a terminal, or use another channel (see [Channels](channels.md))                   |

## See also

- [Configuration](configuration.md): every section and key, the provider rows, and the precedence rules.
- [Commands](commands.md): the command table, flags, exit statuses, the REPL, and signals.
- [Supervisor and heartbeat](supervisor.md): what `serve` starts and what the `run/` files hold.
- [Memory](memory.md): the seed files, the bootstrap handover, and the memory store.
- [Large language model backends](llm.md): provider selection, credential variables, and scrubbing.
