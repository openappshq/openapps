<div align="center">

<img src="design/assets/app-icon.svg" alt="Hertz app icon" width="128" />

# Hertz

**Native macOS menu-bar system monitor.**

Open source · Mac native · No permissions · No telemetry · 3-day trial, no signup

[Install](#install) · [Build and run](#build-and-run) · [Architecture](docs/architecture.md) · [Report a bug](https://github.com/openappshq/openapps/issues)

</div>

## What it shows

One click in the menu bar opens a dashboard of glass cards, read straight from the kernel every two seconds:

- **Health** — a composite 0–100 score, plus chip, cores, memory, macOS version and uptime
- **Diagnosis** — the current bottleneck, the last few pressure changes, and a copyable snapshot for support threads
- **Sleep blockers** — apps and daemons holding the Mac or the display awake, shown only while something does; read-only, with copy, reveal and Activity Monitor actions
- **CPU** — overall %, a sparkline, per-core bars, load average, temperature, fan speed and thermal pressure
- **Memory** — used, free and swap, with the kernel's pressure level and a trend graph
- **Disk** — free space and usage of the startup volume, plus live read/write throughput summed over every attached disk
- **Network** — up/down throughput with a trend graph, interface, local IP, VPN state and the Wi-Fi name where macOS still reports it without Location access
- **Battery** — charge, time to full or empty, live power draw, health, cycles, temperature, adapter wattage and connected accessories
- **Processes** — a tree grouped by app with subtree CPU and memory totals, sortable, with copy, reveal and Activity Monitor in the context menu; Hertz never terminates a process
- **Cleanup Scout** — a read-only scan of known regenerable developer caches with their sizes, revealed in the Finder on request; Hertz never deletes anything

The menu bar item shows the pulse and, by default, CPU usage; Settings can switch the readout to memory or the symbol alone, choose which cards appear, and turn Open at login on.

Hertz needs **no permissions**: everything comes from Mach, libproc, IOKit, the SMC and CoreWLAN. The readings never leave the Mac; nothing is stored beyond your settings and the license records described below.

## Install

```sh
brew install --cask openappshq/tap/hertz
```

The app lands in `/Applications`, opens in the menu bar, and needs no admin password. It is signed with the OpenApps HQ Release certificate but not notarized; the cask clears the download quarantine so it opens without a Gatekeeper prompt. Hertz checks for updates once a day and tells you when there is one (Settings → Updates turns the check off, or turns installing on so it updates when you quit); a check downloads only the signed update list from openapps.space and sends nothing about you or your Mac. Homebrew updates it too:

```sh
brew upgrade --cask hertz
```

Uninstall with `brew uninstall --cask hertz`; `brew uninstall --zap --cask hertz` also removes the saved settings.

## Trial, license and privacy

The official build is paid, on the same terms as every OpenApps HQ app ([LICENSING.md](../../LICENSING.md)): a 3-day free trial that starts when you first open Hertz, then a one-time license for up to 3 Macs, bought on [openapps.space/hertz](https://openapps.space/hertz/). When the trial ends the menu-bar item shows the pulse alone and the dashboard shows one card with **Buy a license** and **Enter a key**; Settings and Quit keep working. Settings → License holds the status, the key field and **Remove this Mac**.

> Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use Hertz are never sent. Builds from source never contact the license service.

The records live in an encrypted file store under `~/Library/Application Support/OpenApps/hertz/records/`, never in the Keychain.

## Requirements

macOS 14 Sonoma or later. The release is a universal binary; per-core detail and temperatures are best on Apple silicon.

## Build and run

Requires Xcode 26 (Swift 6.2 or later).

```sh
swift build            # debug build, licensing compiled out
swift test             # HertzCore (health score, diagnosis, process tree, formatting, cleanup rules, first-run flags)
                       # and HertzTests (the licensing wiring against the package's manager with fakes)
swift run Hertz        # run from the terminal (no setup guide, no login item)
swift run HertzVerify  # cross-check every metric against df, vm_stat, top, ps, pmset and ioreg
scripts/bundle.sh      # release build → build/Hertz.app, ad-hoc signed
```

A build from source has licensing compiled out: no License section, no trial, no license network calls, every reading on. The official flavour needs the Dodo product ID and generates its configuration first (never committed):

```sh
OPENAPPS_LICENSING=1 OPENAPPS_DODO_ENV=test OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… \
  scripts/generate-licensing-config.sh Sources/Hertz/Licensing/LicensingConfig.swift
OPENAPPS_LICENSING=1 swift test --scratch-path .build/licensed
swift test --package-path ../../packages/openapps-licensing   # the shared rules, stores and clients
```

`HertzVerify` must report `ALL CHECKS PASSED` after any change to a collector. The signed release is built by CI from a `hertz-v*` tag; see [RELEASING.md](RELEASING.md).

Regenerate the app icon and menu-bar image from the SVG masters in `design/assets` with `scripts/make-icons.sh`.

## Architecture

| Layer | Where | Notes |
| --- | --- | --- |
| Collectors | `HertzCore` | Mach `host_*`, Darwin notify, `sysctl`, `statfs`, IOKit, `getifaddrs`, CoreWLAN, libproc, the `AppleSMC` user client; plain synchronous code, no UI |
| Model | `MetricsModel` | One two-second timer on the main actor; snapshots, sparkline history, the flight recorder of pressure changes |
| Dashboard | `Dashboard/` | The `MenuBarExtra` window: one glass card per reading, in the shared brand type and colours |
| Settings, setup guide | `Settings/`, `Onboarding/` | Readout, visible cards, Open at login, License; the setup guide shown once after install (welcome, nothing to grant, starts with your Mac, tips) |
| Licensing | `Licensing/`, [`packages/openapps-licensing`](../../packages/openapps-licensing) | Official builds: the trial, the paid license and the record store from the shared package; the controller, the pill, the dashboard card and Settings → License here |
| Verifier | `HertzVerify` | A separate executable, never bundled into the app |

The reasoning, including the metric-accuracy details, is in [docs/architecture.md](docs/architecture.md).

## Credits

Fonts: Bricolage Grotesque, Instrument Sans and IBM Plex Mono (SIL OFL). The Cleanup Scout's allowlist-only, review-first model is inspired by Mole (MIT), implemented independently. See [NOTICE](NOTICE).

---

<div align="center">

<img src="../../design/assets/openapps-hq/app-icon.svg" alt="OpenApps HQ" width="56" />

**[MIT](LICENSE) · An [OpenApps HQ](https://github.com/openappshq) original.**

</div>
