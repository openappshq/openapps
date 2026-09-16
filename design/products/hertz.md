# Hertz

A native menu-bar system monitor: one click shows what the Mac is doing right now, read from the kernel, with nothing to grant.
Open source under MIT; the official build is paid on the same terms as every OpenApps HQ app ([LICENSING.md](../../LICENSING.md): 3-day in-app trial, no signup, one license for 3 Macs). Installed and updated with Homebrew, never from inside the app.

## Identity

Signature color: green (`green/300` tile face, `green/500` shade, `green/700` / `green/300` accent in light / dark); the mark is a single pulse.
The healthy state and the brand share the color on purpose. Warning and critical states therefore always carry a label (`HIGH`, `CRITICAL`, `THERMAL heavy`) or a shape as well; text never changes color alone.
Type follows the shared system: Bricolage Grotesque for the health score and window headings, Instrument Sans for interface text, IBM Plex Mono with tabular digits for every readout and label.
Surfaces are glass cards (Liquid Glass on macOS 26, the system material before, opaque under Reduce Transparency, a visible rim under Increase Contrast), as in OpenReaction.

## Menu bar

The template pulse symbol plus one readout: CPU % (default), memory %, or the symbol alone. Whole percentages, system font, tabular digits.
Clicking opens the dashboard as a `MenuBarExtra` window, 400 pt wide, as tall as the screen allows within limits; the footer with version, Settings… and Quit stays fixed.
While the license keeps the readings off (below), the item shows the pulse alone, whatever the readout setting.

## Dashboard

One scrolling stack of cards, top to bottom:

