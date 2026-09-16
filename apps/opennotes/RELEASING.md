# Releasing OpenNotes

The official build is a universal (Apple silicon + Intel) `OpenNotes.app`
with licensing compiled in ([LICENSING.md](../../LICENSING.md): the 3-day
trial, Dodo live mode, the live product ID) and the in-app updater compiled
in, signed with the stable OpenApps HQ Release certificate and zipped, as
[RELEASES.md](../../RELEASES.md) specifies. It is installed with one
Terminal line or Homebrew and updates itself from a signed feed.
[`.github/workflows/opennotes.yml`](../../.github/workflows/opennotes.yml)
(the pipeline ticket) builds it on GitHub's `macos-26` runner, publishes it
as a GitHub Release, commits the update feed and the install script,
verifies both live and bumps the Homebrew cask. Nothing about a release is
manual except pushing the tag.

```sh
curl -fsSL https://openapps.space/install/opennotes | sh   # how users install it
brew install --cask openappshq/tap/opennotes               # or with Homebrew
brew upgrade --cask opennotes                              # how they can update too
```

The scripts the workflow runs are the ones you can run locally (the same
names as macPaper's and Hertz's):

| Script | Does |
| --- | --- |
| `scripts/generate-licensing-config.sh <out.swift>` | Writes the licensing configuration an official build compiles in (Dodo host and environment, paid product ID, trial registry URL, buy URL) from `OPENAPPS_*` variables; refuses placeholders for a live build. `bundle.sh` runs it; the file is gitignored and never committed |
| `scripts/bundle.sh` | `swift build -c release` (with `OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1` for the official flavour), assembles and signs `build/OpenNotes.app` (hardened runtime, no sandbox, `scripts/OpenNotes.entitlements`, the `opennotes://` URL scheme); with `OPENAPPS_OFFICIAL=1` compiles the shared updater in and pins the feed and update key |
| `scripts/make-zip.sh` | `ditto -c -k --keepParent` into `dist/OpenNotes-<version>.zip`, writes its `.sha256` |
| `scripts/verify-release.sh [--release] <zip>` | Unpacks the zip and runs the checks a user's Mac and the updater run; `--release` requires the pinned designated requirement, the release certificate, licensing compiled in against Dodo's live host with the trial registry, no placeholder product ID, test host or debug preview harness in the binary, and the committed update key pinned |
| `scripts/make-appcast.sh <zip>` | Signs the zip with the update key and writes the signed `dist/appcast.xml` |
| `scripts/sign-update.sh <key> [--feed] <file>` | Ed25519 signing, byte-compatible with Sparkle's `sign_update` |
| `scripts/verify-appcast.sh <appcast> [zip]` | Verifies a feed, and the zip it announces, with the public key only |
| `scripts/verify-live.sh <version> <sha256>` | Downloads the public zip and the live feed and checks both |
| `scripts/publish-release.sh [--dry-run]` | Creates the GitHub Release for a tag, only once the tag provably names the built commit |
| `scripts/create-update-key.sh <dir>` | One-time: creates the Sparkle EdDSA update key |
| `scripts/update-e2e.sh` | The local end-to-end update test: a throwaway certificate and update key, two versions built as the update-test variant (`OPENNOTES_UPDATE_TEST=1`, licensing forced off, its own bundle id, notes folder and Application Support folder), a signed feed served from 127.0.0.1, the fresh-install check default, the upgrade that never asks, consent withdrawn mid-download and after staging, the install on quit and Restart to Update. No secrets, no network beyond 127.0.0.1; everything removed afterwards |
| `scripts/make-icons.sh` | Renders `design/assets/*.svg` into the committed `AppIcon.icns` and menu-bar images |

Shared with every app (repository root): `scripts/release/*` — the
certificate, the designated requirement, the signing keychain, the tag
ruleset, the install script and its live check ([RELEASES.md](../../RELEASES.md)).

## Signing certificate and update key

