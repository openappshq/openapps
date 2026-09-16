# macPaper

A wallpaper maker that lives in the notch: click or hover the notch and a panel drops down with the current wallpaper, a generator to change it, Shuffle, Apply, Favorite and Export. Every wallpaper is made on the Mac from a few parameters and a seed; nothing is downloaded and nothing is uploaded. macPaper makes **stills** that macOS keeps showing after the app quits — light/dark and time-of-day pairs included — and keeps them applied.
Open source under MIT; the official build is paid on the same terms as every OpenApps HQ app ([LICENSING.md](../../LICENSING.md): 3-day in-app trial, no signup, one license for 3 Macs). Installed with Homebrew; the official build checks a signed feed for updates once a day and installs one only when the user says so ([RELEASES.md](../../RELEASES.md)).

Inspired by the idea of a notch-based wallpaper maker; written from scratch, with no code, copy, name or asset from any other product. Scope decided 2026-09-16 by the user from the macPaper roadmap (three scouts of what wallpaper apps ship and users ask for): the whole roadmap is v1, except what a spike ruled out ("Not built" below).

## Identity

Signature color: tangerine (`tangerine/300` tile face, `tangerine/500` shade, `tangerine/700` / `tangerine/300` accent in light / dark); the mark is a display outline with the notch as a filled tab and one horizon line inside.
The color is the app's, not a state: success stays green, danger red, warning HQ yellow, so a tangerine control is always an action or the brand.
Type follows the shared system: Bricolage Grotesque for the panel's heading and the settings window's headings, Instrument Sans for interface text, IBM Plex Mono with tabular digits for seeds, sizes and labels.
Surfaces are glass cards (Liquid Glass on macOS 26, the system material before, opaque under Reduce Transparency, a visible rim under Increase Contrast), as in Hertz and OpenReaction. The notch panel is one such card, squared off at the top where it meets the menu bar.

## Primary task

Make the desktop look the way you want in one gesture: open the panel, pick or shuffle, Apply. Everything else (favorites, scheduled shuffle, export, per-display choices) supports that.

## Generators

Every wallpaper is a document: a generator, its parameters, a seed, a base layer, the finishes and the composition, serialisable as JSON (version 3). The same document renders the same pixels at the same size on every Mac; the seed is shown in the panel so a look can be reproduced or shared.

**Pixel fields** are the heart of it (`MacPaperCore/FieldEngine.swift`): one sampled-field engine, six authored families. A field is evaluated once per cell of the display's pixel grid (cell size 4–64 px), bracketed into 2–8 tone steps along the palette (mixed in OKLab or sRGB), the fractional residual dithered per cell (none, Bayer 8×8, blue noise, or serpentine Floyd–Steinberg diffusion), and every cell filled at native size — a preview integrates the same cells (area filtering), never a fresh pattern at another cell size, so the thumbnail shows the final. Level 0 is the ground: the base layer's pixel when there is one; the lit levels take `Depth` of the base's shading.

| Family | What it is | Knobs (all pinnable) |
| --- | --- | --- |
| Moiré (interference atlas) | A radial and a linear wave beat on the grid inside a crescent envelope around an anchor (`Atlas`), or two twisted lattices / two woven grids fading from the anchor (`Lattice`, `Weave`) | Field, Repeat X/Y (cycles per display height), Twist, Anchor X/Y, Reach, Offset (phase), Balance, Tone steps, Reflect, Cell size, Dither, Depth, OKLab |
| Relief (contour relief) | Warped noise height cut into shifted terraces (each level sampled a little further along the light), rims lit on one side and shaded on the other, like cut paper | Scale, Warp, Tone steps (levels), Offset, Angle (light), Rim, Relief, Anchor, Reach, Focus (bump) |
| Islands (pixel archipelago) | Domain-warped fbm above a sea level, 3–5 terrain bands, shores dithered within a few cells of the coast, crumbs (land under four cells) removed | Scale, Warp, Sea level, Tone steps, Roughness, Shore, Focus, Anchor |
| Plate (resonance plate) | A Chladni-inspired standing-wave pair `cos(mπu)cos(nπv) − β cos(nπu)cos(mπv)` in rotated plate coordinates; density `exp(−|f|/ε)` inside a circular aperture, grains gathering on the nodal lines | Mode M/N, Balance, Nodal width, Angle, Reach (aperture), Density, Tone steps, Anchor |
| Circuit (woven circuit) | Truchet quarter-circle ribbons, one of two pairings per tile from a low-frequency bias field and a hash, arcs joined across tiles into paths (union-find over edge midpoints), inks alternating per path, the smallest rings taking the accent | Scale (tile, in cells), Ribbon, Bias, Bias scale, Loops, Accent, Tone steps |
| Sky (memory sky) | A vertical sky field with a haze band at the horizon, a cropped sun disc and its glow, sparse clouds, two ridges from one-dimensional noise (the near one the darkest tone, the far one the next, both crisp), diffused into large cells by serpentine error diffusion | Horizon, Sun X, Sun, Haze, Ridges, Clouds, Diffusion, Tone steps |

