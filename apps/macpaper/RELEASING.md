# Releasing macPaper

The official build is a universal (Apple silicon + Intel) `macPaper.app` with
licensing compiled in ([LICENSING.md](../../LICENSING.md): the 3-day trial,
Dodo live mode, the live product ID) and the in-app updater compiled in,
signed with the stable OpenApps HQ Release certificate and zipped, as
[RELEASES.md](../../RELEASES.md) specifies. It is installed with the one-line
install script or with Homebrew and updates itself from a signed feed (see
"Updates" below).
[`.github/workflows/macpaper.yml`](../../.github/workflows/macpaper.yml) builds it
on GitHub's `macos-26` runner, publishes it as a GitHub Release, commits the
update feed, verifies both live and bumps the Homebrew cask. Nothing about a
release is manual except pushing the tag.

```sh
curl -fsSL https://openapps.space/install/macpaper | sh   # how users install it
brew install --cask openappshq/tap/macpaper               # or with Homebrew
brew upgrade --cask macpaper                              # how they can update too
```

The scripts the workflow runs are the ones you can run locally:

| Script | Does |
| --- | --- |
| `scripts/generate-licensing-config.sh <out.swift>` | Writes the licensing configuration an official build compiles in (Dodo host and environment, paid product ID, trial registry URL, buy URL) from `OPENAPPS_*` variables; refuses placeholders for a live build. `bundle.sh` runs it; the file is gitignored and never committed |
| `scripts/bundle.sh` | `swift build -c release` (with `OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1` for the official flavour), assembles and signs `build/macPaper.app` (hardened runtime, no sandbox, `scripts/MacPaper.entitlements`, the `macpaper://` URL scheme); with `OPENAPPS_OFFICIAL=1` compiles the shared updater in and pins the feed and update key |
| `scripts/make-zip.sh` | `ditto -c -k --keepParent` into `dist/macPaper-<version>.zip`, writes its `.sha256` |
| `scripts/verify-release.sh [--release] <zip>` | Unpacks the zip and runs the checks a user's Mac and the updater run; `--release` requires the pinned designated requirement, the release certificate, licensing compiled in against Dodo's live host with the trial registry, no placeholder product ID or test host in the binary, and the committed update key pinned |
| `scripts/make-appcast.sh <zip>` | Signs the zip with the update key and writes the signed `dist/appcast.xml` |
| `scripts/sign-update.sh <key> [--feed] <file>` | Ed25519 signing, byte-compatible with Sparkle's `sign_update` |
| `scripts/verify-appcast.sh <appcast> [zip]` | Verifies a feed, and the zip it announces, with the public key only |
| `scripts/verify-live.sh <version> <sha256>` | Downloads the public zip and the live feed and checks both |
| `scripts/publish-release.sh [--dry-run]` | Creates the GitHub Release for a tag, only once the tag provably names the built commit |
| `scripts/create-update-key.sh <dir>` | One-time: creates the Sparkle EdDSA update key |
| `scripts/update-e2e.sh` | The local end-to-end update test, no secrets, no network beyond 127.0.0.1 |
| `scripts/make-icons.sh` | Renders `design/assets/*.svg` into the committed `AppIcon.icns` and menu-bar images |

Shared with every app (repository root):

| Script | Does |
| --- | --- |
| `scripts/release/create-signing-certificate.sh <dir>` | One-time: creates the `OpenApps HQ Release` certificate as a password-protected `.p12` |
| `scripts/release/designated-requirement.sh <bundle id> <cert.pem>` | Prints the designated requirement to pin |
| `scripts/release/with-signing-keychain.sh <command>` | Runs one command with the certificate in a temporary keychain, then removes it |
| `scripts/release/verify-designated-requirement.sh <app> <pinned file>` | Fails unless an app has exactly the pinned requirement |
| `scripts/release/release-tag-ruleset.sh check\|apply <definition> [repo]` | Checks for, or creates, the ruleset that makes `macpaper-v*` tags immutable |
| `packaging/homebrew/bump-cask.sh <cask.rb> <version> <sha256>` | Sets the cask's version and digest; the template is `packaging/homebrew/Casks/macpaper.rb` |
| `packages/openapps-licensing` | The licensing every Swift app compiles into official builds (`swift test --package-path packages/openapps-licensing`) |
| `packages/openapps-updater` | The in-app updater every Swift app compiles into official builds (`swift test --package-path packages/openapps-updater`) |

