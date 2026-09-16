# Releasing OpenReaction

The official build is a universal (Apple silicon + Intel) `OpenReaction.app`,
signed with the stable OpenApps HQ Release certificate, zipped, with
licensing compiled in against Dodo live mode and the in-app updater compiled
in. It is installed with Homebrew and updates itself from a signed feed, all
as [RELEASES.md](../../RELEASES.md) specifies.
[`.github/workflows/openreaction.yml`](../../.github/workflows/openreaction.yml)
builds it on GitHub's `macos-26` runner, publishes it as a GitHub Release,
commits the update feed, verifies both live and bumps the Homebrew cask.
Nothing about a release is manual except pushing the tag.

```sh
curl -fsSL https://openapps.space/install/openreaction | sh   # how users install it
brew install --cask openappshq/tap/openreaction               # or with Homebrew
```

The scripts the workflow runs are the ones you can run locally:

| Script | Does |
| --- | --- |
| `scripts/bundle.sh` | `swift build -c release`, assembles and signs `build/OpenReaction.app` (hardened runtime, no sandbox, `scripts/OpenReaction.entitlements`); with `OPENAPPS_OFFICIAL=1` compiles the shared updater in and pins the feed and update key |
| `scripts/make-zip.sh` | `ditto -c -k --keepParent` into `dist/OpenReaction-<version>.zip`, writes its `.sha256` |
| `scripts/verify-release.sh [--release] <zip>` | Unpacks the zip and runs the checks a user's Mac and the updater run; `--release` requires the pinned designated requirement and the committed update key |
| `scripts/scan-binary.sh <binary> <string>...` | Byte search behind verify-release's debug-only-code gates (the setup preview flag, the update-test hooks); fails closed, never a pipe into `grep -q`. `scripts/tests/scan-binary.test.sh` plants markers and checks they are caught |
| `scripts/make-appcast.sh <zip>` | Signs the zip with the update key and writes the signed `dist/appcast.xml` |
| `scripts/sign-update.sh <key> [--feed] <file>` | Ed25519 signing, byte-compatible with Sparkle's `sign_update` |
| `scripts/verify-appcast.sh <appcast> [zip]` | Verifies a feed, and the zip it announces, with the public key only |
| `scripts/verify-live.sh <version> <sha256>` | Downloads the public zip and the live feed and checks both |
| `scripts/publish-release.sh [--dry-run]` | Creates the GitHub Release for a tag, only once the tag provably names the built commit |
| `scripts/create-update-key.sh <dir>` | One-time: creates the Sparkle EdDSA update key |
| `scripts/update-e2e.sh` | The local end-to-end update test, no secrets, no network beyond 127.0.0.1 |

Shared with every app (repository root):

| Script | Does |
| --- | --- |
| `scripts/release/create-signing-certificate.sh <dir>` | One-time: creates the `OpenApps HQ Release` certificate as a password-protected `.p12` |
| `scripts/release/designated-requirement.sh <bundle id> <cert.pem>` | Prints the designated requirement to pin |
| `scripts/release/with-signing-keychain.sh <command>` | Runs one command with the certificate in a temporary keychain, then removes it |
| `scripts/release/verify-designated-requirement.sh <app> <pinned file>` | Fails unless an app has exactly the pinned requirement |
| `scripts/release/release-tag-ruleset.sh check\|apply <definition> [repo]` | Checks for, or creates, the ruleset that makes `openreaction-v*` tags immutable |
| `packaging/homebrew/bump-cask.sh <cask.rb> <version> <sha256>` | Sets the cask's version and digest; the template is `packaging/homebrew/Casks/openreaction.rb` |
| `packages/openapps-licensing` | The licensing every Swift app compiles into official builds: rules, trial, record store, Dodo and registry clients (`swift test --package-path packages/openapps-licensing`) |
| `packages/openapps-updater` | The in-app updater every Swift app compiles into official builds (`swift test --package-path packages/openapps-updater`) |

## One-time setup

### Signing certificate and update key

Both are created on the release owner's own Mac, never in CI, and only their
public halves are committed. The repository ships with placeholder files
(`NOT GENERATED …`); the release job fails closed while either is still a
placeholder.

