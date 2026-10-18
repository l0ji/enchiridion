# enchiridion

an autonomous agent harness written in Common Lisp

It runs inside its own container with no dependency on the host system. It
begins from operator-written seed files, then develops its own identity. It
rewrites its own skills and tools at runtime. It talks through a CLI, a
webhook, and Fluxer direct messages.

## Build and test

```sh
nix run .#check                 # compile every file; a warning fails the build
nix run .#test                  # the whole suite
nix run .#enchiridion -- help   # the command list
```

Nix keeps an evaluation cache and a fetcher cache under `XDG_CACHE_HOME`. When
that directory is not writable — a sandbox that allows writes only inside the
checkout, for example — both commands fail before they build anything, with
"cannot open SQLite database" or "attempt to write a readonly database". Point
the cache at a writable directory for the run:

```sh
export XDG_CACHE_HOME=$PWD/.nix-cache
nix run .#check
nix run .#test
```

Only the cache moves. `/nix/store` and the build are the same either way.

`nix run` fetches the flake through git, so a file that has not been added is
invisible to the build. `git add` a new source or test file before running the
gate, or the failure reads "Failed to find the TRUENAME of ...".

## License

0BSD
