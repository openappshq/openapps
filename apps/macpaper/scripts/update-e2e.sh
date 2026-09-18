#!/usr/bin/env bash
# The local dry run of the whole update path (RELEASES.md, "Build and test
# locally"), with no secrets and no network beyond 127.0.0.1:
#
#   scripts/update-e2e.sh
#
#   1. a throwaway signing certificate and update key go into a temporary
#      directory;
#   2. version A (1.0.0) and version B (1.0.1) are built as
#      the update-test variant (bundle id com.openappshq.macpaper.updatetest,
#      no URL scheme, no login item, no setup guide, feed on 127.0.0.1)
#      inside scripts/release/with-signing-keychain.sh,
#      which holds the certificate in a temporary keychain (never the login
#      keychain) and removes it again; the keychain search list must be
#      identical before and after; both apps pin the throwaway public key;
#   3. B is zipped, update-signed, and announced by a signed appcast, all
#      verified with the public key alone;
#   4. A is installed into a temporary Applications folder, B's zip and the
#      appcast are served from 127.0.0.1;
#   5. A runs with nothing stored, as a fresh install: the update-test variant
#      compiles licensing out (always; the E2E sets OPENAPPS_LICENSING=0 and
#      bundle.sh refuses the combination), so there is no record store to wait for and
#      the fresh-install default applies at once — "Check for updates
#      automatically" turns on and is recorded as decided, the launch check
#      finds B and reports it available, and nothing is downloaded (installing
#      stays opt-in). Then A runs as an upgrade whose user had turned checks
#      off (the toggle stored as off): the default is recorded without
#      changing it, and the server must see no request at all;
#   6. A runs with both Settings toggles on (their user-defaults keys) and
#      turns "install automatically" off again mid-download, then once more
#      after staging: neither run may install anything or leave a staged copy;
#   7. A runs with both toggles on: it must find B, verify it, report it
#      staged, and install it when it quits;
#   8. the installed app must be B, with the same designated requirement as A;
#   9. A is put back and "Restart to Update" is taken: the install goes
#      through the quit path and the app reopens as B.
#
# Everything is removed afterwards: apps, keychain, certificate, key, the
# test bundle's defaults, caches and its own Application Support folder
# (OpenApps/macpaper-updatetest; the variant never touches the real app's).
# Needs OpenSSL 3 (`openssl` on PATH, Homebrew's openssl@3, or OPENSSL),
# python3, and a logged-in GUI session (the app is a real menu bar app while
# it runs: a status item; it applies nothing to any desktop, and asks for
# no permission).
set -euo pipefail
cd "$(dirname "$0")/.."

# Inner mode, run by with-signing-keychain.sh with the identity available:
#   update-e2e.sh --build-signed <tmp dir> <feed url> <public key>
if [[ "${1:-}" == "--build-signed" ]]; then
    TMP="${2:?tmp dir}"; FEED_URL="${3:?feed url}"; PUBLIC_KEY="${4:?public key}"
    build() { # <version> <destination>
        echo "==> Building ${1}"
        # Licensing explicitly off, whatever the shell inherited from an
        # earlier rehearsal: the test variant must never link the record
        # store, the registry or Dodo's client (bundle.sh refuses the
        # combination anyway).
        VERSION="$1" OPENAPPS_LICENSING=0 OPENAPPS_OFFICIAL=1 MACPAPER_UPDATE_TEST=1 \
            UPDATE_FEED_URL="$FEED_URL" UPDATE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
            scripts/bundle.sh > "$TMP/build-$1.log" 2>&1 || { tail -n 30 "$TMP/build-$1.log" >&2; return 1; }
        rm -rf "$2"
        mkdir -p "$(dirname "$2")"
        ditto build/macPaper.app "$2"
    }
    build 1.0.0 "$TMP/Applications/macPaper.app"
    build 1.0.1 "$TMP/B/macPaper.app"
    exit 0
fi

if [[ -z "${OPENSSL:-}" ]]; then
    for candidate in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        if "$candidate" version 2>/dev/null | grep -q '^OpenSSL 3'; then OPENSSL="$candidate"; break; fi
    done
    OPENSSL="${OPENSSL:-openssl}"
