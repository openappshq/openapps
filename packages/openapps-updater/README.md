# OpenAppsUpdater

The in-app updater every OpenApps HQ Swift app compiles into its official
builds ([RELEASES.md](../../RELEASES.md), "In-app updater"). No dependencies,
nothing app-specific: the app injects its identity, feed and key.

```swift
import OpenAppsUpdater

// Info.plist carries SUFeedURL and SUPublicEDKey (the app's bundle script writes them).
guard let configuration = UpdaterConfiguration(bundle: .main, appID: "openreaction", appName: "OpenReaction") else { return }
let updater = Updater(configuration: configuration)   // @MainActor, @Observable
updater.start()                                        // recovers an interrupted swap; checks only if the user opted in

updater.setChecksAutomatically(true)    // Settings toggles, both off by default
updater.setInstallsAutomatically(true)
updater.checkNow()                      // explicit; ends in .available / .upToDate / .failed
updater.installAvailable()              // explicit consent: download, stage, swap, relaunch
updater.restartToUpdate()               // "Update ready — Restart"
updater.installStagedIfAllowed()        // from applicationShouldTerminate
```

What it guarantees:

- **Signed feed and zip.** Nothing in the feed is trusted before its Ed25519
  signature (the Sparkle `sign_update` trailer) verifies with the pinned key;
  a zip must match the announced length, SHA-256 and signature.
- **Newer only.** An item is offered only if it is the same app and channel,
  strictly newer by version *and* build, with the build derived from the
  version, and its minimum macOS is met.
- **Same identity.** The staged bundle must be validly signed and *satisfy*
  the running app's designated requirement, evaluated with the Security
  framework (`codesign --verify --strict -R=` in-process), never compared as
  text — and again right before the swap.
- **Consent.** Automatic staging happens only while "install automatically"
  is on; turning it off cancels a download and discards a staged update, and
  the quit path re-checks. A manual install keeps its consent.
- **Atomic swap.** `renamex_np(RENAME_SWAP)` exchanges the bundles in one
  step; the old one is deleted only afterwards. Without atomic renames, a
  marked move-aside/move-in rolls the old bundle back on failure; if even
  that fails the old bundle is *preserved* with a marker — nothing removes
  it on its own, launch-time recovery reports it, no swap happens over it,
  and the app shows it until the user discards it.
- **Never over a newer app.** The installed bundle's version is re-read at
  install time; if something else (`brew upgrade`) put an equal or newer
  version there, the staged update is not installed.
- **Bounded quit.** `installStagedIfAllowed(deadline:)` runs the
  verification and swap off the main thread under one deadline and skips
  the install past it, so quitting never hangs.

`swift test` covers feed verification, version and consent rules, the swap
with injected failures (including a kill between the fallback's moves), and
a bundle re-signed with a copied requirement string.
