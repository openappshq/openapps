#!/usr/bin/env bash
# The local dry run of the whole update path (RELEASES.md, "Build and test
# locally"), with no secrets and no network beyond 127.0.0.1:
#
#   scripts/update-e2e.sh
#
#   1. a throwaway signing certificate and update key go into a temporary
#      directory;
#   2. version A (1.0.0, build 1) and version B (1.0.1, build 2) are built as
#      the update-test variant (bundle id com.openappshq.openreaction.updatetest,
#      no event tap, feed on 127.0.0.1) inside scripts/release/with-signing-keychain.sh,
#      which holds the certificate in a temporary keychain (never the login
#      keychain) and removes it again; the keychain search list must be
#      identical before and after; both apps pin the throwaway public key;
#   3. B is zipped, update-signed, and announced by a signed appcast, all
#      verified with the public key alone;
#   4. A is installed into a temporary Applications folder, B's zip and the
#      appcast are served from 127.0.0.1;
#   5. A runs as a fresh install: automatic checks are off, so the server must
#      see no request at all;
#   6. A runs with both Settings toggles on (their user-defaults keys): it must
#      find B, verify it, report it ready, and install it when it quits;
#   7. the installed app must be B, with the same designated requirement as A.
#
# Everything is removed afterwards: apps, keychain, certificate, key, the
# test bundle's defaults and caches. Needs OpenSSL 3 (`openssl` on PATH,
# Homebrew's openssl@3, or OPENSSL), python3, and a logged-in GUI session
# (the app is a real menu bar app while it runs, without permissions or an
# event tap).
set -euo pipefail
cd "$(dirname "$0")/.."

# Inner mode, run by with-signing-keychain.sh with the identity available:
#   update-e2e.sh --build-signed <tmp dir> <feed url> <public key>
if [[ "${1:-}" == "--build-signed" ]]; then
    TMP="${2:?tmp dir}"; FEED_URL="${3:?feed url}"; PUBLIC_KEY="${4:?public key}"
    build() { # <version> <build> <destination>
        echo "==> Building ${1} (build ${2})"
        VERSION="$1" BUILD_NUMBER="$2" OPENAPPS_OFFICIAL=1 OPENREACTION_UPDATE_TEST=1 \
            UPDATE_FEED_URL="$FEED_URL" UPDATE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
            scripts/bundle.sh > "$TMP/build-$1.log" 2>&1 || { tail -n 30 "$TMP/build-$1.log" >&2; return 1; }
        rm -rf "$3"
        mkdir -p "$(dirname "$3")"
        ditto build/OpenReaction.app "$3"
    }
    build 1.0.0 1 "$TMP/Applications/OpenReaction.app"
    build 1.0.1 2 "$TMP/B/OpenReaction.app"
    exit 0
fi

if [[ -z "${OPENSSL:-}" ]]; then
    for candidate in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        if "$candidate" version 2>/dev/null | grep -q '^OpenSSL 3'; then OPENSSL="$candidate"; break; fi
    done
    OPENSSL="${OPENSSL:-openssl}"
fi
"$OPENSSL" version | grep -q '^OpenSSL 3' || { echo "error: needs OpenSSL 3 (brew install openssl@3), or set OPENSSL" >&2; exit 1; }
BUNDLE_ID="com.openappshq.openreaction.updatetest"
SCRATCH_PATH="${SCRATCH_PATH:-.build/update-test}"
export SCRATCH_PATH OPENSSL

