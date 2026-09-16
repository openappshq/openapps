#!/usr/bin/env bash
# Writes an app's one-line install script (RELEASES.md, "Install script"):
# the static POSIX `sh` file served at https://openapps.space/install/<app-id>
# and run as `curl -fsSL … | sh` by people without Homebrew.
#
#   scripts/release/write-install-script.sh <app-id> <App> <version> <sha256> <out-file>
#
# The script pins one release: the zip the cask installs and its SHA-256, the
# digest the release job verified — never one recomputed from a download.
# Like bump-cask.sh, an existing out-file only ever advances: a lower version
# is refused, and so is the same version with a different digest (a release is
# never rewritten); the same release regenerates the file, so a template
# change reaches the served script on the next run.
#
# OPENAPPS_RELEASE_DOWNLOADS (default https://github.com/openappshq/openapps/releases/download/)
# is where the zip is fetched from; only the tests point it at 127.0.0.1.
set -euo pipefail

usage="usage: write-install-script.sh <app-id> <App> <version> <sha256> <out-file>"
APP_ID="${1:?$usage}"
APP_NAME="${2:?$usage}"
VERSION="${3:?$usage}"
SHA256="${4:?$usage}"
OUT="${5:?$usage}"
DOWNLOADS="${OPENAPPS_RELEASE_DOWNLOADS:-https://github.com/openappshq/openapps/releases/download/}"

[[ "$APP_ID" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "error: app id must be lowercase letters, digits and dashes" >&2; exit 1; }
[[ "$APP_NAME" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || { echo "error: app name must be letters and digits (the .app's name)" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: sha256 must be 64 lowercase hex digits" >&2; exit 1; }
# The URL is spliced into a single-quoted shell string and a comment: only
# plain URL characters, and only https except for a local test server.
[[ "$DOWNLOADS" =~ ^https?://[A-Za-z0-9._~:/-]+/$ ]] || { echo "error: OPENAPPS_RELEASE_DOWNLOADS must be a plain http(s) URL ending in /" >&2; exit 1; }
# PROTO, BUNDLE_ID and URL are read through ${!name} when the template is filled in.
# shellcheck disable=SC2034
case "$DOWNLOADS" in
    https://*) PROTO="=https" ;;
    http://127.0.0.1/* | http://127.0.0.1:*) PROTO="=http" ;;
    *) echo "error: OPENAPPS_RELEASE_DOWNLOADS must be https (http is allowed for 127.0.0.1 only)" >&2; exit 1 ;;
esac

# The bundle identifier is what the script tells to quit; it is part of each
# app's contract (its cask's `uninstall quit:`), so it is fixed here.
# shellcheck disable=SC2034
case "$APP_ID" in
    openreaction) BUNDLE_ID="com.openappshq.openreaction" ;;
    openklack) BUNDLE_ID="com.openklack.desktop" ;;
    hertz) BUNDLE_ID="com.openappshq.hertz" ;;
    macpaper) BUNDLE_ID="com.openappshq.macpaper" ;;
    opennotes) BUNDLE_ID="com.openappshq.opennotes" ;;
    *) echo "error: unknown app '$APP_ID'; add its bundle identifier to write-install-script.sh" >&2; exit 1 ;;
esac

# shellcheck disable=SC2034
URL="${DOWNLOADS}${APP_ID}-v${VERSION}/${APP_NAME}-${VERSION}.zip"

# Never move a served script backwards.
if [[ -f "$OUT" ]]; then
    current="$(sed -nE "s/^VERSION='([^']+)'$/\1/p" "$OUT")"
    current_sha="$(sed -nE "s/^SHA256='([^']+)'$/\1/p" "$OUT")"
    if [[ -z "$current" || -z "$current_sha" ]]; then
        echo "error: $OUT exists but pins no release; refusing to overwrite a file this script did not write" >&2
        exit 1
    fi
    if [[ "$current" == "$VERSION" && "$current_sha" != "$SHA256" ]]; then
        echo "error: $OUT already pins $VERSION with a different sha256; a release is never rewritten" >&2
        exit 1
    fi
    if [[ "$current" != "$VERSION" && "$(printf '%s\n%s\n' "$current" "$VERSION" | sort -V | tail -n 1)" != "$VERSION" ]]; then
        echo "error: $OUT pins $current, newer than $VERSION" >&2
        exit 1
    fi
else
    current="none yet"
fi

