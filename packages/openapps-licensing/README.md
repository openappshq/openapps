# OpenAppsLicensing

The licensing every OpenApps HQ Swift app compiles into its official builds
([LICENSING.md](../../LICENSING.md) is the contract): a 3-day in-app trial
registered once with the trial registry, paid licenses activated and checked
daily with Dodo Payments, offline grace, revocation, and an encrypted record
store. No dependencies, nothing app-specific: the app injects its id, its
name, its products, its hosts and its preferences suite.

Two products, so a build with licensing compiled out links no client code:

| Product | Holds | Who links it |
| --- | --- | --- |
| `OpenAppsLicensing` | `LicensePolicy`, `LicenseManager`, `LicenseSnapshot`, the trial (`TrialRecord`, `TrialClock`, `TrialTiming`), `FileRecordStore`, `LicenseBadge`, `LicenseMessage`, and the protocols the manager is driven by (`LicenseClient`, `LicenseStore`, `TrialStore`, `InvalidationJournal`, `TrialRegistryClient`, `DeviceIdentity`) | Every build: the badge type is what the app's UI carries even when licensing is off |
| `OpenAppsLicensingClients` | The live implementations: `DodoLicenseClient` (URLSession), `URLSessionTrialRegistryClient`, `PlatformDeviceIdentity` (`IOPlatformUUID`), `DefaultsInvalidationJournal` (a preferences suite) | Only a build with licensing on (`OPENAPPS_LICENSING=1` in the app's `Package.swift`) |

```swift
import OpenAppsLicensing
import OpenAppsLicensingClients   // licensed builds only

// Both records live in one encrypted file store keyed to this Mac
// (~/Library/Application Support/OpenApps/<app id>/records/).
let device = PlatformDeviceIdentity()
let records = FileRecordStore(appID: "openreaction", device: device)
let manager = LicenseManager(
    appID: "openreaction",                                  // record store, trial registry, device hash
    products: LicenseProducts(paid: ["pdt_…"]),             // Dodo product IDs for this environment
    client: DodoLicenseClient(host: URL(string: "https://live.dodopayments.com")!),
    store: records,
    journal: DefaultsInvalidationJournal(suiteName: "space.openapps.openreaction.license"),
    trialStore: records,
    registry: URLSessionTrialRegistryClient(
        endpoint: URL(string: "https://openapps.space/api/trial")!, appID: "openreaction", environment: "live"
    ),
    device: device,
    trialTiming: .standard                                  // a debug build may shorten the day
)

// On the license actor: read storage, start a provisional trial on a fresh
// Mac, then the launch check and the trial's registration in the background.
await manager.setOnChange { snapshot in /* lock the feature from here, before any I/O */ }
await manager.load()
await manager.checkOnLaunch()
await manager.tick()                    // every timer, wake, clock change and network return
await manager.wake()                    // wake from sleep: the clock-behind check first
let message = await manager.activate(key: key)          // → LicenseMessage
let removed = await manager.removeThisMac()             // → LicenseMessage
Task { @LicenseActor in manager.saveTrialBeforeQuit() }  // on quit, bounded by the app

// What the user sees; the app name goes into the copy.
let state = snapshot.state(now: Date(), uptime: LicenseManager.continuousUptime())
LicenseBadge.label(for: state, appName: "OpenReaction", storageError: false, trialStorageError: false)
message.text(appName: "OpenReaction")
```

What the app keeps for itself: the licensing build flag and its generated
configuration (Dodo host, product IDs, registry URL), the controller that
owns timers, wake and network notifications, the License screen and the
status pill, and the copy around them. What it must never do is read the
trial or license records through anything but the manager: the snapshot the
manager hands over is the one source of the entitlement.

What the package guarantees:

- **A license always wins over the trial.** Without a readable license
  record the trial record decides; a Mac whose trial record is positively
  absent starts a provisional trial (saved before the core turns on) and
  registers it in the background; the registry's answer can only move the
  start earlier.
- **Enforcement never waits on storage.** The manager runs on its own
  executor (`LicenseActor`) and publishes a `LicenseSnapshot` right after
  its memory changes and before it touches the store; the entitlement is
  derived from the snapshot with the clock, so deadlines and the feature
  lock never wait on I/O.
- **Time only moves forward.** The trial's clock is anchored on the wall
  clock and a monotonic clock that keeps counting through sleep; a clock
  found behind at launch or wake freezes the trial until it is right again,
  and a paid license whose clock went backwards needs a check.
- **Invalidation survives a failed save.** `valid: false` and "Remove this
  Mac" are journaled outside the record store first, then take effect in
  memory at once; the entry keeps the activation dead across a restart until
  the record is durably saved as revoked, deleted or replaced.
- **Durable before reported.** `FileRecordStore` writes a temporary file
  beside the record, syncs it, renames it and syncs the directory; a failure
  before the rename leaves the old file untouched, a failed directory sync
  after it is `.indeterminate` and the same write is repeated until it is
  durable — a grant waits for that.

`swift test` covers the shared test cases from LICENSING.md (the paid
license, the in-app trial and the registry), random sequences against the
trial clock, enforcement timing against a blocking store, the file store
with every system call made to fail, and the preferences journal against a
throwaway suite.
