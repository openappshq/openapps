# Releasing OpenReaction

The official build is a signed, notarized, universal (Apple silicon + Intel)
`OpenReaction.app` inside a DMG, with licensing compiled in against Dodo live
mode. [`.github/workflows/openreaction.yml`](../../.github/workflows/openreaction.yml)
builds it on GitHub's `macos-26` runner and publishes it as a GitHub Release.
Nothing about a release is manual except pushing the tag.

The scripts the workflow runs are the ones you can run locally:

| Script | Does |
| --- | --- |
| `scripts/bundle.sh` | `swift build -c release`, assembles and signs `build/OpenReaction.app` (hardened runtime, no sandbox, `scripts/OpenReaction.entitlements`) |
| `scripts/make-dmg.sh` | Packages the app and an Applications link into `dist/OpenReaction-<version>.dmg` and signs it |
| `scripts/notarize.sh <item>` | Submits an app or DMG with `notarytool`, waits, staples the ticket |
| `scripts/verify-release.sh [--notarized] <dmg>` | Mounts the DMG and runs the checks a user's Mac runs |
| `scripts/release-tag-ruleset.sh check\|apply` | Checks for, or creates, the ruleset that makes `openreaction-v*` tags immutable |
| `scripts/publish-release.sh [--dry-run]` | Creates the GitHub Release for a tag, only once the tag provably names the built commit |

## One-time setup

### Apple

1. In the Apple Developer account, create a **Developer ID Application**
   certificate (not "Mac Development", not "Apple Distribution") and install
   it in your login keychain together with its private key.
2. Export it from Keychain Access as a `.p12` with a password, then base64 it:
   `base64 -i DeveloperID.p12 | pbcopy`.
3. Find its exact name: `security find-identity -v -p codesigning` prints
   something like `Developer ID Application: OpenApps HQ (ABCDE12345)`.
