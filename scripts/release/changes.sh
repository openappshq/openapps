#!/usr/bin/env bash
# Says which parts of an app's checks a change calls for (RELEASES.md,
# "Pipeline": the "what runs when" table is this script's rules).
#
#   git diff --name-only <base> <head> | scripts/release/changes.sh <app-id> --diff [flavours] [redo]
#   scripts/release/changes.sh <app-id> --all [flavours] [redo]        # everything: no base to diff against
#   scripts/release/changes.sh <app-id> --fallback [flavours] [redo]   # a publish with no passed run: the suites
#   scripts/release/changes.sh <app-id> --nothing [flavours]           # a publish that relies on a passed run
#
# Prints one `name=true|false` line per decision, ready for $GITHUB_OUTPUT,
# and, given the app's flavours ("source licensed official update-test"),
# `flavours=[…]` — the JSON list of the matrix legs to run:
#
#   suite          the app's full test suite (the source flavour)
#   flavour_suite  the flavour-specific suites (apps/<app>/scripts/flavour-tests.txt), in
#                  every flavour but source — official, licensed and update-test alike
#   build_flavours the licensed and update-test flavours, built with their tests
#   bundle         the ad-hoc signed development app, verified like a release
#   update_e2e     the update end-to-end test
#   licensing_tests, updater_tests   the shared packages' own suites
#   lint           shellcheck, actionlint, the cask template
#   any            at least one of the above
#   flavours       source when the suite runs; official for the flavour suites, and
#                  for the bundle unless an app leg exists; licensed and update-test
#                  for the flavour suites or builds, update-test for the e2e too;
#                  app (a Tauri app's development build, its own leg) for the bundle
#
# A change under the app's Sources always runs the flavour suites: the
# licensing, enforcement, store and isolation checks are the floor that
# nothing skips. Markdown anywhere counts for nothing.
#
# `redo` names the check jobs of the branch's last run that failed or were
# cancelled (scripts/release/last-run-failures.sh), one per line; whatever
# they covered runs again — a failure never drops out because the next push
# touched something else. `--fallback` and `--all` accept it too.
set -euo pipefail

APP="${1:?usage: changes.sh <app-id> --diff|--all|--fallback|--nothing [flavours] [redo] (changed paths on stdin)}"
MODE="${2:---diff}"
FLAVOURS="${3:-}"
REDO="${4:-}"
[[ "$APP" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "error: app id must be lowercase letters, digits and dashes" >&2; exit 1; }
case "$APP" in
    openklack) DIR="apps/openklack-desktop" ;;
    *) DIR="apps/$APP" ;;
esac

