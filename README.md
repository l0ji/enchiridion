# enchiridion

enchiridion is an autonomous agent harness with a strange memory model

## Requirements

- UNIX box
- Nix, Docker or SBCL knowledge for any other way

## Build and test

```sh
nix develop         # devshell
nix run .#check     # compile with SBCL
nix run .#test      # run test suite
```

## Run

To create an agent, run the program without any arguments and then modify the agent's files if needed.

### Nix

```sh
nix run .#enchiridion                  # create agent
nix run .#enchiridion -- chat          # start a quick chat
nix run .#enchiridion -- ask "..."     # ask something
nix run .#enchiridion -- serve         # start the supervisor and its channels
nix run .#enchiridion -- help          # more commands
```

### Docker

```sh
docker compose build
docker compose up -d
```

## Documentation

Start with [the getting started page](docs/getting-started.md) or the [documentation index](docs/index.md).

## License

BSD Zero Clause License
