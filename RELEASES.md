# Releases and updates

How every OpenApps HQ app is released, installed and kept up to date. OpenKlack, OpenReaction and Hertz follow this document, and any new app under `apps/` must too. If an app needs to differ, change this document first. Licensing rules live in [LICENSING.md](LICENSING.md).

## Summary

| Piece | Choice |
| --- | --- |
| Install | One line, no Homebrew needed: `curl -fsSL https://openapps.space/install/<app> | sh` (the [install script](#install-script)); or the Homebrew cask from the `openappshq/homebrew-tap` tap: `brew install --cask openappshq/tap/<app>` |
| Code signing | A stable self-signed code-signing certificate (`OpenApps HQ Release`), the same for every release. No Apple Developer ID or notarization for now |
| Release tags | `<app>-vX.Y.Z` (strict SemVer, never moved or reused) |
| Release files | A zip of the `.app` attached to the GitHub Release for that tag |
| Update feed | `https://openapps.space/updates/<app>/latest.json`, a signed JSON file served by the website |
| Updates | Automatic *checks* on by default (decided 2026-09-16; before that, off): the app notices a new version and says so. Installing stays the user's move: "Update available — Install", `brew upgrade --cask <app>`, or the opt-in "Download and install automatically" toggle, **off by default** |
| Update signatures | Every feed and every zip is signed with an app-specific update key that official builds pin |

| App | Updater | Feed | Update key secret |
| --- | --- | --- | --- |
| OpenKlack | Tauri `updater` feature (Rust) | `updates/openklack/latest.json` + `.sig` | `TAURI_SIGNING_PRIVATE_KEY` |
| OpenReaction | `packages/openapps-updater` (Swift) | `updates/openreaction/appcast.xml` | `SPARKLE_ED_PRIVATE_KEY` |
| Hertz | `packages/openapps-updater` (Swift) | `updates/hertz/appcast.xml` | `SPARKLE_ED_PRIVATE_KEY` |

Hertz's standalone self-updater was removed on import because it fetched the repository-wide latest GitHub release; the shared updater replaced it (decided 2026-09-16). Releases before that (`hertz-v0.1.x`) have no updater and update through `brew upgrade --cask hertz` only.

## Why a stable self-signed certificate

macOS ties Accessibility and Input Monitoring to an app's code-signing identity (its *designated requirement*). An ad-hoc signature's identity is the build's hash (`cdhash`), so every update would count as a different app: OpenReaction would lose Accessibility, OpenKlack would lose Input Monitoring. A self-signed certificate with the same identity for every release keeps a stable designated requirement (`identifier "<bundle id>" and certificate leaf = H"<cert hash>"`), so permissions survive updates.

- **Generation:** a one-time script creates the certificate and private key. It's exported as a password-protected `.p12`, stored once as the `RELEASE_SIGNING_P12` and `RELEASE_SIGNING_P12_PASSWORD` **repository** secrets ([Signing material](#signing-material)), and backed up offline. Losing it means every installed user re-grants permissions once.
- **Signing:** the release job imports it into a temporary keychain, signs with hardened runtime, then deletes the keychain immediately after the last signing step.
- **Verification before publishing:** `codesign --verify --deep --strict`, and the designated requirement must equal the pinned one checked in at `apps/<app>/release/designated-requirement.txt`. A mismatch fails the release.
- **Gatekeeper:** the app isn't notarized, so the cask and the install script clear the quarantine flag after install. A zip downloaded by hand needs right-click → Open once.
- **If identity ever changes anyway:** users re-grant permissions once, which the user accepts for manual updates. The stable certificate is still kept for the permissions. License and trial records live in an encrypted file the app owns, not in the Keychain (`LICENSING.md`, Record store), so an identity change never prompts for them.
- **Later:** switching to Apple Developer ID changes the identity once. Plan that as a single migration release that tells users to re-grant permissions.

## Signing material

Two kinds of secret, kept in two places (decided 2026-09-16; before that every app's environment held a copy of everything, and GitHub cannot read a secret back, so a new app meant re-creating material nobody had any more). The split follows what each secret can do: material that only *signs* is shared once at repository level; anything that can *publish* stays behind an environment, whose deployment-branch policy decides which refs may run with it.

| Where | Secret | Used by |
| --- | --- | --- |
| **Repository** secrets (Settings → Secrets and variables → Actions), shared by every app | `RELEASE_SIGNING_P12`, `RELEASE_SIGNING_P12_PASSWORD` | The release job, to sign with the stable certificate |
| | `RULESET_READ_TOKEN` | The publish job, to read the tag ruleset (Administration: read only; it can change nothing) |
| **Environment** `<app>-release`, one per app, deployment branches `main` and tags `<app>-v*` | The app's update key: `SPARKLE_ED_PRIVATE_KEY` (Swift apps) or `TAURI_SIGNING_PRIVATE_KEY` (OpenKlack) | The release job, to sign the zip and the feed |
| | `FEED_COMMIT_TOKEN` | The feed job, to commit the feed and the install script to `main` |
| | `HOMEBREW_TAP_DEPLOY_KEY` | The feed job, to push the cask bump to the tap |
| | Variables `OPENAPPS_DODO_PAID_PRODUCT_ID`, `OPENAPPS_BUY_URL`, `OPENAPPS_SUPPORT_URL` (OpenKlack: `OPENKLACK_*`) | The release job, compiled into the licensed build |

`${{ secrets.NAME }}` in a job that runs in an environment resolves the environment's secret first and falls back to the repository's, so the workflows name every secret exactly as before. A new app creates its environment with its update key, the two publishing credentials (the same token and deploy key every app uses; copy them from the offline backup) and its variables; the certificate is never copied. The release job checks each secret up front and names the missing one and where it belongs.

Why the two publishing credentials are per environment although every app shares the same values: a repository secret is readable by any workflow run in this repository, from any branch, by anyone who can push one — only pull requests from forks get none. An environment secret is reachable only by a job that runs in that environment, which the deployment-branch policy grants to `main` and the app's release tags alone. So everyone with write access to this repository can *sign* with the certificate (treat granting write access as adding a signer), but *publishing* — committing a feed or install script, moving the cask — still needs a run on `main` or a release tag, and a release still needs the tag ruleset and the publish job's checks.

Do not delete a repository secret to "rotate" it: set the new value in place. The certificate is the identity every installed copy trusts (above); the update keys are per app and losing one strands that app's updater the same way.

## Homebrew cask

Tap repository: `openappshq/homebrew-tap`, one cask per app in `Casks/<app>.rb`.

```ruby
cask "<app>" do
  version "X.Y.Z"
  sha256 "<sha256 of the zip>"
  url "https://github.com/openappshq/openapps/releases/download/<app>-v#{version}/<App>-#{version}.zip"
  name "<App>"
  desc "<one line>"
  homepage "https://openapps.space/<app>/"
  auto_updates true
  depends_on macos: :sonoma
  app "<App>.app"
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/<App>.app"], must_succeed: false
    run "/usr/bin/open", args: ["{{appdir}}/<App>.app"], must_succeed: false
  end
  uninstall quit: "<bundle id>"
  zap trash: ["~/Library/Preferences/<bundle id>.plist", "~/Library/Application Support/<App>"]
end
```

- **Location:** `/Applications`, Homebrew's default `appdir` and where a dragged disk image lands (decided 2026-09-16; before that `~/Applications`). Admin accounts write there without a password, so the in-app updater needs none either; a non-admin account installs with `--appdir`. The System Settings privacy pickers open on `/Applications`, which is why it matters.
- **`auto_updates true`:** Homebrew doesn't fight the in-app updater.
- **`postflight_steps`:** Homebrew's declarative install steps (Homebrew 5.1.14 and newer; the Ruby `postflight do … end` block is deprecated since 6.0.16 and warns on every install). A steps block only takes the fixed step verbs (`run`, `move`, `remove`, …) with literal arguments — no `system_command`, no Ruby interpolation — and `{{appdir}}` is expanded by Homebrew at install time, so `--appdir` is honoured. `must_succeed: false` keeps the old behaviour: a failed `xattr` or `open` is printed, never fails the install. The steps run in Homebrew's sandbox, which allows writes to the app directory.
- **Tap trust:** Homebrew 6 and newer trust third-party casks one at a time. The fully qualified `brew install --cask openappshq/tap/<app>` taps `openappshq/tap` and trusts just that cask (it prints `Trusted cask openappshq/tap/<app>`); nothing to confirm, and `brew upgrade --cask <app>` keeps working afterwards. Never ask users for `brew trust openappshq/tap`: that would trust every current and future cask in the tap.
- **Bumping the cask:** the release workflow updates the cask right after a release is published, by pushing a commit to the tap with an SSH deploy key that can write only to that repository (`HOMEBREW_TAP_DEPLOY_KEY`). There's no polling cron. The cask's `sha256` is the digest the release job verified.

## Install script

`curl -fsSL https://openapps.space/install/<app> | sh` is the primary install on the website (decided 2026-09-16): most people don't have Homebrew, and a plain download is blocked by Gatekeeper without notarization. Homebrew stays as the alternative line.

| Piece | Choice |
| --- | --- |
| URL | `https://openapps.space/install/<app>`, served with `Content-Type: text/x-shellscript; charset=utf-8` and `Cache-Control: public, max-age=0, s-maxage=300, must-revalidate` (`apps/website/headers.ts`): the edge may keep it five minutes like a feed, every client revalidates |
| File | `apps/website/public/install/<app>`, committed; a static, pinned POSIX `sh` script, no bashisms, `set -eu`, nothing read from the terminal |
| Generator | `scripts/release/write-install-script.sh <app-id> <App> <version> <sha256> <out-file>`. The bundle identifier per app is fixed in the generator |
| Pinning | The script names one release: the zip the cask installs and its SHA-256, the digest the release job verified. The generator refuses a lower version and the same version with a different digest, like `bump-cask.sh`; the same release regenerates the file so a template change reaches the served script on the next release |
| Pipeline | Each app's `feed` job regenerates the script in the same commit as the feed (after "Never move the stable feed backwards", where the workflow has it), then `scripts/release/verify-live-install-script.sh <app-id> <version> <sha256>` checks that the served script pins the version and digest, is typed as a shell script, parses and equals the committed file |
| Options | `OPENAPPS_INSTALL_DIR` installs into another folder (the tests use it) |
| Tests | `scripts/release/tests/install-script.test.sh`: a throwaway zip over `127.0.0.1`, `open`/`osascript`/`pgrep` stubbed; run from `openreaction.yml`'s script-test step |

What the script does, in order, and what it refuses:

1. macOS only (`uname`), macOS 14 or newer (`sw_vers`), `curl`, `unzip`, `realpath`, `stat` and `xattr` present, `shasum` or `openssl`. Universal zip, so Apple silicon and Intel are the same path.
2. Picks `/Applications` when the account can write there (admin accounts can, no password), otherwise `~/Applications` with a line saying so. Never `sudo`. A destination folder that is a symbolic link, or a `<App>.app` that is one, is refused: the install would land somewhere other than the path it names.
3. Downloads the release zip over https only (`--proto '=https' --tlsv1.2`) into a private `mktemp -d`, then checks its SHA-256 against the pinned digest **before anything is unpacked**. A mismatch deletes the download and exits 1 with a message that says nothing was installed.
4. Checks the archive listing (`unzip -Z1`): every entry under `<App>.app/` (or ditto's `__MACOSX/` metadata), no absolute or `..` paths. Unpacks with `ditto -xk` (or `unzip`) in the private directory; exactly one `<App>.app` with `Contents/Info.plist`, and every symbolic link inside it must resolve (`realpath`) inside the bundle. Anything else exits 1 before the install starts.
5. If a copy is running (`pgrep -x <App>`), asks it to quit with `osascript -e 'quit app id "<bundle id>"'` in the background and polls for up to ten seconds in all, so a stalled app or an unanswered Automation prompt cannot hold the install; then continues either way. A copy that did not quit is reported, the last line says to quit it and reopen the app, and `open` is skipped. (The first time, macOS may ask to allow Terminal to control the app.)
6. Copies the new bundle into a hidden staging folder created with `mktemp -d` next to its final place. An existing `<App>.app` is moved into another `mktemp -d` folder this run owns (`.<App>.previous.XXXXXX/<App>.app`), the new one is renamed in, and its identity (device and inode, which a rename keeps) is checked at the final path; only then is that exact previous folder removed. Nothing this run did not create is ever deleted. If the rename fails or something else appeared at the path meanwhile, the run undoes its own move, keeps the previous copy and prints where it is, and exits 1. An interrupt caught by the shell puts the previous copy back; a process killed outright between the two renames leaves it at the printed hidden folder, where the next run of the script never touches it.
7. `xattr -dr com.apple.quarantine` on the installed bundle; a failure is printed, and if the attribute is still present the script says so and does not open the app (macOS would ask to confirm the first open). Otherwise `open -a`, and a last line naming where it went and that the app updates itself from then on.

Pipe safety: the whole script is a `main` function called on its last line (`main </dev/null`), so a download cut short before that call defines functions and constants and installs nothing (a prefix ending inside a function is a syntax error), and no command inside can read the script off stdin.

## Release flow (one GitHub Actions workflow per app)

Trigger: a pushed `<app>-vX.Y.Z` tag, or a manual dispatch with a version.

1. **Build** the universal `.app` with licensing on, stamping the version from the tag.
2. **Sign** with the stable certificate, verify the designated requirement, then delete the signing keychain.
3. **Zip** with `ditto -c -k --keepParent` into `<App>-X.Y.Z.zip`, and record its SHA-256 as a job output.
4. **Sign the update:** sign the zip with the app's update key (OpenReaction: Sparkle EdDSA `sign_update`; OpenKlack: the Tauri updater key).
5. **Publish** the GitHub Release for the tag with the zip, using the existing hardened publish path: draft, then check the tag SHA against the built commit, then undraft, with a separate job holding write access.
6. **Write the feed:** generate `apps/website/public/updates/<app>/latest.json`, sign it, regenerate the [install script](#install-script) with the same version and digest, and commit both to `main` with the release bot. The website deploy then serves them at `https://openapps.space/updates/<app>/latest.json` and `https://openapps.space/install/<app>`.
7. **Verify live:** fetch the public zip, the feed and the install script, then check the digest, the feed signature, the version and the script's pin.
8. **Bump the cask** in `openappshq/homebrew-tap`.

The feed and the install script never point at a release until that release's zip is published and verified.

## Pipeline

One workflow per app (`.github/workflows/<app>.yml`), plus `site.yml` for the JavaScript workspace and `nightly.yml` for the full suites. Decided 2026-09-17, after macPaper 0.2.0 took 85 minutes from push to live: four flavours ran the same 318-test suite serially, twice (once on the push, once again inside the publish run), two new tests rendered for 12 minutes, and the shared runner pool is small — the organisation's plan allows **five macOS jobs at a time** across every workflow, so a job is a slot, not free parallelism. The rules below cut the work first and parallelise what is left.

### Jobs

| Job | Runner | What |
| --- | --- | --- |
| `preflight` | Linux | Classifies the change with `scripts/release/changes.sh`, adds whatever the branch's last run left failed or cancelled (`scripts/release/last-run-failures.sh`), records the plan as the run's `preflight` artifact and, on a manual run only, looks for a passed run with `scripts/release/checks-passed.sh`. Everything else keys off its outputs |
| `checks (<flavour>)` | macOS | One leg per flavour the change calls for, in parallel, each building its flavour with its tests from the cached build directory. **source** runs the whole suite; **official**, **licensed** and **update-test** run the suites that read the flavour (`apps/<app>/scripts/flavour-tests.txt`, joined by `scripts/release/test-filter.sh`: the app target's module, whose isolation, licensing and updater assertions differ per flavour); **official** then builds the ad-hoc signed development app and **update-test** runs the update end-to-end test. OpenKlack: the Cargo feature sets (none, `licensing`, `licensing,updater`, `updater`) test and lint in their legs and the development app builds in an `app` leg |
| `packages` | macOS | The shared licensing and updater packages' own suites, when a package changed |
| `lint` | Linux (macOS for OpenReaction, whose release-script tests need `security`, `ditto` and `xattr`) | `shellcheck`, `actionlint`, the cask template, the pipeline scripts' tests |
| `release`, `publish`, `feed` | — | Unchanged. `release` needs every job above: `checks` must have passed here or been skipped because preflight found a passed run; `packages` and `lint` may be skipped on a manual run only; never after a failure or a cancellation |

### Skip what already passed

A manual run (`workflow_dispatch`, the publish path) never repeats checks that passed: `checks-passed.sh <workflow file> <sha>` reads the workflow's completed runs for the commit, newest first, and accepts the first that **concluded `success` as a run** (a cancelled run is none, however its jobs ended) whose check jobs — every job except `preflight`, `release`, `publish`, `feed` — all passed, the last of them within 24 hours (`CHECKS_MAX_AGE_HOURS`). The run's own plan (its `preflight` artifact) says which jobs it skipped by design: `packages` and `lint` may be skipped only if the plan left them out, and the plan must have included both the source suite and the flavour suites — a run that only built the bundle, or whose checks were themselves skipped, proves nothing. Without a plan every check job must have passed. Found: no check job runs, and the release job's summary names the run it relied on. Not found, or the API unreadable: the source flavour and the flavour suites run, then the release. A push or pull request never relies on an earlier run; a tag push runs everything (there is no previous commit to diff against). Tested against recorded API answers, the targeted-run shape and a cancelled run included: `scripts/release/tests/checks-passed.test.sh`.

The dispatched commit is often not the one that was last checked: another app's release, or this app's own feed commit, lands on top of it first (macPaper 0.2.1 dispatched onto `66f9091`, OpenNotes' feed commit — the source and official legs re-ran from cache for nothing). So when the commit itself has no passed run, `checks-passed.sh` walks back over up to 10 first-parent ancestors while `git diff --name-only --no-renames <ancestor> <sha>` touches only the feed job's own paths (`scripts/release/feed-paths.txt`, the same list `changes.sh` reads to classify a feed-only push as nothing to run) and takes the first ancestor with its own passed run; any non-feed path in the diff stops the walk there, since an ancestor's diff only grows going further back. Found this way, the summary names both: "checks passed at `<ancestor>`; `<sha>` differs only by feed files". Dispatching with `--ref <the ancestor's sha>` instead of the branch's head is equivalent, and preferred when scripting: it names the evidence directly rather than relying on the walk.

### Run what the change touches

`changes.sh <app-id> --diff [flavours] [redo]` reads the changed paths (`git diff --name-only --no-renames` against the previous push, or the pull request's base — plain rename detection would show only a moved file's new name, and a source file renamed into a path nothing classifies would then look like no change at all; a new branch, or a force-push whose previous commit is gone, has no base and runs everything) and prints the decisions; the table is its rules, and `scripts/release/tests/changes.test.sh` holds them. The previous push is never assumed green: `last-run-failures.sh` reads the branch's newest completed run and every check job it left failed or cancelled is redone by this run whatever the diff says (a run that broke before any check could pass, or that cannot be read, means everything runs) — so a package failure survives a tests-only push, and the legs a newer push cancelled (below) run on that newer push. Markdown counts for nothing anywhere, and the workflows' `paths` filters already leave Markdown, `design/`, `LICENSING.md` and `RELEASES.md` out: a docs-only push runs no workflow at all. A website-only change runs `site.yml` alone (lint, tests, the design check, the website build, the worker); `design/` triggers it too, since the design check reads the tokens.

| Change | source suite | flavour suites (official, licensed, update-test) | licensed / update-test build | bundle | update e2e | package suites | lint |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `apps/<app>/Sources/**`, `Package.swift` (OpenKlack: `src-tauri/**`) | ✓ | ✓ **always** | ✓ | ✓ | ✓ | | |
| `apps/<app>/Tests/**` | ✓ | ✓ | | | | | |
| `packages/openapps-licensing/**` | | ✓ | ✓ | | | licensing | |
| `packages/openapps-updater/**` | | ✓ | ✓ | ✓ | ✓ | updater | |
| `apps/<app>/scripts/**`, `apps/<app>/release/**` | | | | ✓ | ✓ | | ✓ |
| `scripts/release/**`, `packaging/homebrew/**` | | | | ✓ | | | ✓ |
| `.github/workflows/<app>.yml`, the app's ruleset | ✓ | ✓ | ✓ | ✓ | ✓ | | ✓ |
| The rest of the app's tree (OpenKlack's front end and its workspace packages) | | | | ✓ | | | |
| Tag push, new branch, force-push | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Manual run, checks already passed | | | | | | | |
| Manual run, no passed run | ✓ | ✓ | | | | | |
| Whatever the branch's last run left failed or cancelled | ✓ where it failed | ✓ where it failed | ✓ where it failed | ✓ where it failed | ✓ where it failed | ✓ where it failed | ✓ where it failed |

What a fix during a release costs (OpenNotes 0.1.1, 2026-09-17, paid two full 35-minute cycles for one timing-sensitive window test): a push that touches only `Tests/**` runs the source and official suites, a few minutes in parallel; the publish dispatch that follows finds that run and runs no checks at all. A test that watches the clock or a window's timing belongs under `.heavy` if it cannot be made deterministic — never in the push path.

The floor: a change under an app's `Sources` always runs that app's flavour suites — licensing wiring and enforcement, the keeper, the updater's wiring, the setup guide — in the official flavour, and the update end-to-end test stays on every change to the app's sources, scripts or the updater. Nothing that gates licensing or data safety leaves the push path.

### Test once, build the rest

Every app's `<App>Core` target is compiled the same in every flavour; only the app target reads `OPENAPPS_LICENSING`/`OPENAPPS_OFFICIAL`/the update-test define. So the source flavour runs the whole suite once, and every other flavour runs the app target's suites (`flavour-tests.txt`: `MacPaperTests`, `OpenNotesTests`, `HertzTests`; OpenReaction's `OpenReactionTests.GateRunnerShutdownTests`, the one app suite that never touches real input) — a few hundred fast tests whose assertions differ per flavour: OpenNotes' update-test variant keeping its notes in its own `Notes` folder, the updater compiled in or out, the About copy's network claims. Locally `swift test` in any flavour still runs everything.

### Heavy tests

A test that renders at 4K or more, drives sheets, measures a budget in wall-clock time, or takes more than five seconds on its own is marked heavy: in Swift Testing `@Test("…", .heavy, .tags(.heavy))` with the `Heavy.swift` support file in the test target (`extension Trait where Self == ConditionTrait { static var heavy }` skips it while `OPENAPPS_HEAVY_TESTS=0`; the tag is for Xcode's filters); in XCTest, `try XCTSkipIf(ProcessInfo.processInfo.environment["OPENAPPS_HEAVY_TESTS"] == "0")` at the top of the test. The app workflows set `OPENAPPS_HEAVY_TESTS=0`; a local run and the nightly leave it unset. Today, all in macPaper: `presetsRead` (every preset through every context, 7.5 minutes in a debug build), `fiveK` (three 5K renders, 5 minutes), `shuffleNeverMakesABaseLayer` (forty documents through the quality gate, 4 minutes) and the five quality-gate sweeps — the taste set, the preset × field matrix, random documents, both-context and same-on-all draws — at 15–30 seconds each, which together held the parallel run for two and a half minutes. The gate's rules stay covered on every push by the per-family and data-driven known-good/known-bad cases.

`nightly.yml` runs every app's full suite in every flavour, heavy tests included, plus the packages and OpenKlack's feature sets, at 03:00 UTC and on demand. A failure opens the issue labelled `nightly`, or comments on the open one; close it when the run is green again. GitHub also e-mails the failure of a scheduled run.

### Build cache

Each leg restores `apps/<app>/.build` from `actions/cache`, keyed by app, flavour, the toolchain version and the package manifests, with the newest cache for the flavour as the fallback, and saves its own build for the next run (90–200 MB each, compressed). A newer push to the same branch or pull request cancels the older run's checks (workflow-level `concurrency`, `cancel-in-progress` for pushes and pull requests only — a tag push or a manual run is its own group and is never cancelled); the legs it cancelled are redone by the newer run. OpenKlack's legs share one cache of `src-tauri/target` and the Cargo registry (about a gigabyte; a target directory holds every feature set side by side), keyed by toolchain and `Cargo.lock`. Old caches go first when the repository's 10 GB fill up; the steady state is one commit's worth, under 4 GB. A checkout stamps every file with the time it was written, which would make SwiftPM rebuild everything, so `scripts/release/restore-mtimes.sh` first gives every tracked file **unchanged since the cache's own commit** its last commit's time — the cache carries the commit it was built from in a marker file, `git diff` against it says what changed, and a changed file keeps the checkout's now, newer than anything cached. That distinction is what keeps a build system honest whichever way it compares times: Cargo asks "newer than my output?", and a changed file's commit time can be older than the cached build (a rebase, a merge of an older branch), so it must never receive one. `scripts/release/tests/restore-mtimes.test.sh` proves it for SwiftPM and Cargo: a test changed in a commit dated before the cached build must fail. The legs check out with the history for all this. The official flavour's generated `LicensingConfig.swift` is gitignored, outside `.build`, and removed at the end of the job either way; the cache holds compiled placeholder configuration only, which nothing publishes and `verify-release.sh --release` would refuse.

### Adding an app

The `new-app` skill copies this shape: `preflight` with the app's flavours, the matrix, `packages`, `lint`, and `release` needing all four with the pass-or-skipped rule; `apps/<app>/scripts/flavour-tests.txt`; the app's rows in `nightly.yml`. Keep the job names — `checks-passed.sh` counts every job except `preflight`, `release`, `publish` and `feed` as a check.

## Update feed

`https://openapps.space/updates/<app>/latest.json`. The same URL keeps working when the website moves from Vercel to Cloudflare, so installed apps never change it.

```json
{
  "app": "openreaction",
  "channel": "stable",
  "version": "1.2.0",
  "build": 42,
  "minimum_macos": "14.0",
  "published_at": "2026-09-15T10:00:00Z",
  "notes": "Short release notes.",
  "url": "https://github.com/openappshq/openapps/releases/download/openreaction-v1.2.0/OpenReaction-1.2.0.zip",
  "sha256": "<hex>",
  "signature": "<update-key signature of the zip>"
}
```

- **Feed signature:** `latest.json.sig`, next to the feed, signs the exact feed bytes with the same update key. Apps verify it against the public key compiled into the official build before trusting any field. A feed or zip that fails verification is ignored, and nothing is installed.
- **Per-app shape:** an app may publish its updater's native format instead (Sparkle `appcast.xml` with `sparkle:edSignature`, Tauri `latest.json` with `platforms`), as long as the feed itself is signed and carries the fields above.
- **Newer versions only:** apps never downgrade.
- **Pulling a bad release:** commit the previous feed back. Installs that already updated keep it, and the fix ships as a higher version. Tags are never reused.

## In-app updater

| Rule | Detail |
| --- | --- |
| Who updates | Official builds only. Builds from source never check, download or install |
| When | With automatic checks on (the default on a fresh install): on launch in the background, every 24 hours while running, and on wake if the last check is older than 24 hours. With automatic checks off, the app never contacts the feed on its own |
| Settings | "Check for updates automatically" (**on** by default), "Download and install automatically" (**off** by default), and "Check now", which always works. **Defaults apply to fresh installs only:** a default is written once, the first time the app runs with no earlier preferences, and recorded as decided; an upgrade never changes a toggle the user could have set, whether they touched it or not. Same rule as "Open at login" |
| Install | Download and verify in the background, then install on the next quit or relaunch; the menu shows "Update ready — Restart". Never interrupt typing or sound playback mid-use |
| Location | Install in place; if the app runs from a read-only location or App Translocation, show "Move <App> to Applications to enable updates" instead |
| Failures | Retry with backoff (1 hour, then daily). Never loop or block the app |
| Licensing | Updates never depend on the license or trial state |
| Privacy | The check sends only a plain GET for the feed. No identifiers |

## Build and test locally

Every release step has a local dry run that needs no secrets:

- a throwaway self-signed certificate and update key generated into a temporary directory;
- the full build, sign, zip, update-sign and feed generation;
- verification of the designated requirement and both signatures;
- an update test that serves a feed and zip from `127.0.0.1` to a dev build configured with the throwaway public key, and confirms download, verification and install-on-quit.