# A path the feed job commits (feed-paths.txt, shared with checks-passed.sh):
# never a source change, and already outside every case below, but named
# explicitly so a future pattern that would otherwise match stays inert.
FEED_PATHS="$(dirname "${BASH_SOURCE[0]}")/feed-paths.txt"
is_feed_path() {
    local path="$1" pattern
    while IFS= read -r pattern; do
        [[ -z "$pattern" || "$pattern" == \#* ]] && continue
        # shellcheck disable=SC2053  # a glob from feed-paths.txt, matched on purpose
        [[ "$path" == $pattern ]] && return 0
    done < "$FEED_PATHS"
    return 1
}

# other: the rest of the app's tree — a Tauri app's web front end and its
# workspace packages, which its development build compiles.
sources=false tests=false app_scripts=false other=false licensing=false updater=false scripts=false workflow=false
case "$MODE" in
    --all) sources=true tests=true app_scripts=true other=true licensing=true updater=true scripts=true workflow=true ;;
    --fallback|--nothing) ;;
    --diff)
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            case "$path" in
                *.md) continue ;;
            esac
            is_feed_path "$path" && continue
            case "$path" in
                "$DIR"/Sources/*|"$DIR"/Package.swift|"$DIR"/src-tauri/*) sources=true ;;
                "$DIR"/Tests/*) tests=true ;;
                "$DIR"/scripts/*|"$DIR"/release/*) app_scripts=true ;;
                "$DIR"/*) other=true ;;
                packages/openapps-licensing/*) licensing=true ;;
                packages/openapps-updater/*) updater=true ;;
                packages/*|package.json|pnpm-lock.yaml|pnpm-workspace.yaml|tsconfig.base.json|tsconfig.json|vite.config.ts)
                    [[ "$APP" == openklack ]] && other=true ;;
                scripts/release/*|packaging/homebrew/*) scripts=true ;;
                .github/workflows/"$APP".yml|.github/rulesets/"$APP"-*) workflow=true ;;
                # OpenReaction's lint is the one that checks the shared workflows.
                .github/workflows/nightly.yml|.github/workflows/site.yml) [[ "$APP" == openreaction ]] && workflow=true ;;
            esac
        done ;;
    *) echo "error: unknown mode $MODE" >&2; exit 1 ;;
esac

any_of() { for v in "$@"; do [[ "$v" == true ]] && { echo true; return; }; done; echo false; }

if [[ "$MODE" == --fallback ]]; then
    suite=true flavour_suite=true build_flavours=false bundle=false update_e2e=false licensing_tests=false updater_tests=false lint=false
else
    suite="$(any_of "$sources" "$tests" "$workflow")"
    flavour_suite="$(any_of "$sources" "$tests" "$licensing" "$updater" "$workflow")"
    build_flavours="$(any_of "$sources" "$licensing" "$updater" "$workflow")"
    bundle="$(any_of "$sources" "$app_scripts" "$other" "$updater" "$scripts" "$workflow")"
    update_e2e="$(any_of "$sources" "$app_scripts" "$updater" "$workflow")"
    licensing_tests="$licensing"
    updater_tests="$updater"
    lint="$(any_of "$scripts" "$app_scripts" "$workflow")"
fi
# What the last run left failed or cancelled runs again, whatever this
# change touched (--nothing relies on a run that passed everything it ran).
if [[ "$MODE" != --nothing && -n "$REDO" ]]; then
    while IFS= read -r job; do
        case "$job" in
            "") ;;
            "checks (source)") suite=true ;;
            "checks (official)") flavour_suite=true; bundle=true ;;
            "checks (licensed)") flavour_suite=true; build_flavours=true ;;
            "checks (update-test)") flavour_suite=true; build_flavours=true; update_e2e=true ;;
            "checks (app)") bundle=true ;;
            packages) licensing_tests=true; updater_tests=true ;;
            lint) lint=true ;;
            checks) ;;  # the all-skipped placeholder never fails
            *) echo "error: unknown check job to redo: $job" >&2; exit 1 ;;
        esac
    done <<< "$REDO"
fi
for name in suite flavour_suite build_flavours bundle update_e2e licensing_tests updater_tests lint; do
    echo "$name=${!name}"
done
echo "any=$(any_of "$suite" "$flavour_suite" "$build_flavours" "$bundle" "$update_e2e" "$licensing_tests" "$updater_tests" "$lint")"

if [[ -n "$FLAVOURS" ]]; then
    legs=()
    case " $FLAVOURS " in *" app "*) bundle_in_official=false ;; *) bundle_in_official="$bundle" ;; esac
    for flavour in $FLAVOURS; do
        case "$flavour" in
            source) runs="$suite" ;;
            licensed) runs="$(any_of "$flavour_suite" "$build_flavours")" ;;
            official) runs="$(any_of "$flavour_suite" "$bundle_in_official")" ;;
            update-test) runs="$(any_of "$flavour_suite" "$build_flavours" "$update_e2e")" ;;
            app) runs="$bundle" ;;
            *) echo "error: unknown flavour $flavour" >&2; exit 1 ;;
        esac
        [[ "$runs" == true ]] && legs+=("\"$flavour\"")
    done
    printf 'flavours=[%s]\n' "$(IFS=,; echo "${legs[*]-}")"
fi