# The script itself. Single-quoted heredoc: nothing here is expanded by this
# generator; the @PLACEHOLDERS@ are substituted below and checked to be gone.
# (`read -d ''` rather than `$(cat …)`: bash 3.2 misparses `case` inside `$()`.)
template=""
read -r -d '' template <<'TEMPLATE' || true
#!/bin/sh
# Installs @APP_NAME@ @VERSION@ on your Mac.
#
#   curl -fsSL https://openapps.space/install/@APP_ID@ | sh
#
# What it does: downloads the signed release zip (the same file the Homebrew
# cask installs), checks its SHA-256 against the digest pinned below, unpacks
# it in a private temporary directory, quits a running copy, replaces
# /Applications/@APP_NAME@.app (or ~/Applications/@APP_NAME@.app when
# /Applications is not writable), clears the download quarantine and opens
# the app. It never asks for a password, never uses sudo, and reads nothing
# from the terminal. Afterwards @APP_NAME@ updates itself.
#
# Options, as environment variables:
#   OPENAPPS_INSTALL_DIR   install into this folder instead of /Applications
#
# This file is generated for every release by scripts/release/write-install-script.sh
# in https://github.com/openappshq/openapps and served from
# apps/website/public/install/@APP_ID@ in that repository. Read it there, or
# save this file and read it before running it.

set -eu
IFS="$(printf ' \t\nx')"; IFS="${IFS%x}"
umask 022

APP_ID='@APP_ID@'
APP_NAME='@APP_NAME@'
BUNDLE_ID='@BUNDLE_ID@'
VERSION='@VERSION@'
SHA256='@SHA256@'
URL='@URL@'
MINIMUM_MACOS=14

work=''
staging=''
old=''
target=''
still_running=''
quarantine_left=''

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Runs on every exit. If the previous copy was moved aside and nothing is at
# its place, it goes back; if it cannot go back it is kept and its location
# printed. Only directories this run created with mktemp are ever removed.
cleanup() {
    status=$?
    if [ -n "$old" ] && [ -d "$old/$APP_NAME.app" ]; then
        if [ ! -e "$target" ] && [ ! -L "$target" ] && mv "$old/$APP_NAME.app" "$target" 2>/dev/null; then
            rmdir "$old" 2>/dev/null || true
        else
            printf 'The previous %s is kept at %s\n' "$APP_NAME.app" "$old/$APP_NAME.app" >&2
        fi
    elif [ -n "$old" ]; then
        rmdir "$old" 2>/dev/null || true
    fi
    if [ -n "$staging" ]; then rm -rf "$staging"; fi
    if [ -n "$work" ]; then rm -rf "$work"; fi
    exit "$status"
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        openssl dgst -sha256 -r "$1" | cut -d' ' -f1
    fi
}

# Device and inode: the identity of a directory across a rename.
identity() { stat -f '%d:%i' "$1" 2>/dev/null; }

check_macos() {
    if [ "$(uname -s 2>/dev/null)" != Darwin ]; then
        fail "$APP_NAME is a Mac app; this installer runs on macOS only."
    fi
    for tool in curl unzip realpath stat xattr; do
        command -v "$tool" >/dev/null 2>&1 || fail "$tool is required and was not found."
    done
    command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 \
        || fail "shasum or openssl is required to check the download and neither was found."
    macos="$(sw_vers -productVersion 2>/dev/null || true)"
    major="${macos%%.*}"
    case "$major" in
        '' | *[!0-9]*) fail "Could not read the macOS version from sw_vers." ;;
    esac
    if [ "$major" -lt "$MINIMUM_MACOS" ]; then
        fail "$APP_NAME needs macOS $MINIMUM_MACOS or newer; this Mac runs $macos."
    fi
}

# /Applications when this account can write there (admin accounts can, without
# a password), otherwise ~/Applications, which the Finder also lists. Sets dest
# and target. A symlinked folder or a symlinked <App>.app is refused: the
# install would land somewhere other than the path it names.
choose_dest() {
    if [ -n "${OPENAPPS_INSTALL_DIR:-}" ]; then
        dest="$OPENAPPS_INSTALL_DIR"
        [ -L "$dest" ] && fail "$dest is a symbolic link; set OPENAPPS_INSTALL_DIR to a real folder."
        mkdir -p "$dest" || fail "Could not create $dest."
    elif [ -d /Applications ] && [ ! -L /Applications ] && [ -w /Applications ]; then
        dest=/Applications
    else
        [ -n "${HOME:-}" ] || fail "/Applications is not writable for this account and HOME is not set."
        dest="$HOME/Applications"
        say "/Applications is not writable for this account; installing into $dest instead."
        [ -L "$dest" ] && fail "$dest is a symbolic link; replace it with a real folder or set OPENAPPS_INSTALL_DIR."
        mkdir -p "$dest" || fail "Could not create $dest."
    fi
    [ -d "$dest" ] && [ ! -L "$dest" ] && [ -w "$dest" ] || fail "$dest is not a writable folder."
    target="$dest/$APP_NAME.app"
    [ -L "$target" ] && fail "$target is a symbolic link; move it aside first."
    if [ -e "$target" ] && [ ! -d "$target" ]; then
        fail "$target exists and is not an app bundle; move it aside first."
    fi
    return 0
}

