<div align="center">

<img src="design/assets/app-icon.svg" alt="macPaper app icon" width="128" />

# macPaper

**Wallpapers, made from the notch.**

Open source · Mac native · No permissions · No telemetry · 3-day trial, no signup · In development

[What it does](#what-it-does) · [Trial, license and privacy](#trial-license-and-privacy) · [Build and run](#build-and-run) · [Architecture](#architecture) · [Report a bug](https://github.com/openappshq/openapps/issues)

</div>

## What it does

Click or hover the notch and a panel drops down with the wallpaper on your desktop. Pick a generator, move a slider, press Apply:

- **Gradient** — linear, radial or conic, two to six colors, angle or center
- **Mesh** — a grid of control points blended into one soft field; the seed places them
- **Pattern** — dots, lines, checks or noise, two colors, any scale and angle
- **Solid** — one color, with film grain if you like
- **Pixelize** — your own photo in blocks, optionally reduced to a small palette

Every wallpaper is a *document*: a generator, its parameters, a seed and a grain amount, rendered on your Mac at your display's exact pixel size. The seed is shown so a look can be typed back in; a favorite is the document, so it renders again on any display. **Shuffle** makes a random one and applies it; Settings can shuffle on a schedule, from your favorites only, the same on every display or a different one per display. **Export** writes the render as PNG or, where the generator is vector, a real SVG.

Without a notch (or with the panel turned off) everything lives in the menu-bar popover. A global hotkey (⌃⌥⌘W by default) opens either.

macPaper needs **no permissions**: the notch hover is a tracking area on its own transparent window, the hotkey is Carbon's `RegisterEventHotKey`, and the desktop is set through `NSWorkspace`. Nothing leaves the Mac.

## Install

macPaper is in development: there is no public download yet. It will install like every OpenApps HQ app, `brew install --cask openappshq/tap/macpaper`, once its first release is tagged ([RELEASING.md](RELEASING.md)).

## Trial, license and privacy

The official build is paid, on the same terms as every OpenApps HQ app ([LICENSING.md](../../LICENSING.md)): a 3-day free trial that starts when you first open macPaper, then a one-time license for up to 3 Macs, bought on [openapps.space/macpaper](https://openapps.space/macpaper/). When the trial ends the panel and the popover show one card in the generator's place with **Buy a license** and **Enter a key**; Shuffle, Apply and Export are off, the wallpaper you applied stays, and Settings, favorites and Quit keep working. Settings → License holds the status, the key field and **Remove this Mac**; a trial pill in the panel's header and the Settings title bar says where the trial stands.

> Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, your wallpapers, and how you use macPaper are never sent. Builds from source never contact the license service.

The records live in an encrypted file store under `~/Library/Application Support/OpenApps/macpaper/records/`, never in the Keychain. The official build also checks for updates once a day (on by default for a fresh install; installing stays your call) from the signed feed at `openapps.space/updates/macpaper/`, and nothing else leaves the Mac.

## Requirements

macOS 14 Sonoma or later; the notch panel needs a Mac with a notch, the popover does not.

## Build and run

Requires Xcode 26 (Swift 6.2 or later).

```sh
swift build            # debug build, licensing and the updater compiled out
swift test             # MacPaperCore (generators with golden hashes, pixelize, export, stores, apply, shuffle, notch geometry, panel rules, first-run rules)
                       # and MacPaperTests (the model over fakes, preferences, the licensing wiring and enforcement, the setup guide)
scripts/bundle.sh      # release build → build/macPaper.app, ad-hoc signed
```

To see the UI without changing anything on the Mac, the debug build has a preview harness: it draws the notch panel for every generator, the popover, the restricted state and Settings in light and dark to PNGs, with a throwaway defaults suite and a recording desktop applier, and quits:

```sh
swift build && .build/debug/MacPaper --preview /tmp/macpaper-preview
```

Regenerate the app icon and menu-bar image from the SVG masters in `design/assets` with `scripts/make-icons.sh`.

A build from source has licensing compiled out: no License section, no trial, no license network calls, everything on. The official flavour needs the Dodo product ID and generates its configuration first (never committed):

```sh
OPENAPPS_DODO_ENV=test OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… \
  scripts/generate-licensing-config.sh Sources/MacPaper/Licensing/LicensingConfig.swift
OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1 swift test --scratch-path .build/official   # licensing and the updater compiled in
swift test --package-path ../../packages/openapps-licensing   # the shared rules, stores and clients
swift test --package-path ../../packages/openapps-updater     # the shared updater
```

The signed release is built by CI from a `macpaper-v*` tag; see [RELEASING.md](RELEASING.md).

## Architecture

| Layer | Where | Notes |
| --- | --- | --- |
| Documents and generators | `MacPaperCore` | `Wallpaper` (JSON), software renderers for every generator, pixelize with median cut, seeded grain; the same seed gives the same bytes on every Mac |
| Export | `MacPaperCore/Export.swift` | PNG through ImageIO; SVG as gradients, patterns and a turbulence filter, an embedded PNG for noise and pixelize |
| Stores | `MacPaperCore/Stores.swift` | Favorites, the applied state and imported images under `~/Library/Application Support/OpenApps/macpaper/`; a byte-bounded render cache |
| Apply | `MacPaperCore/Displays.swift` | A new PNG per display and per apply, handed to an injectable `DesktopApplier`; the app's calls `NSWorkspace`, tests record |
| Panel rules | `MacPaperCore/PanelStateMachine.swift`, `Notch.swift` | Hover, click, hotkey, fullscreen and settings as a pure state machine; the notch rect and the panel frame as pure geometry |
| App | `MacPaper` | `AppModel` (the draft, previews off the main actor, actions), the status item and popover, `NotchPanelController` (the hover window and the `NSPanel`), `HotkeyCenter` (Carbon), `ShuffleEngine`, Settings, the login item, the preview harness |
| Licensing | `MacPaper/Licensing/`, [`packages/openapps-licensing`](../../packages/openapps-licensing) | Official builds: the trial, the paid license and the record store from the shared package; the controller, the pill, the panel's card, Settings → License and the `macpaper://activate` deep link here. Every action asks the projected entitlement at the click |
| Setup guide, updates | `MacPaper/Onboarding/`, `MacPaper/Updates/`, [`packages/openapps-updater`](../../packages/openapps-updater) | The guide shown once after install (welcome, nothing to grant, starts with your Mac, tips); the shared updater in official builds, with the fresh-install defaults from `MacPaperCore/FirstRun.swift` |

## Credits

Fonts: Bricolage Grotesque, Instrument Sans and IBM Plex Mono (SIL OFL). See [NOTICE](NOTICE).

---

<div align="center">

<img src="../../design/assets/openapps-hq/app-icon.svg" alt="OpenApps HQ" width="56" />

**[MIT](LICENSE) · An [OpenApps HQ](https://github.com/openappshq) original.**

</div>