## Build flavours

| Build | How | Licensing | Updater |
| --- | --- | --- | --- |
| From source (`swift build`, `scripts/bundle.sh`) | no variables | Compiled out: no License section, no trial, no license network calls, everything on | Compiled out: Settings → Updates says so |
| Official development | `OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 OPENAPPS_DODO_ENV=test OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_…` | Dodo test mode, the test product, trial registry `env: "test"` | On, feed and key pinned |
| Official release (CI) | the same with `OPENAPPS_DODO_ENV=live` and the live product ID | Dodo live mode | On, the committed key |
| Update test | `OPENAPPS_OFFICIAL=1 MACPAPER_UPDATE_TEST=1`, never with licensing | Compiled out | On, with test hooks; bundle id `com.openappshq.macpaper.updatetest`, its own Application Support folder (`OpenApps/macpaper-updatetest`), no URL scheme, no login item, no setup guide |

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
empty to hide the link). The generator fails loudly when anything a licensed
build needs is missing, so a placeholder can never ship; the checks job
compiles the test flavour with `pdt_placeholder_macpaper`, which
`verify-release.sh --release` refuses.

The tests run in every flavour, none of them opening a window, reading the
real record store or reaching the network:

```sh
swift test
OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 swift test --scratch-path .build/official
OPENAPPS_OFFICIAL=1 MACPAPER_UPDATE_TEST=1 swift test --scratch-path .build/updatetest
```

## Licensing, trial and the setup guide