1. **The certificate**, shared by every OpenApps HQ app (create it once, or
   reuse the existing one):

   ```sh
   scripts/release/create-signing-certificate.sh ~/openapps-release-signing
   scripts/release/designated-requirement.sh com.openappshq.openreaction \
       ~/openapps-release-signing/release-signing.cert.pem \
       > apps/openreaction/release/designated-requirement.txt
   ```

   Commit `release/designated-requirement.txt`
   (`identifier "com.openappshq.openreaction" and certificate leaf = H"<sha1>"`).
   Every release is signed with exactly this requirement and verified against
   it, so permissions survive updates. Losing the
   certificate means every installed user re-grants permissions once.

2. **The update key**, one per app:

   ```sh
   apps/openreaction/scripts/create-update-key.sh ~/openreaction-update-key
   ```

   It writes the private key to `~/openreaction-update-key/sparkle-ed25519.key`
   and the public key to `release/sparkle-public-key.txt`; commit the latter.
   Official builds pin it as `SUPublicEDKey` and require every feed and zip
   to be signed with it. Losing the key means no installed copy can verify
   another update.

3. Back both folders up offline, set the secrets below, then delete the
   folders from the Mac. Never add either to the login keychain; nothing in
   the release path needs that.

### GitHub

**Tag protection (required).** The publish step refuses to run unless an
active repository ruleset makes `openreaction-v*` tags immutable: no
updates, no force pushes, no deletions, and no bypass actors at all. That is
what guarantees a release's binaries and its tag name the same commit even
if someone tries to move the tag while a release is running. The definition
is checked in at
[`.github/rulesets/openreaction-release-tags.json`](../../.github/rulesets/openreaction-release-tags.json);
a repository admin applies it once:

```sh
scripts/release/release-tag-ruleset.sh apply .github/rulesets/openreaction-release-tags.json openappshq/openapps   # gh must be logged in as an admin
scripts/release/release-tag-ruleset.sh check .github/rulesets/openreaction-release-tags.json openappshq/openapps   # what the workflow runs
```

Creating tags stays allowed; once a release tag exists it can only ever be
left alone. A wrong release is fixed by a new patch version, never by
re-tagging.

GitHub shows a ruleset's bypass actors only to callers allowed to
administer the repository; to anyone else the ruleset looks as if nobody
were exempt. The workflow's own token is not such a caller, so the publish
job reads rulesets with a dedicated **`RULESET_READ_TOKEN`**.

**The tap.** `openappshq/homebrew-tap` holds `Casks/openreaction.rb`. The
release workflow creates the cask from
[`packaging/homebrew/Casks/openreaction.rb`](../../packaging/homebrew/Casks/openreaction.rb)
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

**Environment.** Create the environment **`openreaction-release`**
(Settings → Environments) and add, on that environment, the following.
Restrict its deployment branches and tags to `main` and `openreaction-v*` so
nothing else can reach the update key or publish. The build, publish and
feed jobs all run in this environment, so any required reviewers approve
each.

**Secrets** — the app's own update key, and the two publishing credentials
(the same values every app uses, restored from the offline backup; they stay
per environment so only `main` and release tags can publish):

| Secret | Value |
| --- | --- |
| `SPARKLE_ED_PRIVATE_KEY` | The update key (`sparkle-ed25519.key`, one base64 line) |
| `FEED_COMMIT_TOKEN` | Fine-grained token for this repository only, Contents: Read and write; used only to push the update feed commit to `main` |
| `HOMEBREW_TAP_DEPLOY_KEY` | The private half of an SSH deploy key added to `openappshq/homebrew-tap` with write access (`gh repo deploy-key add --allow-write`); it can push only to the tap |

`FEED_COMMIT_TOKEN` belongs to a bot account or the
release owner; the commits they push are authored `openapps-release
<release@openapps.space>`. If `main` requires status checks or reviews for
pushes, allow that account to bypass them for the feed path only.

**Variables** (public configuration, per [LICENSING.md](../../LICENSING.md)):

| Variable | Required | Value |
| --- | --- | --- |
| `OPENAPPS_DODO_PAID_PRODUCT_ID` | yes | The live-mode `OpenReaction` product ID, `pdt_…` |
| `OPENAPPS_BUY_URL` | no | The `https://checkout.dodopayments.com/buy/<paid id>?quantity=1&redirect_url=https://openapps.space/openreaction/thanks/` link; the Buy button says "coming soon" without it |
| `OPENAPPS_SUPPORT_URL` | no | `https://` or `mailto:` link for Contact support |

