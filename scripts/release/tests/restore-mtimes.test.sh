#!/usr/bin/env bash
# restore-mtimes.sh can never make a cached build miss a change: a test file
# changed in a commit *older* than the cached build (a rebase, a merge of an
# older branch) keeps the checkout time, so the build system recompiles it
# and a newly failing test fails — under SwiftPM and under Cargo, which
# compare times differently. Unchanged files get their commit times, so the
# cache is still worth restoring. Builds two throwaway packages in a
# temporary repository; Cargo is skipped when it is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/restore-mtimes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A commit dated in the past: older than any build this test makes.
old_commit() {
    GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
        git -c user.name=t -c user.email=t@example.com commit -q -m "$1"
}
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
checkout_like() { # every tracked file gets "now", as a checkout would stamp it
    git ls-files -z | xargs -0 touch -m
}

# --- SwiftPM ---------------------------------------------------------------
swift_repo="$work/swift"
mkdir -p "$swift_repo/Sources/Thing" "$swift_repo/Tests/ThingTests"
cd "$swift_repo"
git init -q
cat > Package.swift <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Thing",
    targets: [
        .target(name: "Thing"),
        .testTarget(name: "ThingTests", dependencies: ["Thing"]),
    ]
)
EOF
echo 'public func answer() -> Int { 42 }' > Sources/Thing/Thing.swift
echo .build > .gitignore
cat > Tests/ThingTests/ThingTests.swift <<'EOF'
import XCTest
import Thing
final class ThingTests: XCTestCase {
    func testAnswer() { XCTAssertEqual(answer(), 42) }
}
EOF
git add -A && old_commit "first"
marker=".build/openapps-cache-commit"
"$script" "$marker" Sources Tests Package.swift >/dev/null
swift build --build-tests -q 2>/dev/null
swift test --skip-build -q 2>/dev/null >/dev/null || { echo "error: the throwaway Swift package must pass first" >&2; exit 1; }
[[ "$(cat "$marker")" == "$(git rev-parse HEAD)" ]] || { echo "error: the marker must name the built commit" >&2; exit 1; }
# The "next run": a commit older than the build breaks the test; the checkout stamps everything with now.
sed -i.bak 's/42) }/41) }/' Tests/ThingTests/ThingTests.swift && rm Tests/ThingTests/ThingTests.swift.bak
git add -A && old_commit "break the test, dated before the build"
checkout_like
before_source="$(mtime Sources/Thing/Thing.swift)"
out="$("$script" "$marker" Sources Tests Package.swift)"
grep -q "2 unchanged files got their commit times, 1 changed files keep" <<< "$out" || { echo "error: expected two restored and one changed file (Swift): $out" >&2; exit 1; }
[[ "$(mtime Sources/Thing/Thing.swift)" != "$before_source" ]] || { echo "error: the unchanged source must get its commit time (Swift)" >&2; exit 1; }
[[ "$(mtime Tests/ThingTests/ThingTests.swift)" -ge "$(( $(date +%s) - 120 ))" ]] || { echo "error: the changed test must keep the checkout time (Swift)" >&2; exit 1; }
swift build --build-tests -q 2>/dev/null
if swift test --skip-build -q >/dev/null 2>&1; then echo "error: SwiftPM reused the stale test binary — the change was lost" >&2; exit 1; fi
echo "ok: SwiftPM — a test changed in an older commit still fails after the cache"

# A marker naming a commit this checkout does not have restores nothing.
echo 0123456789abcdef0123456789abcdef01234567 > "$marker"
checkout_like
before_source="$(mtime Sources/Thing/Thing.swift)"
out="$("$script" "$marker" Sources Tests Package.swift)"
grep -q "does not have" <<< "$out" || { echo "error: an unknown cache commit must be reported: $out" >&2; exit 1; }
[[ "$(mtime Sources/Thing/Thing.swift)" == "$before_source" ]] || { echo "error: nothing may be restored against an unknown commit" >&2; exit 1; }
echo "ok: an unknown cache commit restores nothing"

# --- Cargo -----------------------------------------------------------------
if ! command -v cargo >/dev/null 2>&1; then echo "skipped: Cargo is not installed"; exit 0; fi
cargo_repo="$work/cargo"
mkdir -p "$cargo_repo/src"
cd "$cargo_repo"
git init -q
cat > Cargo.toml <<'EOF'
[package]
name = "thing"
version = "0.1.0"
edition = "2021"
EOF
cat > src/lib.rs <<'EOF'
pub fn answer() -> i32 { 42 }
#[cfg(test)]
mod tests {
    #[test]
    fn answer() { assert_eq!(super::answer(), 42); }
}
EOF
echo 'pub fn other() -> i32 { 1 }' > src/other.rs
echo target > .gitignore
sed -i.bak '1i\
pub mod other;
' src/lib.rs && rm src/lib.rs.bak
git add -A && old_commit "first"
marker="target/openapps-cache-commit"
"$script" "$marker" src Cargo.toml >/dev/null
cargo test -q --offline >/dev/null 2>&1 || { echo "error: the throwaway crate must pass first" >&2; exit 1; }
sed -i.bak 's/), 42)/), 41)/' src/lib.rs && rm src/lib.rs.bak
git add -A && old_commit "break the test, dated before the build"
checkout_like
out="$("$script" "$marker" src Cargo.toml)"
grep -q "2 unchanged files got their commit times, 1 changed files keep" <<< "$out" || { echo "error: expected two restored and one changed file (Cargo): $out" >&2; exit 1; }
if cargo test -q --offline >/dev/null 2>&1; then echo "error: Cargo reused the stale test binary — the change was lost" >&2; exit 1; fi
echo "ok: Cargo — a test changed in an older commit still fails after the cache"
