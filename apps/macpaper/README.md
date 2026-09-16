<div align="center">

<img src="design/assets/app-icon.svg" alt="macPaper app icon" width="128" />

# macPaper

**Wallpapers, made from the notch.**

Open source · Mac native · No permissions · No telemetry · In development

[What it does](#what-it-does) · [Build and run](#build-and-run) · [Architecture](#architecture) · [Report a bug](https://github.com/openappshq/openapps/issues)

</div>

## What it does

Click or hover the notch and a panel drops down with the wallpaper on your desktop. Pick a generator, move a slider, press Apply:

- **Gradient** — linear, radial or conic, two to six colors, angle or center
- **Mesh** — a grid of control points blended into one soft field; the seed places them
- **Pattern** — dots, lines, checks or noise, two colors, any scale and angle
- **Solid** — one color, with film grain if you like
- **Pixelize** — your own photo in blocks, optionally reduced to a small palette, framed by a focal point you drag
- **Dither** — the same photo through Bayer, Floyd–Steinberg, blue noise, halftone or ASCII, in two colors or a palette from the image

Every wallpaper is a *document*: a generator, its parameters, a seed, the finishes (tint, duotone, gradient map, grain, a shade for the menu bar) and how it composes around the notch (emerge, contours, a painted pill for displays without one), rendered on your Mac at your display's exact pixel size. Every document has a light and a dark side (the dark one derived unless you edit it) and can be applied as a **light/dark pair** or a **time-of-day set** — a HEIC with Apple's own dynamic-desktop record, so macOS keeps switching after macPaper quits. **Pin so it stays** re-applies macPaper's file whenever macOS shows something else. The seed is shown so a look can be typed back in; **Copy link** shares the whole document as `macpaper://s/…`; a favorite is the document, so it renders again on any display. **Shuffle** makes a random one and applies it; Settings can shuffle on a schedule, from your favorites only, the same on every display or a different one per display, and never from what you marked "never show". **Export** writes PNG, a real SVG where the generator is vector, the HEIC pair, or a desktop + phone pair. A palette-matched clock can sit on the wallpaper layer, and a screen saver module shows your stills.

Without a notch (or with the panel turned off) everything lives in the menu-bar popover. A global hotkey (⌃⌥⌘W by default) opens either.

macPaper needs **no permissions**: the notch hover is a tracking area on its own transparent window, the hotkey is Carbon's `RegisterEventHotKey`, the desktop is set and read through `NSWorkspace`, and the theme comes from a distributed notification. Nothing leaves the Mac. The lock screen follows the desktop (macOS offers no public way to set a separate one); Now Playing art and moving wallpapers are deliberately not built (see the [product contract](../../design/products/macpaper.md)).

## Install

macPaper is in development: there is no public download yet. It will install like every OpenApps HQ app, `brew install --cask openappshq/tap/macpaper`, once its first release is tagged ([RELEASING.md](RELEASING.md)).

## Requirements

macOS 14 Sonoma or later; the notch panel needs a Mac with a notch, the popover does not.

## Build and run

Requires Xcode 26 (Swift 6.2 or later).

```sh
swift build            # debug build, licensing compiled out
swift test             # MacPaperCore (generators with golden hashes, pixelize, export, stores, apply, shuffle, notch geometry, panel rules)
                       # and MacPaperTests (the model over fakes, preferences, the licensing seam)
scripts/bundle.sh      # release build → build/macPaper.app, ad-hoc signed
```

To see the UI without changing anything on the Mac, the debug build has a preview harness: it draws the notch panel for every generator, the popover, the restricted state and Settings in light and dark to PNGs, with a throwaway defaults suite and a recording desktop applier, and quits:

```sh
swift build && .build/debug/MacPaper --preview /tmp/macpaper-preview
```

Regenerate the app icon and menu-bar image from the SVG masters in `design/assets` with `scripts/make-icons.sh`.

Licensing and the updater are compiled out of every build until the licensing ticket wires `packages/openapps-licensing` and `packages/openapps-updater` in; the `#if OPENAPPS_LICENSING` seams are in place.

## Architecture

| Layer | Where | Notes |
| --- | --- | --- |
| Documents and generators | `MacPaperCore` | `Wallpaper` (JSON, version 2), software renderers for every generator, the dither lab, pixelize with median cut, OKLCH, finishes, notch compositions, the dark side and the day curve; the same seed gives the same bytes on every Mac |
| Export and pairs | `MacPaperCore/Export.swift`, `Pairs.swift`, `Share.swift` | PNG through ImageIO; SVG as gradients, patterns and a turbulence filter, an embedded PNG otherwise; HEIC with `apple_desktop:apr` / `h24`; share codes; the never-show list |
| Stores | `MacPaperCore/Stores.swift` | Favorites, the applied state (files, per-Space and fallback displays) and bounded imports under `~/Library/Application Support/OpenApps/macpaper/`; a byte-bounded render cache |
| Apply | `MacPaperCore/Displays.swift` | A new file per display and per apply (PNG or HEIC, with a PNG fallback), owned through a manifest, handed to an injectable `DesktopApplier`; the pin policy; the app's applier calls `NSWorkspace`, tests record |
| Panel rules | `MacPaperCore/PanelStateMachine.swift`, `Notch.swift` | Hover, click, hotkey, fullscreen and settings as a pure state machine; the notch rect and the panel frame as pure geometry |
| App | `MacPaper` | `AppModel` (the draft behind one gated edit entry, previews off the main actor, actions), the status item and popover, `NotchPanelController` (the hover window and the `NSPanel`), `DesktopKeeper` (the pin), `ThemeWatcher`, `ClockController`, `HotkeyCenter` (Carbon), `ShuffleEngine`, Settings, the login item, the preview harness |
| Screen saver | `MacPaperSaver` | A `ScreenSaverView` over the core, assembled into `macPaper.saver` by `scripts/bundle.sh` |

## Credits

Fonts: Bricolage Grotesque, Instrument Sans and IBM Plex Mono (SIL OFL). See [NOTICE](NOTICE).

---

<div align="center">

<img src="../../design/assets/openapps-hq/app-icon.svg" alt="OpenApps HQ" width="56" />

**[MIT](LICENSE) · An [OpenApps HQ](https://github.com/openappshq) original.**

</div>
