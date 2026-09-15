# Releasing Hertz

The official build is a universal (Apple silicon + Intel) `Hertz.app`, signed
with the stable OpenApps HQ Release certificate and zipped, as
[RELEASES.md](../../RELEASES.md) specifies. It is installed and updated with
Homebrew; Hertz has no in-app updater (see "Updates" below).
[`.github/workflows/hertz.yml`](../../.github/workflows/hertz.yml) builds it
on GitHub's `macos-26` runner, publishes it as a GitHub Release, verifies the
public download and bumps the Homebrew cask. Nothing about a release is
manual except pushing the tag.

```sh
brew install --cask openappshq/tap/hertz   # how users install it
brew upgrade --cask hertz                  # how they update
```

The scripts the workflow runs are the ones you can run locally:

| Script | Does |
| --- | --- |
| `scripts/bundle.sh` | `swift build -c release`, assembles and signs `build/Hertz.app` (hardened runtime, no sandbox, `scripts/Hertz.entitlements`) |
| `scripts/make-zip.sh` | `ditto -c -k --keepParent` into `dist/Hertz-<version>.zip`, prints its SHA-256 |
| `scripts/verify-release.sh [--release] <zip>` | Unpacks the zip and runs the checks a user's Mac runs; `--release` requires the pinned designated requirement and the release certificate |
| `scripts/publish-release.sh [--dry-run]` | Creates the GitHub Release for a tag, only once the tag provably names the built commit |
| `scripts/make-icons.sh` | Renders `design/assets/*.svg` into the committed `AppIcon.icns` and menu-bar images |

Shared with every app (repository root):

| Script | Does |
| --- | --- |
| `scripts/release/create-signing-certificate.sh <dir>` | One-time: creates the `OpenApps HQ Release` certificate as a password-protected `.p12` |
| `scripts/release/designated-requirement.sh <bundle id> <cert.pem>` | Prints the designated requirement to pin |
| `scripts/release/with-signing-keychain.sh <command>` | Runs one command with the certificate in a temporary keychain, then removes it |
| `scripts/release/verify-designated-requirement.sh <app> <pinned file>` | Fails unless an app has exactly the pinned requirement |
| `scripts/release/release-tag-ruleset.sh check\|apply <definition> [repo]` | Checks for, or creates, the ruleset that makes `hertz-v*` tags immutable |
| `packaging/homebrew/bump-cask.sh <cask.rb> <version> <sha256>` | Sets the cask's version and digest; the template is `packaging/homebrew/Casks/hertz.rb` |

## Updates

Hertz v1 ships without an in-app updater: `brew upgrade --cask hertz` is the
update path, and the app never contacts a feed or a release API (Settings →
Updates says so and offers the command). The standalone repository's
self-updater was removed on import because it fetched the repository-wide
latest GitHub release, which in this monorepo is usually another app's.
When the shared `packages/openapps-updater` lands, adopt it here and add the
signed feed at `https://openapps.space/updates/hertz/latest.json` per
RELEASES.md; until then the cask sets `auto_updates false` so Homebrew
reports and installs upgrades itself.

## One-time setup

### Signing certificate

The certificate is created on the release owner's own Mac, never in CI, and
only its public half is committed. The repository ships with a placeholder
(`release/designated-requirement.txt`, `NOT GENERATED …`); the release job
fails closed while it is still a placeholder.

The certificate is shared by every OpenApps HQ app: create it once, or reuse
the existing one, then derive Hertz's pinned requirement from it:

```sh
scripts/release/create-signing-certificate.sh ~/openapps-release-signing   # once, for every app
scripts/release/designated-requirement.sh com.openappshq.hertz \
    ~/openapps-release-signing/release-signing.cert.pem \
    > apps/hertz/release/designated-requirement.txt
```

Commit `release/designated-requirement.txt`
(`identifier "com.openappshq.hertz" and certificate leaf = H"<sha1>"`). Every
release is signed with exactly this requirement and verified against it.
Hertz asks macOS for no permissions, so a changed certificate costs its users
nothing; the stable identity is still kept, because it is the identity
`brew upgrade` replaces in place and the one every other app depends on.

Back the folder up offline, set the secrets below, then delete it from the
Mac. Never add it to the login keychain; nothing in the release path needs
that.

### GitHub

**Tag protection (required).** The publish step refuses to run unless an
active repository ruleset makes `hertz-v*` tags immutable: no updates, no
force pushes, no deletions, and no bypass actors at all. That is what
guarantees a release's binaries and its tag name the same commit even if
someone tries to move the tag while a release is running. The definition is
checked in at
[`.github/rulesets/hertz-release-tags.json`](../../.github/rulesets/hertz-release-tags.json);
a repository admin applies it once:

```sh
scripts/release/release-tag-ruleset.sh apply .github/rulesets/hertz-release-tags.json openappshq/openapps   # gh must be logged in as an admin
scripts/release/release-tag-ruleset.sh check .github/rulesets/hertz-release-tags.json openappshq/openapps   # what the workflow runs
```

Creating tags stays allowed; once a release tag exists it can only ever be
left alone. A wrong release is fixed by a new patch version, never by
re-tagging.

GitHub shows a ruleset's bypass actors only to callers allowed to administer
the repository; to anyone else the ruleset looks as if nobody were exempt.
The workflow's own token is not such a caller, so the publish job reads
rulesets with a dedicated **`RULESET_READ_TOKEN`**.

