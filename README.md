# enchiridion

enchiridion is an unstable autonomous agent harness with a strange memory model.

## Requirements

- UNIX box
- Nix, Docker or SBCL knowledge

## Build and test

```sh
nix develop
nix run .#check     # compile every file; a warning fails
nix run .#test      # run both test systems
```

## Run

```sh
cp config.example.lsp config.lsp              # modify these two
cp .env.example .env && chmod 600 .env

nix run .#enchiridion                       # create agent folder
nix run .#enchiridion -- chat               # start the REPL
nix run .#enchiridion -- ask "..."          # ask a question
nix run .#enchiridion -- serve              # start the supervisor
nix run .#enchiridion -- help               # more!
```

## Docker

```sh
cp config.example.lsp config.lsp              # modify these two
cp .env.example .env && chmod 600 .env

docker compose build
docker compose run --rm enchiridion init    # initialize agent
docker compose up -d
```

## Documentation

Start with [Getting started](docs/getting-started.md) or the [documentation index](docs/index.md).

> [!note]
> Please note that the documentation is almost entirely AI generated, I'll rewrite
it once it becomes stable I promise :)

## License

BSD Zero Clause License
