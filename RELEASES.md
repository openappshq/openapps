# Releases and updates

How every OpenApps HQ app is released, installed and kept up to date. OpenKlack and OpenReaction follow this document, and any new app under `apps/` must too. If an app needs to differ, change this document first. Licensing rules live in [LICENSING.md](LICENSING.md).

## Summary

| Piece | Choice |
| --- | --- |
| Install | Homebrew cask from the `openappshq/homebrew-tap` tap: `brew install --cask openappshq/tap/<app>` |
| Code signing | A stable self-signed code-signing certificate (`OpenApps HQ Release`), the same for every release. No Apple Developer ID or notarization for now |
| Release tags | `<app>-vX.Y.Z` (strict SemVer, never moved or reused) |
| Release files | A zip of the `.app` attached to the GitHub Release for that tag |
| Update feed | `https://openapps.space/updates/<app>/latest.json`, a signed JSON file served by the website |
| Updates | In the app: daily check, background download, install on the next quit or relaunch. Settings toggles |
| Update signatures | Every feed and every zip is signed with an app-specific update key that official builds pin |

## Why a stable self-signed certificate

macOS ties Accessibility, Input Monitoring and Keychain access to an app's code-signing identity (its *designated requirement*). An ad-hoc signature's identity is the build's hash (`cdhash`), so every update would count as a different app: OpenReaction would lose Accessibility, OpenKlack would lose Input Monitoring, and both would lose access to their license and trial Keychain items. A self-signed certificate with the same identity for every release keeps a stable designated requirement (`identifier "<bundle id>" and certificate leaf = H"<cert hash>"`), so permissions and Keychain access survive updates.

- **Generation:** a one-time script creates the certificate and private key. It's exported as a password-protected `.p12`, stored as the `RELEASE_SIGNING_P12` and `RELEASE_SIGNING_P12_PASSWORD` secrets of each app's release environment, and backed up offline. Losing it means every installed user re-grants permissions once.
- **Signing:** the release job imports it into a temporary keychain, signs with hardened runtime, then deletes the keychain immediately after the last signing step.
- **Verification before publishing:** `codesign --verify --deep --strict`, and the designated requirement must equal the pinned one checked in at `apps/<app>/release/designated-requirement.txt`. A mismatch fails the release.
- **Gatekeeper:** the app isn't notarized, so the cask clears the quarantine flag after install (as Hertz does). A zip downloaded by hand needs right-click → Open once.
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
  depends_on macos: ">= :sonoma"
  app "<App>.app", target: "#{Dir.home}/Applications/<App>.app"
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{Dir.home}/Applications/<App>.app"]
    system_command "/usr/bin/open", args: ["#{Dir.home}/Applications/<App>.app"]
  end
  uninstall quit: "<bundle id>"
  zap trash: ["~/Library/Preferences/<bundle id>.plist", "~/Library/Application Support/<App>"]
end
```

- **Location:** installed into `~/Applications`, so updates never need an admin password.
- **`auto_updates true`:** Homebrew doesn't fight the in-app updater.
- **Bumping the cask:** the release workflow updates the cask right after a release is published, by pushing a commit to the tap with a token scoped to that repository only (`HOMEBREW_TAP_TOKEN`). There's no polling cron. The cask's `sha256` is the digest the release job verified.

## Release flow (one GitHub Actions workflow per app)

Trigger: a pushed `<app>-vX.Y.Z` tag, or a manual dispatch with a version.

1. **Build** the universal `.app` with licensing on, stamping the version from the tag.
2. **Sign** with the stable certificate, verify the designated requirement, then delete the signing keychain.
3. **Zip** with `ditto -c -k --keepParent` into `<App>-X.Y.Z.zip`, and record its SHA-256 as a job output.
4. **Sign the update:** sign the zip with the app's update key (OpenReaction: Sparkle EdDSA `sign_update`; OpenKlack: the Tauri updater key).
5. **Publish** the GitHub Release for the tag with the zip, using the existing hardened publish path: draft, then check the tag SHA against the built commit, then undraft, with a separate job holding write access.
6. **Write the feed:** generate `apps/website/public/updates/<app>/latest.json`, sign it, and commit it to `main` with the release bot. The website deploy then serves it at `https://openapps.space/updates/<app>/latest.json`.
7. **Verify live:** fetch the public zip and feed, then check the digest, the feed signature and the version.
8. **Bump the cask** in `openappshq/homebrew-tap`.

The feed never points at a release until that release's zip is published and verified.

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
| When | On launch in the background, every 24 hours while running, and on wake if the last check is older than 24 hours |
| Settings | "Check for updates automatically" (on by default), "Download and install automatically" (on by default), and "Check now" |
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