`OPENAPPS_DODO_ENV` is always `live` in the release job; it is not a variable.
The trial lives in the app and needs no configuration: release builds
register trials with `https://openapps.space/api/trial` (`env: "live"`), and
there is no trial product.

The release job checks every secret, the paid product ID and both committed
public files before it touches the certificate, and fails naming what is
missing and where it belongs. There is no unsigned fallback. The certificate lives in a temporary
keychain for exactly the build-and-sign step (`with-signing-keychain.sh`),
which deletes it before the zip, the feed, the upload or the publish run,
and a live build refuses placeholder product IDs in any casing.

## Cutting a release

1. Merge everything the release needs into `main` and make sure the
   OpenReaction workflow is green there.
2. Pick the version, `MAJOR.MINOR.PATCH` (each part at most 999). It becomes
   `CFBundleShortVersionString`; `CFBundleVersion` is derived from it
   (`MAJOR*1000000 + MINOR*1000 + PATCH`), so build order is release order:
   the updater compares both, and a back-port cut from a later commit never
   outranks the release it patches.
3. Tag and push:

   ```sh
   git checkout main && git pull
   git tag -a openreaction-v1.0.0 -m "OpenReaction 1.0.0"
   git push origin openreaction-v1.0.0
   ```

4. The workflow runs four jobs, following RELEASES.md step by step:
   - `checks`, as on every change.
   - `release` (read-only token): imports the certificate into a temporary
     keychain, builds the universal licensed app with the updater, signs it
     with the pinned designated requirement and verifies that, deletes the
     keychain, zips with `ditto`, records the zip's SHA-256 as a job output,
     verifies the zip as a release, signs it with the update key and writes
     the signed `appcast.xml`, and uploads all of it as a workflow artifact.
   - `publish` (the only job that can write releases): downloads that exact
     artifact by id, checks the zip against the SHA-256 the release job
     reported (a checksum file that travelled with the download is never
     trusted), confirms the tag ruleset is active with no bypass actors,
     confirms `openreaction-v1.0.0` names exactly the commit that was built,
     creates a *draft* release, uploads `OpenReaction-1.0.0.zip` and its
     `.sha256`, confirms the tag once more, and only then publishes.
   - `feed`: re-verifies the signed feed against the published zip's digest,
     commits it to `main` as
     `apps/website/public/updates/openreaction/appcast.xml` (the website
     deploy then serves it at
     `https://openapps.space/updates/openreaction/appcast.xml`), downloads
     the public zip and polls the live feed until both check out, then
     bumps `Casks/openreaction.rb` in `openappshq/homebrew-tap`. The feed
     and the cask only ever move forward: a version below the live feed's
     fails the job unless the run set `allow_older`, in which case the
     back-port is published as a GitHub Release only and both stay put.
   Expect 15–30 minutes, most of it the website deploy wait.
5. Open the release, check the notes, and run the clean-Mac check below
   before announcing it.

Builds for the same version and publications of any version are
serialised by GitHub concurrency groups, so two runs never publish at the
same time. A version lower than the newest published release is refused
unless the manual run sets `allow_older` (a deliberate back-port).

If `release` fails, fix the cause, but do not move or delete the tag: the
ruleset forbids it, and a tag that exists is final. Push the fix to `main`
and tag it as the next patch version. Re-running a failed run is fine as
long as nothing was published yet (a leftover draft is discarded); once a
release is published for a tag, the publish step refuses to touch it again.
A release that turns out to be bad gets a new patch version; to stop it
being offered as an update meanwhile, restore the previous `appcast.xml`
on `main` from git history.

### Release candidates

**Actions → OpenReaction → Run workflow** on a branch (with a `version`) or
on an existing `openreaction-v*` tag (version comes from the tag), with
`publish` left off, runs the same signed build and uploads
`OpenReaction-<version>-signed` as a workflow artifact without creating a
release, committing a feed or touching the tap. With `publish` on it creates
the tag at that commit if it does not exist yet and publishes exactly as a
tag push would; prefer pushing a tag on `main`.

To rehearse publication without changing anything, run the publish script
locally against the downloaded artifact:

