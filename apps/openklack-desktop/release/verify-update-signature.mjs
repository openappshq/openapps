#!/usr/bin/env node
// Verifies a Tauri updater signature without the app:
//
//   node release/verify-update-signature.mjs <file> <file.sig> [public key file]
//
// The public key defaults to release/updater-public-key.txt. Both the key and the
// signature are what `tauri signer` writes: base64 of a minisign public key or
// signature file. Only prehashed (BLAKE2b-512) Ed25519 signatures are accepted,
// which is what `tauri signer sign` produces and what the app accepts. The
// trusted comment's global signature is checked too.
import { createHash, createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [
  file,
  signatureFile,
  keyFile = join(dirname(fileURLToPath(import.meta.url)), "updater-public-key.txt"),
] = process.argv.slice(2);
if (!file || !signatureFile) {
  console.error("usage: verify-update-signature.mjs <file> <file.sig> [public key file]");
  process.exit(2);
}

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

function lines(base64Text, what) {
  const text = Buffer.from(base64Text.trim(), "base64").toString("utf8");
  const result = text.split("\n").map((line) => line.replace(/\r$/, ""));
  if (result.length < 2) fail(`${what} is not a minisign file`);
  return result;
}

const keyText = readFileSync(keyFile, "utf8").trim();
if (keyText.startsWith("NOT GENERATED")) fail(`${keyFile} has no update key yet`);
const keyBytes = Buffer.from(lines(keyText, "the public key")[1], "base64");
if (keyBytes.length !== 42 || keyBytes.subarray(0, 2).toString() !== "Ed")
  fail("unsupported public key");
const keyId = keyBytes.subarray(2, 10);
const publicKey = createPublicKey({
  key: { kty: "OKP", crv: "Ed25519", x: keyBytes.subarray(10).toString("base64url") },
  format: "jwk",
});

const [, signatureLine, trustedLine, globalLine] = lines(
  readFileSync(signatureFile, "utf8"),
  "the signature",
);
const signatureBytes = Buffer.from(signatureLine ?? "", "base64");
if (signatureBytes.length !== 74) fail("malformed signature");
if (signatureBytes.subarray(0, 2).toString() !== "ED")
  fail("only prehashed signatures are accepted");
if (!signatureBytes.subarray(2, 10).equals(keyId)) fail("signed with a different key");
const digest = createHash("blake2b512").update(readFileSync(file)).digest();
if (!verify(null, digest, publicKey, signatureBytes.subarray(10)))
  fail(`bad signature for ${file}`);

const prefix = "trusted comment: ";
if (!trustedLine?.startsWith(prefix) || !globalLine) fail("missing trusted comment");
const trusted = Buffer.from(trustedLine.slice(prefix.length), "utf8");
const global = Buffer.from(globalLine, "base64");
if (!verify(null, Buffer.concat([signatureBytes.subarray(10), trusted]), publicKey, global)) {
  fail("bad trusted comment signature");
}
console.log(`ok: ${file} is signed by the update key`);
