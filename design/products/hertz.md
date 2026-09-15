# Hertz

A native menu-bar system monitor: one click shows what the Mac is doing right now, read from the kernel, with nothing to grant and nothing sent anywhere.
Free and open source; installed and updated with Homebrew, never from inside the app.

## Identity

Signature color: green (`green/300` tile face, `green/500` shade, `green/700` / `green/300` accent in light / dark); the mark is a single pulse.
The healthy state and the brand share the color on purpose. Warning and critical states therefore always carry a label (`HIGH`, `CRITICAL`, `THERMAL heavy`) or a shape as well; text never changes color alone.
Type follows the shared system: Bricolage Grotesque for the health score and window headings, Instrument Sans for interface text, IBM Plex Mono with tabular digits for every readout and label.
Surfaces are glass cards (Liquid Glass on macOS 26, the system material before, opaque under Reduce Transparency, a visible rim under Increase Contrast), as in OpenReaction.

## Menu bar

The template pulse symbol plus one readout: CPU % (default), memory %, or the symbol alone. Whole percentages, system font, tabular digits.
Clicking opens the dashboard as a `MenuBarExtra` window, 400 pt wide, as tall as the screen allows within limits; the footer with version, Settings… and Quit stays fixed.

## Dashboard

One scrolling stack of cards, top to bottom:

| Card | Shows | Always |
| --- | --- | --- |
| Health | Score 0–100 in display type, its word, uptime; chip, cores, memory, macOS | yes |
| Diagnosis | Up to three insights (the bottleneck first), the last three pressure changes, Copy snapshot | toggle |
| Sleep blockers | Which processes hold system or display sleep, for how long; copy, reveal, Activity Monitor; read-only | toggle, and only while something blocks |
| CPU | Total %, sparkline, per-core bars, load average, temperature, fan, thermal pressure pill | yes |
| Memory | Used %, sparkline of pressure, used / free / swap, the kernel's pressure level | yes |
| Disk, Network | Half-width pair: free space, usage bar, read/write; throughput sparkline, down/up, interface, Wi-Fi, IP, VPN pill | yes |
| Battery | Charge, bar, time to full or empty, draw, cycles, health, temperature, adapter; connected accessories | when present |
| Processes | Tree by app with subtree totals, top 8 roots, expand on click, sort by CPU or memory, context menu: copy, reveal, terminate (confirmed) | toggle |
| Cleanup Scout | Scan → list of allowlisted caches with sizes → Clean… → inline confirmation → clean | toggle |

Every card: mono label left, headline reading right, chart in the state color, one mono detail line. Charts and pills carry state; numbers stay in the text color.
Refresh every two seconds; rates need two samples, so the first tick shows 0 for CPU and network.

## Settings

| Section | Behavior |
| --- | --- |
| General | Open at login (opt-in, `SMAppService`, approval state shown); menu bar shows CPU / memory / symbol only |
| Dashboard | Diagnosis, sleep blockers, processes, Cleanup Scout on or off; the vitals are always shown |
| Updates | Version; "installed and updated with Homebrew, never checks on its own"; the `brew upgrade` command with Copy |
| About | Welcome window again; MIT; Copy diagnostics (the same snapshot as the Diagnosis card, plus version and login state) |

## Welcome

Shown once, on the first launch of the packaged app: the icon, "Hertz is in your menu bar", a drawn menu bar with the item highlighted, three points (what it shows, what explains what, no permissions / no telemetry), the Open at login toggle on a card, Done. Never shown by `swift run`.

## Defaults and recovery

| Situation | Behavior |
| --- | --- |
| A reading is unavailable (no battery, no fan, no SMC key, no pressure sysctl) | The card or line is omitted or reads "—"; nothing is invented |
| Thermal or memory pressure signal missing | Fall back to `ProcessInfo.thermalState` / usage-derived level; label says which |
| Process terminate | SIGTERM, children first; protected, exited or re-used PIDs are skipped and reported; Hertz itself is never a target |
| Sleep blocker | Never cleared by Hertz; the row explains and offers copy, reveal, Activity Monitor |
| Cleanup Scout | Only paths `scan()` produced (allowlisted cache roots or their direct children) under the home folder; protected folders, symlinks and anything else refused; nothing removed before the inline confirmation |
| Login item registration fails | The toggle reverts and shows the error; Login Items can be opened directly |

No permissions, no accounts, no network, no telemetry. Diagnostics are copied only on request and only to the pasteboard.

## Marketing only

At `/hertz/`: the green key in the headline, a drawn copy of the dashboard beside the list of readings, three feature articles, one Homebrew install line with Copy, questions, the closing field. No Download, no Buy, no download or thanks page.

## References

[App README](../../apps/hertz/README.md) · [Architecture](../../apps/hertz/docs/architecture.md) · [Releasing](../../apps/hertz/RELEASING.md) · [Tokens](../../apps/hertz/design/tokens.json).
