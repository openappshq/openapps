#!/usr/bin/env bash
# changes.sh: which checks a change calls for, per kind of change — the
# "what runs when" table in RELEASES.md, "Pipeline".
set -euo pipefail
cd "$(dirname "$0")/.."

# expect <label> <app> <mode-or-paths> <expected true names, space separated; "-" for none>
expect() {
    local label="$1" app="$2" input="$3" want="$4"
    local got
    if [[ "$input" == --* ]]; then
        got="$(./changes.sh "$app" "$input")"
    else
        got="$(tr ' ' '\n' <<< "$input" | ./changes.sh "$app")"
    fi
    local truths
    truths="$(printf '%s\n' "$got" | sed -n 's/=true$//p' | paste -sd ' ' -)"
    [[ "$want" == - ]] && want=""
    if [[ "$truths" != "$want" ]]; then
        echo "error ($label): got '$truths', expected '$want'" >&2
        printf '%s\n' "$got" >&2
        exit 1
    fi
    echo "ok: $label"
}

all="suite flavour_suite build_flavours bundle update_e2e licensing_tests updater_tests lint any"
expect "no base to diff against: everything" macpaper --all "$all"
expect "a publish with no passed run: both suites" macpaper --fallback "suite flavour_suite any"
expect "a publish that relies on a passed run: nothing" macpaper --nothing -
expect "an empty diff" macpaper "" -
expect "docs only" macpaper "apps/macpaper/README.md RELEASES.md design/products/macpaper.md LICENSING.md" -
expect "another app's sources" macpaper "apps/hertz/Sources/Hertz/App.swift" -
expect "the app's sources: every leg, the floor included" macpaper "apps/macpaper/Sources/MacPaper/App.swift" "suite flavour_suite build_flavours bundle update_e2e any"
expect "Package.swift counts as sources" macpaper "apps/macpaper/Package.swift" "suite flavour_suite build_flavours bundle update_e2e any"
expect "the app's tests only: the suites, no build-only flavour, no bundle" macpaper "apps/macpaper/Tests/MacPaperCoreTests/PanelTests.swift" "suite flavour_suite any"
expect "the licensing package: its own tests, the flavour suites, the flavour builds" macpaper "packages/openapps-licensing/Sources/OpenAppsLicensing/Trial.swift" "flavour_suite build_flavours licensing_tests any"
expect "the updater package: its tests, the flavour suites and builds, the bundle and the e2e" macpaper "packages/openapps-updater/Sources/OpenAppsUpdater/Updater.swift" "flavour_suite build_flavours bundle update_e2e updater_tests any"
expect "the app's scripts: bundle, e2e, lint" macpaper "apps/macpaper/scripts/bundle.sh" "bundle update_e2e lint any"
expect "the pinned requirement" macpaper "apps/macpaper/release/designated-requirement.txt" "bundle update_e2e lint any"
expect "the shared release scripts: bundle, lint" macpaper "scripts/release/with-signing-keychain.sh" "bundle lint any"
expect "the cask: bundle, lint" macpaper "packaging/homebrew/Casks/macpaper.rb" "bundle lint any"
expect "the app's workflow: everything but the package suites" macpaper ".github/workflows/macpaper.yml" "suite flavour_suite build_flavours bundle update_e2e lint any"
expect "the app's tag ruleset" macpaper ".github/rulesets/macpaper-release-tags.json" "suite flavour_suite build_flavours bundle update_e2e lint any"
expect "another app's workflow" macpaper ".github/workflows/hertz.yml" -
expect "web packages and the JS workspace are nothing to a Swift app" macpaper "packages/ui/theme.css pnpm-lock.yaml package.json" -
expect "a mix accumulates" macpaper "apps/macpaper/Tests/MacPaperTests/AppModelTests.swift packages/openapps-licensing/Package.swift" "suite flavour_suite build_flavours licensing_tests any"
expect "OpenKlack's Rust tree is its sources" openklack "apps/openklack-desktop/src-tauri/src/main.rs" "suite flavour_suite build_flavours bundle update_e2e any"
expect "OpenKlack's front end and workspace packages: the development build" openklack "apps/openklack-desktop/src/App.tsx packages/openklack-ui/index.ts pnpm-lock.yaml" "bundle any"
expect "OpenKlack's release scripts" openklack "apps/openklack-desktop/release/build-signed.sh" "bundle update_e2e lint any"

legs() {
    local label="$1" app="$2" input="$3" flavours="$4" want="$5"
    local got
    got="$(tr ' ' '\n' <<< "$input" | ./changes.sh "$app" --diff "$flavours" | sed -n 's/^flavours=//p')"
    if [[ "$got" != "$want" ]]; then echo "error ($label): legs $got, expected $want" >&2; exit 1; fi
    echo "ok: $label"
}
four="source licensed official update-test"
legs "sources: every leg" macpaper "apps/macpaper/Sources/MacPaper/App.swift" "$four" '["source","licensed","official","update-test"]'
legs "tests only: the two suites" macpaper "apps/macpaper/Tests/MacPaperTests/AppModelTests.swift" "$four" '["source","official"]'
legs "the licensing package: the flavour suites and builds" macpaper "packages/openapps-licensing/Package.swift" "$four" '["licensed","official","update-test"]'
legs "the app's scripts: the bundle and the e2e" macpaper "apps/macpaper/scripts/bundle.sh" "$four" '["official","update-test"]'
legs "the shared scripts: the bundle" macpaper "scripts/release/write-install-script.sh" "$four" '["official"]'
legs "docs: no leg" macpaper "apps/macpaper/README.md" "$four" '[]'
legs "an app with two flavours" hertz "apps/hertz/Sources/Hertz/HertzApp.swift" "source official" '["source","official"]'
legs "OpenKlack's front end: the development build's own leg" openklack "apps/openklack-desktop/src/App.tsx" "source licensed official update-test app" '["app"]'
legs "OpenKlack's Rust tree: every leg" openklack "apps/openklack-desktop/src-tauri/Cargo.lock" "source licensed official update-test app" '["source","licensed","official","update-test","app"]'
legs "no flavours asked for: no list" macpaper "apps/macpaper/Sources/MacPaper/App.swift" "" ''
got="$(./changes.sh macpaper --fallback "$four" | sed -n 's/^flavours=//p')"
[[ "$got" == '["source","official"]' ]] || { echo "error (fallback legs): $got" >&2; exit 1; }
echo "ok: a publish with no passed run: the source and official legs"
if ./changes.sh macpaper --all "source nightly" >/dev/null 2>&1; then echo "error: an unknown flavour was accepted" >&2; exit 1; fi
if ./changes.sh "Bad App" --all >/dev/null 2>&1; then echo "error: a malformed app id was accepted" >&2; exit 1; fi
if ./changes.sh macpaper --whatever >/dev/null 2>&1; then echo "error: an unknown mode was accepted" >&2; exit 1; fi
echo "ok: bad arguments are refused"
