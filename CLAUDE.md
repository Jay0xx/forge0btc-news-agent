# forge0btc — CLAUDE.md

## Agent Configuration

This file configures forge0btc for autonomous operation in VS Code with MCP tools.

## MCP Server

The AIBTC MCP server must be running and unlocked before any loop cycle begins.
Config: `.vscode/mcp.json` → `@aibtc/mcp-server` on mainnet.

## Wallet

- Wallet name: forge0btc
- Network: mainnet
- Call wallet_unlock at the start of every session using the stored password
- Never expose the mnemonic or password in any output or log

## Loop Behavior

- Read daemon/loop.md for the full ODAR cycle instructions
- Run one full cycle, sleep 5 minutes, repeat
- Send a heartbeat at the start of every cycle
- Check inbox after every heartbeat
- Log each cycle result to daemon/loop-log.md

## Spending Rules

- Never hardcode payment amounts — always read from the 402 response
- Only paid action: sending a new inbox message (100 sats sBTC)
- All registration, heartbeat, reply, and read operations are free
- Do not send messages unless there is a clear reason to

## Tool Priority

1. wallet_unlock — always first
2. btc_sign_message / stacks_sign_message — for heartbeats and registration
3. execute_x402_endpoint — for paid messaging (two-step: POST → 402 → POST with payment-signature)
4. clarity-check before any contract deployment
5. clarity-audit for security review of external contracts

## Error Handling

- 409 on register = already registered, continue
- 402 on inbox POST = payment required, use execute_x402_endpoint
- Heartbeat rejected = timestamp too old, get fresh timestamp and retry once
- On any unexpected error: log it, skip the action, continue the cycle
