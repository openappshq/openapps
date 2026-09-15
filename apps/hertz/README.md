<div align="center">

<img src="design/assets/app-icon.svg" alt="Hertz app icon" width="128" />

# Hertz

**Native macOS menu-bar system monitor.**

Free & open source · Mac native · No permissions · No telemetry

[Install](#install) · [Build and run](#build-and-run) · [Architecture](docs/architecture.md) · [Report a bug](https://github.com/openappshq/openapps/issues)

</div>

## What it shows

One click in the menu bar opens a dashboard of glass cards, read straight from the kernel every two seconds:

- **Health** — a composite 0–100 score, plus chip, cores, memory, macOS version and uptime
- **Diagnosis** — the current bottleneck, the last few pressure changes, and a copyable snapshot for support threads
- **Sleep blockers** — apps and daemons holding the Mac or the display awake, shown only while something does; read-only, with copy, reveal and Activity Monitor actions
- **CPU** — overall %, a sparkline, per-core bars, load average, temperature, fan speed and thermal pressure
- **Memory** — used, free and swap, with the kernel's pressure level and a trend graph
- **Disk** — free space, usage bar and live read/write throughput
- **Network** — up/down throughput with a trend graph, interface, Wi-Fi name, local IP and VPN state
- **Battery** — charge, time to full or empty, live power draw, health, cycles, temperature, adapter wattage and connected accessories
- **Processes** — a tree grouped by app with subtree CPU and memory totals, sortable, with copy, reveal and terminate in the context menu
- **Cleanup Scout** — a read-only scan of known regenerable developer caches, then a confirmed clean; protected paths are refused

The menu bar item shows the pulse and, by default, CPU usage; Settings can switch the readout to memory or the symbol alone, choose which cards appear, and turn Open at login on.

Hertz needs **no permissions**: everything comes from Mach, libproc, IOKit, the SMC and CoreWLAN. Nothing is stored beyond your settings and nothing leaves the Mac.

## Install

```sh
brew install --cask openappshq/tap/hertz
```

The app lands in `~/Applications`, opens in the menu bar, and needs no admin password. It is signed with the OpenApps HQ Release certificate but not notarized; the cask clears the download quarantine so it opens without a Gatekeeper prompt. Updates come from Homebrew, never from the app:

```sh
brew upgrade --cask hertz
```

Uninstall with `brew uninstall --cask hertz`; `brew uninstall --zap --cask hertz` also removes the saved settings.

## Requirements

macOS 14 Sonoma or later. The release is a universal binary; per-core detail and temperatures are best on Apple silicon.

## Build and run

Requires Xcode 26 (Swift 6.2 or later).

```sh
swift build            # debug build
swift test             # HertzCore: health score, diagnosis, process tree, formatting, cleanup rules
swift run Hertz        # run from the terminal (no welcome window, no login item)
swift run HertzVerify  # cross-check every metric against df, vm_stat, top, ps, pmset and ioreg
scripts/bundle.sh      # release build → build/Hertz.app, ad-hoc signed
```

`HertzVerify` must report `ALL CHECKS PASSED` after any change to a collector. The signed release is built by CI from a `hertz-v*` tag; see [RELEASING.md](RELEASING.md).

Regenerate the app icon and menu-bar image from the SVG masters in `design/assets` with `scripts/make-icons.sh`.

## Architecture

| Layer | Where | Notes |
| --- | --- | --- |
| Collectors | `HertzCore` | Mach `host_*`, Darwin notify, `sysctl`, `statfs`, IOKit, `getifaddrs`, CoreWLAN, libproc, the `AppleSMC` user client; plain synchronous code, no UI |
| Model | `MetricsModel` | One two-second timer on the main actor; snapshots, sparkline history, the flight recorder of pressure changes |
| Dashboard | `Dashboard/` | The `MenuBarExtra` window: one glass card per reading, in the shared brand type and colours |
| Settings, welcome | `Settings/`, `Onboarding/` | Readout, visible cards, Open at login; the welcome window shown once after install |
| Verifier | `HertzVerify` | A separate executable, never bundled into the app |

The reasoning, including the metric-accuracy details, is in [docs/architecture.md](docs/architecture.md).

## Credits

Fonts: Bricolage Grotesque, Instrument Sans and IBM Plex Mono (SIL OFL). The Cleanup Scout's review-first safety model is inspired by Mole (MIT), implemented independently. See [NOTICE](NOTICE).

---

<div align="center">

<img src="../../design/assets/openapps-hq/app-icon.svg" alt="OpenApps HQ" width="56" />

**[MIT](LICENSE) · An [OpenApps HQ](https://github.com/openappshq) original.**

</div>
