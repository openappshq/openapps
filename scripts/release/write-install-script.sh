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

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Runs on every exit: puts a previous copy back if the new one never landed,
# and removes everything temporary. Never touches an installed app.
cleanup() {
    status=$?
    if [ -n "$old" ] && [ -e "$old" ] && [ ! -e "$target" ]; then
        mv "$old" "$target" || true
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

check_macos() {
    if [ "$(uname -s 2>/dev/null)" != Darwin ]; then
        fail "$APP_NAME is a Mac app; this installer runs on macOS only."
    fi
    command -v curl >/dev/null 2>&1 || fail "curl is required and was not found."
    command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 \
        || fail "shasum or openssl is required to check the download and neither was found."
    command -v ditto >/dev/null 2>&1 || command -v unzip >/dev/null 2>&1 \
        || fail "ditto or unzip is required to unpack the download and neither was found."
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
# a password), otherwise ~/Applications, which the Finder also lists. Sets dest.
choose_dest() {
    if [ -n "${OPENAPPS_INSTALL_DIR:-}" ]; then
        dest="$OPENAPPS_INSTALL_DIR"
        mkdir -p "$dest" || fail "Could not create $dest."
    elif [ -d /Applications ] && [ -w /Applications ]; then
        dest=/Applications
    else
        [ -n "${HOME:-}" ] || fail "/Applications is not writable for this account and HOME is not set."
        dest="$HOME/Applications"
        say "/Applications is not writable for this account; installing into $dest instead."
        mkdir -p "$dest" || fail "Could not create $dest."
    fi
    [ -d "$dest" ] && [ -w "$dest" ] || fail "$dest is not a writable folder."
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

unpack() {
    mkdir "$work/unpacked"
    if command -v ditto >/dev/null 2>&1; then
        ditto -xk "$zip" "$work/unpacked" || fail "Could not unpack the download."
    else
        unzip -q "$zip" -d "$work/unpacked" || fail "Could not unpack the download."
    fi
    unpacked="$work/unpacked/$APP_NAME.app"
    [ -d "$unpacked" ] && [ -f "$unpacked/Contents/Info.plist" ] \
        || fail "The download does not contain $APP_NAME.app."
}

# Asks a running copy to quit and gives it a moment; the install goes ahead
# either way, since the new bundle only replaces the old one on disk.
quit_running() {
    if ! pgrep -qx "$APP_NAME" 2>/dev/null; then return 0; fi
    say "Quitting the running $APP_NAME..."
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    tries=0
    while [ "$tries" -lt 20 ] && pgrep -qx "$APP_NAME" 2>/dev/null; do
        sleep 0.5
        tries=$((tries + 1))
    done
}

# The new bundle is copied next to its final place first, so the swap is two
# renames on one volume: the old app moves aside, the new one moves in, and
# only then is the old one removed. A failure in between puts the old one back.
install_app() {
    target="$dest/$APP_NAME.app"
    staging="$(mktemp -d "$dest/.$APP_NAME.install.XXXXXX")" || fail "Could not create a folder in $dest."
    if ! ditto "$unpacked" "$staging/$APP_NAME.app" 2>/dev/null; then
        rm -rf "$staging/$APP_NAME.app"
        cp -pR "$unpacked" "$staging/$APP_NAME.app" || fail "Could not copy $APP_NAME.app into $dest."
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
        old="$dest/.$APP_NAME.app.previous.$$"
        mv "$target" "$old" || fail "Could not move the existing $target aside."
    fi
    if ! mv "$staging/$APP_NAME.app" "$target"; then
        if [ -n "$old" ]; then mv "$old" "$target" || true; fi
        fail "Could not put $APP_NAME.app into $dest."
    fi
    if [ -n "$old" ]; then
        rm -rf "$old"
        old=''
    fi
    xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
}

main() {
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    check_macos
    choose_dest
    work="$(mktemp -d "${TMPDIR:-/tmp}/$APP_ID-install.XXXXXX")" || fail "Could not create a temporary folder."
    download
    unpack
    quit_running
    install_app
    say "Installed $APP_NAME $VERSION to $target."
    if open -a "$target" 2>/dev/null; then
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