The certificate is the one every OpenApps HQ app signs with
([RELEASES.md, Signing material](../../RELEASES.md#signing-material)); its
designated requirement for this app is pinned in
[`release/designated-requirement.txt`](release/designated-requirement.txt)
as `identifier "com.openappshq.opennotes" and certificate leaf = H"<sha1>"`
— the same certificate leaf as Hertz's and macPaper's, our own identifier.
The public half of the update key is committed in
[`release/sparkle-public-key.txt`](release/sparkle-public-key.txt) and
compiled in as `SUPublicEDKey`; the private half lives only in the
`opennotes-release` environment as `SPARKLE_ED_PRIVATE_KEY`.

## GitHub

The pipeline ticket's workflow follows macPaper's exactly: the tag ruleset
[`.github/rulesets/opennotes-release-tags.json`](../../.github/rulesets/opennotes-release-tags.json)
makes `opennotes-v*` tags immutable; the environment `opennotes-release`
(deployment branches and tags `main` and `opennotes-v*`) holds
`SPARKLE_ED_PRIVATE_KEY`, `FEED_COMMIT_TOKEN`, `HOMEBREW_TAP_DEPLOY_KEY` and
the licensing variables `OPENAPPS_DODO_PAID_PRODUCT_ID`, `OPENAPPS_BUY_URL`
and optional `OPENAPPS_SUPPORT_URL`; the certificate and
`RULESET_READ_TOKEN` are repository secrets and are never copied. The tap
`openappshq/homebrew-tap` takes `Casks/opennotes.rb` from
[`packaging/homebrew/Casks/opennotes.rb`](../../packaging/homebrew/Casks/opennotes.rb)
on the first release.

## Cutting a release

Merge to `main`, then:

```sh
git tag -a opennotes-v0.1.0 -m "OpenNotes 0.1.0"
git push origin opennotes-v0.1.0
```

The version is stamped from the tag (`CFBundleVersion` is derived from it,
`MAJOR*1000000 + MINOR*1000 + PATCH`, so builds order as releases do). The
workflow builds, signs, verifies, publishes, commits the feed and the
install script to `main`, checks both live and bumps the cask. A bad
release is pulled by committing the previous feed back and fixed with a new
patch version; tags are never moved or reused.

## Build flavours

| Flavour | Variables | Links | What differs |
| --- | --- | --- | --- |
| Source (default) | none | `OpenAppsLicensing` (the rules and the badge type only) | No trial, no License section, every note editable, no updater (Settings → Updates says so), no network calls |
| Official | `OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1`, `OPENAPPS_DODO_ENV`, `OPENAPPS_DODO_PAID_PRODUCT_ID` (+ `OPENAPPS_BUY_URL`, `OPENAPPS_SUPPORT_URL`, `OPENAPPS_TRIAL_REGISTRY_BASE_URL` optional) | `OpenAppsLicensingClients`, `OpenAppsUpdater` | The 3-day trial and read-only after it, the pill, Settings → License, the setup guide once, the updater with automatic checks on for a fresh install, the fresh-install login item |
| Update test | `OPENAPPS_OFFICIAL=1 OPENNOTES_UPDATE_TEST=1` (never with licensing; `Package.swift` and `bundle.sh` refuse it) | `OpenAppsUpdater` | Bundle id `com.openappshq.opennotes.updatetest`, feed from `UPDATE_FEED_URL`, test hooks (`OPENNOTES_UPDATE_TEST_ACTION`), no login item, no guide, its notes in `~/Library/Application Support/OpenApps/opennotes-updatetest/Notes`; `verify-release.sh` refuses its hooks in a release |

The licensing configuration is generated, never committed: `bundle.sh` runs
`scripts/generate-licensing-config.sh` into the gitignored
`Sources/OpenNotes/Licensing/LicensingConfig.swift` (Dodo host and
environment, the paid product, the trial registry `…/api/trial`, the buy
URL `https://openapps.space/opennotes/`, the support URL
`https://openapps.space/opennotes/#questions`). A live build refuses a
placeholder product id; the CI checks job compiles the test flavour with
`pdt_placeholder_opennotes`.

## Verify locally before the first publish

```sh
swift test                                                                       # source flavour
OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 swift test --scratch-path .build/official   # after generate-licensing-config.sh with the test product
OPENAPPS_OFFICIAL=1 OPENNOTES_UPDATE_TEST=1 swift test --scratch-path .build/updatetest
scripts/bundle.sh && scripts/make-zip.sh && scripts/verify-release.sh dist/OpenNotes-*.zip
OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 OPENAPPS_DODO_ENV=test OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… UNIVERSAL=1 \
    scripts/bundle.sh && scripts/make-zip.sh && scripts/verify-release.sh dist/OpenNotes-*.zip
scripts/update-e2e.sh                                       # the whole update path, throwaway keys, ~10 minutes
shellcheck scripts/*.sh
.build/debug/OpenNotes --preview /tmp/opennotes-preview   # every surface, light and dark, no window
```

A signing dry run with a throwaway certificate, `verify-release.sh
--release`, `actionlint` and a `publish=false` workflow run complete the
list (the `new-app` skill, §5). Before the first licensed release, run
LICENSING.md's end-to-end checks in Dodo test mode (a trial that ends,
a test checkout, 3 activations and the 4th refused, a refund, Remove this
Mac); a debug build shortens the trial with
`OPENNOTES_DEBUG_TRIAL_DAY_SECONDS=60`.