The other generators stay, each with the same base and finish stack:

| Generator | Parameters | Rendering |
| --- | --- | --- |
| Dither | Bayer 2/4/8, Floyd–Steinberg (serpentine), blue noise (a 64×64 void-and-cluster tile), halftone (dot size by luminance on a rotated grid) or ASCII (a built-in 5×7 glyph ramp, no font); cell size; 2 colors (ink/paper) or a reduced palette of up to 16; framing. With no photo the **base layer** is what gets dithered, sampled once per cell | Software, from the source pixels; two-color diffusion carries the luma residual only, so an ink lighter than its paper still dithers |
| Pattern | Dots, lines or checks (noise stays as an option); foreground over the base or a flat paper; scale; angle | Software raster |
| Mesh | Columns × rows of control points (2–5 each), a palette of up to 6 colors, jitter and softness; the seed places the points and picks their colors | Inverse-distance blend, software; its bytes go through the ordered dither, so it never bands. Mostly a **base** now |
| Pixelize | An imported image, block size 4–64 px, optional palette reduction to 2–32 colors; framing; with no photo, the base in blocks | Averaged per block from the source pixels, optionally quantised (median cut) |
| Gradient (advanced) | Linear, radial or conic; 2–6 stops; interpolation in sRGB or OKLCH. Its bytes go through an 8×8 ordered dither, so a slow gradient never bands | Per pixel, software. **Never a result on its own**: not in the shuffle families, not in the taste set, last in the picker; its place is as a base under a texture |
| Solid | One color. Not in the picker any more: a flat color is a base. **True black** (`#000000` with nothing on top) still decodes and renders exact zeros | Flat fill |

**Base layer** (`BaseLayer`): none, a flat color, a gradient or a soft mesh from the palette's ground, under every texture — a pattern's paper, a moiré's ground, what a dither dithers without a photo, the backdrop of pixelize without one. The dark side folds the base's colors the way it folds the generator's.

**Finishes**, in this order after the generator and the composition: tint (one color, amount), duotone, gradient map (2–6 stops over luminance), **wash** (a two-color gradient mixed over the render in OKLCH, the paper-density drift that keeps a texture from looking flat), **vignette** (darkening toward the corners, off on the pixel families so their cells stay exact), **fringe** (a chromatic split of red and blue at luma edges only, 1–6 px at native size, scaled with previews), film grain (0–100 %, seeded, monochrome, weighted by luma the way film is: full in the midtones, a third near black and white), and **top shade**. Every curated recipe ships with a finish stack on: nothing is a flat two-color fill or a bare gradient.

The panel reads the menu-bar strip of every render against the text the side gets and says **"Menu bar: reads" / "Menu bar: low contrast"** (4.5:1 and an even strip); the low-contrast state offers "Shade the top" with one click. Renders are made at the display's pixel size; previews render at a fraction of it (`renderScale`) so a slider drag never waits on a 6-megapixel image. A render cache keyed by document and size keeps the last few full-size renders within a byte limit. Budget: one uncached 5K still of a curated recipe, finishes included, is about 0.2 s in a release build on an M-series Mac (the target was one second).

**Palettes** (`MacPaperCore/Palettes.swift`): 56 preset palettes of 2–5 tones in OKLCH, grouped (Circuit, Cyber, Blueprint, Vapor, VGA, Magma, Rust, Signal, Paper, Sea, Forest, Dusk), plus **Custom** for a document's own colors. Every preset passes the preset rule — the ground reads at 7:1 against white or black text (never the mid luminance where nothing reads), and so does its dark-side fold — and its tones are visibly distinct (ΔE ≥ 0.05 in OKLab). A recipe is named after the preset its colors are from. Every color row also offers **From photo…** (median cut) and **From accent color** (the Mac's accent expanded in OKLCH).

