#!/usr/bin/env bash
# Signs a release zip or an appcast with the update key, exactly as Sparkle's
# `sign_update` does (Ed25519 over the file's bytes, base64), so the feed
# format stays Sparkle-compatible without shipping Sparkle:
#
#   scripts/sign-update.sh <key file> <zip>              # prints the signature
#   scripts/sign-update.sh <key file> --feed <appcast.xml>   # appends the feed signature comment
#
# The key file holds the private key as scripts/create-update-key.sh wrote
# it (base64 of the 32-byte seed). Needs Xcode's Swift (CryptoKit).
set -euo pipefail

KEY_FILE="${1:?usage: sign-update.sh <key file> [--feed] <file>}"
if [[ "${2:-}" == "--feed" ]]; then
    MODE="feed"
    FILE="${3:?usage: sign-update.sh <key file> --feed <appcast.xml>}"
else
    MODE="file"
    FILE="${2:?usage: sign-update.sh <key file> [--feed] <file>}"
fi
test -f "$KEY_FILE" || { echo "error: key file ${KEY_FILE} not found" >&2; exit 1; }
test -f "$FILE" || { echo "error: ${FILE} not found" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macpaper-sign.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/sign.swift" <<'SWIFT'
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
let keyText = try String(contentsOfFile: arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: keyText), seed.count == 32 else {
    FileHandle.standardError.write(Data("error: the key file does not hold a base64 Ed25519 seed\n".utf8))
    exit(1)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
let signature = try key.signature(for: data).base64EncodedString()
if arguments[2] == "feed" {
    // The same trailer sign_update writes: the signature covers the bytes before it.
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: arguments[3]))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(data.count)\n-->\n".utf8))
    try handle.close()
} else {
    print(signature)
}
SWIFT
xcrun swift "$WORK/sign.swift" "$KEY_FILE" "$MODE" "$FILE"