fi
"$OPENSSL" version | grep -q '^OpenSSL 3' || { echo "error: needs OpenSSL 3 (brew install openssl@3), or set OPENSSL" >&2; exit 1; }
BUNDLE_ID="com.openappshq.macpaper.updatetest"
SCRATCH_PATH="${SCRATCH_PATH:-.build/update-test}"
export SCRATCH_PATH OPENSSL

if pgrep -f "macpaper-update-e2e\..*/macPaper\.app/Contents/MacOS/macPaper" >/dev/null; then
    echo "error: an update-test app from an earlier run is still running; quit it first (pkill -f macpaper-update-e2e)" >&2
    exit 1
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macpaper-update-e2e.XXXXXX")"
# Canonical: a reopened app reports its real path, which pgrep must match.
TMP="$(cd "$TMP" && pwd -P)"
SERVER_PID=""
APP_PID=""
cleanup() {
    local status=$?
    trap - EXIT
    set +e
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
    # Any instance of the test bundle, from this run or an earlier one: a
    # stale one would catch `open` by bundle id and break the restart step.
    pkill -f "macpaper-update-e2e\..*/macPaper\.app/Contents/MacOS/macPaper" 2>/dev/null
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    # `defaults delete` leaves the emptied domain behind as an empty plist;
    # delete that too.
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/Application Support/$BUNDLE_ID" \
        "$HOME/Library/Application Support/OpenApps/macpaper-updatetest" \
        "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$TMP" build/macPaper.app build/macPaper.saver
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
mkdir -p "$TMP/Applications" "$TMP/serve" "$TMP/A"
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
for app in "$TMP/Applications/macPaper.app" "$TMP/B/macPaper.app"; do
    codesign --verify --deep --strict "$app"
    actual="$(codesign --display -r- "$app" 2>/dev/null | sed -n 's/^designated => //p')"
    [[ "$actual" == "$REQUIREMENT" ]] || { echo "error: ${app} has requirement '${actual}'" >&2; exit 1; }
    [[ "$(plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist")" == "$PUBLIC_KEY" ]]
    [[ "$(plutil -extract SUFeedURL raw -o - "$app/Contents/Info.plist")" == "$FEED_URL" ]]
    test ! -d "$app/Contents/Frameworks"
done
[[ "$(plutil -extract CFBundleVersion raw -o - "$TMP/Applications/macPaper.app/Contents/Info.plist")" == 1000000 ]]
[[ "$(plutil -extract CFBundleVersion raw -o - "$TMP/B/macPaper.app/Contents/Info.plist")" == 1000001 ]]
# A wrongly signed app must not satisfy the requirement (the pinned check has teeth).
cp -R "$TMP/B/macPaper.app" "$TMP/wrong.app"
codesign --force --sign - "$TMP/wrong.app" 2>/dev/null
if codesign --verify -R="$REQUIREMENT" "$TMP/wrong.app" 2>/dev/null; then
    echo "error: an ad-hoc signed app satisfies the release requirement" >&2; exit 1
fi
echo "ok: A and B carry the requirement; a re-signed app does not"
ditto "$TMP/Applications/macPaper.app" "$TMP/A/macPaper.app"

echo "==> 3. Zip, update-sign and announce B"
(cd "$TMP/B" && ditto -c -k --sequesterRsrc --keepParent macPaper.app "$TMP/serve/macPaper-1.0.1.zip")
SPARKLE_ED_KEY_FILE="$TMP/update-key/sparkle-ed25519.key" UPDATE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
    DOWNLOAD_URL="http://127.0.0.1:${PORT}/macPaper-1.0.1.zip" OUT="$TMP/serve/appcast.xml" \
    scripts/make-appcast.sh "$TMP/serve/macPaper-1.0.1.zip"
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

APP="$TMP/Applications/macPaper.app"
BIN="$APP/Contents/MacOS/macPaper"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Caches/$BUNDLE_ID"

run_app() { # <log> <action>: runs A until it quits by itself (or 2 minutes pass)
    # Each run is a fresh day: the last check is what makes a launch check due.
    defaults delete "$BUNDLE_ID" OpenAppsUpdater.lastCheck >/dev/null 2>&1 || true
    MACPAPER_UPDATE_TEST_ACTION="$2" "$BIN" > "$1" 2>&1 &
    APP_PID=$!
    for _ in $(seq 1 120); do
        if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
        sleep 1
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
        echo "error: A did not quit within 2 minutes; its log:" >&2
        cat "$1" >&2
        echo "--- main thread:" >&2
        sample "$APP_PID" 1 2>/dev/null | sed -n '/Call graph/,/Total number/p' | head -60 >&2
        exit 1
    fi
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
}
still_1_0_0() { # <label>
    local version
    version="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
    [[ "$version" == "1.0.0" ]] || { echo "error ($1): the installed app changed to ${version}" >&2; exit 1; }
    if [[ -e "$TMP/Applications/.macPaper.app.update" ]]; then
        echo "error ($1): a staged update was left behind" >&2; exit 1
    fi
}

echo "==> 5. A fresh install turns automatic checks on, finds B, downloads nothing; an upgrade with checks off never asks"
# Nothing stored and no licensing (no record store to wait for): the
# fresh-install default resolves at launch (RELEASES.md, "In-app updater").
run_app "$TMP/run-fresh.log" quit-after-check
if grep -q 'dyld\[' "$TMP/run-fresh.log"; then
    echo "error: A did not launch:" >&2; cat "$TMP/run-fresh.log" >&2; exit 1
fi
grep -q 'macpaper-update-test: available 1.0.1' "$TMP/run-fresh.log" || { echo "error: the fresh install did not find 1.0.1:" >&2; cat "$TMP/run-fresh.log" >&2; exit 1; }
grep -q 'macpaper-update-test: cycle-finished ok' "$TMP/run-fresh.log" || { echo "error: the launch check did not finish cleanly:" >&2; cat "$TMP/run-fresh.log" >&2; exit 1; }
if grep -q 'macpaper-update-test: downloading\|macpaper-update-test: staged' "$TMP/run-fresh.log"; then
    echo "error: a fresh install downloaded an update without consent" >&2; exit 1
fi
requests_since_probes | grep -q '"GET /appcast.xml' || { echo "error: the fresh install never fetched the feed:" >&2; cat "$TMP/server.log" >&2; exit 1; }
if requests_since_probes | grep -q '"GET /macPaper-1.0.1.zip'; then
    echo "error: the fresh install fetched the zip with installing off" >&2; exit 1
fi
[[ "$(defaults read "$BUNDLE_ID" OpenAppsUpdater.checkAutomatically 2>/dev/null)" == 1 ]] || { echo "error: the check toggle was not turned on" >&2; exit 1; }
[[ "$(defaults read "$BUNDLE_ID" updates.checkDefaultApplied 2>/dev/null)" == 1 ]] || { echo "error: the default was not recorded as decided" >&2; exit 1; }
[[ "$(defaults read "$BUNDLE_ID" OpenAppsUpdater.installAutomatically 2>/dev/null || echo 0)" != 1 ]] || { echo "error: installing turned itself on" >&2; exit 1; }
still_1_0_0 "fresh install"
echo "ok: checks on by default, 1.0.1 found, nothing downloaded"
# An upgrade: a user who turned checks off under an earlier version. The
# stored toggle is a preference, so the default records itself and leaves it.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" OpenAppsUpdater.checkAutomatically -bool false
probe_requests="$(grep -c '"GET ' "$TMP/server.log" || true)"
"$BIN" > "$TMP/run-upgrade.log" 2>&1 &
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
if grep -q 'macpaper-update-test: cycle' "$TMP/run-upgrade.log"; then
    echo "error: an update cycle ran with automatic checks off" >&2; exit 1
fi
[[ "$(defaults read "$BUNDLE_ID" OpenAppsUpdater.checkAutomatically 2>/dev/null)" == 0 ]] || { echo "error: the upgrade's toggle was changed" >&2; exit 1; }
[[ "$(defaults read "$BUNDLE_ID" updates.checkDefaultApplied 2>/dev/null)" == 1 ]] || { echo "error: the default was not recorded for the upgrade" >&2; exit 1; }
echo "ok: an explicit off is left alone, no request"

defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" OpenAppsUpdater.checkAutomatically -bool true
defaults write "$BUNDLE_ID" OpenAppsUpdater.installAutomatically -bool true

echo "==> 6. Turning \"install automatically\" off withdraws a download and a staged update"
run_app "$TMP/run-revoke-download.log" revoke-during-download
grep -q 'macpaper-update-test: revoked-during-download' "$TMP/run-revoke-download.log" \
    || { echo "error: the download was never revoked:" >&2; cat "$TMP/run-revoke-download.log" >&2; exit 1; }
grep -q 'macpaper-update-test: staged' "$TMP/run-revoke-download.log" && { echo "error: the update was staged after the revocation" >&2; exit 1; }
still_1_0_0 "revoked during download"
echo "ok: revoked mid-download, nothing installed"
# The toggle is off now (the app saved it); turn it back on for the next run.
defaults write "$BUNDLE_ID" OpenAppsUpdater.installAutomatically -bool true
run_app "$TMP/run-revoke-staged.log" revoke-after-staged
grep -q 'macpaper-update-test: staged' "$TMP/run-revoke-staged.log" || { echo "error: the update was never staged:" >&2; cat "$TMP/run-revoke-staged.log" >&2; exit 1; }
grep -q 'macpaper-update-test: revoked-after-staged' "$TMP/run-revoke-staged.log" || { echo "error: the staged update was never revoked" >&2; exit 1; }
still_1_0_0 "revoked after staging"
echo "ok: revoked after staging, nothing installed"
defaults write "$BUNDLE_ID" OpenAppsUpdater.installAutomatically -bool true

echo "==> 7. With both toggles on, A finds B and installs it on quit"
run_app "$TMP/run-update.log" quit
grep -q 'macpaper-update-test: ready 1.0.1' "$TMP/run-update.log" || { echo "error: A never reported the update ready:" >&2; cat "$TMP/run-update.log" >&2; exit 1; }
if ! requests_since_probes | grep -q '"GET /appcast.xml' || ! requests_since_probes | grep -q '"GET /macPaper-1.0.1.zip'; then
    echo "error: the feed or the zip was not fetched:" >&2; cat "$TMP/server.log" >&2; exit 1
fi

echo "==> 8. The installed app is B with A's designated requirement"
installed=""
for _ in $(seq 1 60); do
    installed="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$installed" == "1.0.1" ]] && break
    sleep 1
