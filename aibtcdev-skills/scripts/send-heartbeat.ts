#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { getWalletManager } from "../src/lib/services/wallet-manager.js";
import {
  Transaction,
  p2wpkh,
  Script,
  RawTx,
  RawWitness,
  NETWORK as BTC_MAINNET,
} from "@scure/btc-signer";

function sha256(data: Uint8Array): Buffer {
  return createHash("sha256").update(data).digest();
}

function doubleSha256(data: Uint8Array): Uint8Array {
  return sha256(sha256(data));
}

function concatBytes(...arrays: Uint8Array[]): Uint8Array {
  const totalLen = arrays.reduce((sum, a) => sum + a.length, 0);
  const result = new Uint8Array(totalLen);
  let offset = 0;
  for (const array of arrays) {
    result.set(array, offset);
    offset += array.length;
  }
  return result;
}

function encodeVarInt(n: number): Uint8Array {
  if (n < 0xfd) return new Uint8Array([n]);
  if (n <= 0xffff) return new Uint8Array([0xfd, n & 0xff, (n >> 8) & 0xff]);
  if (n <= 0xffffffff) {
    return new Uint8Array([
      0xfe,
      n & 0xff,
      (n >> 8) & 0xff,
      (n >> 16) & 0xff,
      (n >> 24) & 0xff,
    ]);
  }
  throw new Error("Message too long for varint encoding");
}

function writeUint32LE(n: number): Uint8Array {
  return new Uint8Array([
    n & 0xff,
    (n >> 8) & 0xff,
    (n >> 16) & 0xff,
    (n >> 24) & 0xff,
  ]);
}

function writeUint64LE(n: bigint): Uint8Array {
  const buffer = new Uint8Array(8);
  let value = n;
  for (let index = 0; index < 8; index++) {
    buffer[index] = Number(value & 0xffn);
    value >>= 8n;
  }
  return buffer;
}

function taggedHash(tag: string, data: Uint8Array): Uint8Array {
  const tagHash = sha256(new TextEncoder().encode(tag));
  return sha256(concatBytes(tagHash, tagHash, data));
}

function bip322TaggedHash(message: string): Uint8Array {
  return taggedHash("BIP0322-signed-message", new TextEncoder().encode(message));
}

function bip322BuildToSpendTxId(message: string, scriptPubKey: Uint8Array): Uint8Array {
  const messageHash = bip322TaggedHash(message);
  const scriptSig = concatBytes(new Uint8Array([0x00, 0x20]), messageHash);

  const rawTx = RawTx.encode({
    version: 0,
    segwitFlag: false,
    inputs: [
      {
        txid: new Uint8Array(32),
        index: 0xffffffff,
        finalScriptSig: scriptSig,
        sequence: 0,
      },
    ],
    outputs: [
      {
        amount: 0n,
        script: scriptPubKey,
      },
    ],
    witnesses: [],
    lockTime: 0,
  });

  return doubleSha256(rawTx).reverse();
}

function bip322SignP2WPKH(message: string, privateKey: Uint8Array, publicKey: Uint8Array): string {
  const scriptPubKey = p2wpkh(publicKey, BTC_MAINNET).script;
  const toSpendTxid = bip322BuildToSpendTxId(message, scriptPubKey);

  const toSignTx = new Transaction({ version: 0, lockTime: 0, allowUnknownOutputs: true });
  toSignTx.addInput({
    txid: toSpendTxid,
    index: 0,
    sequence: 0,
    witnessUtxo: { amount: 0n, script: scriptPubKey },
  });
  toSignTx.addOutput({ script: Script.encode(["RETURN"]), amount: 0n });

  toSignTx.signIdx(privateKey, 0);
  toSignTx.finalizeIdx(0);

  const input = toSignTx.getInput(0);
  if (!input.finalScriptWitness) {
    throw new Error("Heartbeat signing failed: missing witness");
  }

  return Buffer.from(RawWitness.encode(input.finalScriptWitness)).toString("base64");
}

async function main() {
  const args = new Map<string, string>();
  for (let index = 2; index < process.argv.length; index += 2) {
    const key = process.argv[index];
    const value = process.argv[index + 1];
    if (!key || !value || !key.startsWith("--")) {
      throw new Error("Invalid arguments");
    }
    args.set(key.slice(2), value);
  }

  const walletId = args.get("wallet-id");
  const password = args.get("password");
  const btcAddress = args.get("btc-address");
  const timestamp = args.get("timestamp") ?? new Date().toISOString();

  if (!walletId || !password || !btcAddress) {
    throw new Error("Missing required arguments: --wallet-id, --password, --btc-address");
  }

  const walletManager = getWalletManager();
  await walletManager.unlock(walletId, password);
  const account = walletManager.getAccount();
  if (!account) {
    throw new Error("Wallet unlock failed");
  }

  if (account.btcAddress !== btcAddress) {
    throw new Error(`BTC address mismatch: wallet has ${account.btcAddress} but script received ${btcAddress}`);
  }

  if (!account.btcPrivateKey || !account.btcPublicKey) {
    throw new Error("Bitcoin signing keys are unavailable for this wallet");
  }

  const message = `AIBTC Check-In | ${timestamp}`;
  const signature = bip322SignP2WPKH(message, account.btcPrivateKey, account.btcPublicKey);

  const response = await fetch("https://aibtc.com/api/heartbeat", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      signature,
      timestamp,
      btcAddress: account.btcAddress,
    }),
  });

  const responseText = await response.text();
  let parsed: unknown = responseText;
  try {
    parsed = JSON.parse(responseText);
  } catch {
    // keep raw text
  }

  console.log(JSON.stringify({
    success: response.ok,
    status: response.status,
    message,
    timestamp,
    btcAddress: account.btcAddress,
    signature,
    response: parsed,
  }, null, 2));

  await writeFile(
    "../heartbeat-output.json",
    JSON.stringify(
      {
        success: response.ok,
        status: response.status,
        message,
        timestamp,
        btcAddress: account.btcAddress,
        signature,
        response: parsed,
      },
      null,
      2
    )
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
