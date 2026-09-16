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

> **Status.** This document is the skeleton the app ships with its first
> ticket. The licensing and updater wiring (the parity ticket) and the
> workflow, cask and environment (the pipeline ticket) fill the seams it
> names: until they land, `scripts/bundle.sh` builds the source flavour
> only, `OPENAPPS_LICENSING=1` has nothing to compile the generated
> configuration against, and `scripts/update-e2e.sh` does not exist yet.

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
| `scripts/update-e2e.sh` | The local end-to-end update test, no secrets, no network beyond 127.0.0.1 (arrives with the updater wiring) |
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

## Verify locally before the first publish

```sh
swift test
scripts/bundle.sh && scripts/make-zip.sh && scripts/verify-release.sh dist/OpenNotes-*.zip
shellcheck scripts/*.sh
.build/debug/OpenNotes --preview /tmp/opennotes-preview   # every surface, light and dark, no window
```

A signing dry run with a throwaway certificate, `verify-release.sh
--release`, `actionlint` and a `publish=false` workflow run complete the
list once the pipeline ticket lands (the `new-app` skill, §5).
