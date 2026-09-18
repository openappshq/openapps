#!/usr/bin/env bash
# bump-cask.sh on a copy of the template: the first release fills it in, a
# newer one replaces it, an older one and a rewrite are refused, a repeat is
# a no-op; with the template as the fourth argument the desc follows it,
# on a bump and on a repeat alike, and never without it.
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
desc_of() { sed -nE 's/^  desc "([^"]+)"$/\1/p' "$cask"; }
template_desc="$(sed -nE 's/^  desc "([^"]+)"$/\1/p' Casks/openklack.rb)"
[[ -n "$template_desc" ]] || { echo "the template has no desc line" >&2; exit 1; }
stale_desc() { sed -i.bak -E 's/^  desc "[^"]+"$/  desc "An older line of copy"/' "$cask" && rm -f "$cask.bak"; }

./bump-cask.sh "$cask" 0.1.0 "$a"
[[ "$(version_of)" == 0.1.0 && "$(sha_of)" == "$a" ]] || { echo "first release not applied" >&2; exit 1; }
grep -q "already names" <<< "$(./bump-cask.sh "$cask" 0.1.0 "$a")" || { echo "repeat should be a no-op" >&2; exit 1; }
if ./bump-cask.sh "$cask" 0.1.0 "$b" 2>/dev/null; then echo "rewrite accepted" >&2; exit 1; fi
if ./bump-cask.sh "$cask" 0.0.9 "$b" 2>/dev/null; then echo "downgrade accepted" >&2; exit 1; fi
./bump-cask.sh "$cask" 0.2.0 "$b"
[[ "$(version_of)" == 0.2.0 && "$(sha_of)" == "$b" ]] || { echo "newer release not applied" >&2; exit 1; }
if ./bump-cask.sh "$cask" 0.1.1 "$a" 2>/dev/null; then echo "downgrade accepted" >&2; exit 1; fi
diff <(grep -v '^  version \|^  sha256 ' Casks/openklack.rb) <(grep -v '^  version \|^  sha256 ' "$cask")

# The desc: a stale one stays without the template, follows it on a bump,
# and on a repeat of the same release.
stale_desc
[[ "$(desc_of)" == "An older line of copy" ]] || { echo "the stale desc was not written" >&2; exit 1; }
./bump-cask.sh "$cask" 0.2.1 "$a"
[[ "$(desc_of)" == "An older line of copy" ]] || { echo "desc changed without a template" >&2; exit 1; }
grep -q "desc set from" <<< "$(./bump-cask.sh "$cask" 0.2.2 "$b" Casks/openklack.rb)" || { echo "desc sync not reported" >&2; exit 1; }
[[ "$(version_of)" == 0.2.2 && "$(desc_of)" == "$template_desc" ]] || { echo "desc not taken from the template on a bump" >&2; exit 1; }
stale_desc
grep -q "already names" <<< "$(./bump-cask.sh "$cask" 0.2.2 "$b" Casks/openklack.rb)" || { echo "repeat with a template should still be a no-op bump" >&2; exit 1; }
[[ "$(desc_of)" == "$template_desc" ]] || { echo "desc not taken from the template on a repeat" >&2; exit 1; }
if grep -q "desc set from" <<< "$(./bump-cask.sh "$cask" 0.2.2 "$b" Casks/openklack.rb)"; then echo "an unchanged desc was reported as set" >&2; exit 1; fi
if ./bump-cask.sh "$cask" 0.2.2 "$b" "$work/missing.rb" 2>/dev/null; then echo "missing template accepted" >&2; exit 1; fi
diff <(grep -v '^  version \|^  sha256 ' Casks/openklack.rb) <(grep -v '^  version \|^  sha256 ' "$cask")
echo "ok: bump-cask.sh"
