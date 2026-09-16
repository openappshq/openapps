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
server_pids=()
cleanup() {
    for pid in ${server_pids[@]+"${server_pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT

# Serves a directory on 127.0.0.1: `serve <dir> <log> [media type]` leaves
# the port in $server_port and the pid in server_pids. python3's http.server
# first; when python3 is missing, exits, or never answers (the macos-26
# runner let it sit through the whole wait without a line of output), ruby
# with its socket library, which every macOS ships and needs no webrick.
# Either prints `port <n>` first and logs every request as `"GET /path
# HTTP/1.1"`, the line requests() counts; a media type, when given,
# replaces the one guessed from the file name. A server counts as up only
# once a GET on its root is answered, within 30 seconds; the log of one
# that never gets there is printed before the next runtime is tried, and
# the runtime that came up once serves every later directory too.
server_runtime=""
serve() {
    dir="$1"; log="$2"; media_type="${3:-}"
    server_port=""
    for runtime in ${server_runtime:-python3 ruby}; do
        command -v "$runtime" >/dev/null || continue
        : > "$log"
        case "$runtime" in
            python3) python3 -u - "$dir" "$media_type" > "$log" 2>&1 <<'PY' &
import functools, http.server, sys
directory, media_type = sys.argv[1], sys.argv[2]
class Handler(http.server.SimpleHTTPRequestHandler):
    def guess_type(self, path):
        return media_type or super().guess_type(path)
with http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=directory)) as httpd:
    print("port", httpd.server_address[1], flush=True)
    httpd.serve_forever()
PY
            ;;
            ruby) ruby - "$dir" "$media_type" > "$log" 2>&1 <<'RB' &
require 'socket'
directory, media_type = File.expand_path(ARGV[0]), ARGV[1]
server = TCPServer.new('127.0.0.1', 0)
$stdout.puts "port #{server.addr[1]}"
$stdout.flush
loop do
  Thread.new(server.accept) do |client|
    begin
      request = client.gets.to_s.strip
      nil while (line = client.gets) && !line.strip.empty?
      method, target = request.split(' ')
      path = File.expand_path(target.to_s.sub(/\?.*/, '').sub(%r{\A/+}, ''), directory)
      status, type, body = '404 Not Found', 'text/plain', ''
      if method == 'GET' && (path == directory || path.start_with?(directory + '/'))
        if File.file?(path)
          status, type, body = '200 OK', (media_type.empty? ? 'application/octet-stream' : media_type), File.binread(path)
        elsif File.directory?(path)
          status, type = '200 OK', 'text/html'
        end
      end
      $stderr.puts "127.0.0.1 - - \"#{request}\" #{status.split(' ').first} -"
      client.write "HTTP/1.0 #{status}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
      client.write body
    ensure
      client.close
    end
  end
end
RB
            ;;
        esac
        pid=$!
        disown
        server_pids+=("$pid")
        why="did not answer within 30s"
        for _ in $(seq 1 150); do
            kill -0 "$pid" 2>/dev/null || { why="exited"; break; }
            if [[ -z "$server_port" ]]; then
                server_port="$(sed -nE 's/^port ([0-9]+)$/\1/p' "$log" | head -n 1)"
            fi
            if [[ -n "$server_port" ]]; then
                code="$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "http://127.0.0.1:$server_port/" || true)"
                [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && { server_runtime="$runtime"; return 0; }
            fi
            sleep 0.2
        done
        kill "$pid" 2>/dev/null || true
        echo "warning: the $runtime test server $why; its log:" >&2
        cat "$log" >&2
        server_port=""
    done
    echo "error: the test server did not start" >&2
    exit 1
}

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
cp "$serve/$app-$version.zip" "$work/good.zip"
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
# A stalled app or an unanswered Automation prompt: the call never returns.
if [ -n "${STUB_QUIT_STALLS:-}" ]; then sleep 60; fi
EOF
cat > "$work/bin/mv" <<'EOF'
#!/bin/sh
# Races the promotion: something else creates the target right before the
# install script renames the new bundle to it.
if [ -n "${STUB_RACE_TARGET:-}" ] && [ "$#" = 2 ] && [ "$2" = "$STUB_RACE_TARGET" ]; then
    mkdir -p "$2/Contents"
    printf 'foreign\n' > "$2/Contents/marker"
