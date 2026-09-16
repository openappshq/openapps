#!/usr/bin/env bash
# Creates Hertz's update key: the Ed25519 (Sparkle EdDSA) key pair that
# signs every release zip and appcast. Run it once, on a trusted machine,
# never in CI:
#
#   scripts/create-update-key.sh <output-dir> [public-key-file]
#
# <output-dir> must not exist yet and must be outside any git work tree. It
# receives `sparkle-ed25519.key`, the private key in the form Sparkle's
# `sign_update --ed-key-file` reads (base64 of the 32-byte seed): the
# SPARKLE_ED_PRIVATE_KEY secret. The public key (base64, 32 bytes) is written
# to [public-key-file], by default release/sparkle-public-key.txt, which is
# committed and compiled into official builds as SUPublicEDKey.
#
# Unlike Sparkle's generate_keys, nothing is stored in a keychain. Back the
# private key up offline and delete it from this machine: losing it means no
# installed copy can verify another update.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: create-update-key.sh <output-dir> [public-key-file]}"
PUBLIC_FILE="${2:-release/sparkle-public-key.txt}"

if [[ -e "$OUT" ]]; then
    echo "error: ${OUT} already exists; choose a new directory so no key is ever overwritten" >&2
    exit 1
fi
mkdir -p "$(dirname "$OUT")"
parent="$(cd "$(dirname "$OUT")" && pwd)"
if git -C "$parent" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: ${OUT} is inside a git work tree; keep private keys out of repositories" >&2
    exit 1
fi

umask 077
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hertz-update-key.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/generate.swift" <<'SWIFT'
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: out, options: .withoutOverwriting)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
public_key="$(xcrun swift "$WORK/generate.swift" "$OUT/sparkle-ed25519.key")"
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "error: unexpected public key '${public_key}'" >&2; exit 1; }
printf '%s\n' "$public_key" > "$PUBLIC_FILE"
chmod 644 "$PUBLIC_FILE"
echo "==> Private key: ${OUT}/sparkle-ed25519.key"
echo "==> Public key (${PUBLIC_FILE}): ${public_key}"