download() {
    zip="$work/$APP_NAME-$VERSION.zip"
    say "Downloading $APP_NAME $VERSION..."
    curl --proto '@PROTO@' --tlsv1.2 -fsSL --retry 3 --max-time 900 -o "$zip" "$URL" \
        || fail "The download from $URL failed. Nothing was installed."
    actual="$(sha256_of "$zip")"
    if [ "$actual" != "$SHA256" ]; then
        rm -f "$zip"
        fail "The download does not match the release pinned in this script (SHA-256 $actual, expected $SHA256). It was deleted and nothing was installed. If this keeps happening, fetch the script again: curl -fsSL https://openapps.space/install/$APP_ID | sh"
    fi
    say "Checked the download: SHA-256 matches."
}

# The archive must hold exactly one top-level <App>.app (plus ditto's
# __MACOSX metadata, which unpacking folds back in) and nothing that could
# reach outside it: no absolute or ".." entries, and after unpacking no
# symbolic link that resolves outside the bundle.
check_archive() {
    unzip -Z1 "$zip" > "$work/entries" || fail "Could not list the download."
    [ -s "$work/entries" ] || fail "The download is empty."
    if grep -v -e "^$APP_NAME\.app/" -e '^__MACOSX/' "$work/entries" | grep -q .; then
        fail "The download holds more than $APP_NAME.app. Nothing was installed."
    fi
    if grep -E '(^|/)\.\.(/|$)' "$work/entries" | grep -q .; then
        fail "The download names a path outside $APP_NAME.app. Nothing was installed."
    fi
}

