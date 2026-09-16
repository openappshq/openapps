# OpenAppsUpdater

The in-app updater every OpenApps HQ Swift app compiles into its official
builds ([RELEASES.md](../../RELEASES.md), "In-app updater"). No dependencies,
nothing app-specific: the app injects its identity, feed and key.

```swift
import OpenAppsUpdater

// Info.plist carries SUFeedURL and SUPublicEDKey (the app's bundle script writes them).
guard let configuration = UpdaterConfiguration(bundle: .main, appID: "openreaction", appName: "OpenReaction") else { return }
let updater = Updater(configuration: configuration)   // @MainActor, @Observable
updater.start()                                        // recovers an interrupted swap; checks only if the toggle is on

updater.setChecksAutomatically(true)    // Settings toggles; nothing stored reads as off. The app writes the
                                        // fresh-install default (RELEASES.md); turning checks on after start() checks now if due
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
- **Atomic swap, or nothing.** `renamex_np(RENAME_SWAP)` exchanges the
  bundles in one step; a volume without it cannot be updated in place and
  the install is refused with "Move the app to the Applications folder on
  your startup disk". A state file (`staging` → `exchanging` → `superseded`)
  is written and read back *before* each step; if it can't be, nothing
  starts. Launch-time recovery removes a staging folder only when the state
  says it holds a never-installed download or the superseded old bundle;
  anything else with a bundle in it is preserved, reported, refused as a
  swap target, and shown in the app until the user discards it.
- **Never over a newer app.** The installed bundle's version is re-read at
  install time; if something else (`brew upgrade`) put an equal or newer
  version there, the staged update is not installed.
- **Bounded, cooperative quit.** `installStagedIfAllowed(deadline:)` runs
  the verification and exchange off the main thread. Past the deadline the
  install is abandoned only if the worker has not reached its commit point
  (nothing changed); once it has, the quit waits for the exchange to finish,
  so the process never exits mid-swap. "Restart to Update" goes through the
  app's own quit path (`finishQuit()`) and reopens the app after exit via a
  detached helper, since an app that prohibits multiple instances cannot
  open a second copy of itself.
- **Trusted identity.** The requirement every update must satisfy is taken
  from the running code at launch (`SecCodeCopySelf`), never re-read from a
  path on disk; symbolic links are refused as swap targets.

`swift test` covers feed verification (including bogus signature trailers),
version and consent rules, the swap with injected failures at every step
and the recovery of each recorded state, the commit/abort hand-off of the
quit path, and a bundle re-signed with a copied requirement string.
