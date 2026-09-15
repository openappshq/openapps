#!/usr/bin/env bash
# The release's local dry run (RELEASES.md, "Build and test locally"): no
# secrets, no network beyond 127.0.0.1, nothing left behind.
#
#   apps/openklack-desktop/release/test-update-locally.sh
#
# In a temporary folder it creates a throwaway signing certificate and a
# throwaway update key, builds two debug apps (A = the checked-in version,
# B = the next patch) signed with that certificate and verified against the
# certificate's designated requirement, installs A into a private Applications
# folder, packages B and a signed feed exactly as the release does, serves
# them from 127.0.0.1, and runs A twice with the dev-only feed override
# (compiled out of release builds), a private HOME and no input listener:
#
#   1. fresh install: automatic checks are off, so A must make no request;
#   2. with both automatic settings on: A must find B, verify and stage it,
#      quit, and install it on the way out, so the installed app is B with the
#      same designated requirement as A.
#
# Real permissions are never requested, the login keychain is never touched,
# and everything (apps, keychain, certificate, key) is removed on exit. Set
# KEEP=1 to keep the working folder for inspection.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SCRIPTS="$ROOT/../../scripts/release"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/openklack-update-test.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
SERVER_PID=""
APP_PID=""
BUNDLE_ID=com.openklack.desktop
VERSION_A="$(node -p 'JSON.parse(require("fs").readFileSync("src-tauri/tauri.conf.json","utf8")).version')"
# shellcheck disable=SC2016  # JavaScript template literal
VERSION_B="$(node -p 'const [a,b,c]=process.argv[1].split(".").map(Number); `${a}.${b}.${c+1}`' "$VERSION_A")"

