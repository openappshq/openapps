#!/usr/bin/env bash
# The install script (write-install-script.sh) against a throwaway zip served
# from 127.0.0.1: a wrong digest aborts before anything is unpacked, a good one
# installs, clears quarantine and opens the app, an existing copy is replaced
# in place, a running copy is asked to quit, and a script cut short runs
# nothing. Everything lands in a temporary directory; `open`, `osascript` and
# `pgrep` are stubs, so no app is ever started or quit on this Mac.
# INSTALL_SH (default `sh`, bash on macOS) is the shell the script runs under;
# `INSTALL_SH=/bin/dash`, or a `sh` symlink to zsh, checks the POSIX subset.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

app=OpenKlack
version=0.1.0
serve="$work/serve/openklack-v$version"
mkdir -p "$serve" "$work/bin" "$work/tmp"

# A dummy bundle with quarantine on its files, as a zip saved by a browser
# would carry it; the zip gets the attribute too, though HTTP does not carry it.
mkdir -p "$work/$app.app/Contents/MacOS"
printf '<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>\n' "$version" > "$work/$app.app/Contents/Info.plist"
printf '#!/bin/sh\nexit 0\n' > "$work/$app.app/Contents/MacOS/$app"
chmod +x "$work/$app.app/Contents/MacOS/$app"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$work/$app.app/Contents/MacOS/$app" "$work/$app.app/Contents/Info.plist"
ditto -c -k --keepParent "$work/$app.app" "$serve/$app-$version.zip"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$serve/$app-$version.zip"
good="$(shasum -a 256 "$serve/$app-$version.zip" | cut -d' ' -f1)"
bad="$(printf 'b%.0s' $(seq 1 64))"

# Stubs: open and osascript only record their arguments; pgrep reports a
# running copy for the first calls of a case that asks for one; ditto records
# its arguments and then does the real work.
cat > "$work/bin/open" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG/open"
EOF
cat > "$work/bin/osascript" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG/osascript"
EOF
cat > "$work/bin/pgrep" <<'EOF'
#!/bin/sh
count=0
[ -f "$STUB_LOG/pgrep" ] && count="$(cat "$STUB_LOG/pgrep")"
count=$((count + 1))
printf '%s' "$count" > "$STUB_LOG/pgrep"
[ "$count" -le "${STUB_RUNNING_CALLS:-0}" ]
EOF
cat > "$work/bin/ditto" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG/ditto"
exec /usr/bin/ditto "$@"
EOF
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH"
export TMPDIR="$work/tmp"

python3 -u -m http.server --bind 127.0.0.1 --directory "$work/serve" 0 > "$work/server.log" 2>&1 &
server_pid=$!
disown
port=""
for _ in $(seq 1 50); do
    port="$(sed -nE 's/.*port ([0-9]+).*/\1/p' "$work/server.log" | head -n 1)"
    [[ -n "$port" ]] && break
    sleep 0.1
done
[[ -n "$port" ]] || { echo "error: the test server did not start" >&2; cat "$work/server.log" >&2; exit 1; }
export OPENAPPS_RELEASE_DOWNLOADS="http://127.0.0.1:$port/"

./write-install-script.sh openklack "$app" "$version" "$good" "$work/install-good"
./write-install-script.sh openklack "$app" "$version" "$bad" "$work/install-bad"
if command -v shellcheck >/dev/null; then shellcheck -s sh "$work/install-good"; fi
grep -q "^main </dev/null$" "$work/install-good"
[[ "$(tail -n 1 "$work/install-good")" == "main </dev/null" ]] || { echo "error: main must be the last line" >&2; exit 1; }
[[ "$(grep -c '^main' "$work/install-good")" == 1 ]]

requests() { grep -c "GET /openklack-v$version/$app-$version.zip" "$work/server.log" || true; }
# Runs one case the way `curl … | sh` does: the script on stdin, its own env.
run_case() {
    name="$1"; script="$2"; shift 2
    export STUB_LOG="$work/log-$name"
    mkdir -p "$STUB_LOG"
    export OPENAPPS_INSTALL_DIR="$work/dest-$name"
    set +e
    env "$@" "${INSTALL_SH:-sh}" < "$script" > "$STUB_LOG/stdout" 2> "$STUB_LOG/stderr"
    status=$?
    set -e
}
no_leftovers() {
    if find "$work/dest-$1" "$work/tmp" -mindepth 1 -maxdepth 1 -name ".$app.*" -o -mindepth 1 -maxdepth 1 -name "openklack-install.*" | grep -q .; then
        echo "error ($1): temporary files were left behind:" >&2
        find "$work/dest-$1" "$work/tmp" -mindepth 1 -maxdepth 1 >&2
        exit 1
    fi
}

