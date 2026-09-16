# Releasing macPaper

macPaper follows [RELEASES.md](../../RELEASES.md) like every OpenApps HQ
app: a universal `macPaper.app` with licensing and the in-app updater
compiled in, signed with the stable OpenApps HQ Release certificate, zipped,
published as the GitHub release `macpaper-vX.Y.Z`, with a signed update
feed at `apps/website/public/updates/macpaper/` and a Homebrew cask,
`openappshq/tap/macpaper`. The release pipeline (`.github/workflows/macpaper.yml`,
the update key, the cask, the tag ruleset, the `macpaper-release` environment)
is a later ticket; this file grows with it. Hertz's [RELEASING.md](../hertz/RELEASING.md)
is the template.

What exists today:

| Piece | State |
| --- | --- |
| `scripts/generate-licensing-config.sh <out.swift>` | Writes the licensing configuration an official build compiles in (Dodo host and environment, paid product ID, trial registry URL, buy URL) from `OPENAPPS_*` variables; refuses placeholders for a live build. `bundle.sh` runs it; the file is gitignored and never committed |
| `scripts/bundle.sh` | `swift build -c release` (with `OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1` for the official flavour), assembles and signs `build/macPaper.app` (hardened runtime, no sandbox, `scripts/MacPaper.entitlements`, the `macpaper://` URL scheme; ad-hoc by default, the release certificate inside `scripts/release/with-signing-keychain.sh`); with `OPENAPPS_OFFICIAL=1` compiles the shared updater in and pins the feed and update key |
| `scripts/make-zip.sh` | `dist/macPaper-<version>.zip` and its `.sha256` |
| `scripts/verify-release.sh [--release] <zip>` | The checks a user's Mac and the updater run; `--release` requires the pinned designated requirement, the release certificate, licensing compiled in against Dodo's live host with the trial registry, no placeholder product ID or test host in the binary, the committed update key pinned, and nothing of the update-test variant |
| `scripts/make-icons.sh` | Renders `design/assets/*.svg` into the committed `AppIcon.icns` and menu-bar images |
| `release/designated-requirement.txt` | `identifier "com.openappshq.macpaper" and certificate leaf = H"<sha1>"`, the same certificate as every OpenApps HQ app |
| `release/sparkle-public-key.txt` | Not yet: created with the release ticket's `scripts/create-update-key.sh`. Until it is committed, an official build pins a throwaway key with `UPDATE_PUBLIC_ED_KEY` (below) |

## Build flavours

| Build | How | Licensing | Updater |
| --- | --- | --- | --- |
| From source (`swift build`, `scripts/bundle.sh`) | no variables | Compiled out: no License section, no trial, no license network calls, everything on | Compiled out: Settings → Updates says so |
| Official development | `OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 OPENAPPS_DODO_ENV=test OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_…` | Dodo test mode, the test product, trial registry `env: "test"` | On, feed and key pinned |
| Official release (CI) | the same with `OPENAPPS_DODO_ENV=live` and the live product ID | Dodo live mode | On, the committed key |
| Update test | `OPENAPPS_OFFICIAL=1 MACPAPER_UPDATE_TEST=1`, never with licensing | Compiled out | On, with test hooks; bundle id `com.openappshq.macpaper.updatetest`, no URL scheme, no login item, no setup guide |

`Package.swift` links `packages/openapps-licensing`'s rules into every build
(the badge type the UI carries and the manager the tests drive with fakes),
its Dodo, registry and preferences clients only into a licensed build, and
`packages/openapps-updater` only into an official build. `Package.swift`
and `bundle.sh` both refuse `MACPAPER_UPDATE_TEST=1` with
`OPENAPPS_LICENSING=1`, so the update-test variant can never reach the
record store, the registry or Dodo.

The licensing configuration is generated, never committed:

```sh
OPENAPPS_DODO_ENV=test OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… \
  scripts/generate-licensing-config.sh Sources/MacPaper/Licensing/LicensingConfig.swift
```

`OPENAPPS_DODO_ENV` is `test` (test.dodopayments.com, trial registry env
"test") or `live`. Optional: `OPENAPPS_TRIAL_REGISTRY_BASE_URL` (default
`https://openapps.space`; a test build may use a local `wrangler dev` such
as `http://127.0.0.1:8787`), `OPENAPPS_BUY_URL` (default
`https://openapps.space/macpaper/`, the website page that states the price;
the thanks page deep-links the key back as `macpaper://activate?key=…`, which
only pre-fills the key) and `OPENAPPS_SUPPORT_URL` ("Contact support" on a
revoked license; default `https://openapps.space/macpaper/#questions`, set it
empty to hide the link). The generator fails loudly
when anything a licensed build needs is missing, so a placeholder can never
ship; the checks job compiles the test flavour with `pdt_placeholder_macpaper`,
which `verify-release.sh --release` refuses.

