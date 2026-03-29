---
title: Create Inscriptions
description: Inscribe content on Bitcoin using the two-step commit/reveal pattern — text, images, HTML, or any data permanently on-chain.
skills: [wallet, btc, ordinals]
estimated-steps: 8
order: 15
---

# Create Inscriptions

Bitcoin ordinals let you inscribe arbitrary data — text, images, HTML, SVG — permanently on-chain. Each inscription gets a unique ID and lives at a Taproot address. Inscriptions are the foundation for on-chain art, agent cards, trade receipts, and any content you want to exist forever on Bitcoin.

The process uses a two-step commit/reveal pattern:
1. **Commit** — broadcasts a transaction that locks funds to a Taproot script containing your content
2. **Reveal** — spends that output, publishing the inscription on-chain

## Prerequisites

- [ ] Wallet unlocked — `bun run wallet/wallet.ts unlock --password <password>`
- [ ] BTC balance on your SegWit (bc1q) address — check with `bun run btc/btc.ts balance`
- [ ] Content prepared (text, image file, HTML, etc.)
- [ ] Enough sats to cover commit + reveal fees (estimate first)

## Steps

### 1. Check Your BTC Balance

```bash
bun run btc/btc.ts balance
```

You need BTC on the SegWit address (not Taproot) to fund the commit transaction. Typical inscriptions cost 3,000-20,000 sats depending on content size and fee rates.

### 2. Get Your Taproot Address

This is where the inscription will land after the reveal:

```bash
bun run ordinals/ordinals.ts get-taproot-address
```

Expected output: a `bc1p...` address. Save this — it's where your inscriptions live.

### 3. Prepare Your Content

Encode your content as base64. Examples for common content types:

**Plain text:**
```bash
CONTENT_B64=$(echo -n "Hello from Agent #3" | base64)
CONTENT_TYPE="text/plain"
```

**HTML (agent cards, art, interactive content):**
```bash
CONTENT_B64=$(base64 -w0 < my-card.html)
CONTENT_TYPE="text/html"
```

**SVG:**
```bash
CONTENT_B64=$(base64 -w0 < artwork.svg)
CONTENT_TYPE="image/svg+xml"
```

**PNG/JPEG image:**
```bash
CONTENT_B64=$(base64 -w0 < photo.png)
CONTENT_TYPE="image/png"
```

### 4. Estimate the Fee

Before committing real sats, check the cost:

```bash
bun run ordinals/ordinals.ts estimate-fee \
  --content-type "$CONTENT_TYPE" \
  --content-base64 "$CONTENT_B64"
```

Expected output shows `commitFee`, `revealFee`, and `totalCost` in satoshis. If the cost is too high, wait for lower fee rates or reduce content size.

### 5. Broadcast the Commit Transaction

```bash
bun run ordinals/ordinals.ts inscribe \
  --content-type "$CONTENT_TYPE" \
  --content-base64 "$CONTENT_B64" \
  --fee-rate medium
```

Fee rate options: `fast` (next block), `medium` (30 min), `slow` (1 hour), or a specific number in sat/vB.

Expected output:
```json
{
  "status": "commit_broadcast",
  "commitTxid": "abc123...",
  "revealAmount": 2506,
  "feeRate": 8
}
```

**Save these three values** — you need them for the reveal step:
- `commitTxid`
- `revealAmount`
- `feeRate` (optional, can use a different rate for reveal)

### 6. Wait for Commit Confirmation

The commit transaction must confirm before you can reveal. Check status:

```bash
# Check on mempool.space
curl -s "https://mempool.space/api/tx/COMMIT_TXID" | python3 -c "
import json, sys
tx = json.load(sys.stdin)
status = tx.get('status', {})
if status.get('confirmed'):
    print(f'Confirmed in block {status[\"block_height\"]}')
else:
    print('Unconfirmed — waiting...')
"
```

Typical wait: 10-60 minutes depending on fee rate and mempool congestion.

### 7. Broadcast the Reveal Transaction

Once the commit confirms, finalize the inscription:

```bash
bun run ordinals/ordinals.ts inscribe-reveal \
  --commit-txid COMMIT_TXID \
  --reveal-amount REVEAL_AMOUNT \
  --content-type "$CONTENT_TYPE" \
  --content-base64 "$CONTENT_B64" \
  --fee-rate medium
```

**Critical:** The `--content-type` and `--content-base64` must match exactly what you used in the commit step. Any mismatch will produce an invalid reveal.

Expected output:
```json
{
  "status": "success",
  "inscriptionId": "def456...i0",
  "reveal": {
    "txid": "def456...",
    "explorerUrl": "https://mempool.space/tx/def456..."
  }
}
```

The inscription ID is `{revealTxid}i0`.

### 8. Verify the Inscription

After the reveal confirms, verify your inscription content:

```bash
bun run ordinals/ordinals.ts get-inscription --txid REVEAL_TXID
```

You can also view it on ordinals explorers:
- `https://ordinals.com/inscription/{inscriptionId}`
- `https://mempool.space/tx/{revealTxid}`

## Batch Inscriptions

For multiple inscriptions (e.g., a set of agent cards), repeat steps 5-7 for each item. Tips:

- **Sequential commits**: Send all commits first, then reveal in order after each confirms
- **Same fee rate**: Use the same fee rate for all commits in a batch to keep costs predictable
- **Track state**: Save each `commitTxid` and `revealAmount` in a file or database
- **UTXO management**: Each commit consumes a UTXO. If you're doing many inscriptions, consolidate UTXOs first

## Content Size Limits

| Content Type | Practical Size | Cost at 10 sat/vB |
|-------------|---------------|---------------------|
| Plain text | Up to 4 KB | ~5,000 sats |
| HTML | Up to 20 KB | ~25,000 sats |
| SVG | Up to 10 KB | ~15,000 sats |
| PNG/JPEG | Up to 50 KB | ~60,000 sats |

Bitcoin blocks have a 4 MB weight limit. Larger inscriptions are possible but expensive.

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Commit fails with insufficient funds | Not enough BTC on SegWit address | Transfer BTC to your bc1q address |
| Reveal fails with "UTXO not found" | Commit hasn't confirmed yet | Wait for confirmation, check mempool.space |
| Reveal fails with "script mismatch" | Content doesn't match commit | Use exact same content-type and content-base64 |
| Inscription not showing on explorers | Reveal hasn't confirmed | Wait 10-60 minutes for confirmation |
| High fees | Mempool congestion | Use `slow` fee rate or wait for lower fees |

## Verification

At the end of this workflow, verify:
- [ ] Commit transaction confirmed on mempool.space
- [ ] Reveal transaction confirmed on mempool.space
- [ ] `get-inscription` returns your content with correct content type
- [ ] Inscription visible on ordinals.com (after indexing, may take hours)
- [ ] Inscription landed at your Taproot address

## Related Skills

| Skill | Used For |
|-------|---------|
| `wallet` | Unlocking wallet for signing transactions |
| `btc` | Checking balance and UTXOs on SegWit address |
| `ordinals` | All inscription operations (commit, reveal, get) |

## See Also

- [Send BTC Payment](./send-btc-payment.md) — fund your SegWit address before inscribing
- [Check Balances and Status](./check-balances-and-status.md) — verify BTC balance
- [Sign and Verify](./sign-and-verify.md) — sign inscriptions or metadata
