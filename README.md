# BTC AI AGENT

Workspace scaffold for the forge0btc AIBTC agent setup.

## Included files

- `.vscode/mcp.json`
- `SOUL.md`
- `CLAUDE.md`
- `daemon/loop.md`
- `.github/copilot-instructions.md`

## Local-only artifacts

The generated logs and output files in `daemon/` and the `*-output.*` files are ignored by git so they do not end up in a public repo. They remain available locally for monitoring and debugging.

## Next steps

- Open the workspace in VS Code.
- Install the AIBTC MCP server.
- Paste and execute the setup prompts in order.
- Run `scripts/watch-news-agent.ps1` to monitor the active news agent and append status snapshots to `daemon/news-watch.md`.
- Run `scripts/watch-inbox-agent.ps1` to monitor the active inbox and append status snapshots to `daemon/inbox-watch.md`.
- Run `scripts/watch-news-review.ps1` to track the latest signal on the active beat and log approval or rejection updates in `daemon/news-review-watch.md`.
- Run `scripts/auto-topic-news-signal.ps1` to auto-pick the freshest Infrastructure release candidate and file a signal when the beat is open.
