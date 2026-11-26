# Documentation

Start with [Getting started](getting-started.md) to run enchiridion locally, or
[Deployment](deployment.md) for a Linux server with Docker Compose.

For the full list of CLI and REPL commands, run `enchiridion help` (or
`enchiridion help <command>` for subcommands and usage).

## Guides

| Page | Covers |
| --- | --- |
| [Getting started](getting-started.md) | First run, identity files, `chat`, `ask`, and `serve` |
| [Configuration](configuration.md) | `config.lsp`, `.env`, LLM providers (OpenAI, Anthropic, local, Bedrock, Vertex), channels, and budgets |
| [Channels](channels.md) | Terminal REPL, HTTP webhook API, and Fluxer direct messages |
| [Memory](memory.md) | Identity files, bootstrap, git history, episodic retrieval, T2 claims, and `ADAPT.md` |
| [Tools and plugins](tools-and-plugins.md) | Built-in tools, writing `.lsp` plugins and `.md` skills, verification, and hot-reload |
| [Deployment](deployment.md) | Docker Compose, Tailscale Serve, backups, supervisor/schedule, and secret isolation |

## Reference

| Page | Covers |
| --- | --- |
| [Settings reference](config-reference.md) | Every `config.lsp` key and environment variable |
| [Development](development.md) | Repo layout, Nix commands, Lisp conventions, and tests |