**The tap.** `openappshq/homebrew-tap` holds `Casks/hertz.rb`. The release
workflow creates the cask from
[`packaging/homebrew/Casks/hertz.rb`](../../packaging/homebrew/Casks/hertz.rb)
on the first release and bumps it after every later one.

**Environment.** Create the environment **`hertz-release`** (Settings →
Environments) and add, on that environment, the following. Restrict its
deployment branches and tags to `main` and `hertz-v*` so nothing else can
reach the signing certificate or publish. The build, publish and cask jobs
all run in this environment, so any required reviewers approve each.

**Secrets:**

| Secret | Value |
| --- | --- |
| `RELEASE_SIGNING_P12` | The certificate and key as a `.p12`, base64-encoded (`release-signing.p12.base64`) |
| `RELEASE_SIGNING_P12_PASSWORD` | Its password (`release-signing.p12.password`) |
| `RULESET_READ_TOKEN` | [Fine-grained token](https://github.com/settings/personal-access-tokens/new) for this repository only, Administration: Read-only, created by a repository admin; used only to read the tag ruleset before publishing |
| `HOMEBREW_TAP_DEPLOY_KEY` | The private half of an SSH deploy key added to `openappshq/homebrew-tap` with write access (`gh repo deploy-key add --allow-write`); it can push only to the tap |

`HOMEBREW_TAP_DEPLOY_KEY` is a deploy key on the tap repository; the
commits it pushes are authored `openapps-release <release@openapps.space>`.
Hertz has no licensing and no feed, so there are no variables and no
`FEED_COMMIT_TOKEN`.

The release job checks every secret and the committed requirement before it
touches the certificate, and fails naming what is missing. There is no
unsigned fallback. The certificate lives in a temporary keychain for exactly
the build-and-sign step (`with-signing-keychain.sh`), which deletes it before
the zip, the upload or the publish run.

## Cutting a release

1. Merge everything the release needs into `main` and make sure the Hertz
   workflow is green there.
2. Pick the version, `MAJOR.MINOR.PATCH`. It becomes
   `CFBundleShortVersionString`; `CFBundleVersion` is the commit count on
   `main`, which only grows. The standalone repository's last release was
   `v0.1.16`; the first release from this repository should be `0.2.0` or
   later, since the bundle identifier and the tap both changed (a copy
   installed from the standalone repository's tap is a separate app to macOS and to
   Homebrew; uninstall it first).
3. Tag and push:

   ```sh
   git checkout main && git pull
   git tag -a hertz-v0.2.0 -m "Hertz 0.2.0"
   git push origin hertz-v0.2.0
   ```

4. The workflow runs four jobs, following RELEASES.md step by step:
   - `checks`, as on every change: `swift test`, shellcheck, the cask
     template, and an ad-hoc signed universal development zip.
   - `release` (read-only token): imports the certificate into a temporary
     keychain, builds the universal app, signs it with the pinned designated
     requirement and verifies that, deletes the keychain, zips with `ditto`,
     verifies the zip as a release, records its SHA-256 as a job output and
     uploads it as a workflow artifact.
   - `publish` (the only job that can write releases): downloads that exact
     artifact by id, checks the zip against the SHA-256 the release job
     reported (a checksum file that travelled with the download is never
     trusted), confirms the tag ruleset is active with no bypass actors,
     confirms `hertz-v0.2.0` names exactly the commit that was built,
     creates a *draft* release, uploads `Hertz-0.2.0.zip` and its `.sha256`,
     confirms the tag once more, and only then publishes.
   - `cask`: downloads the now-public zip, checks its digest, then bumps
     `Casks/hertz.rb` in `openappshq/homebrew-tap`. The cask only ever moves
     forward: a version below the cask's fails the job unless the run set
     `allow_older`, in which case the back-port is published as a GitHub
     Release only.
   Expect 10–20 minutes.
5. `brew update && brew upgrade --cask hertz` on a Mac with the previous
   version confirms the upgrade before announcing it.

A manual run (Actions → Hertz → Run workflow) from `main` with a version and
`publish` ticked does the same and creates the tag at that commit; without
`publish` it builds and verifies a release-signed zip as an artifact only.

## Local rehearsal

Every release step has a local dry run that needs no secrets:

```sh
scripts/release/create-signing-certificate.sh /tmp/hertz-rehearsal
scripts/release/designated-requirement.sh com.openappshq.hertz /tmp/hertz-rehearsal/release-signing.cert.pem > /tmp/hertz-rehearsal/requirement.txt
cd apps/hertz
cp /tmp/hertz-rehearsal/requirement.txt release/designated-requirement.txt    # temporarily; do not commit
UNIVERSAL=1 VERSION=0.2.0 RELEASE_SIGNING_P12_FILE=/tmp/hertz-rehearsal/release-signing.p12 \
  RELEASE_SIGNING_P12_PASSWORD="$(cat /tmp/hertz-rehearsal/release-signing.p12.password)" \
  ../../scripts/release/with-signing-keychain.sh scripts/bundle.sh
git checkout release/designated-requirement.txt
scripts/make-zip.sh
PINNED_REQUIREMENT_FILE=/tmp/hertz-rehearsal/requirement.txt scripts/verify-release.sh --release dist/Hertz-0.2.0.zip
```

`with-signing-keychain.sh` fails if the throwaway identity can still be
found afterwards, so the rehearsal leaves nothing behind.

## Pulling a bad release

Tags are never reused and releases are never rewritten. Ship the fix as a
higher patch version; `brew upgrade` moves everyone forward. A GitHub Release
can be marked as a pre-release or its notes edited, but its assets stay as
verified.