**Curated Shuffle** (`MacPaperCore/Curation.swift`). Shuffle only ever lands on a curated recipe: it draws a recipe *family* — an authored look with the parameter bands that are known to be good (the moiré atlas, relief, islands, plate, circuit and sky, plus a pixelized photo when the draft has one; the lattice moiré, pattern grids and dithered bases are manual picks, not shuffle families) — with a preset palette (never a random hue), applies the pins, and passes the candidate through the **quality gate** before it is shown. The gate refuses: a bare gradient or a flat fill as the generator; a palette whose endpoints sit closer than 0.25 L or whose adjacent tones are alike; near-zero texture energy in the structure before any finish (measured where the cells are still pixels, so grain cannot rescue a blank base); too little lightness range at 56 px (no silhouette); more than 60 % of pixels in the grey-brown mid-luminance band; a share of quiet ground outside the family's band; the family's own topology rule (the atlas needs one to six masses at 56 px, islands 20–65 % land in one to five islands with the largest at least 45 % and no crumbs, the plate nodal coverage between 3 and 45 % and no bright central cross, the circuit at least 60 % of its ribbon in paths of three tiles or more and under 40 % in rings, the sky no diffusion bias over 0.025 L, the relief at least three terraces and under 30 crumbs); a menu-bar strip that does not read under the text macOS would draw — every one of sixteen patches along it at 3:1 or better, the strip at 4.5:1 (one repair is tried: the top shade); and a candidate visibly the same as the previous document. Refused candidates are redrawn, up to twelve times, deterministically from the seed — a share code still reproduces. **A refused candidate is never shown or applied**: when every attempt fails (the pins leave no room), the desktop keeps its current wallpaper and the panel says "Nothing better found — try another palette or unpin something." **macPaper never ships a bare gradient.**

**Recipes and pins.** A recipe is a named document: the wallpaper, a name and the palette's name. The library (`favorites.json`, version 2; version-1 favorites migrate, each named "<palette> · <generator>") starts on a fresh install with the **taste set**: 34 recipes chosen by eye across every family, the seeds the shuffle families are calibrated on. A `.macpaper` file is the recipe document (`{"macpaper":1,"kind":"recipe","name":…,"palette":…,"wallpaper":{…}}`, pretty-printed), exported and imported through save/open panels, opened by double-click from the Finder, dropped onto the panel, or dragged out of the library; a `macpaper://s/<code>` link is the same document deflated and base64url-encoded (a link made of a bare document still opens, named by default). Decoding is bounded like a share code (64 KB, names one line of at most 80 characters). Every parameter row has a **pin**: a pinned parameter — a knob, the palette, the generator, the base, the seed, a finish — is kept by Shuffle; the rest is drawn fresh.

## Pairs

