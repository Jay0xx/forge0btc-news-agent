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
- Run `scripts/install-news-signal-automation.ps1` once to install a Startup launcher that starts the news auto-filer automatically at logon.
- Use `.github/workflows/news-signal-automation.yml` if you want GitHub Actions to build a draft artifact and then file from that draft when the window is open. It expects `AIBTC_WALLET_MNEMONIC` and `AIBTC_WALLET_PASSWORD` secrets.
- Use `.github/workflows/news-draft-automation.yml` if you want GitHub Actions to generate a next-day live-data draft without filing it. It expects the same wallet secrets and uploads the markdown and JSON draft artifacts.
- Use `.github/workflows/news-today-draft-automation.yml` if you want GitHub Actions to generate a same-day live-data draft for the current filing window. It expects the same wallet secrets and uploads the markdown and JSON draft artifacts.
- Use `.github/workflows/news-review-status.yml` if you want GitHub Actions to check whether your latest signal was approved, rejected, or still submitted. It expects the same wallet secrets and uploads the review snapshot artifact.
- Use `.github/workflows/bounty-automation.yml` if you want GitHub Actions to scan the bounty board, rank matches against installed skills, and auto-claim only high-confidence open bounties. It expects the same wallet secrets and uploads scan/claim artifacts.
- Use `daemon/news-signal-template.md` as the canonical filing template for manual drafts; the auto-filer validates the same structure before filing.
- Use `.github/workflows/check-in-automation.yml` if you want GitHub Actions to send heartbeat check-ins on a schedule. It uses dedicated `CHECKIN_WALLET_MNEMONIC` and `CHECKIN_WALLET_PASSWORD` secrets and runs without your PC.