## Licensing, trial and the setup guide

Official builds follow [LICENSING.md](../../LICENSING.md): a 3-day trial
that starts in the app with no signup, registered once with the trial
registry by a per-app hash of the hardware UUID; a paid license checked with
Dodo daily, with a week of offline grace; both records in the encrypted file
store under `~/Library/Application Support/OpenApps/macpaper/records/`,
never the Keychain. The core feature is generating and applying: while the
license restricts it, the panel and the popover show one card in the
generator's place, Shuffle (manual and scheduled), Apply, Export and a new
seed are off, and the wallpaper already applied stays. Every action asks the
controller's projection of the latest snapshot to the current clocks at the
click and again after every wait (the image picker, a render, a save panel,
each display's desktop call), so a deadline no timer has delivered yet still
refuses and nothing started under the trial commits after it. Settings →
License shows the state, Buy a license (the website states the price, the
app never does), the key field and Remove this Mac; the trial pill sits in
the panel's header and the Settings title bar.

The setup guide opens once, on the first launch of the packaged app
(welcome with the trial line from the real state, "Nothing to grant",
"Starts with your Mac" from the real login setting, tips), resumes where it
was left, and is reachable again from Settings → About → Show setup guide.
Update-test builds and `swift run` builds never open it.

Two settings turn on once, on a demonstrably fresh install (no preference
from an earlier launch, both records positively absent), and are recorded as
decided under their own flag (`FreshInstallDefault`, `MacPaperCore/FirstRun.swift`):
"Open at login" and "Check for updates automatically". "Download and install
automatically" stays off until the user turns it on. An upgrade never changes
a toggle the user could have set, and a toggle flipped while storage is still
answering wins.

## Updates

Official builds compile in the shared updater,
[`packages/openapps-updater`](../../packages/openapps-updater)
(`OPENAPPS_OFFICIAL=1`; source builds have no updater at all). `Info.plist`
pins the feed `https://openapps.space/updates/macpaper/appcast.xml`
(`SUFeedURL`) and the public update key (`SUPublicEDKey`); the app trusts
nothing in a feed before its Ed25519 signature verifies, and nothing in a
zip before its length, SHA-256 and signature do. A found update is said in
the panel ("macPaper X.Y.Z available — Install") and in Settings → Updates;
a staged one waits for quit or "Update ready — Restart". "Check Now" always
works, a copy outside Applications or under App Translocation says so
instead of checking, and `brew upgrade --cask macpaper` keeps working.
Updates never depend on the license or trial state. The quit path saves the
trial's latest observed time (bounded, so a stuck disk never holds up Quit)
and then hands the quit to the updater.

## Local rehearsal, no secrets

```sh
UNIVERSAL=1 VERSION=0.1.0 scripts/bundle.sh          # source flavour, ad-hoc signed
scripts/make-zip.sh
scripts/verify-release.sh dist/macPaper-0.1.0.zip    # the requirement is reported, not compared
```

An ad-hoc development build of the official flavour needs only the test
product ID and a throwaway public update key (until `release/sparkle-public-key.txt`
is committed, this is the only way to build the official flavour):

```sh
UNIVERSAL=1 OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 OPENAPPS_DODO_ENV=test \
OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… VERSION=0.1.0 \
UPDATE_PUBLIC_ED_KEY="$(xcrun swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())')" \
scripts/bundle.sh
scripts/make-zip.sh
scripts/verify-release.sh dist/macPaper-0.1.0.zip
```

The tests run in every flavour, none of them opening a window, reading the
real record store or reaching the network:

```sh
swift test
OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 swift test --scratch-path .build/official
OPENAPPS_OFFICIAL=1 MACPAPER_UPDATE_TEST=1 swift test --scratch-path .build/updatetest
```

Before the first licensed release, run LICENSING.md's end-to-end checks in
Dodo test mode with a test-mode build: the trial starts and ends on its own
(a debug build shortens it with `MACPAPER_DEBUG_TRIAL_DAY_SECONDS=60`), a
test checkout issues a key that activates on 3 Macs and is refused on the
4th, a refund revokes, Remove this Mac frees a slot.
