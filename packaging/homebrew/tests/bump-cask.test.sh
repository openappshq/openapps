#!/usr/bin/env bash
# bump-cask.sh on a copy of the template: the first release fills it in, a
# newer one replaces it, an older one and a rewrite are refused, a repeat is
# a no-op.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cask="$work/openklack.rb"
cp Casks/openklack.rb "$cask"
a="$(printf 'a%.0s' $(seq 1 64))"
b="$(printf 'b%.0s' $(seq 1 64))"
version_of() { sed -nE 's/^  version "([^"]+)"$/\1/p' "$cask"; }
sha_of() { sed -nE 's/^  sha256 "([^"]+)"$/\1/p' "$cask"; }

./bump-cask.sh "$cask" 0.1.0 "$a"
[[ "$(version_of)" == 0.1.0 && "$(sha_of)" == "$a" ]] || { echo "first release not applied" >&2; exit 1; }
./bump-cask.sh "$cask" 0.1.0 "$a" | grep -q "already names" || { echo "repeat should be a no-op" >&2; exit 1; }
if ./bump-cask.sh "$cask" 0.1.0 "$b" 2>/dev/null; then echo "rewrite accepted" >&2; exit 1; fi
if ./bump-cask.sh "$cask" 0.0.9 "$b" 2>/dev/null; then echo "downgrade accepted" >&2; exit 1; fi
./bump-cask.sh "$cask" 0.2.0 "$b"
[[ "$(version_of)" == 0.2.0 && "$(sha_of)" == "$b" ]] || { echo "newer release not applied" >&2; exit 1; }
if ./bump-cask.sh "$cask" 0.1.1 "$a" 2>/dev/null; then echo "downgrade accepted" >&2; exit 1; fi
diff <(grep -v '^  version \|^  sha256 ' Casks/openklack.rb) <(grep -v '^  version \|^  sha256 ' "$cask")
echo "ok: bump-cask.sh"
