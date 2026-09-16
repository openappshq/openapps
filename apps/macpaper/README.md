<div align="center">

<img src="design/assets/app-icon.svg" alt="macPaper app icon" width="128" />

# macPaper

**Wallpapers, made from the notch.**

Open source · Mac native · No permissions · No telemetry · In development

[What it does](#what-it-does) · [Build and run](#build-and-run) · [Architecture](#architecture) · [Report a bug](https://github.com/openappshq/openapps/issues)

</div>

## What it does

Click or hover the notch and a column drops down with the wallpaper on your desktop: a library of looks, the generators, the palette, the parameters and the effects, one section at a time. Pick a look, move a slider — every change lands on the desktop as you make it, and a pin beside any parameter keeps it through Shuffle:

- **Pixel fields** — six authored looks on one sampled-field engine, every cell of the display's pixel grid one flat tone: **Moiré** (a radial and a linear wave beating inside a crescent, or two twisted lattices), **Relief** (warped noise cut into shifted terraces with lit rims), **Islands** (an archipelago with dithered shores), **Plate** (Chladni nodal lines gathering grains inside an aperture), **Circuit** (Truchet ribbons joined across tiles), **Sky** (a horizon, two ridges, a cropped sun, diffused into large cells)
- **Dither** — Bayer, Floyd–Steinberg, blue noise, halftone or ASCII over a photo, or over the base layer when there is none
- **Pattern** — dots, lines or checks over a gradient or mesh base
- **Mesh** and **Pixelize**; a gradient or a flat color is a base layer, not a generator

Every wallpaper is a *document*: a generator, its parameters, a seed, a **base layer** (flat, gradient or mesh under the texture), the finishes (tint, duotone, gradient map, wash, vignette, fringe, grain, a shade for the menu bar) and how it composes around the notch, rendered on your Mac at your display's exact pixel size. **56 preset palettes** in OKLCH, grouped and named, feed every generator; a document's colors name it after its palette. Every document has a light and a dark side and can be applied as a **light/dark pair** or a **time-of-day set** — a HEIC with Apple's own dynamic-desktop record. **Pin so it stays** re-applies macPaper's file whenever macOS shows something else. **Shuffle only ever lands on a curated recipe**: a family of authored looks, a preset palette, and a quality gate that refuses flat fills, bare gradients, mud, no silhouette and unreadable menu bars — macPaper never ships a bare gradient, and when the pins leave nothing the gate passes, the desktop keeps what it shows. Every parameter has a **pin**: pinned, Shuffle keeps it. A **recipe** is a named document; the library starts with a taste set of 34, and a recipe travels as a `.macpaper` file (export, import, double-click, drag) or as a `macpaper://s/…` link — the same document. **Export** writes PNG, SVG, the HEIC pair, or a desktop + phone pair. A palette-matched clock can sit on the wallpaper layer, and a screen saver module shows your stills.

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
swift test             # MacPaperCore (generators and pixel fields with golden hashes, palettes, the quality gate, recipes, pins, export, stores, apply, notch geometry, panel rules)
                       # and MacPaperTests (the model over fakes, preferences, the licensing seam)
scripts/bundle.sh      # release build → build/macPaper.app, ad-hoc signed
```

To see the UI without changing anything on the Mac, the debug build has a preview harness: it draws the column over four desktops (a saturated mesh, grey, near-black, near-white) at every width, every section, every generator's parameters, the column under a menu-bar item on a display without a notch, the popover, the restricted state and Settings in light and dark to PNGs, with a throwaway defaults suite and a recording desktop applier, and quits:

```sh
swift build && .build/debug/MacPaper --preview /tmp/macpaper-preview
```

The debug build also renders documents and contact sheets without any UI — the taste set at three display sizes, every shuffle family across palettes and seeds with the gate's verdict, the moiré at three cell sizes, a run of curated Shuffle, a timed 5K render — with `MacPaper --renders /tmp/macpaper-renders [taste|families|cells|shuffle|bench|dither|pick]`; a release build with the harness compiled in (`swift build -c release -Xswiftc -DDEBUG`) does it ten times faster.

Regenerate the app icon and menu-bar image from the SVG masters in `design/assets` with `scripts/make-icons.sh`.

Licensing and the updater are compiled out of every build until the licensing ticket wires `packages/openapps-licensing` and `packages/openapps-updater` in; the `#if OPENAPPS_LICENSING` seams are in place.

## Architecture

| Layer | Where | Notes |
| --- | --- | --- |
| Documents and generators | `MacPaperCore` | `Wallpaper` (JSON, version 3: generator, base, finishes, pins), software renderers for every generator, the pixel-field engine (`Field.swift`, `FieldEngine.swift`: six families on one sampled grid, tone bracketing, the residual dither, native cell fill and area-filtered previews), the dither lab, pixelize with median cut, OKLCH, finishes, notch compositions, the dark side and the day curve; the same seed gives the same bytes on every Mac |
| Palettes, curation | `MacPaperCore/Palettes.swift`, `Curation.swift`, `TasteSet.swift` | The 56 presets and the preset rule; the recipe families, the quality gate and curated Shuffle with pins; the taste set the library starts with |
| Export and pairs | `MacPaperCore/Export.swift`, `Pairs.swift`, `Share.swift`, `Recipes.swift` | PNG through ImageIO; SVG as gradients, patterns and a turbulence filter, an embedded PNG otherwise; HEIC with `apple_desktop:apr` / `h24`; recipe documents as `.macpaper` files and share codes; the never-show list |
| Stores | `MacPaperCore/Stores.swift`, `Recipes.swift` | The recipe library (the favorites of earlier versions, migrated), the applied state (files, per-Space and fallback displays) and bounded imports under `~/Library/Application Support/OpenApps/macpaper/`; a byte-bounded render cache |
| Apply | `MacPaperCore/Displays.swift` | A new file per display and per apply (PNG or HEIC, with a PNG fallback), owned through a manifest, handed to an injectable `DesktopApplier`; the pin policy; the app's applier calls `NSWorkspace`, tests record |
| Panel rules | `MacPaperCore/PanelStateMachine.swift`, `Notch.swift` | Hover, click, hotkey, fullscreen and settings as a pure state machine; the notch rect and the panel frame as pure geometry |
| App | `MacPaper` | `AppModel` (the draft behind one gated edit entry, previews off the main actor, actions), the status item and popover, `NotchPanelController` (the hover window and the `NSPanel`), `DesktopKeeper` (the pin), `ThemeWatcher`, `ClockController`, `HotkeyCenter` (Carbon), `ShuffleEngine`, Settings, the login item, the preview harness |
| Screen saver | `MacPaperSaver` | A `ScreenSaverView` over the core, assembled into `macPaper.saver` by `scripts/bundle.sh` |
| Licensing | `MacPaper/Licensing/`, [`packages/openapps-licensing`](../../packages/openapps-licensing) | Official builds: the trial, the paid license and the record store from the shared package; the controller, the pill, the panel's card, Settings → License and the `macpaper://activate` deep link here. Every edit, action and resumption asks the projected entitlement at that moment |
| Setup guide, updates | `MacPaper/Onboarding/`, `MacPaper/Updates/`, [`packages/openapps-updater`](../../packages/openapps-updater) | The guide shown once after install (welcome, nothing to grant, starts with your Mac, tips); the shared updater in official builds, with the fresh-install defaults from `MacPaperCore/FirstRun.swift` |

## Credits

Fonts: Bricolage Grotesque, Instrument Sans and IBM Plex Mono (SIL OFL). See [NOTICE](NOTICE).

---

<div align="center">

<img src="../../design/assets/openapps-hq/app-icon.svg" alt="OpenApps HQ" width="56" />

**[MIT](LICENSE) · An [OpenApps HQ](https://github.com/openappshq) original.**

</div>
