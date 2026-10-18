# enchiridion

an autonomous agent written in Common Lisp

## Build and test

```sh
nix run .#check                 # compile every file; a warning fails the build
nix run .#test                  # the whole suite
nix run .#enchiridion -- help   # the command list
```

## License

0BSD
