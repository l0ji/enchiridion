# enchiridion

an autonomous agent written in Common Lisp

## Build and test

The host Nix caches are not writable on this machine. Point the cache at the
workspace before a build, or Nix stops at the first fetch.

```sh
export XDG_CACHE_HOME=$PWD/.nix-cache
nix run .#check                 # compile every file; a warning fails the build
nix run .#test                  # the whole suite
nix run .#enchiridion -- help   # the command list
```

## Usage

### Run the agent

```sh
nix run .#enchiridion              # first launch writes the agent files, then stops
nix run .#enchiridion -- chat      # the REPL
nix run .#enchiridion -- ask "..." # one turn, then exit
nix run .#enchiridion -- serve     # the supervisor, with the enabled channels
```

### The HTTP webhook

```sh
nix run .#enchiridion -- serve --channel http --bind 127.0.0.1 --port 8787
```

`--channel` takes `cli`, `http`, or `fluxer`. `--bind` and `--port` belong to the
webhook, and a channel flag with no subcommand is a request to serve.

`--token-env NAME` names the variable that holds the bearer token. The
configuration key is `:token-env` under `:http`, and the default name is
`ENCHIRIDION_HTTP_TOKEN`. A bind address other than loopback needs a token, or
the process refuses to start.

| Route | Method | Returns |
| --- | --- | --- |
| `/message` | POST | The reply and the token usage for one turn |
| `/health` | GET | The live supervisor: uptime and channels |
| `/usage` | GET | The token ledger |

### Commands

| Command | Effect |
| --- | --- |
| `enchiridion secrets` | The loaded secret names and their sources. It never prints a value. |
| `enchiridion health` | The status file that the supervisor writes |
| `enchiridion heartbeat on\|off\|run` | Turn the heartbeat on or off, or ask for one tick |
| `enchiridion tasks list\|add\|rm` | The task queue |
| `enchiridion usage` | The token ledger by model, day, and channel |
| `enchiridion budget` | The caps and the spend against them |
| `enchiridion channels list\|enable N\|disable N` | The channels of a running supervisor |
| `enchiridion reload` | Ask the running supervisor to load new agent code |

`health`, `heartbeat`, `secrets`, `tasks`, `usage`, and `budget` work from a shell.
`heartbeat`, `channels`, and `reload` need a running supervisor, and they exit
non-zero without one.

### The container

```sh
nix build .#container                # Linux builder only
docker image load -i result

docker run -d --name enchiridion \
  -p 8787:8787 \
  --tmpfs /run/secrets:mode=0700 \
  -v enchiridion-state:/var/lib/enchiridion \
  enchiridion:0.1.0 \
  serve --channel http --bind 0.0.0.0 --port 8787
```

The image is Linux only, so the build needs a Linux host or a Nix linux-builder.
The `-p` flag publishes the webhook port. The tmpfs is where the secret file
goes, and the agent user cannot read it. The named volume keeps the agent
directory and the memory database.

Docker has no proc mount type, so hidepid needs `--cap-add SYS_ADMIN` and a
remount of `/proc` inside the container. The entrypoint does not do that yet.

## License

0BSD
