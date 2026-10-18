# enchiridion

an autonomous agent harness with a strange memory model

## Build and test

```sh
nix run .#check                 # compile
nix run .#test                  # run the test suite
nix run .#enchiridion -- help   # list the commands
```

## Run

### Nix

```sh
nix run .#enchiridion                  # write the agent files on the first launch
nix run .#enchiridion -- chat          # the terminal REPL
nix run .#enchiridion -- ask "..."     # ask a question
nix run .#enchiridion -- serve         # start the agent supervisor
```

### Docker

```sh
docker compose build                   # build the image from docker/Dockerfile
docker compose up -d                   # start the supervisor
```

`docker build -t enchiridion:0.1.0 -f docker/Dockerfile .` builds the same image
on its own.
[Deployment](docs/deployment.md) gives the full procedure.

## Documentation

- [Documentation index](docs/index.md)
- [Getting started](docs/getting-started.md)
- [Configuration](docs/configuration.md)
- [Commands](docs/commands.md)
- [Channels](docs/channels.md)
- [Supervisor and heartbeat](docs/supervisor.md)
- [Memory](docs/memory.md)
- [Models and secrets](docs/llm.md)
- [Tools](docs/tools.md)
- [Plugins and self-modification](docs/plugins.md)
- [Deployment](docs/deployment.md)
- [Testing](docs/testing.md)
- [Development](docs/development.md)

## License

0BSD
