---
title: Execute a Taproot Multisig Transaction
description: Coordinate an M-of-N Bitcoin Taproot multisig transaction between autonomous agents using BIP-340 Schnorr and OP_CHECKSIGADD.
skills: [wallet, signing, taproot-multisig]
estimated-steps: 6
order: 18
---

# Execute a Taproot Multisig Transaction

Coordinate an M-of-N Bitcoin Taproot multisig spend between autonomous agents using BIP-340 Schnorr signatures and BIP-342 OP_CHECKSIGADD. Proven on mainnet: 2-of-2 (block 937,849) and 3-of-3 (block 938,206).

## Goal

All M signers independently sign the same BIP-341 sighash, submit signatures to a coordination API (e.g., QuorumClaw), and the coordinator broadcasts the transaction once the threshold is reached.

## Prerequisites

- [ ] Wallet exists and can be unlocked
- [ ] All signers have a funded multisig address (the coordinator creates this from everyone's pubkeys)
- [ ] A multisig coordination API endpoint is available (e.g., QuorumClaw from SetZeus)
- [ ] You have the coordination API's join link or proposal details

## Steps

### 1. Check Wallet Status

```bash
bun run wallet/wallet.ts status
```

Confirm wallet exists and note your Taproot address. Unlock if needed:

```bash
bun run wallet/wallet.ts unlock --password <your-password>
```

### 2. Get Your Public Key

```bash
bun run taproot-multisig/taproot-multisig.ts get-pubkey
```

Expected output:
```json
{
  "success": true,
  "internalPubKey": "abcd1234...",
  "taprootAddress": "bc1p...",
  "network": "mainnet",
  "keyFormat": "x-only (32 bytes)",
  "derivationPath": "m/86'/0'/0'/0/0",
  "usage": "Register 'internalPubKey' when joining a multisig. ...",
  "warning": "Always register internalPubKey, NOT the tweaked key. ..."
}
```

Share the `internalPubKey` value with the multisig coordinator. This is the key the coordinator uses to build the multisig Tapscript.

**Do not share:** the tweaked key, the full address, or any private key material.

### 3. Join the Multisig Wallet

Register your `internalPubKey` with the coordination API. The process varies by platform:

- **QuorumClaw:** Use the join link shared by the coordinator. Paste your `internalPubKey` when prompted.
- **Custom API:** POST to the registration endpoint with your pubkey and agent identifier.

Wait for the coordinator to confirm all N signers have joined and the multisig address is live.

### 4. Receive and Review the Sighash

The coordinator creates a spending proposal and distributes a 32-byte sighash. Before signing:

- Confirm the coordinator is trusted
- Note the destination address and amount if available
- Confirm this is the transaction you agreed to sign

### 5. Sign the Sighash

First call (shows digest for review):
```bash
bun run signing/signing.ts schnorr-sign-digest --digest <sighash_hex>
```

After reviewing the digest, sign with confirmation:
```bash
bun run signing/signing.ts schnorr-sign-digest \
  --digest <sighash_hex> \
  --confirm-blind-sign
```

Expected output:
```json
{
  "success": true,
  "signature": "64byteHex...",
  "publicKey": "32byteHex...",
  "signatureFormat": "BIP-340 Schnorr (64 bytes)"
}
```

Submit the `signature` and `publicKey` to the coordination API.

### 6. Verify Co-Signers (Optional but Recommended)

After signatures are collected, verify each co-signer:

```bash
bun run taproot-multisig/taproot-multisig.ts verify-cosig \
  --digest <sighash_hex> \
  --signature <cosig_hex> \
  --public-key <cosigner_pubkey_hex>
```

`isValid: true` confirms the co-signer's key signed this exact sighash. Repeat for each signer.

The coordinator broadcasts once the threshold M is reached.

## Troubleshooting

### Signature rejected by coordination API

Your signature may be valid but against the wrong key. This happens when:
- You registered the tweaked key (from your `bc1p` address) but signed with the internal key (default in `schnorr-sign-digest`)
- Fix: always register `internalPubKey` from `get-pubkey`, not the tweaked key

To verify which key you registered: compare the pubkey you submitted to the coordinator against the `internalPubKey` from `get-pubkey`.

### co-signer verification fails

`isValid: false` means either:
- The sighash was tampered between when you received it and when you're verifying
- The co-signer registered a different key than the one they signed with
- The signature was corrupted in transit

Do not broadcast a transaction with invalid co-signer signatures. Alert the coordinator.

### Wallet unlock fails

Ensure `ARC_CREDS_PASSWORD` is set or pass `--password` explicitly. The `schnorr-sign-digest` command requires the wallet to remain unlocked during the call.

## BIP-86 Key Types Reference

| Key Type | How to Get It | Sign With |
|----------|---------------|-----------|
| Internal key | `get-pubkey` → `internalPubKey` | `schnorr-sign-digest` (default) |
| Tweaked key | Embedded in bc1p address | Custom derivation (avoid unless required) |

**Always use the internal key.** The signing skill uses the internal key. Register the internal key. They match.

## M-of-N Configurations

| Config | Script Threshold | Resilience |
|--------|-----------------|------------|
| 2-of-2 | Both must sign | None — any offline = frozen |
| 2-of-3 | Any 2 of 3 | 1 signer can be offline/compromised |
| 3-of-5 | Any 3 of 5 | 2 signers can be offline/compromised |
| N-of-N | All must sign | Maximum security, zero redundancy |

The coordination flow (key exchange, sighash distribution, signature collection) is identical for all configurations. Only the Tapscript threshold changes.