| Card | Shows | Always |
| --- | --- | --- |
| Health | Score 0–100 in display type, its word, uptime; chip, cores, memory, macOS. In official builds the license pill sits above the score while there is something to say (the trial's days left, a reason the readings are off); it opens Settings → License | yes |
| Diagnosis | Up to three insights (the bottleneck first), the last three pressure changes, Copy snapshot | toggle |
| Sleep blockers | Which processes hold system or display sleep, for how long; copy, reveal, Activity Monitor; read-only | toggle, and only while something blocks |
| CPU | Total %, sparkline, per-core bars, load average, temperature, fan, thermal pressure pill | yes |
| Memory | Used %, sparkline of pressure, used / free / swap, the kernel's pressure level | yes |
| Disk, Network | Half-width pair: startup-volume free space and usage bar, read/write summed over every attached disk; throughput sparkline, down/up, interface, IP, VPN pill, Wi-Fi name when macOS reports it (newer macOS withholds the SSID without Location access; the line omits it) | yes |
| Battery | Charge, bar, time to full or empty, draw, cycles, health, temperature, adapter; connected accessories | when present |
| Processes | Tree by app with subtree totals, top 8 roots, expand on click, sort by CPU or memory, context menu: copy, reveal, open Activity Monitor. Hertz never terminates a process | toggle |
| Cleanup Scout | Scan → list of allowlisted caches with sizes → reveal in the Finder or copy the report. Read-only: Hertz never deletes | toggle |

Every card: mono label left, headline reading right, chart in the state color, one mono detail line. Charts and pills carry state; numbers stay in the text color.
Refresh every two seconds; rates need two samples, so the first tick shows 0 for CPU and network.

## Licensing

Official builds follow [LICENSING.md](../../LICENSING.md) through the shared `packages/openapps-licensing`: a 3-day trial that starts on first launch with no signup and registers once with the trial registry, a paid key activated and checked daily with Dodo Payments, offline grace, an encrypted record store under `~/Library/Application Support/OpenApps/hertz/records/`. Builds from source have none of it and every reading on.

**The core feature is the live readings.** While the state is Trial, Licensed or Grace they run. In every other state (TrialEnded, TrialNeedsConnection, TrialClockBehind, CheckRequired, Revoked, and the storage-error forms of TrialUnavailable) they are off:

| Surface | While the readings run | While they are off |
| --- | --- | --- |
| Menu-bar item | Pulse + the chosen readout | Pulse alone |
| Dashboard | The cards above; the license pill in the Health card while not simply licensed | One card at the top in place of the cards, then the footer |
| Collection | Every two seconds, started only once the license has granted access | Off: nothing is read, and the sample taken under the earlier grant is dropped |
| Copy snapshot, Copy Diagnostics | The report | Version, login state and the build's licensing flavour only; the readings line says they are not collected |
| Settings, License, Quit | Work | Work |

The entitlement is asked at the moment it matters, never remembered: the collector, the readout, the dashboard and both copy paths read the license controller's projection of the manager's latest snapshot to the current clocks (the trial's monotonic clock, a held clock-behind, an unchecked wake). A deadline that passes between the deadline timer's schedule and its callback therefore already refuses the next read; the timers only wake the app to re-render and run the manager's housekeeping.

The dashboard card names the state in LICENSING.md's words and offers a way out, never a price (the website states it):

| State | Title | Actions |
| --- | --- | --- |
| Trial starting (storage not answered yet) | Starting your free trial… | Enter a key |
| License or trial record unreadable | Can’t read the license record / Can’t read or save the free trial record | Try again · Enter a key |
| TrialEnded | Your free trial has ended | **Buy a license** · Enter a key |
| TrialNeedsConnection | Connect to the internet to continue your free trial | **Try again** · Buy a license · Enter a key |
| TrialClockBehind | Your Mac’s clock is behind | **Buy a license** · Enter a key |
| CheckRequired | Connect to the internet to verify your license | **Try again** · Enter a key |
| Revoked | This license is no longer active on this Mac | **Enter a key** · Buy a license |

"Buy a license" opens `https://openapps.space/hertz/`; "Enter a key" opens Settings → License with the key field focused; "Try again" retries storage, the trial registry or the license check now. When the trial ends, the card and the pill say so; nothing opens on its own. The website's thanks page deep-links `hertz://activate?key=…`, which only pre-fills the key: the user confirms in Settings → License.

## Settings

| Section | Behavior |
| --- | --- |
| General | Open at login (on once on a fresh install, `SMAppService`, approval state shown; the user can turn it off); menu bar shows CPU / memory / symbol only |
| Dashboard | Diagnosis, sleep blockers, processes, Cleanup Scout on or off; the vitals are always shown |
| License (official builds) | Status line; Buy a license (opens the website; never a price); paste a key + Activate; Remove this Mac (confirmed); Try again and the storage-error copy when a record can't be read; the shared privacy copy as the footer. The trial pill sits in the window's title bar while there is something to say |
| Updates | Version; "installed and updated with Homebrew, never checks on its own"; the `brew upgrade` command with Copy |
| About | What Hertz reads and where it goes (kernel; the only network calls are the license check and the trial registry, none in a source build); Show setup guide; MIT; Copy diagnostics (the same snapshot as the Diagnosis card, plus version, login state and the build's licensing flavour) |

## Setup guide

The same guide as OpenReaction and OpenKlack, opened once on the first launch of the packaged app and again from Settings → About → Show setup guide; skippable at every step, and reopening resumes at the furthest step reached. Never shown by `swift run`.

| Step | Content |
| --- | --- |
| Welcome | The icon, "Hertz is in your menu bar.", the trial line from the real license state with the license pill (official builds), Get started / Skip for now |
| Permissions — "Nothing to grant." | What Hertz reads (Mach, libproc, IOKit, the SMC, CoreWLAN) and that none of it needs a permission; the privacy line; read-only actions; the Wi-Fi name without Location access |
| Login — "Starts with your Mac." | The Open at login toggle from the real `SMAppService` state, and where to change it later |
| Tips | A drawn menu bar with the item highlighted; the readout choice, the dashboard cards, License in Settings (official builds), what to do when the icon is hidden; Done |

## Defaults and recovery

| Situation | Behavior |
| --- | --- |
| Fresh install (no earlier preferences, both records positively absent) | Open at login is turned on once, after storage answers; never revisited. An upgrade from a free 0.1.x build, a reinstall over kept records or a login item the user turned off is left alone |
| A reading is unavailable (no battery, no fan, no SMC key, no pressure sysctl) | The card or line is omitted or reads "—"; nothing is invented |
| Thermal or memory pressure signal missing | Fall back to `ProcessInfo.thermalState` / usage-derived level; label says which |
| Process actions | Copy, reveal, open Activity Monitor only. A row is a snapshot of a PID and a path, not a process identity, so Hertz never signals anything; terminating happens in Activity Monitor |
| Sleep blocker | Never cleared by Hertz; the row explains and offers copy, reveal, Activity Monitor |
| Cleanup Scout | Lists only allowlisted cache roots (or their direct children) under the home folder; protected folders and any path with a symbolic link between the home folder and the cache are refused. Nothing is ever removed by Hertz |
| Login item registration fails | The toggle reverts and shows the error; Login Items can be opened directly |
| License or trial record can't be read or saved | Storage error in the dashboard card and Settings → License, retried; never a new trial over a record that couldn't be read, never a deleted setting |
| Quit while the trial runs | The trial's latest observed time is saved first, bounded to two seconds |

No permissions, no accounts, no telemetry. Diagnostics are copied only on request and only to the pasteboard. The privacy copy every licensed app ships (LICENSING.md, "Privacy copy") is Hertz's too: the only network calls are the license check and the trial registry's one-way device hash; builds from source make none.

## Marketing only

At `/hertz/`: the green key in the headline, a drawn copy of the dashboard beside the list of readings, three feature articles, the install block with the Homebrew command and Copy, Buy, questions, the closing field. The paid catalog entry, Buy and the thanks page ship with the first licensed release, so Buy never shows for a free build.

## References

[App README](../../apps/hertz/README.md) · [Architecture](../../apps/hertz/docs/architecture.md) · [Releasing](../../apps/hertz/RELEASING.md) · [Tokens](../../apps/hertz/design/tokens.json) · [Licensing](../../LICENSING.md).