| Pair | What it is | How it is applied |
| --- | --- | --- |
| Light / dark | Every document has a light and a dark side. The dark side is derived (**Make dark from light**: every color's OKLCH lightness folded down, hue and chroma kept) or edited on its own; a segmented control above the preview switches which side is edited, and the preview shows the side matching the Mac's appearance | Applied as one HEIC with the two images and the `apple_desktop:apr` appearance record (the format macOS's own dynamic desktops use, written with ImageIO), so macOS switches by itself after macPaper quits. Where a display refuses the HEIC (an old macOS, a screen that only takes stills), the two PNGs are kept and swapped on the theme-change notification while macPaper runs |
| Time of day | The same seed at 4, 8 or 16 moments of the day: the document's colors follow a day curve (lightness and warmth up toward noon, down toward midnight), the seed unchanged | One HEIC with the frames and the `apple_desktop:h24` time record (fractions of the day, plus which frame is light and dark), so macOS keeps cycling after quit. No Location: the curve is by clock time, not the sun; a sun-position (`solar`) variant is listed under "Not built" |
| Phone | The desktop still and a 1290×2796 portrait of the same document | **Export → Phone pair** writes both PNGs; the phone one is AirDropped by the user |

A favorite is a document, so it keeps its pair and its frames.

## Seeds and sharing

**Share** puts `macpaper://s/<code>` on the pasteboard, where the code is the whole document (deflated JSON, base64url): every knob, the seed, the finishes, the pair and the composition, never an image (a pixelize or dither document shares without its photo and says so). Opening such a link in macPaper loads it as the draft. **Remix** is a new seed on the loaded document. **Never show this** puts a document on a blocklist shuffle never picks from (and removes it from favorites); the list is cleared in Settings.

## Notch panel

The panel is anchored to the notch of the display that hosts it and opens downwards from it, centered on the notch, its top squared against the menu bar and its bottom corners rounded. Without a notch the panel opens from the top center of the host display (the hover zone is then a 2-point strip at the top edge, so no menu-bar item is covered) and the menu-bar popover stays the primary surface.

| Setting | Values | Default |
| --- | --- | --- |
| Notch panel | on / off (off: the menu-bar popover only) | on |
| Host display | the notch display / the main display / every notched display | the notch display |
| Open on | hover / click / both | both |
| Direction | down (v1 renders down only; left, right are stored for a later release) | down |
| Width | compact / regular / wide (360 / 440 / 560 pt) | regular |
| Hide in fullscreen | on / off | on |
| Hotkey | any key with at least one modifier, or none | ⌃⌥⌘ W |

Behavior:

- Hover opens after 180 ms over the notch and closes 400 ms after the pointer leaves the panel and the notch; a click opens at once and then only a click outside, Escape, the hotkey or Hide in fullscreen closes it. Opening by click while a hover-open is pending cancels the pending open. A hover-opened panel that the pointer enters stays as long as the pointer is inside.
- The hotkey toggles the panel on the host display. With the panel off it opens the menu-bar popover instead.
- In fullscreen (Hide in fullscreen on) the panel closes and hover does nothing until the space leaves fullscreen; the hotkey still opens the popover.
- Reduce Motion: no drop animation, the panel appears in place; the standard drop takes 180 ms otherwise.
- The panel never takes key focus from the app in front unless the user types in it (the seed field, a color field); Escape then returns focus.
- The panel's content, top to bottom: the current wallpaper's preview in the display's aspect ratio (with the display's name when there is more than one, "on the desktop" while the draft is what the display shows, the menu-bar readability verdict, and the focal point for a framed image); the Light / Dark / Time-of-day control; the generator segmented control; the generator's parameters (sliders, brand segmented controls, color swatches that open the system color panel, minus/plus counters, From photo… / From accent color on color rows); a **Finishes** disclosure (tint, duotone, gradient map, grain, top shade) and a **Composition** row (none / emerge / contours / painted pill); a row of actions: **Shuffle** (a random document, applied at once), **Apply** (this display · all displays · this Space only in a split button, or one button while "same on all displays" is on), Favorite (a star, filled while the document is a favorite), a **more** menu (Export as PNG / SVG / HEIC pair / Phone pair, Share link, Remix, Never show this); a status line after an action; a footer with the seed (click to type one, a die for a new one), Settings… and Quit.

### Notch-aware composition

A document may compose around the notch of the display it is applied to: **Emerge** (the mesh's brightest control point sits at the cutout's bottom center and the field grows out of it), **Contours** (the pattern's lines part around the notch pill, as a distance field from it), or **Painted pill** (a black pill of the notch's proportion painted at the top center of a display without one, for symmetry with the notched one). The composition is part of the document and renders per display: the notch's position and size come from the display, so the same favorite composes correctly on a 14" and a 16". A display without a notch renders Emerge and Contours from the top center.

## Menu bar

A template symbol (the mark) with no readout. Clicking opens the popover with the same content as the notch panel, 420 pt wide. The popover is the only surface when the notch panel is off, when no display has a notch and the host display setting is "the notch display", and in fullscreen while the panel is hidden.

## Apply, finished

| Rule | Behavior |
| --- | --- |
| Native pixels | Every apply renders at the display's pixel size and hands macOS a file of exactly that size; nothing is scaled by the system |
| The file | PNG for a plain still, HEIC for a light/dark or time-of-day pair, into `~/Library/Application Support/OpenApps/macpaper/applied/`, one file per display and per apply (macOS ignores a new image at the URL it already shows); the last three per display are kept. macPaper never writes into `com.apple.wallpaper` or any other Apple cache |
| **Pin so it stays** (on by default) | The applied file is macPaper's own copy, so it survives an OS update that clears caches. While macPaper runs it re-applies the recorded file for a display whenever macOS shows something else: at launch, on wake, on unlock, when the active Space changes, when displays change — only files it wrote itself and still lists for that display, never while an apply is landing (the check waits for it), and never once the pin is off. Off: apply once and leave the desktop to macOS |
| Spaces | `setDesktopImageURL` sets the current Space of a display. **Apply → Every Space** (default) applies now and lets the pin re-apply as each Space becomes active, so every Space ends up the same; **This Space only** applies once and takes that display off the pin until the next Every-Space apply. macOS gives no public Space identity, so "this Space" cannot be followed if macOS rearranges Spaces automatically; Settings says so and offers the "Automatically rearrange Spaces" toggle's location |
| Lock screen | Since macOS Sonoma the lock screen shows the current desktop wallpaper; there is no public way to set a separate lock-screen still, and the wallpaper store is private. macPaper therefore states it plainly under Settings → About: **the lock screen follows the desktop**; a light/dark pair follows too |
| Theme change | A HEIC pair switches by itself. For a display where the HEIC was refused, macPaper swaps the light and dark PNGs on `AppleInterfaceThemeChangedNotification` while it runs |
| Failure | A display that refuses the file is reported beside Apply with the reason; the others are applied; nothing is retried on its own except by the pin, which retries once per event |

## Wallpapers settings

| Setting | Behavior | Default |
| --- | --- | --- |
| Shuffle | Off, or every 15 min / 30 min / hour / 3 hours / 6 hours / day; a shuffle renders a new document (a curated recipe through the quality gate, keeping the draft's pins, or one of the favorites) and applies it | off |
| Favorites only | Shuffle picks from the favorites; with none saved it falls back to random and the settings row says so | off |
| Same on all displays | Apply and Shuffle set one document on every display; off: each display keeps its own, Apply offers "this display" and "all displays", Shuffle changes every display to a different document | on |
| Keep it applied | The pin above | on |
| Export folder | Where PNG, SVG, HEIC and phone exports land; Choose… opens an open panel | ~/Pictures/macPaper |
| Never show | The blocklist's count and Clear | — |
| Clock | Off, or a clock face on the wallpaper layer (below the icons): analog or digital, palette-matched to the applied document, updated once a second, hidden in fullscreen and under Reduce Motion drawn without a sweeping hand; position: a corner or the center; size | off |
| Screen saver | **Install screen saver** (Settings → Desktop) copies `macPaper.saver` from the app into `~/Library/Screen Savers/` — staged beside the destination and verified first, and never over a symbolic link or a bundle that is not macPaper's own (those are reported and left alone); the saver shows the applied stills (and, with favorites, crossfades through up to four of them every minute) and needs nothing from the app while it runs. macOS's screen-saver picker is where it is chosen; macPaper cannot select it | not installed |

Favorites are documents (JSON), not images, kept in `~/Library/Application Support/OpenApps/macpaper/favorites.json`; a favorite renders again for any display size. Imported images for Pixelize and Dither are copied into `imports/` under the same folder so a favorite keeps working after the original moves; a favorite whose import is gone says so in the panel and renders its background.

## Not built (spiked 2026-09-16)

| Item | Why not |
| --- | --- |
| Now Playing art as wallpaper, notch transport | Reading what is playing needs the private MediaRemote framework (blocked for unentitled apps since macOS 15.4) or a MusicKit entitlement; either breaks zero-permissions/no-entitlements. Out until Apple offers a public API |
| Subtle motion (Metal) and an own-MP4 loop | A moving wallpaper is a window kept alive by a running app, the opposite of a still macOS keeps after quit; the battery/fullscreen pause and the <2 % CPU bound could not be measured on the build machine (display asleep), so the promise cannot be made honestly. Out |
| Sun-position (`solar`) HEIC | Needs the Mac's location for the sun's altitude and azimuth; the time-of-day (`h24`) pair covers the use without a permission. Location stays optional and unused |
| Daily licensed still to remix | Network; out of a zero-network app |

## General settings

Open at login (on once on a fresh install, `SMAppService`, approval state shown; the user can turn it off), the notch settings above, Show setup guide, and About: what macPaper does and where it writes (this Mac only; the only network calls of an official build are the license check, the trial registry and the update check, none in a source build), the lock-screen note, MIT, Copy Diagnostics (version, login state, licensing flavour, displays and their notches, the panel settings, the pin and clock state, the shuffle state, the applied documents).

## Licensing

Official builds follow [LICENSING.md](../../LICENSING.md) through the shared `packages/openapps-licensing`, like Hertz. **The core feature is generating and applying wallpapers.** When restricted (TrialEnded, TrialNeedsConnection, TrialClockBehind, CheckRequired, Revoked, the storage-error forms of TrialUnavailable): generating (a new or typed seed, an import), Shuffle (manual and scheduled), Apply and Export are off, and the panel and the popover show the license card in place of the generator, in LICENSING.md's words with the same actions as Hertz's card (Buy a license, Enter a key, Try again); Settings, favorites browsing and Quit keep working. Every action asks the projected entitlement at the click, never a value a view captured earlier, and again at every resumption after a wait — the image picker, a render, a save panel, each display's desktop call — so work started under the trial and finished after it commits nothing; a refused click says so in the status line. The star (favorites) stays under the card. A trial pill in the panel's header and the Settings title bar shows where the trial stands and opens Settings → License. The already applied wallpaper stays: macPaper never removes what it set, and keeping an already committed wallpaper is allowed while restricted — the pin hands the recorded, committed, owned file over again when macOS replaces it (a Space change, wake, unlock, a display change), and the fallback display keeps the side it has; nothing is rendered or newly applied, and a file the pin's manifest never listed as committed, one listed for another display, or one that is no longer macPaper's own regular file is refused. Builds from source have no licensing and everything on.

## Defaults and recovery

| Situation | Behavior |
| --- | --- |
| Fresh install (no earlier preferences; in official builds both records positively absent) | Open at login on once (and, with the updater, automatic update checks), under its own flag; an upgrade or a setting the user turned off is left alone |
| First launch | Nothing is applied on its own: the panel shows a seeded gradient as its starting document; the desktop changes only on Apply or when shuffle is turned on. The pin has nothing recorded, so it does nothing |
| No display has a notch | Host "the notch display" leaves the panel closed; the popover carries everything; Settings says so under Host display |
| The notch display is unplugged | The panel closes and comes back on the next notched display that appears; "every notched display" keeps one panel per notched display |
| Fullscreen on the host display | See Hide in fullscreen; detection is from the window list (the front app owns a window covering the screen) on Space and app changes, without Screen Recording or Accessibility |
| `setDesktopImageURL` fails (a screen went away, the file could not be written) | The action reports the error in the panel beside the Apply button and keeps the previous document; nothing is retried on its own |
| An imported image cannot be decoded | Pixelize and Dither keep their previous source and say why beside Import |
| A favorite's imported image is gone from `imports/` | The panel says "Image missing — import it again" beside Import and renders the background color; the favorite is kept |
| A display refuses the HEIC pair | The light PNG is applied instead and the theme-change swap takes over for that display while macPaper runs; the panel says which |
| Export folder missing or unwritable | Export asks for a folder with a save panel instead |
| Shuffle due while the Mac sleeps, or overdue at launch | Nothing fires at launch or on wake; the next shuffle is one interval after that moment. Missed shuffles are not caught up |
| Login item registration fails | The toggle reverts and shows the error; Login Items can be opened directly |
| Hotkey cannot be registered (taken by another app) | Settings says so beside the recorder; the panel still opens by hover, click or the menu bar |

No permissions: no Accessibility, no Input Monitoring, no Screen Recording, no Location. Hover uses a tracking area on macPaper's own transparent window over the notch; the hotkey uses Carbon's `RegisterEventHotKey`; clicks outside use a global mouse-down monitor, which needs nothing; the pin reads `NSWorkspace.desktopImageURL(for:)`; the clock is a window on the desktop level that ignores the mouse; the theme is `AppleInterfaceThemeChangedNotification`. No telemetry; diagnostics are copied only on request and only to the pasteboard.

## Marketing only

At `/macpaper/`: the tangerine key in the headline, a drawn notch panel over a mesh gradient, feature articles (generators and the dither lab, pairs that macOS keeps switching, the notch, apply-finished: pin, native pixels, true black; seeds and sharing; the clock and the screen saver), the install block, Buy, questions, the closing field. Never claim motion, Now Playing or a separate lock screen. The catalog entry, Buy and the thanks page ship with the first licensed release.

## References

[App README](../../apps/macpaper/README.md) · [Releasing](../../apps/macpaper/RELEASING.md) · [Tokens](../../apps/macpaper/design/tokens.json) · [Licensing](../../LICENSING.md).