# 1. A wrong digest: deleted, nothing unpacked, nothing installed, exit 1.
before="$(requests)"
run_case mismatch "$work/install-bad" STUB_RUNNING_CALLS=0
[[ "$status" == 1 ]] || { echo "error (mismatch): exit $status, expected 1" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
grep -q "does not match the release pinned in this script" "$STUB_LOG/stderr"
grep -q "nothing was installed" "$STUB_LOG/stderr"
[[ "$(requests)" == $((before + 1)) ]]
[[ ! -e "$work/dest-mismatch/$app.app" ]]
[[ ! -f "$STUB_LOG/ditto" ]] || { echo "error (mismatch): ditto ran after a digest mismatch:" >&2; cat "$STUB_LOG/ditto" >&2; exit 1; }
[[ ! -f "$STUB_LOG/open" ]]
no_leftovers mismatch
echo "ok: a digest mismatch aborts before anything is unpacked"

# 2. A good download: installed, quarantine gone, opened, temporary files gone.
run_case fresh "$work/install-good" STUB_RUNNING_CALLS=0
[[ "$status" == 0 ]] || { echo "error (fresh): exit $status" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
[[ -f "$work/dest-fresh/$app.app/Contents/Info.plist" ]]
[[ -x "$work/dest-fresh/$app.app/Contents/MacOS/$app" ]]
if xattr -lr "$work/dest-fresh/$app.app" | grep -q com.apple.quarantine; then
    echo "error (fresh): the installed app is still quarantined" >&2; exit 1
fi
grep -q -- "-xk " "$STUB_LOG/ditto"
[[ "$(cat "$STUB_LOG/open")" == "-a $work/dest-fresh/$app.app" ]]
[[ ! -f "$STUB_LOG/osascript" ]]
grep -q "Checked the download: SHA-256 matches" "$STUB_LOG/stdout"
grep -q "Installed $app $version to $work/dest-fresh/$app.app" "$STUB_LOG/stdout"
grep -q "checks for updates itself" "$STUB_LOG/stdout"
[[ ! -s "$STUB_LOG/stderr" ]] || { echo "error (fresh): unexpected stderr:" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
no_leftovers fresh
echo "ok: a good download installs, clears quarantine and opens the app"

# 3. An existing copy is replaced: the new bundle is in place, the old one gone.
mkdir -p "$work/dest-replace/$app.app/Contents"
printf 'old\n' > "$work/dest-replace/$app.app/Contents/marker"
run_case replace "$work/install-good" STUB_RUNNING_CALLS=0
[[ "$status" == 0 ]] || { echo "error (replace): exit $status" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
[[ -f "$work/dest-replace/$app.app/Contents/Info.plist" ]]
[[ ! -e "$work/dest-replace/$app.app/Contents/marker" ]]
[[ "$(find "$work/dest-replace" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 1 ]]
no_leftovers replace
echo "ok: an existing copy is replaced and nothing else is left in the folder"

# 4. A running copy is asked to quit by bundle id, then the install goes on.
run_case running "$work/install-good" STUB_RUNNING_CALLS=3
[[ "$status" == 0 ]] || { echo "error (running): exit $status" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
[[ "$(cat "$STUB_LOG/osascript")" == '-e quit app id "com.openklack.desktop"' ]]
grep -q "Quitting the running $app" "$STUB_LOG/stdout"
[[ -f "$work/dest-running/$app.app/Contents/Info.plist" ]]
echo "ok: a running copy is asked to quit, then replaced"

# 5. A script cut short runs nothing: neither a complete prefix without the
#    final call nor one cut inside a function downloads, installs or opens.
before="$(requests)"
sed '$d' "$work/install-good" > "$work/install-no-main"
run_case no-main "$work/install-no-main" STUB_RUNNING_CALLS=0
[[ "$status" == 0 ]]
head -n "$(( $(wc -l < "$work/install-good") / 2 ))" "$work/install-good" > "$work/install-half"
run_case half "$work/install-half" STUB_RUNNING_CALLS=0
[[ "$status" != 0 ]]
[[ "$(requests)" == "$before" ]] || { echo "error: a truncated script downloaded the zip" >&2; exit 1; }
[[ ! -e "$work/dest-no-main" && ! -e "$work/dest-half" ]]
[[ ! -f "$work/log-no-main/open" && ! -f "$work/log-half/open" ]]
[[ -z "$(ls -A "$work/tmp")" ]]
echo "ok: a truncated script runs nothing"

# 6. The generator only ever advances a served script.
a="$(printf 'a%.0s' $(seq 1 64))"
out="$work/pinned"
./write-install-script.sh hertz Hertz 0.2.0 "$a" "$out" >/dev/null
grep -q "^VERSION='0.2.0'$" "$out"
if ./write-install-script.sh hertz Hertz 0.1.9 "$a" "$out" 2>/dev/null; then echo "error: downgrade accepted" >&2; exit 1; fi
if ./write-install-script.sh hertz Hertz 0.2.0 "$bad" "$out" 2>/dev/null; then echo "error: rewrite accepted" >&2; exit 1; fi
./write-install-script.sh hertz Hertz 0.2.0 "$a" "$out" >/dev/null
./write-install-script.sh hertz Hertz 0.2.1 "$bad" "$out" >/dev/null
grep -q "^VERSION='0.2.1'$" "$out"
grep -q "^SHA256='$bad'$" "$out"
grep -q "^URL='http://127.0.0.1:$port/hertz-v0.2.1/Hertz-0.2.1.zip'$" "$out"
if ./write-install-script.sh notanapp NotAnApp 0.1.0 "$a" "$work/unknown" 2>/dev/null; then echo "error: unknown app accepted" >&2; exit 1; fi
if OPENAPPS_RELEASE_DOWNLOADS="http://example.com/" ./write-install-script.sh hertz Hertz 0.3.0 "$a" "$work/plain-http" 2>/dev/null; then echo "error: plain http accepted" >&2; exit 1; fi
unset OPENAPPS_RELEASE_DOWNLOADS
./write-install-script.sh hertz Hertz 0.3.0 "$a" "$work/live" >/dev/null
grep -q "^URL='https://github.com/openappshq/openapps/releases/download/hertz-v0.3.0/Hertz-0.3.0.zip'$" "$work/live"
grep -q -- "--proto '=https'" "$work/live"
echo "ok: the generator pins, refuses to go backwards and defaults to the GitHub release"

echo "ok: install-script.test.sh"