```sh
GH_REPO=openappshq/openapps TAG=openreaction-v1.0.0 VERSION=1.0.0 \
BUILT_COMMIT=$(git rev-parse openreaction-v1.0.0^{commit}) DIST=path/to/artifact \
EXPECTED_SHA256=$(shasum -a 256 path/to/artifact/OpenReaction-1.0.0.zip | cut -d' ' -f1) \
RULESET_READ_TOKEN=$(gh auth token) \
scripts/publish-release.sh --dry-run
```

## Verifying the download on a clean Mac

Use a Mac (or a fresh user account) that has never run a development build.
Every command must succeed.

```sh
brew install --cask openappshq/tap/openreaction
codesign --verify --deep --strict --verbose=2 /Applications/OpenReaction.app
#   valid on disk / satisfies its Designated Requirement
codesign --display --verbose=2 /Applications/OpenReaction.app 2>&1 | grep -E 'Authority|flags'
#   Authority=OpenApps HQ Release, flags=… (runtime)
codesign --display -r- /Applications/OpenReaction.app 2>&1 | grep designated
#   exactly the line in apps/openreaction/release/designated-requirement.txt
lipo -archs /Applications/OpenReaction.app/Contents/MacOS/OpenReaction   # x86_64 arm64
```

The cask launches the app: it opens without a Gatekeeper dialog (the cask
cleared quarantine; a zip downloaded by hand instead needs right-click →
Open once), the onboarding window asks for Accessibility and Input
Monitoring, and after granting both, typing `:tada:` in TextEdit turns into
🎉. Also verify a Chromium app (Chrome's address bar or a text field on a
page) and an Electron app (VS Code, or an Electron chat app that is not
excluded): `:tada:` must turn into 🎉 there too — that path enables the app's
accessibility tree on activation and, where the field still can't be read
back, falls back to typed replacement, and neither can be exercised by the
test suite. Settings must have a License section with the Buy link and an Updates
section with "Check for updates automatically" **on** (a fresh install),
"Download and install automatically" **off** and a working "Check Now" (a
source build has neither section). Turning the second toggle on, quitting
and relaunching after the next release must install it without asking for
permissions again.
`brew upgrade --cask openreaction` must also work.

## Updates

Official builds compile in the shared updater,
[`packages/openapps-updater`](../../packages/openapps-updater)
(`OPENAPPS_OFFICIAL=1`; source builds have no updater at all and depend on
nothing outside this repository). `Info.plist` pins the feed
`https://openapps.space/updates/openreaction/appcast.xml` (`SUFeedURL`) and
the public update key (`SUPublicEDKey`); the app trusts nothing in a feed
before its Ed25519 signature verifies, and nothing in a zip before its
length, SHA-256 and signature do. **"Check for updates automatically" is on
by default and "Download and install automatically" off** (RELEASES.md): a
fresh install looks for updates and says when one is out, but installs
nothing on its own. Each default is written once, the first time the app
runs with no earlier preferences (none of the keys the app writes to its
defaults domain is present — a stored "off" counts as a preference) and no
kept trial or license record, and recorded as decided under its own flag
(`FreshInstallDefault` in `OpenReactionCore/FirstRun.swift`, the rule "Open
at login" already follows); an upgrade never changes a toggle the user could
have set. "Check Now" always works, and most users update with
`brew upgrade --cask openreaction`.

With "Check for updates automatically" on, the app checks on launch, every
24 hours and on wake when a check is overdue, and retries a failed check
once after an hour. With "Download and install automatically" on as well, a
found update is downloaded, verified and unpacked into a private staging
folder next to the app (`/Applications/.OpenReaction.app.update`, mode
0700); the staged bundle must be validly signed and *satisfy the running
app's designated requirement* (evaluated with the Security framework, the
same check as `codesign --verify --strict -R=`, never compared as text) and
carry the announced version and build. It installs when the app quits, or
at once from "Update ready — Restart" / "Restart to Update". Turning either
toggle off cancels a download in flight and discards a staged automatic
update, so nothing installs on quit; the quit path checks the toggle again.
"Check Now" → "Install and Restart" is the user's explicit consent and
installs immediately, independent of the toggles.

