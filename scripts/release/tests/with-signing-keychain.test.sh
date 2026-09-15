#!/usr/bin/env bash
# with-signing-keychain.sh must leave the user keychain search list exactly as
# it found it and no identity behind, whether run through its shebang, through
# an explicit `bash`, or through an explicit `zsh` — and whether the command
# succeeds or fails. Uses a throwaway certificate; never touches the login
# keychain's contents.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
./create-signing-certificate.sh "$work/cert" >/dev/null
export RELEASE_SIGNING_P12_FILE="$work/cert/release-signing.p12"
RELEASE_SIGNING_P12_PASSWORD="$(cat "$work/cert/release-signing.p12.password")"
export RELEASE_SIGNING_P12_PASSWORD
fingerprint="$(openssl x509 -in "$work/cert/release-signing.cert.pem" -outform der | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F)"

before="$(security list-keychains -d user)"
check() {
    local label="$1"
    local after
    after="$(security list-keychains -d user)"
    if [[ "$after" != "$before" ]]; then
        echo "error ($label): the keychain search list changed:" >&2
        printf '%s\n' "$after" >&2
        exit 1
    fi
    if security find-identity -p codesigning 2>/dev/null | grep -q "$fingerprint"; then
        echo "error ($label): the throwaway identity is still available" >&2
        exit 1
    fi
    echo "ok: $label"
}

# The command must see the identity, in the temporary keychain only.
# shellcheck disable=SC2016  # expanded by the inner shell, inside the wrapper
inside='security find-identity -p codesigning "$RELEASE_SIGNING_KEYCHAIN" | grep -q "$RELEASE_SIGNING_IDENTITY"'
./with-signing-keychain.sh sh -c "$inside"; check "shebang, success"
bash ./with-signing-keychain.sh sh -c "$inside"; check "bash, success"
zsh ./with-signing-keychain.sh sh -c "$inside"; check "zsh, success"
if zsh ./with-signing-keychain.sh false 2>/dev/null; then echo "error: a failing command must fail the wrapper" >&2; exit 1; fi
check "zsh, failure"
if bash ./with-signing-keychain.sh false 2>/dev/null; then echo "error: a failing command must fail the wrapper" >&2; exit 1; fi
check "bash, failure"