done
[[ "$installed" == "1.0.1" ]] || { echo "error: installed version is '${installed}', not 1.0.1" >&2; exit 1; }
sleep 2 # the installer's last file operations
pkill -f "$BIN" 2>/dev/null || true
[[ "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" == 1000001 ]]
test ! -e "$TMP/Applications/.macPaper.app.update"
test ! -e "$TMP/Applications/.macPaper.app.previous"
codesign --verify --deep --strict "$APP"
after="$(codesign --display -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
[[ "$after" == "$REQUIREMENT" ]] || { echo "error: the installed app's requirement changed to '${after}'" >&2; exit 1; }
echo "ok: 1.0.0 → 1.0.1 installed on quit; requirement unchanged"

echo "==> 9. Restart to Update installs through the quit path and reopens the app"
rm -rf "$APP"
ditto "$TMP/A/macPaper.app" "$APP"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" == "1.0.0" ]]
run_app "$TMP/run-restart.log" restart
grep -q 'macpaper-update-test: ready 1.0.1' "$TMP/run-restart.log" || { echo "error: no update staged before the restart:" >&2; cat "$TMP/run-restart.log" >&2; exit 1; }
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" == "1.0.1" ]] || { echo "error: the restart did not install 1.0.1" >&2; exit 1; }
relaunched=""
for _ in $(seq 1 30); do
    if pgrep -f "$BIN" >/dev/null; then relaunched=1; break; fi
    sleep 1
done
[[ -n "$relaunched" ]] || { echo "error: the app was not reopened after the restart:" >&2; cat "$TMP/run-restart.log" >&2; exit 1; }
pkill -f "$BIN" 2>/dev/null || true
sleep 1
test ! -e "$TMP/Applications/.macPaper.app.update"
echo "ok: restarted into 1.0.1"
echo "==> Update end-to-end test passed"