The install is one atomic exchange of the two bundles (`renamex_np` with
`RENAME_SWAP`), re-verified right before it: at no instant is the app
missing, and the old bundle is deleted only after a recorded, read-back
"superseded" state. A volume without atomic exchanges cannot be updated in
place: the install is refused with "Move OpenReaction to the Applications
folder on your startup disk" and nothing changes. A state file written
before every step lets the next launch clean up only what it knows is safe;
a staging folder holding a bundle of uncertain provenance is kept, and
Settings shows it with "Remove Previous Copy" until the user decides. The
installed bundle's version is re-read right before installing, so a newer
copy put there by `brew upgrade` meanwhile is never replaced. The install on
quit is cooperative: past its deadline it is abandoned only before the
commit point, and after it the quit waits for the exchange; "Restart to
Update" runs through the normal quit (tap drain, license save, install)
and reopens the app after it has exited. A copy running from a
read-only volume or App Translocation shows "Move OpenReaction to
Applications to enable updates" instead. Updates never depend on the
license or trial state. `scripts/update-e2e.sh` proves the whole path
locally (below); the package's own tests cover feed verification, version
rules, the swap with injected failures and the copied-requirement case.

## Local builds

An unsigned build is ad-hoc and only good for the packaging path; the
official flavour needs an update key, which a development build may pin as
a throwaway:

```sh
UNIVERSAL=1 OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 OPENAPPS_DODO_ENV=test \
OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… VERSION=1.0.0 \
UPDATE_PUBLIC_ED_KEY="$(xcrun swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())')" \
scripts/bundle.sh
scripts/make-zip.sh
scripts/verify-release.sh dist/OpenReaction-1.0.0.zip    # the requirement is reported, not compared
```

To rehearse the release job's signing with a throwaway certificate and key,
put their public halves into `release/` temporarily (do not commit them):

```sh
scripts/release/create-signing-certificate.sh /tmp/rehearsal-cert          # from the repository root
apps/openreaction/scripts/create-update-key.sh /tmp/rehearsal-key apps/openreaction/release/sparkle-public-key.txt
scripts/release/designated-requirement.sh com.openappshq.openreaction /tmp/rehearsal-cert/release-signing.cert.pem \
    > apps/openreaction/release/designated-requirement.txt
cd apps/openreaction
RELEASE_SIGNING_P12_FILE=/tmp/rehearsal-cert/release-signing.p12 \
RELEASE_SIGNING_P12_PASSWORD="$(cat /tmp/rehearsal-cert/release-signing.p12.password)" \
UNIVERSAL=1 OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 OPENAPPS_DODO_ENV=test OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… VERSION=1.0.0 \
../../scripts/release/with-signing-keychain.sh scripts/bundle.sh
scripts/make-zip.sh
scripts/verify-release.sh --release dist/OpenReaction-1.0.0.zip
SPARKLE_ED_KEY_FILE=/tmp/rehearsal-key/sparkle-ed25519.key scripts/make-appcast.sh dist/OpenReaction-1.0.0.zip
git checkout release/   # restore the placeholders, or the real pins
```

### The update end-to-end test

```sh
scripts/update-e2e.sh
```

With no secrets and no network beyond `127.0.0.1`, it creates a throwaway
certificate and update key in a temporary folder, builds versions 1.0.0 and
1.0.1 of the update-test variant (bundle id
`com.openappshq.openreaction.updatetest`, no URL scheme, the event tap and
permission prompts disabled, so it is safe on any Mac), both signed with
that certificate inside `with-signing-keychain.sh`, checks the keychain
search list is unchanged and the identity gone afterwards, verifies both
carry the same designated requirement and an ad-hoc re-signed copy does not,
zips and update-signs 1.0.1, writes and verifies the signed appcast (and
refuses a tampered one), serves both from a local port, runs 1.0.0 as a
fresh install and asserts the server sees no request, runs it with both
toggles on and turns "install automatically" off mid-download and again
after staging (nothing may install or stay staged), runs it with both on
and asserts 1.0.1 is downloaded, verified, staged and installed on quit
with the requirement unchanged and no leftovers, then puts 1.0.0 back and
takes "Restart to Update": the install runs through the quit path and the
app reopens as 1.0.1. Everything it created is
removed afterwards. It needs OpenSSL 3 (`brew install openssl@3`), python3
and a logged-in session.