unpack() {
    mkdir "$work/unpacked"
    if command -v ditto >/dev/null 2>&1; then
        ditto -xk "$zip" "$work/unpacked" || fail "Could not unpack the download."
    else
        unzip -q "$zip" -d "$work/unpacked" || fail "Could not unpack the download."
    fi
    rm -rf "$work/unpacked/__MACOSX"
    unpacked="$work/unpacked/$APP_NAME.app"
    [ "$(find "$work/unpacked" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] && [ -d "$unpacked" ] && [ ! -L "$unpacked" ] \
        || fail "The download does not unpack to a single $APP_NAME.app."
    [ -f "$unpacked/Contents/Info.plist" ] && [ ! -L "$unpacked/Contents" ] && [ ! -L "$unpacked/Contents/Info.plist" ] \
        || fail "The download does not contain $APP_NAME.app."
    root="$(realpath "$unpacked")" || fail "Could not resolve $unpacked."
    find "$unpacked" -type l -print > "$work/links"
    while IFS= read -r link; do
        [ -n "$link" ] || continue
        resolved="$(cd "$(dirname "$link")" && realpath -q "$(readlink "$link")" 2>/dev/null)" \
            || fail "$APP_NAME.app contains a link that does not resolve: ${link#"$unpacked"/}. Nothing was installed."
        case "$resolved" in
            "$root"/*) ;;
            *) fail "$APP_NAME.app contains a link that points outside the bundle: ${link#"$unpacked"/}. Nothing was installed." ;;
        esac
    done < "$work/links"
}

# Asks a running copy to quit and gives it up to ten seconds in all: the
# AppleScript runs in the background so a stalled app or an unanswered
# Automation prompt cannot hold the install. The install goes ahead either
# way, since the new bundle only replaces the old one on disk.
quit_running() {
    if ! pgrep -qx "$APP_NAME" 2>/dev/null; then return 0; fi
    say "Quitting the running $APP_NAME..."
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 &
    quit_pid=$!
    tries=0
    while [ "$tries" -lt 20 ] && pgrep -qx "$APP_NAME" 2>/dev/null; do
        sleep 0.5
        tries=$((tries + 1))
    done
    kill "$quit_pid" 2>/dev/null || true
    if pgrep -qx "$APP_NAME" 2>/dev/null; then
        still_running=1
        say "$APP_NAME did not quit in time; the new version replaces it on disk and runs the next time you open it."
    fi
}

# The new bundle is copied next to its final place first, so the swap is two
# renames on one volume. The previous copy moves into a private directory this
# run created with mktemp; only that exact directory is ever removed, and only
# after the new bundle is confirmed at its place (a rename keeps the inode, so
# a bundle that landed inside some other directory is detected and undone).
install_app() {
    staging="$(mktemp -d "$dest/.$APP_NAME.install.XXXXXX")" || fail "Could not create a folder in $dest."
    if ! ditto "$unpacked" "$staging/$APP_NAME.app" 2>/dev/null; then
        rm -rf "$staging/$APP_NAME.app"
        cp -pR "$unpacked" "$staging/$APP_NAME.app" || fail "Could not copy $APP_NAME.app into $dest."
    fi
    staged_id="$(identity "$staging/$APP_NAME.app")" || fail "Could not read the staged bundle."
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -d "$target" ] && [ ! -L "$target" ] || fail "$target changed while installing; nothing was replaced."
        old="$(mktemp -d "$dest/.$APP_NAME.previous.XXXXXX")" || fail "Could not create a folder in $dest."
        mv "$target" "$old/$APP_NAME.app" || fail "Could not move the existing $target aside."
    fi
    if [ -e "$target" ] || [ -L "$target" ] || ! mv "$staging/$APP_NAME.app" "$target" \
        || [ -L "$target" ] || [ "$(identity "$target")" != "$staged_id" ]; then
        # Something else appeared at the target. Undo our own move if it nested.
        if [ -d "$target/$APP_NAME.app" ] && [ "$(identity "$target/$APP_NAME.app")" = "$staged_id" ]; then
            rm -rf "$target/$APP_NAME.app"
        fi
        fail "$target was changed by something else while installing; nothing of it was touched."
    fi
    if [ -n "$old" ]; then
        rm -rf "$old"
        old=''
    fi
    # The app is signed but not notarized: without this, Gatekeeper would
    # refuse to open it. Reported, never hidden.
    if ! xattr -dr com.apple.quarantine "$target" 2> "$work/xattr.err"; then
        say "Clearing the download quarantine reported: $(tr '\n' ' ' < "$work/xattr.err")"
    fi
    if xattr -lr "$target" 2>/dev/null | grep -q 'com\.apple\.quarantine'; then
        quarantine_left=1
        say "The download quarantine could not be cleared from $target; macOS may ask to confirm the first open (right-click, Open)."
    fi
}

main() {
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    check_macos
    choose_dest
    work="$(mktemp -d "${TMPDIR:-/tmp}/$APP_ID-install.XXXXXX")" || fail "Could not create a temporary folder."
    download
    check_archive
    unpack
    quit_running
    install_app
    say "Installed $APP_NAME $VERSION to $target."
    if [ -n "$still_running" ]; then
        say "Quit the running $APP_NAME and open it again to run $VERSION. It checks for updates itself, so this is the only time you need this command."
    elif [ -n "$quarantine_left" ]; then
        say "Open it from $dest. $APP_NAME checks for updates itself, so this is the only time you need this command."
    elif open -a "$target" 2>/dev/null; then
        say "It is opening now. $APP_NAME checks for updates itself, so this is the only time you need this command."
    else
        say "Open it from $dest. $APP_NAME checks for updates itself, so this is the only time you need this command."
    fi
}

# Nothing above runs on its own: a download cut short stops at a syntax error
# instead of running half a script. This line must stay the last one.
main </dev/null
TEMPLATE

script="$template"
for name in APP_ID APP_NAME BUNDLE_ID VERSION SHA256 URL PROTO; do
    value="${!name}"
    # Every value was validated above: no quotes, backslashes or & to upset the
    # shell string it lands in.
    [[ "$value" != *[\'\\\&]* ]] || { echo "error: $name contains a quote, backslash or &" >&2; exit 1; }
    script="${script//@${name}@/${value}}"
done
if [[ "$script" =~ @[A-Z_]+@ ]]; then
    echo "error: an unsubstituted placeholder is left in the script: ${BASH_REMATCH[0]}" >&2
    exit 1
fi

tmp="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$script" > "$tmp"
sh -n "$tmp" || { echo "error: the generated script does not parse" >&2; exit 1; }
# ASCII only: bash 3.2 (macOS /bin/sh) reads a multibyte character after a
# variable name as part of the name under some locales.
if LC_ALL=C grep -q '[^[:print:][:space:]]' "$tmp"; then
    echo "error: the generated script contains a non-ASCII or control character" >&2; exit 1
fi
chmod 0644 "$tmp"
mv "$tmp" "$OUT"
echo "ok: $OUT $current -> $VERSION ($SHA256)"
