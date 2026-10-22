# enchiridion

enchiridion is an unstable autonomous agent harness with a strange memory model

## Requirements

- UNIX box
- Nix, Docker or SBCL knowledge

## Build and test

```sh
nix develop         # devshell
nix run .#check     # compile with SBCL
nix run .#test      # run test suite
```

## Run

### Nix

```sh
cp .env.example .env && chmod 600 .env      # modify these two
cp config.example.cl config.cl

nix run .#enchiridion                       # write the agent directory and exit
nix run .#enchiridion -- chat               # start the terminal REPL
nix run .#enchiridion -- ask "..."          # send a query
nix run .#enchiridion -- serve              # start the supervisor and its channels
nix run .#enchiridion -- help               # list all commands
```

### Docker

```sh
cp .env.example .env && chmod 600 .env      # modify these two
cp config.example.cl config.cl

docker compose build
docker compose run --rm enchiridion init
docker compose up -d
```

## Documentation

Start with [the getting started page](docs/getting-started.md) or the [documentation index](docs/index.md).

Please note that the documentation is almost entirely AI generated, I'll rewrite it once it becomes stable I promise :)

## License

BSD Zero Clause License