cleanup() {
    local status=$?
    trap - EXIT
    [[ -z "$APP_PID" ]] || kill "$APP_PID" 2>/dev/null || true
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    if [[ "${KEEP:-0}" == 1 ]]; then
        echo "kept $WORK"
    else
        rm -rf "$WORK"
    fi
    if [[ $status -eq 0 ]]; then echo "ok: local update test passed"; else echo "FAILED (status $status)" >&2; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

step() { printf '\n==> %s\n' "$*"; }

step "Throwaway signing certificate and update key in $WORK"
"$SCRIPTS/create-signing-certificate.sh" "$WORK/cert" >/dev/null
"$SCRIPTS/designated-requirement.sh" "$BUNDLE_ID" "$WORK/cert/release-signing.cert.pem" > "$WORK/designated-requirement.txt"
cat "$WORK/designated-requirement.txt"
node_modules/.bin/tauri signer generate --ci -p "" -w "$WORK/update.key" >/dev/null 2>&1
PUBLIC_KEY="$(tr -d '\n' < "$WORK/update.key.pub")"
export TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD=""
TAURI_SIGNING_PRIVATE_KEY="$(cat "$WORK/update.key")"
export RELEASE_SIGNING_P12_FILE="$WORK/cert/release-signing.p12"
RELEASE_SIGNING_P12_PASSWORD="$(cat "$WORK/cert/release-signing.p12.password")"
export RELEASE_SIGNING_P12_PASSWORD

build() {
    local version="$1" out="$WORK/build-$1" overlay="$WORK/tauri-$1.json"
    step "Building OpenKlack $version, signed with the throwaway certificate"
    node release/updater-config.mjs "$overlay" "$version" "$WORK/update.key.pub"
    # shellcheck disable=SC2016  # expanded by the inner shell, inside the keychain wrapper
    "$SCRIPTS/with-signing-keychain.sh" sh -c '
        APPLE_SIGNING_IDENTITY="$RELEASE_SIGNING_IDENTITY" node_modules/.bin/tauri build --debug --config "$1" --bundles app --features updater >"$2" 2>&1
    ' _ "$overlay" "$WORK/build-$version.log" || { tail -40 "$WORK/build-$version.log"; return 1; }
    local bundle=src-tauri/target/debug/bundle/macos
    "$SCRIPTS/verify-designated-requirement.sh" "$bundle/OpenKlack.app" "$WORK/designated-requirement.txt"
    mkdir -p "$out"
    ditto "$bundle/OpenKlack.app" "$out/OpenKlack.app"
    cp "$bundle/OpenKlack.app.tar.gz" "$bundle/OpenKlack.app.tar.gz.sig" "$out/"
}
build "$VERSION_A"
build "$VERSION_B"
if security find-identity -p codesigning 2>/dev/null | grep -q 'OpenApps HQ Release'; then
    echo "error: the throwaway identity is still in a keychain" >&2; exit 1
fi

step "Packaging $VERSION_B and its signed feed"
release/package.sh "$WORK/build-$VERSION_B" "$VERSION_B" "$WORK/dist" "$WORK/update.key.pub"
SHA256="$(cut -d' ' -f1 "$WORK/dist/OpenKlack-$VERSION_B.zip.sha256")"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
ORIGIN="http://127.0.0.1:$PORT"
mkdir -p "$WORK/www/releases/download/openklack-v$VERSION_B" "$WORK/www/updates/openklack"
cp "$WORK/dist/"* "$WORK/www/releases/download/openklack-v$VERSION_B/"
DOWNLOADS="$ORIGIN/releases/download/" release/write-feed.sh "$VERSION_B" "$WORK/dist" "$WORK/www/updates/openklack"
node release/verify-update-signature.mjs "$WORK/www/updates/openklack/latest.json" "$WORK/www/updates/openklack/latest.json.sig" "$WORK/update.key.pub"

step "Serving the release from $ORIGIN"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -sf "$ORIGIN/updates/openklack/latest.json" >/dev/null && break; sleep 0.2; done
FEED_URL="$ORIGIN/updates/openklack/latest.json" DOWNLOADS="$ORIGIN/releases/download/" \
    release/verify-live.sh "$VERSION_B" "$SHA256" "$WORK/update.key.pub"
: > "$WORK/server.log"

step "Installing $VERSION_A into a private Applications folder"
mkdir -p "$WORK/Applications" "$WORK/home"
ditto "$WORK/build-$VERSION_A/OpenKlack.app" "$WORK/Applications/OpenKlack.app"
INSTALLED="$WORK/Applications/OpenKlack.app"
DR_A="$(codesign --display --requirements - "$INSTALLED" 2>&1 | sed -n 's/^designated => //p')"
DATA="$WORK/home/Library/Application Support/$BUNDLE_ID"
mkdir -p "$DATA"

run_app() {
    # A private HOME keeps settings and the updates file out of the real
    # account; --no-input-listener (debug builds only) never starts the
    # global key listener or asks for Input Monitoring.
    HOME="$WORK/home" \
    OPENKLACK_DEV_UPDATE_FEED="$ORIGIN/updates/openklack/latest.json" \
    OPENKLACK_DEV_UPDATE_PUBLIC_KEY="$PUBLIC_KEY" \
    OPENKLACK_DEV_UPDATE_DOWNLOADS="$ORIGIN/releases/download/" \
    "$@" "$INSTALLED/Contents/MacOS/openklack-desktop" --background --no-input-listener
}

step "1. A fresh install makes no request to the feed"
run_app env > "$WORK/app-fresh.log" 2>&1 &
APP_PID=$!
sleep 10
kill "$APP_PID"; wait "$APP_PID" 2>/dev/null || true
APP_PID=""
if grep -q '"GET' "$WORK/server.log"; then
    echo "error: a fresh install contacted the feed:" >&2; cat "$WORK/server.log" >&2; exit 1
fi
echo "ok: no requests"
test ! -e "$DATA/updates.json"

step "2. With automatic checks and installs on, A updates itself to $VERSION_B on quit"
printf '{"settings":{"checkAutomatically":true,"installAutomatically":true}}\n' > "$DATA/updates.json"
run_app env OPENKLACK_DEV_QUIT_WHEN_UPDATE_READY=1 > "$WORK/app-update.log" 2>&1 &
APP_PID=$!
for _ in $(seq 1 180); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "error: the app did not quit after staging the update" >&2
    cat "$WORK/server.log" "$WORK/app-update.log" >&2
    exit 1
fi
wait "$APP_PID" || true
APP_PID=""
cat "$WORK/app-update.log"
grep -q 'installed the staged update' "$WORK/app-update.log"
for path in "/updates/openklack/latest.json" "/updates/openklack/latest.json.sig" "/releases/download/openklack-v$VERSION_B/OpenKlack-$VERSION_B.app.tar.gz"; do
    grep -Fq "\"GET $path HTTP" "$WORK/server.log" || { echo "error: $path was never fetched" >&2; cat "$WORK/server.log" >&2; exit 1; }
done
if grep -Fq "OpenKlack-$VERSION_B.zip HTTP" "$WORK/server.log"; then
    echo "error: the app fetched the cask's zip instead of the update archive" >&2; exit 1
fi
installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist")"
[[ "$installed_version" == "$VERSION_B" ]] || { echo "error: installed app is $installed_version, not $VERSION_B" >&2; exit 1; }
"$SCRIPTS/verify-designated-requirement.sh" "$INSTALLED" "$WORK/designated-requirement.txt"
DR_B="$(codesign --display --requirements - "$INSTALLED" 2>&1 | sed -n 's/^designated => //p')"
[[ "$DR_A" == "$DR_B" ]] || { echo "error: designated requirement changed: $DR_A -> $DR_B" >&2; exit 1; }
echo "ok: $INSTALLED is $VERSION_B with the designated requirement of $VERSION_A"
node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(!s.history?.lastSuccessAt) throw new Error("history not saved")' "$DATA/updates.json"
test -z "$(ls -A "$DATA/updates" 2>/dev/null)" || { echo "error: staged archive left behind" >&2; exit 1; }

step "3. The installed $VERSION_B starts"
: > "$WORK/server.log"
run_app env > "$WORK/app-b.log" 2>&1 &
APP_PID=$!
sleep 5
kill -0 "$APP_PID" || { echo "error: $VERSION_B exited early" >&2; cat "$WORK/app-b.log" >&2; exit 1; }
kill "$APP_PID"; wait "$APP_PID" 2>/dev/null || true
APP_PID=""
# B checks at launch (automatic checks are on) and finds nothing newer.
grep -Fq '"GET /updates/openklack/latest.json HTTP' "$WORK/server.log"
echo "ok: $VERSION_B runs and finds no newer release"
