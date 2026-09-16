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

- **Generation:** a one-time script creates the certificate and private key. It's exported as a password-protected `.p12`, stored as the `RELEASE_SIGNING_P12` and `RELEASE_SIGNING_P12_PASSWORD` secrets of each app's release environment, and backed up offline. Losing it means every installed user re-grants permissions once.
- **Signing:** the release job imports it into a temporary keychain, signs with hardened runtime, then deletes the keychain immediately after the last signing step.
- **Verification before publishing:** `codesign --verify --deep --strict`, and the designated requirement must equal the pinned one checked in at `apps/<app>/release/designated-requirement.txt`. A mismatch fails the release.
- **Gatekeeper:** the app isn't notarized, so the cask and the install script clear the quarantine flag after install. A zip downloaded by hand needs right-click → Open once.
- **If identity ever changes anyway:** users re-grant permissions once, which the user accepts for manual updates. The stable certificate is still kept for the permissions. License and trial records live in an encrypted file the app owns, not in the Keychain (`LICENSING.md`, Record store), so an identity change never prompts for them.
- **Later:** switching to Apple Developer ID changes the identity once. Plan that as a single migration release that tells users to re-grant permissions.

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
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/<App>.app"]
    system_command "/usr/bin/open", args: ["#{appdir}/<App>.app"]
  end
  uninstall quit: "<bundle id>"
  zap trash: ["~/Library/Preferences/<bundle id>.plist", "~/Library/Application Support/<App>"]
end
```

- **Location:** `/Applications`, Homebrew's default `appdir` and where a dragged disk image lands (decided 2026-09-16; before that `~/Applications`). Admin accounts write there without a password, so the in-app updater needs none either; a non-admin account installs with `--appdir`. The System Settings privacy pickers open on `/Applications`, which is why it matters.
- **`auto_updates true`:** Homebrew doesn't fight the in-app updater.
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