4. Create an [app-specific password](https://support.apple.com/102654) for
   the Apple ID that belongs to the team; `notarytool` uses it.
5. The Team ID is the ten-character code in parentheses in the identity name.

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
scripts/release-tag-ruleset.sh apply openappshq/openapps   # gh must be logged in as an admin
scripts/release-tag-ruleset.sh check openappshq/openapps   # what the workflow runs
```

(Equivalent: `gh api --method POST repos/openappshq/openapps/rulesets --input .github/rulesets/openreaction-release-tags.json`.)
Creating tags stays allowed; once a release tag exists it can only ever be
left alone. A wrong release is fixed by a new patch version, never by
re-tagging.

GitHub shows a ruleset's bypass actors only to callers allowed to
administer the repository; to anyone else the ruleset looks as if nobody
were exempt. The workflow's own token is not such a caller, so the publish
job reads rulesets with a dedicated **`RULESET_READ_TOKEN`**: a
[fine-grained personal access token](https://github.com/settings/personal-access-tokens/new)
for this repository only, with the single permission **Administration:
Read-only**, no other access, created by a repository admin. A ruleset whose
bypass actors are not visible fails the check, and so does a missing token.

**Environment.** Create the environment **`openreaction-release`**
(Settings → Environments) and add, on that environment, the following.
Restrict its deployment branches and tags to `main` and `openreaction-v*` so
nothing else can reach the signing certificate or publish. Both the build
job and the publish job run in this environment, so any required reviewers
approve both.

**Secrets** (the same names OpenKlack's `openklack-release` environment uses):

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | The `.p12`, base64-encoded |
| `APPLE_CERTIFICATE_PASSWORD` | The `.p12` export password |
| `KEYCHAIN_PASSWORD` | Any random string; protects the temporary keychain on the runner |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: <Name> (<TEAMID>)`, exactly as `security find-identity` prints it |
| `APPLE_ID` | The Apple ID used for notarization |
| `APPLE_PASSWORD` | Its app-specific password |
| `APPLE_TEAM_ID` | The ten-character Team ID |
| `RULESET_READ_TOKEN` | Fine-grained token, this repository, Administration: Read-only; used only to read the tag ruleset before publishing |

**Variables** (public configuration, per [LICENSING.md](../../LICENSING.md)):

| Variable | Required | Value |
| --- | --- | --- |
| `OPENAPPS_DODO_PAID_PRODUCT_ID` | yes | The live-mode `OpenReaction` product ID, `pdt_…` |
| `OPENAPPS_BUY_URL` | no | The `https://checkout.dodopayments.com/buy/<paid id>?quantity=1&redirect_url=https://openapps.space/openreaction/thanks/` link; the Buy button says "coming soon" without it |
| `OPENAPPS_SUPPORT_URL` | no | `https://` or `mailto:` link for Contact support |
| `OPENAPPS_DODO_TRIAL_PRODUCT_ID` | no | The live-mode trial product ID, if trial keys are still sold; leave unset otherwise |
| `OPENAPPS_TRIAL_URL` | no | The trial checkout link, if trial keys are still sold |

`OPENAPPS_DODO_ENV` is always `live` in the release job; it is not a variable.
The trial variables exist only for builds that still accept Dodo trial keys;
the in-app trial does not need them.

The release job checks every secret and the paid product ID before it
touches the certificate, and fails naming what is missing. There is no
unsigned fallback: without a `Developer ID Application` identity the job
stops before building. The certificate lives in a temporary keychain that is
deleted as soon as the DMG is signed, before notarization, upload or
publishing run, and a live build refuses placeholder product IDs in any
casing.

## Cutting a release

1. Merge everything the release needs into `main` and make sure the
   OpenReaction workflow is green there.
2. Pick the version, `MAJOR.MINOR.PATCH`. It becomes `CFBundleShortVersionString`;
   `CFBundleVersion` is the commit count on `main`, so it always grows.
3. Tag and push:

   ```sh
   git checkout main && git pull
   git tag -a openreaction-v1.0.0 -m "OpenReaction 1.0.0"
   git push origin openreaction-v1.0.0
   ```

4. The workflow runs three jobs. `checks` as on every change. `release`
   (read-only token) imports the certificate into a temporary keychain,
   builds the universal licensed app, signs it, notarizes and staples the
   app, builds and signs the DMG, removes the signing identity, notarizes
   and staples the DMG, verifies the result and uploads
   `OpenReaction-1.0.0.dmg` plus its `.sha256` as a workflow artifact.
   `publish` (the only job that can write to the repository) downloads that
   exact artifact by id, checks the DMG against the SHA-256 the release job
   reported as a job output (a checksum file that travelled with the
   download is never trusted), confirms the tag ruleset is active with no
   bypass actors, confirms `openreaction-v1.0.0` names exactly the commit
   that was built, creates a *draft* release, uploads the files, confirms
   the tag once more, and only then publishes. Release notes are generated
   from the commits. Expect 20–40 minutes; notarization is most of it.
5. Open the release, check the notes, and download the DMG for the clean-Mac
   check below before linking it from the website.

Builds for the same version and publications of any version are
serialised by GitHub concurrency groups, so two runs never publish at the
same time. GitHub keeps at most one run waiting per group and cancels an
older waiting run when a newer one arrives, so if several releases are
started in quick succession only the running one and the latest waiting one
survive; start the next release once the previous run has finished. A
version lower than the newest published release is refused unless the
manual run sets `allow_older` (a deliberate back-port).

If `release` fails, fix the cause, but do not move or delete the tag: the
ruleset forbids it, and a tag that exists is final. Push the fix to `main`
and tag it as the next patch version. Re-running a failed run is fine as
long as nothing was published yet (a leftover draft is discarded); once a
release is published for a tag, the publish step refuses to touch it again.
A release that turns out to be bad gets a new patch version.

### Release candidates

**Actions → OpenReaction → Run workflow** on a branch (with a `version`) or
on an existing `openreaction-v*` tag (version comes from the tag), with
`publish` left off, runs the same signed and notarized build and uploads
`OpenReaction-<version>-signed` as a workflow artifact without creating a
release. With `publish` on it creates the tag at that commit if it does not
exist yet and publishes exactly as a tag push would; prefer pushing a tag
on `main`. `allow_older` permits publishing a version below the newest
published one.

To rehearse publication without changing anything, run the publish script
locally against the downloaded artifact:

```sh
GH_REPO=openappshq/openapps TAG=openreaction-v1.0.0 VERSION=1.0.0 \
BUILT_COMMIT=$(git rev-parse openreaction-v1.0.0^{commit}) DIST=path/to/artifact \
EXPECTED_SHA256=$(shasum -a 256 path/to/artifact/OpenReaction-1.0.0.dmg | cut -d' ' -f1) \
RULESET_READ_TOKEN=$(gh auth token) \
scripts/publish-release.sh --dry-run
```

(`EXPECTED_SHA256` is normally the release job's output; computing it from
the file only makes sense for a rehearsal. `gh auth token` works for an
admin's own login, which sees the ruleset's bypass actors.)

## Verifying the download on a clean Mac

Use a Mac (or a fresh user account) that has never run a development build,
with the DMG downloaded through a browser so it carries the quarantine flag.
Every command must succeed.

```sh
cd ~/Downloads
shasum -a 256 -c OpenReaction-1.0.0.dmg.sha256          # OK

spctl --assess --type open --context context:primary-signature -vv OpenReaction-1.0.0.dmg
#   accepted, source=Notarized Developer ID
xcrun stapler validate OpenReaction-1.0.0.dmg            # The validate action worked!

open OpenReaction-1.0.0.dmg
cp -R /Volumes/OpenReaction/OpenReaction.app /Applications/
codesign --verify --deep --strict --verbose=2 /Applications/OpenReaction.app
#   valid on disk / satisfies its Designated Requirement
codesign --display --verbose=2 /Applications/OpenReaction.app 2>&1 | grep -E 'Authority|flags'
#   Authority=Developer ID Application: …, flags=… (runtime)
spctl --assess --type execute -vv /Applications/OpenReaction.app
#   accepted, source=Notarized Developer ID
xcrun stapler validate /Applications/OpenReaction.app     # The validate action worked!
lipo -archs /Applications/OpenReaction.app/Contents/MacOS/OpenReaction   # x86_64 arm64
```

Then launch `/Applications/OpenReaction.app`: Gatekeeper must open it without
the "cannot be opened" or "malicious software" dialog, the onboarding window
asks for Accessibility and Input Monitoring, and after granting both,
typing `:tada:` in TextEdit turns into 🎉. Settings must have a License
section with the Buy link (a source build has no License section at all).
Finally, turn Wi-Fi off, quit and relaunch: the stapled ticket means the app
still opens offline.

The same checks, apart from the quarantine flag, run in the workflow's
"Verify the download" step via `scripts/verify-release.sh --notarized`.

## Local builds

A signed local build needs the Developer ID identity in your keychain; an
unsigned one is ad-hoc and only good for the packaging path:

```sh
UNIVERSAL=1 OPENAPPS_LICENSING=1 OPENAPPS_DODO_ENV=test \
OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… VERSION=1.0.0 scripts/bundle.sh
scripts/make-dmg.sh
scripts/verify-release.sh dist/OpenReaction-1.0.0.dmg    # Gatekeeper/stapler are reported, not required
```

With `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD` and
`APPLE_TEAM_ID` set, `scripts/notarize.sh build/OpenReaction.app` and
`scripts/notarize.sh dist/OpenReaction-1.0.0.dmg` reproduce the release job
end to end, and `scripts/verify-release.sh --notarized` then has to pass.
