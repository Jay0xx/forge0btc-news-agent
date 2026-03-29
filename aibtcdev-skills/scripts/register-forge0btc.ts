#!/usr/bin/env bun
import { createHash } from "node:crypto";
import {
  getWalletManager,
} from "../src/lib/services/wallet-manager.js";
import {
  hashMessage,
} from "@stacks/encryption";
import { bytesToHex } from "@stacks/common";
import { signMessageHashRsv } from "@stacks/transactions";
import {
  Transaction,
  p2wpkh,
  Script,
  RawTx,
  RawWitness,
  SigHash,
  NETWORK as BTC_MAINNET,
  TEST_NETWORK as BTC_TESTNET,
} from "@scure/btc-signer";

const BITCOIN_MSG_PREFIX = "\x18Bitcoin Signed Message:\n";

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
  if (n < 0xfd) {
    return new Uint8Array([n]);
  }

  if (n <= 0xffff) {
    return new Uint8Array([0xfd, n & 0xff, (n >> 8) & 0xff]);
  }

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

function parseDERSignature(der: Uint8Array): Uint8Array {
  if (der[0] !== 0x30) throw new Error("Expected DER signature");
  let position = 2;
  if (der[position] !== 0x02) throw new Error("Expected DER r marker");
  position++;
  const rLength = der[position++];
  const rBytes = der.slice(rLength === 33 ? position + 1 : position, position + rLength);
  position += rLength;
  if (der[position] !== 0x02) throw new Error("Expected DER s marker");
  position++;
  const sLength = der[position++];
  const sBytes = der.slice(sLength === 33 ? position + 1 : position, position + sLength);

  const compact = new Uint8Array(64);
  compact.set(rBytes, 32 - rBytes.length);
  compact.set(sBytes, 64 - sBytes.length);
  return compact;
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

function bip322SignP2WPKH(
  message: string,
  privateKey: Uint8Array,
  publicKey: Uint8Array,
  network: typeof BTC_MAINNET
): string {
  const scriptPubKey = p2wpkh(publicKey, network).script;
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
    throw new Error("BTC signing failed: missing witness");
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
  const description = args.get("description") ??
    "Autonomous DeFi agent. Builds and audits Clarity smart contracts on Bitcoin and Stacks.";
  const registerUrl = args.get("register-url") ?? "https://aibtc.com/api/register";
  const message = "Bitcoin will be the currency of AIs";

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

  const btcSignature = bip322SignP2WPKH(
    message,
    account.btcPrivateKey,
    account.btcPublicKey,
    BTC_MAINNET
  );

  const stacksHash = bytesToHex(hashMessage(message));
  const stacksSignature = signMessageHashRsv({
    messageHash: stacksHash,
    privateKey: account.privateKey,
  });

  const payload = {
    bitcoinSignature: btcSignature,
    stacksSignature,
    btcAddress: account.btcAddress,
    description,
  };

  const response = await fetch(registerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });

  const responseText = await response.text();
  let parsed: unknown = responseText;
  try {
    parsed = JSON.parse(responseText);
  } catch {
    // keep raw text
  }

  console.log(JSON.stringify({
    success: response.ok || response.status === 409,
    status: response.status,
    payload,
    response: parsed,
  }, null, 2));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
