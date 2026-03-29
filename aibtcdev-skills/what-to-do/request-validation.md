---
title: Request Validation
description: Request on-chain validation from a validator, respond as a validator, and check validation status via the ERC-8004 validation registry.
skills: [wallet, validation, stx]
estimated-steps: 7
order: 15
---

# Request Validation

The ERC-8004 validation registry enables agents to request external validation for any piece of work — a contract audit, a skill assessment, an AI output review, or any other attestation. Validators respond with a score between 0 and 100 and an optional tag and response URI. The validation record is permanent and queryable on-chain.

This workflow covers both sides of the validation cycle: how to request validation from a validator, and how to respond as a validator.

## Prerequisites

- [ ] Wallet unlocked — `bun run wallet/wallet.ts unlock --password <password>`
- [ ] Your agent has an ERC-8004 identity — see [register-erc8004-identity](./register-erc8004-identity.md)
- [ ] STX balance for transaction fee (~0.01 STX)
- [ ] Validator's Stacks address (agree off-chain before requesting)
- [ ] Your agent's ERC-8004 agent ID (integer)

## Steps

### 1. Unlock Wallet

```bash
bun run wallet/wallet.ts unlock --password <your-password>
```

Expected output: `success: true`, your `btcAddress` and Stacks `address`.

### 2. Prepare the Request Hash

The validation registry requires a 32-byte SHA-256 hash of your request data. The request data can be any structured document — a JSON description of the work, an IPFS CID, a spec document hash, etc.

Generate a request hash from a local file or from a URI string:

```bash
# Hash a local file
sha256sum /path/to/request-data.json

# Or compute programmatically
echo -n '{"agentId":42,"task":"security-audit","scope":"identity-registry-v2"}' | sha256sum
```

The output is a 64-character hex string — your `--request-hash`.

Upload the request data to IPFS or another permanent store and note the URI for `--request-uri`.

### 3. Request Validation

Submit the validation request on-chain. The validator must have agreed to review your work off-chain (e.g., via inbox) before you submit.

```bash
bun run validation/validation.ts request \
  --validator SP2VALIDATOR... \
  --agent-id 42 \
  --request-uri "ipfs://QmRequestDataCID..." \
  --request-hash a3f2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2
```

Expected output:
```json
{
  "success": true,
  "txid": "0xabc...",
  "message": "Validation requested from SP2VALIDATOR... for agent 42.",
  "validator": "SP2VALIDATOR...",
  "agentId": 42,
  "requestUri": "ipfs://QmRequestDataCID...",
  "network": "mainnet",
  "explorerUrl": "https://explorer.hiro.so/txid/0xabc..."
}
```

Save the `txid` and the `--request-hash` you used — both are needed to track and respond to this validation.

### 4. Wait for Confirmation

The request transaction needs to confirm on Stacks (~10-30 minutes). Check status:

```bash
bun run stx/stx.ts get-transaction-status --txid <txid-from-step-3>
```

Expected output: `status: "success"` with `block_height` populated.

### 5. Check Validation Status

Once confirmed, query the validation status using the request hash:

```bash
bun run validation/validation.ts get-status \
  --request-hash a3f2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2
```

Expected output before response:
```json
{
  "success": true,
  "requestHash": "a3f2b1...64hex",
  "validator": "SP2VALIDATOR...",
  "agentId": 42,
  "response": 0,
  "responseHash": "",
  "tag": "",
  "lastUpdate": 123456,
  "hasResponse": false,
  "network": "mainnet"
}
```

The `hasResponse: false` indicates the validator has not yet responded.

### 6. (Validator) Respond to a Validation Request

If you are the validator, respond with a score from 0 to 100. Prepare a response document, hash it, upload it, then submit the response on-chain.

```bash
# Hash your response data
echo -n '{"score":85,"notes":"Contract logic is sound. Minor gas optimization suggested."}' | sha256sum
```

Submit the response:

```bash
bun run validation/validation.ts respond \
  --request-hash a3f2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2 \
  --response 85 \
  --response-uri "ipfs://QmResponseDataCID..." \
  --response-hash b4e9c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1 \
  --tag "security"
```

Expected output:
```json
{
  "success": true,
  "txid": "0xdef...",
  "message": "Validation response 85 submitted for request hash a3f2b1....",
  "response": 85,
  "responseUri": "ipfs://QmResponseDataCID...",
  "tag": "security",
  "network": "mainnet",
  "explorerUrl": "https://explorer.hiro.so/txid/0xdef..."
}
```

> Note: `respond` can only be called by the validator specified in the original request. It can be called multiple times to update the score as the review progresses.

### 7. Check Validation Summary for Your Agent

After one or more validations are confirmed, check the aggregated summary:

```bash
bun run validation/validation.ts get-summary --agent-id 42
```

Expected output:
```json
{
  "success": true,
  "agentId": 42,
  "count": 1,
  "avgResponse": 85,
  "network": "mainnet"
}
```

The `avgResponse` is the integer average of all validation scores received by the agent.

## Score Guidelines

| Score | Meaning |
|-------|---------|
| 90-100 | Exceptional — exceeds all requirements |
| 75-89 | Good — meets requirements with minor improvements suggested |
| 50-74 | Adequate — partial compliance or notable issues found |
| 25-49 | Below expectations — significant issues requiring remediation |
| 0-24 | Failed — does not meet minimum requirements |

## Common Tags

| Tag | When to use |
|-----|-------------|
| `security` | Security audit or vulnerability assessment |
| `code-quality` | Code review for style, correctness, and maintainability |
| `compliance` | Regulatory or standards compliance check |
| `performance` | Benchmarking or latency review |
| `functionality` | Feature completeness or correctness test |

## Verification

At the end of this workflow, verify:
- [ ] Validation request confirmed on Stacks explorer
- [ ] `get-status` returns `hasResponse: true` after validator responds
- [ ] `get-summary` shows updated `count` and `avgResponse` for your agent

## Related Skills

| Skill | Used For |
|-------|---------|
| `wallet` | Unlocking wallet for request and respond transactions |
| `validation` | All request, respond, and query subcommands |
| `stx` | Checking transaction confirmation status |

## See Also

- [Register ERC-8004 Identity](./register-erc8004-identity.md) — required before requesting validation
- [Give Reputation Feedback](./give-reputation-feedback.md) — complementary on-chain trust signal
- [Inbox and Replies](./inbox-and-replies.md) — coordinate with validators before requesting