TMP="$(mktemp -d "${TMPDIR:-/tmp}/openreaction-update-e2e.XXXXXX")"
SERVER_PID=""
APP_PID=""
cleanup() {
    local status=$?
    trap - EXIT
    set +e
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
    pkill -f "$TMP/Applications/OpenReaction.app/Contents/MacOS/OpenReaction" 2>/dev/null
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/Application Support/$BUNDLE_ID" \
        "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$TMP" build/OpenReaction.app
    echo "==> Cleaned up (${TMP}, defaults, caches)"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "==> 1. Throwaway certificate and update key in ${TMP}"
../../scripts/release/create-signing-certificate.sh "$TMP/cert" >/dev/null
scripts/create-update-key.sh "$TMP/update-key" "$TMP/update-key/public.txt" >/dev/null
PUBLIC_KEY="$(head -n 1 "$TMP/update-key/public.txt")"
REQUIREMENT="$(../../scripts/release/designated-requirement.sh "$BUNDLE_ID" "$TMP/cert/release-signing.cert.pem")"
echo "requirement: ${REQUIREMENT}"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
FEED_URL="http://127.0.0.1:${PORT}/appcast.xml"

echo "==> 2. Building A and B, signed with the throwaway certificate"
mkdir -p "$TMP/Applications" "$TMP/serve"
search_list_before="$(security list-keychains -d user)"
RELEASE_SIGNING_P12_FILE="$TMP/cert/release-signing.p12" \
    RELEASE_SIGNING_P12_PASSWORD="$(cat "$TMP/cert/release-signing.p12.password")" \
    ../../scripts/release/with-signing-keychain.sh scripts/update-e2e.sh --build-signed "$TMP" "$FEED_URL" "$PUBLIC_KEY"
search_list_after="$(security list-keychains -d user)"
if [[ "$search_list_before" != "$search_list_after" ]]; then
    echo "error: the keychain search list changed:" >&2
    diff <(printf '%s\n' "$search_list_before") <(printf '%s\n' "$search_list_after") >&2 || true
    exit 1
fi
if security find-identity -p codesigning 2>/dev/null | grep -q 'OpenApps HQ Release'; then
    echo "error: the throwaway signing identity is still available" >&2; exit 1
fi
echo "ok: keychain search list unchanged, identity gone"
for app in "$TMP/Applications/OpenReaction.app" "$TMP/B/OpenReaction.app"; do
    codesign --verify --deep --strict "$app"
    actual="$(codesign --display -r- "$app" 2>/dev/null | sed -n 's/^designated => //p')"
    [[ "$actual" == "$REQUIREMENT" ]] || { echo "error: ${app} has requirement '${actual}'" >&2; exit 1; }
    [[ "$(plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist")" == "$PUBLIC_KEY" ]]
    [[ "$(plutil -extract SUFeedURL raw -o - "$app/Contents/Info.plist")" == "$FEED_URL" ]]
    [[ "$(plutil -extract SUEnableAutomaticChecks raw -o - "$app/Contents/Info.plist")" == false ]]
done
# A wrongly signed app must not satisfy the requirement (the pinned check has teeth).
cp -R "$TMP/B/OpenReaction.app" "$TMP/wrong.app"
codesign --force --sign - "$TMP/wrong.app" 2>/dev/null
if codesign --verify -R="$REQUIREMENT" "$TMP/wrong.app" 2>/dev/null; then
    echo "error: an ad-hoc signed app satisfies the release requirement" >&2; exit 1
fi
echo "ok: A and B carry the requirement; a re-signed app does not"

echo "==> 3. Zip, update-sign and announce B"
(cd "$TMP/B" && ditto -c -k --sequesterRsrc --keepParent OpenReaction.app "$TMP/serve/OpenReaction-1.0.1.zip")
SPARKLE_ED_KEY_FILE="$TMP/update-key/sparkle-ed25519.key" UPDATE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
    DOWNLOAD_URL="http://127.0.0.1:${PORT}/OpenReaction-1.0.1.zip" OUT="$TMP/serve/appcast.xml" \
    scripts/make-appcast.sh "$TMP/serve/OpenReaction-1.0.1.zip"
# A feed signed with another key must be refused by the verifier.
cp "$TMP/serve/appcast.xml" "$TMP/tampered.xml"
sed -i '' 's|<openapps:channel>stable</openapps:channel>|<openapps:channel>stable</openapps:channel><!-- x -->|' "$TMP/tampered.xml"
if UPDATE_PUBLIC_ED_KEY="$PUBLIC_KEY" scripts/verify-appcast.sh "$TMP/tampered.xml" >/dev/null 2>&1; then
    echo "error: a modified feed verified" >&2; exit 1
fi
echo "ok: a modified feed is refused"

echo "==> 4. Serving B from 127.0.0.1:${PORT}"
(cd "$TMP/serve" && python3 -m http.server --bind 127.0.0.1 "$PORT" > "$TMP/server.log" 2>&1) &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -sf -o /dev/null "http://127.0.0.1:${PORT}/appcast.xml" && break; sleep 0.1; done
curl -sf -o /dev/null "http://127.0.0.1:${PORT}/appcast.xml" || { echo "error: the local server did not start" >&2; exit 1; }
# Requests so far are this script's own readiness probes.
probe_requests="$(grep -c '"GET ' "$TMP/server.log" || true)"
requests_since_probes() { tail -n "+$((probe_requests + 1))" "$TMP/server.log" | grep '"GET ' || true; }

APP="$TMP/Applications/OpenReaction.app"
BIN="$APP/Contents/MacOS/OpenReaction"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Caches/$BUNDLE_ID"

echo "==> 5. A fresh install never contacts the feed"
OPENREACTION_DISABLE_TAP=1 "$BIN" > "$TMP/run-fresh.log" 2>&1 &
APP_PID=$!
sleep 8
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
if [[ -n "$(requests_since_probes)" ]]; then
    echo "error: the app requested the feed with automatic checks off:" >&2
    requests_since_probes >&2
    exit 1
fi
if grep -q 'openreaction-update-test: cycle' "$TMP/run-fresh.log"; then
    echo "error: an update cycle ran on a fresh install" >&2; exit 1
fi
if grep -q 'dyld\[' "$TMP/run-fresh.log"; then
    echo "error: A did not launch:" >&2; cat "$TMP/run-fresh.log" >&2; exit 1
fi
echo "ok: no request, no update cycle"

echo "==> 6. With both toggles on, A finds B and installs it on quit"
defaults write "$BUNDLE_ID" SUEnableAutomaticChecks -bool true
defaults write "$BUNDLE_ID" SUAutomaticallyUpdate -bool true
OPENREACTION_DISABLE_TAP=1 OPENREACTION_UPDATE_TEST_ACTION=quit "$BIN" > "$TMP/run-update.log" 2>&1 &
APP_PID=$!
for _ in $(seq 1 120); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
    sleep 1
done
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "error: A did not quit within 2 minutes; its log:" >&2
    cat "$TMP/run-update.log" >&2
    exit 1
fi
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
grep -q 'openreaction-update-test: ready' "$TMP/run-update.log" || { echo "error: A never reported the update ready:" >&2; cat "$TMP/run-update.log" >&2; exit 1; }
if ! requests_since_probes | grep -q '"GET /appcast.xml' || ! requests_since_probes | grep -q '"GET /OpenReaction-1.0.1.zip'; then
    echo "error: the feed or the zip was not fetched:" >&2; cat "$TMP/server.log" >&2; exit 1
fi

echo "==> 7. The installed app is B with A's designated requirement"
installed=""
for _ in $(seq 1 60); do
    installed="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$installed" == "1.0.1" ]] && break
    sleep 1
done
[[ "$installed" == "1.0.1" ]] || { echo "error: installed version is '${installed}', not 1.0.1" >&2; exit 1; }
sleep 2 # the installer's last file operations
pkill -f "$BIN" 2>/dev/null || true
[[ "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" == 2 ]]
codesign --verify --deep --strict "$APP"
after="$(codesign --display -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
[[ "$after" == "$REQUIREMENT" ]] || { echo "error: the installed app's requirement changed to '${after}'" >&2; exit 1; }
echo "ok: 1.0.0 → 1.0.1 installed on quit; requirement unchanged"
echo "==> Update end-to-end test passed"