Official builds follow [LICENSING.md](../../LICENSING.md): a 3-day trial
that starts in the app with no signup, registered once with the trial
registry by a per-app hash of the hardware UUID; a paid license checked with
Dodo daily, with a week of offline grace; both records in the encrypted file
store under `~/Library/Application Support/OpenApps/macpaper/records/`,
never the Keychain. The core feature is generating and applying: while the
license restricts it, the panel and the popover show one card in the
generator's place, Shuffle (manual and scheduled), Apply, Export, every
edit and a new seed are off, and the wallpaper already applied stays (a
display that took a fallback still keeps the side it has). Every edit goes
through the model's one gated entry, every action asks the controller's
projection of the latest snapshot to the current clocks at the click and
again after every wait (the image picker, a render, a save panel, each
display's desktop call and the fallback still after a refused HEIC), so a
deadline no timer has delivered yet still refuses and nothing started under
the trial commits after it. Settings → License shows the state, Buy a
license (the website states the price, the app never does), the key field
and Remove this Mac; the trial pill sits in the panel's header and the
Settings title bar.

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

## One-time setup

### Signing certificate and update key

Both are created on the release owner's own Mac, never in CI, and only their
public halves are committed. A placeholder (`NOT GENERATED …`) in either
`release/designated-requirement.txt` or `release/sparkle-public-key.txt`
makes the release job fail closed.

1. **The certificate**, shared by every OpenApps HQ app (create it once, or
   reuse the existing one), then macPaper's pinned requirement derived from it
   (done: `release/designated-requirement.txt` names the shared certificate):

   ```sh
   scripts/release/create-signing-certificate.sh ~/openapps-release-signing   # once, for every app
   scripts/release/designated-requirement.sh com.openappshq.macpaper \
       ~/openapps-release-signing/release-signing.cert.pem \
       > apps/macpaper/release/designated-requirement.txt
   ```

   Commit `release/designated-requirement.txt`
   (`identifier "com.openappshq.macpaper" and certificate leaf = H"<sha1>"`).
   Every release is signed with exactly this requirement and verified
   against it. macPaper asks macOS for no permissions, so a changed certificate
   costs its users nothing there; the stable identity is still what every
   update must satisfy before the updater swaps it in, and what
   `brew upgrade` replaces in place.

2. **The update key**, one per app (done 2026-09-16: the public half is
   committed and the private half is the `SPARKLE_ED_PRIVATE_KEY` secret of
   `macpaper-release`; the folder it was generated in was deleted):

   ```sh
   apps/macpaper/scripts/create-update-key.sh ~/macpaper-update-key
   ```

   It writes the private key to `~/macpaper-update-key/sparkle-ed25519.key` and
   the public key to `release/sparkle-public-key.txt` (the second argument, if
   given, is relative to `apps/macpaper`); commit the latter. Official builds
   pin it as `SUPublicEDKey` and require every feed and zip to be signed with
   it. Losing the key means no installed copy can verify another update.

3. Back both folders up offline, set the secrets below, then delete the
   folders from the Mac. Never add either to the login keychain; nothing in
   the release path needs that.

### GitHub

**Tag protection (required).** The publish step refuses to run unless an
active repository ruleset makes `macpaper-v*` tags immutable: no updates, no
force pushes, no deletions, and no bypass actors at all. That is what
guarantees a release's binaries and its tag name the same commit even if
someone tries to move the tag while a release is running. The definition is
checked in at
[`.github/rulesets/macpaper-release-tags.json`](../../.github/rulesets/macpaper-release-tags.json);
a repository admin applies it once:

```sh
scripts/release/release-tag-ruleset.sh apply .github/rulesets/macpaper-release-tags.json openappshq/openapps   # gh must be logged in as an admin
scripts/release/release-tag-ruleset.sh check .github/rulesets/macpaper-release-tags.json openappshq/openapps   # what the workflow runs
```

Creating tags stays allowed; once a release tag exists it can only ever be
left alone. A wrong release is fixed by a new patch version, never by
re-tagging.

GitHub shows a ruleset's bypass actors only to callers allowed to administer
the repository; to anyone else the ruleset looks as if nobody were exempt.
The workflow's own token is not such a caller, so the publish job reads
rulesets with a dedicated **`RULESET_READ_TOKEN`**.

**The tap.** `openappshq/homebrew-tap` holds `Casks/macpaper.rb`. The release
workflow creates the cask from
[`packaging/homebrew/Casks/macpaper.rb`](../../packaging/homebrew/Casks/macpaper.rb)
on the first release and bumps it after every later one.

**Shared secrets (already there).** The certificate and the read-only
ruleset token are **repository** secrets shared by every app ([RELEASES.md,
Signing material](../../RELEASES.md#signing-material)); the workflow reads
them by name and they are never copied per app:

| Repository secret | Value |
| --- | --- |
| `RELEASE_SIGNING_P12` | The certificate and key as a `.p12`, base64-encoded (`release-signing.p12.base64`) |
| `RELEASE_SIGNING_P12_PASSWORD` | Its password (`release-signing.p12.password`) |
| `RULESET_READ_TOKEN` | [Fine-grained token](https://github.com/settings/personal-access-tokens/new) for this repository only, Administration: Read-only, created by a repository admin; used only to read the tag ruleset before publishing |

**Environment.** Create the environment **`macpaper-release`** (Settings →
Environments) and add, on that environment, the following. Restrict its
deployment branches and tags to `main` and `macpaper-v*` so nothing else can
reach the update key or publish. The build, publish and feed jobs all run
in this environment, so any required reviewers approve each.

**Secrets** — the app's own update key, and the two publishing credentials
(the same values every app uses, restored from the offline backup; they stay
per environment so only `main` and release tags can publish):

| Secret | Value |
| --- | --- |
| `SPARKLE_ED_PRIVATE_KEY` | The update key (`sparkle-ed25519.key`, one base64 line) |
| `FEED_COMMIT_TOKEN` | Fine-grained token for this repository only, Contents: Read and write; used only to push the update feed commit to `main` |
| `HOMEBREW_TAP_DEPLOY_KEY` | The private half of an SSH deploy key added to `openappshq/homebrew-tap` with write access (`gh repo deploy-key add --allow-write`); it can push only to the tap |

`FEED_COMMIT_TOKEN` belongs to a bot account or the release owner, and
`HOMEBREW_TAP_DEPLOY_KEY` is a deploy key on the tap repository; the commits
they push are authored `openapps-release <release@openapps.space>`. If
`main` requires status checks or reviews for pushes, allow that account to
bypass them for the feed path only.

Environment **variables** (public configuration, not secrets):

| Variable | Value |
| --- | --- |
| `OPENAPPS_DODO_PAID_PRODUCT_ID` | macPaper's **live** Dodo product (`pdt_…`, LICENSING.md "Dodo Payments setup"). The release job fails before building when it is unset or not a product ID; `generate-licensing-config.sh` refuses a placeholder for a live build |
| `OPENAPPS_BUY_URL` | Optional. Where "Buy a license" opens; the app's default is `https://openapps.space/macpaper/` |
| `OPENAPPS_SUPPORT_URL` | Optional. "Contact support" on a revoked license; the app's default is `https://openapps.space/macpaper/#questions`, an empty value hides the link |

The checks job never sees these: it compiles the licensed and the official
flavour against Dodo **test** mode with the placeholder
`pdt_placeholder_macpaper`, and
`verify-release.sh --release` refuses any binary that contains a placeholder
ID or the test host.

The release job checks every secret, the product ID and both committed
public files before it touches the certificate, and fails naming what is
missing and where it belongs. There is no unsigned fallback. The certificate lives in a temporary
keychain for exactly the build-and-sign step (`with-signing-keychain.sh`),
which deletes it before the zip, the feed, the upload or the publish run.

## Cutting a release

1. Merge everything the release needs into `main` and make sure the macPaper
   workflow is green there.
2. Pick the version, `MAJOR.MINOR.PATCH` (each part at most 999). It becomes
   `CFBundleShortVersionString`; `CFBundleVersion` is derived from it
   (`MAJOR*1000000 + MINOR*1000 + PATCH`), so build order is release order:
   the updater compares both, and a back-port cut from a later commit never
   outranks the release it patches. The first release is `0.1.0`.
3. Tag and push:

   ```sh
   git checkout main && git pull
   git tag -a macpaper-v0.1.0 -m "macPaper 0.1.0"
   git push origin macpaper-v0.1.0
   ```

4. The workflow runs four jobs, following RELEASES.md step by step:
   - `checks`, as on every change: `swift test` in the source flavour and,
     with a generated test-mode configuration, in the licensed flavour
     (licensing only) and the official flavour (licensing and the updater);
     the licensing and updater packages' tests;
     shellcheck and actionlint; the cask template; and an ad-hoc signed
     universal development zip of the official flavour against Dodo test
     mode with a throwaway update key.
   - `release` (read-only token): checks the secrets, the product ID
     variable and both public pins, imports the certificate into a temporary
     keychain, generates the live licensing configuration and builds the
     universal app with the updater, signs it with the pinned designated
     requirement and verifies that, deletes the keychain, zips with `ditto`,
     verifies the zip as a release (signature, live host, no placeholder,
     the committed update key pinned), signs it with the update key and
     writes the signed `appcast.xml`, records the zip's SHA-256 as a job
     output and uploads all of it as a workflow artifact.
   - `publish` (the only job that can write releases): downloads that exact
     artifact by id, checks the zip against the SHA-256 the release job
     reported (a checksum file that travelled with the download is never
     trusted), confirms the tag ruleset is active with no bypass actors,
     confirms `macpaper-v0.1.0` names exactly the commit that was built,
     creates a *draft* release, uploads `macPaper-0.1.0.zip` and its `.sha256`,
     confirms the tag once more, and only then publishes.
   - `feed`: re-verifies the signed feed against the published zip's digest,
     commits it to `main` as `apps/website/public/updates/macpaper/appcast.xml`
     (the website deploy then serves it at
     `https://openapps.space/updates/macpaper/appcast.xml`), downloads the
     public zip and polls the live feed until both check out, then bumps
     `Casks/macpaper.rb` in `openappshq/homebrew-tap`. The feed and the cask
     only ever move forward: a version below the live feed's fails the job
     unless the run set `allow_older`, in which case the back-port is
     published as a GitHub Release only and both stay put.
   Expect 15–30 minutes, most of it the website deploy wait.
5. Open the release, check the notes, and confirm the upgrade on a Mac with
   the previous version before announcing it: Settings → Updates → Check Now
   must offer it (and `brew update && brew upgrade --cask macpaper` must work
   too).

Builds for the same version and publications of any version are serialised
by GitHub concurrency groups, so two runs never publish at the same time. A
version lower than the newest published release is refused unless the manual
run sets `allow_older` (a deliberate back-port).

If `release` fails, fix the cause, but do not move or delete the tag: the
ruleset forbids it, and a tag that exists is final. Push the fix to `main`
and tag it as the next patch version. Re-running a failed run is fine as long
as nothing was published yet (a leftover draft is discarded); once a release
is published for a tag, the publish step refuses to touch it again. A release
that turns out to be bad gets a new patch version; to stop it being offered
as an update meanwhile, restore the previous `appcast.xml` on `main` from git
history.

A manual run (Actions → macPaper → Run workflow) from `main` with a version and
`publish` ticked does the same and creates the tag at that commit; without
`publish` it builds and verifies a release-signed zip and its appcast as an
artifact only, committing no feed and touching no tap.

## Updates

Official builds compile in the shared updater,
[`packages/openapps-updater`](../../packages/openapps-updater)
(`OPENAPPS_OFFICIAL=1`; source builds have no updater at all and depend on
nothing outside this repository). `Info.plist` pins the feed
`https://openapps.space/updates/macpaper/appcast.xml` (`SUFeedURL`) and the
public update key (`SUPublicEDKey`); the app trusts nothing in a feed before
its Ed25519 signature verifies, and nothing in a zip before its length,
SHA-256 and signature do. **"Check for updates automatically" is on by
default and "Download and install automatically" off** (RELEASES.md): a
fresh install looks for updates and says when one is out — in the menu-bar
popover ("macPaper X.Y.Z available — Install") and in Settings → Updates — but
installs nothing on its own. Each default is written once, the first time
the app runs with no earlier preferences (none of the keys the app writes to
its defaults domain is present — a stored "off" counts as a preference) and
no kept trial or license record,
and recorded as decided under its own flag (`FreshInstallDefault` in
`MacPaperCore/FirstRun.swift`, the rule "Open at login" already follows); an
upgrade never changes a toggle the user could have set, and a toggle flipped
in Settings while storage is still answering wins. "Check Now" always works,
and `brew upgrade --cask macpaper` keeps working.

With "Check for updates automatically" on, the app checks on launch, every
24 hours and on wake when a check is overdue, and retries a failed check
once after an hour. With "Download and install automatically" on as well, a
found update is downloaded, verified and unpacked into a private staging
folder next to the app (`/Applications/.macPaper.app.update`, mode 0700); the
staged bundle must be validly signed and *satisfy the running app's
designated requirement* (evaluated with the Security framework, the same
check as `codesign --verify --strict -R=`, never compared as text) and
carry the announced version and build. It installs when the app quits, or
at once from the panel's "Update ready — Restart" / Settings' "Restart to
Update". Turning either toggle off cancels a download in flight and discards
a staged automatic update, so nothing installs on quit; the quit path checks
the toggle again. "Install" after a check is the user's explicit consent and
installs immediately, independent of the toggles.

The install is one atomic exchange of the two bundles (`renamex_np` with
`RENAME_SWAP`), re-verified right before it: at no instant is the app
missing, and the old bundle is deleted only after a recorded, read-back
"superseded" state. A volume without atomic exchanges cannot be updated in
place: the install is refused with "Move the app to the Applications folder
on your startup disk" and nothing changes. A state file written before every
step lets the next launch clean up only what it knows is safe; a staging
folder holding a bundle of uncertain provenance is kept, and Settings shows
it with "Remove Previous Copy" until the user decides. The installed
bundle's version is re-read right before installing, so a newer copy put
there by `brew upgrade` meanwhile is never replaced. The install on quit is
cooperative: past its deadline it is abandoned only before the commit point,
and after it the quit waits for the exchange; "Restart" runs through the
normal quit (the trial's save, then the install) and reopens the app after
it has exited. A copy running from a read-only volume or App Translocation
shows "Move macPaper to Applications to enable updates" instead. Updates never
depend on the license or trial state. `scripts/update-e2e.sh` proves the
whole path locally (below); the package's own tests cover feed verification,
version rules, the swap with injected failures and the copied-requirement
case.

Updates come from the signed feed only: `verify-release.sh` refuses a binary
that names `api.github.com` (a "latest GitHub release" check would find another
app's release in this monorepo).

## Local rehearsal

Every release step has a local dry run that needs no secrets. To rehearse
the release job's signing with a throwaway certificate and key, put their
public halves into `release/` temporarily (do not commit them):

```sh
scripts/release/create-signing-certificate.sh /tmp/macpaper-rehearsal          # from the repository root
apps/macpaper/scripts/create-update-key.sh /tmp/macpaper-rehearsal-key release/sparkle-public-key.txt   # the second path is relative to apps/macpaper
scripts/release/designated-requirement.sh com.openappshq.macpaper /tmp/macpaper-rehearsal/release-signing.cert.pem \
    > apps/macpaper/release/designated-requirement.txt
cd apps/macpaper
UNIVERSAL=1 VERSION=0.1.0 RELEASE_SIGNING_P12_FILE=/tmp/macpaper-rehearsal/release-signing.p12 \
  RELEASE_SIGNING_P12_PASSWORD="$(cat /tmp/macpaper-rehearsal/release-signing.p12.password)" \
  OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 OPENAPPS_DODO_ENV=live OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… \
  ../../scripts/release/with-signing-keychain.sh scripts/bundle.sh
scripts/make-zip.sh
scripts/verify-release.sh --release dist/macPaper-0.1.0.zip
SPARKLE_ED_KEY_FILE=/tmp/macpaper-rehearsal-key/sparkle-ed25519.key scripts/make-appcast.sh dist/macPaper-0.1.0.zip
git checkout release/   # restore the real pins
```

`with-signing-keychain.sh` fails if the throwaway identity can still be
found afterwards, so the rehearsal leaves nothing behind. A rehearsal
against Dodo test mode (`OPENAPPS_DODO_ENV=test` with the test product ID)
verifies without `--release`; the release check requires the live host. An
ad-hoc development build of the official flavour needs only a throwaway
public key:

```sh
UNIVERSAL=1 OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 OPENAPPS_DODO_ENV=test \
OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… VERSION=0.1.0 \
UPDATE_PUBLIC_ED_KEY="$(xcrun swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())')" \
scripts/bundle.sh
scripts/make-zip.sh
scripts/verify-release.sh dist/macPaper-0.1.0.zip    # the requirement is reported, not compared
```

### The update end-to-end test

```sh
scripts/update-e2e.sh
```

With no secrets and no network beyond `127.0.0.1`, it creates a throwaway
certificate and update key in a temporary folder, builds versions 1.0.0 and
1.0.1 of the update-test variant (bundle id
`com.openappshq.macpaper.updatetest`, its own Application Support folder,
no URL scheme, no login item, no setup guide and no licensing — the script
sets `OPENAPPS_LICENSING=0` whatever the shell inherited, and `bundle.sh`
and `Package.swift` refuse `MACPAPER_UPDATE_TEST=1` with
`OPENAPPS_LICENSING=1`, so it can never reach the record store, the registry
or Dodo, and leaves nothing behind on any Mac), both signed with that
certificate inside `with-signing-keychain.sh`, checks the keychain search
list is unchanged and the identity gone afterwards, verifies both carry the
same designated requirement and an ad-hoc re-signed copy does not, zips and
update-signs 1.0.1, writes and verifies the signed appcast (and refuses a
tampered one), serves both from a local port, runs 1.0.0 as a fresh install
and asserts the fresh-install default turns checks on, finds 1.0.1 and
downloads nothing, runs it as an upgrade with checks stored off and asserts
the server sees no request and the toggle is untouched, runs it with both
toggles on and turns "install automatically" off mid-download and again
after staging (nothing may install or stay staged), runs it with both on and
asserts 1.0.1 is downloaded, verified, staged and installed on quit with the
requirement unchanged and no leftovers, then puts 1.0.0 back and takes
"Restart": the install runs through the quit path and the app reopens as
1.0.1. Everything it created is removed afterwards. It needs OpenSSL 3
(`brew install openssl@3`), python3 and a logged-in session.

Before the first licensed release, run LICENSING.md's end-to-end checks in
Dodo test mode with a test-mode build: the trial starts and ends on its own
(a debug build shortens it with `MACPAPER_DEBUG_TRIAL_DAY_SECONDS=60`), a test
checkout issues a key that activates on 3 Macs and is refused on the 4th, a
refund revokes, Remove this Mac frees a slot.

## Pulling a bad release

Tags are never reused and releases are never rewritten. Restore the previous
`apps/website/public/updates/macpaper/appcast.xml` on `main` from git history
so the bad version is no longer offered (installs that already updated keep
it), then ship the fix as a higher patch version; the feed, the updater and
`brew upgrade` move everyone forward. A GitHub Release can be marked as a
pre-release or its notes edited, but its assets stay as verified.