fi
exec /bin/mv "$@"
EOF
cat > "$work/bin/pgrep" <<'EOF'
#!/bin/sh
count=0
[ -f "$STUB_LOG/pgrep" ] && count="$(cat "$STUB_LOG/pgrep")"
count=$((count + 1))
printf '%s' "$count" > "$STUB_LOG/pgrep"
[ "$count" -le "${STUB_RUNNING_CALLS:-0}" ]
EOF
cat > "$work/bin/xattr" <<'EOF'
#!/bin/sh
# A quarantine that cannot be removed (STUB_XATTR_FAILS): the delete fails and
# the attribute stays for the check that follows.
if [ -n "${STUB_XATTR_FAILS:-}" ] && [ "$1" = -dr ]; then echo "xattr: [Errno 1] Operation not permitted" >&2; exit 1; fi
exec /usr/bin/xattr "$@"
EOF
cat > "$work/bin/ditto" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG/ditto"
exec /usr/bin/ditto "$@"
EOF
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH"
export TMPDIR="$work/tmp"

serve "$work/serve" "$work/server.log"
port="$server_port"
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
# Expects exit 1 with a message on stderr, printing stderr otherwise.
expect_refused() {
    if [[ "$status" != 1 ]] || ! grep -q "$2" "$STUB_LOG/stderr"; then
        echo "error ($1): exit $status, or the message '$2' is missing:" >&2
        cat "$STUB_LOG/stderr" >&2
        exit 1
    fi
}
no_leftovers() {
    if find "$work/dest-$1" "$work/tmp" -mindepth 1 -maxdepth 1 \( -name ".$app.*" -o -name "openklack-install.*" \) ! -name '*.planted' | grep -q .; then
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
grep -q "It is opening now" "$STUB_LOG/stdout"
[[ -f "$work/dest-running/$app.app/Contents/Info.plist" ]]
echo "ok: a running copy is asked to quit, then replaced"

# 4b. A copy that never quits, and an AppleScript call that never returns:
#     the whole quit step stays inside its bound, the install goes on, the
#     user is told to reopen the app, and nothing is opened on top of it.
started=$(date +%s)
run_case stalled "$work/install-good" STUB_RUNNING_CALLS=1000 STUB_QUIT_STALLS=1
elapsed=$(( $(date +%s) - started ))
[[ "$status" == 0 ]] || { echo "error (stalled): exit $status" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
(( elapsed < 20 )) || { echo "error (stalled): the quit step took ${elapsed}s" >&2; exit 1; }
grep -q "did not quit in time" "$STUB_LOG/stdout"
grep -q "Quit the running $app and open it again" "$STUB_LOG/stdout"
[[ ! -f "$STUB_LOG/open" ]]
[[ -f "$work/dest-stalled/$app.app/Contents/Info.plist" ]]
echo "ok: a copy that will not quit is bounded and reported"

# 4f. A quarantine that cannot be cleared is reported, the install still
#     counts, and the app is not opened into a Gatekeeper refusal.
run_case quarantine "$work/install-good" STUB_RUNNING_CALLS=0 STUB_XATTR_FAILS=1
[[ "$status" == 0 ]] || { echo "error (quarantine): exit $status" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
grep -q "Clearing the download quarantine reported: xattr: \[Errno 1\] Operation not permitted" "$STUB_LOG/stdout"
grep -q "quarantine could not be cleared from $work/dest-quarantine/$app.app; macOS may ask" "$STUB_LOG/stdout"
grep -q "Installed $app $version" "$STUB_LOG/stdout"
grep -q "Open it from $work/dest-quarantine" "$STUB_LOG/stdout"
[[ ! -f "$STUB_LOG/open" ]]
xattr -lr "$work/dest-quarantine/$app.app" | grep -q com.apple.quarantine
echo "ok: a quarantine that will not clear is reported, not hidden"

# 4c. A directory already sitting at a backup-looking name is never touched:
#     the previous copy goes into a folder this run created, and only that
#     folder is removed.
mkdir -p "$work/dest-planted/$app.app/Contents" "$work/dest-planted/.$app.app.previous.$$.planted" "$work/dest-planted/.$app.previous.abc123.planted"
printf 'keep\n' > "$work/dest-planted/.$app.app.previous.$$.planted/sentinel"
printf 'keep\n' > "$work/dest-planted/.$app.previous.abc123.planted/sentinel"
run_case planted "$work/install-good" STUB_RUNNING_CALLS=0
[[ "$status" == 0 ]] || { echo "error (planted): exit $status" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
[[ -f "$work/dest-planted/.$app.app.previous.$$.planted/sentinel" && -f "$work/dest-planted/.$app.previous.abc123.planted/sentinel" ]] || { echo "error (planted): a pre-existing directory was removed" >&2; exit 1; }
[[ ! -e "$work/dest-planted/.$app.app.previous.$$.planted/$app.app" ]]
[[ -f "$work/dest-planted/$app.app/Contents/Info.plist" ]]
no_leftovers planted
echo "ok: a pre-existing backup-looking directory is left alone"

# 4d. Something else creates <App>.app between the two renames: the new
#     bundle is not nested into it, the foreign directory is untouched, the
#     previous copy is kept and its location printed, exit 1.
mkdir -p "$work/dest-race/$app.app/Contents"
printf 'old\n' > "$work/dest-race/$app.app/Contents/marker"
run_case race "$work/install-good" STUB_RUNNING_CALLS=0 STUB_RACE_TARGET="$work/dest-race/$app.app"
[[ "$status" == 1 ]] || { echo "error (race): exit $status, expected 1" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
grep -q "was changed by something else while installing" "$STUB_LOG/stderr"
[[ "$(cat "$work/dest-race/$app.app/Contents/marker")" == foreign ]]
[[ ! -e "$work/dest-race/$app.app/$app.app" ]]
[[ ! -e "$work/dest-race/$app.app/Contents/Info.plist" ]]
kept="$(sed -nE 's/^The previous OpenKlack.app is kept at (.*)$/\1/p' "$STUB_LOG/stderr")"
[[ -n "$kept" && "$(cat "$kept/Contents/marker")" == old ]] || { echo "error (race): the previous copy was not kept" >&2; cat "$STUB_LOG/stderr" >&2; exit 1; }
[[ ! -f "$STUB_LOG/open" ]]
[[ -z "$(ls -A "$work/tmp")" ]]
echo "ok: a target that appears mid-install is never nested into or touched"

# 4e. Symbolic links are refused: a linked destination folder, a linked
#     <App>.app, an archive with a link that escapes the bundle, and an
#     archive with more than the bundle in it.
mkdir -p "$work/real-dest"; ln -s "$work/real-dest" "$work/dest-symlink-dir"
run_case symlink-dir "$work/install-good" STUB_RUNNING_CALLS=0
expect_refused symlink-dir "is a symbolic link"
[[ -z "$(ls -A "$work/real-dest")" ]]
mkdir -p "$work/dest-symlink-app" "$work/elsewhere.app"; ln -s "$work/elsewhere.app" "$work/dest-symlink-app/$app.app"
run_case symlink-app "$work/install-good" STUB_RUNNING_CALLS=0
expect_refused symlink-app "is a symbolic link"
[[ -L "$work/dest-symlink-app/$app.app" && -d "$work/elsewhere.app" ]]
# An escaping link inside the bundle, served in place of the good zip.
cp -R "$work/$app.app" "$work/escape.app"; ln -s ../../.. "$work/escape.app/Contents/etc"
mv "$work/escape.app" "$work/$app.app.escape"; mkdir "$work/escape"; mv "$work/$app.app.escape" "$work/escape/$app.app"
ditto -c -k --keepParent "$work/escape/$app.app" "$serve/$app-$version.zip"
escape_sha="$(shasum -a 256 "$serve/$app-$version.zip" | cut -d' ' -f1)"
./write-install-script.sh openklack "$app" "$version" "$escape_sha" "$work/install-escape" >/dev/null
run_case escape "$work/install-escape" STUB_RUNNING_CALLS=0
expect_refused escape "points outside the bundle"
[[ ! -e "$work/dest-escape/$app.app" ]]
# Two top-level entries.
mkdir -p "$work/two/$app.app/Contents" "$work/two/Extra"
cp "$work/$app.app/Contents/Info.plist" "$work/two/$app.app/Contents/"; printf 'x\n' > "$work/two/Extra/file"
(cd "$work/two" && zip -qr "$serve/$app-$version.zip" "$app.app" Extra)
two_sha="$(shasum -a 256 "$serve/$app-$version.zip" | cut -d' ' -f1)"
./write-install-script.sh openklack "$app" "$version" "$two_sha" "$work/install-two" >/dev/null
run_case two "$work/install-two" STUB_RUNNING_CALLS=0
expect_refused two "holds more than $app.app"
[[ ! -f "$STUB_LOG/ditto" ]]
[[ ! -e "$work/dest-two" ]]
# Restore the good zip for the cases that follow.
cp "$work/good.zip" "$serve/$app-$version.zip"
echo "ok: symbolic links and extra archive entries are refused"

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

# 7. The live check against a served copy of a committed script: passes when
#    the pin, the media type and the bytes match, fails on another media type,
#    another digest or a script cut short.
committed="../../apps/website/public/install/openklack"
c_version="$(sed -nE "s/^VERSION='([^']+)'$/\1/p" "$committed")"
c_sha="$(sed -nE "s/^SHA256='([^']+)'$/\1/p" "$committed")"
mkdir -p "$work/live-sh" "$work/live-bin" "$work/live-cut"
cp "$committed" "$work/live-sh/openklack"
cp "$committed" "$work/live-bin/openklack"
sed '$d' "$committed" > "$work/live-cut/openklack"
serve "$work/live-sh" "$work/live-sh.log" "text/x-shellscript; charset=utf-8"; typed_port="$server_port"
serve "$work/live-bin" "$work/live-bin.log" "application/octet-stream"; plain_port="$server_port"
serve "$work/live-cut" "$work/live-cut.log" "text/x-shellscript; charset=utf-8"; cut_port="$server_port"
(cd ../.. && WAIT_SECONDS=0 OPENAPPS_INSTALL_URL_BASE="http://127.0.0.1:$typed_port/" scripts/release/verify-live-install-script.sh openklack "$c_version" "$c_sha") | grep -q "served as text/x-shellscript"
if (cd ../.. && WAIT_SECONDS=0 OPENAPPS_INSTALL_URL_BASE="http://127.0.0.1:$plain_port/" scripts/release/verify-live-install-script.sh openklack "$c_version" "$c_sha" 2> "$work/verify.err"); then echo "error: the wrong media type passed" >&2; exit 1; fi
grep -q "served as 'application/octet-stream', not text/x-shellscript" "$work/verify.err"
if (cd ../.. && WAIT_SECONDS=0 OPENAPPS_INSTALL_URL_BASE="http://127.0.0.1:$typed_port/" scripts/release/verify-live-install-script.sh openklack "$c_version" "$bad" 2> "$work/verify.err"); then echo "error: the wrong digest passed" >&2; exit 1; fi
grep -q "not $bad" "$work/verify.err"
if (cd ../.. && WAIT_SECONDS=0 OPENAPPS_INSTALL_URL_BASE="http://127.0.0.1:$cut_port/" scripts/release/verify-live-install-script.sh openklack "$c_version" "$c_sha" 2> "$work/verify.err"); then echo "error: a truncated script passed" >&2; exit 1; fi
grep -q "does not end with the call to main" "$work/verify.err"
echo "ok: the live check accepts the served script and refuses the wrong type, digest or a cut-off file"

echo "ok: install-script.test.sh"
