# macPaper

A wallpaper maker that lives in the notch: click or hover the notch and a column drops down with the current wallpaper, the library of looks, a generator to change it, its parameters and effects, Shuffle and Export. Every change lands on the desktop as it is made. Every wallpaper is made on the Mac from a few parameters and a seed; nothing is downloaded and nothing is uploaded. macPaper makes **stills** that macOS keeps showing after the app quits — light/dark and time-of-day pairs included — and keeps them applied.
Open source under MIT; the official build is paid on the same terms as every OpenApps HQ app ([LICENSING.md](../../LICENSING.md): 3-day in-app trial, no signup, one license for 3 Macs). Installed with Homebrew; the official build checks a signed feed for updates once a day and installs one only when the user says so ([RELEASES.md](../../RELEASES.md)).

Inspired by the idea of a notch-based wallpaper maker; written from scratch, with no code, copy, name or asset from any other product. Scope decided 2026-09-16 by the user from the macPaper roadmap (three scouts of what wallpaper apps ship and users ask for): the whole roadmap is v1, except what a spike ruled out ("Not built" below).

## Identity

Signature color: tangerine (`tangerine/300` tile face, `tangerine/500` shade, `tangerine/700` / `tangerine/300` accent in light / dark); the mark is a display outline with the notch as a filled tab and one horizon line inside.
The color is the app's, not a state: success stays green, danger red, warning HQ yellow, so a tangerine control is always an action or the brand.
Type follows the shared system: Bricolage Grotesque for the panel's heading and the settings window's headings, Instrument Sans for interface text, IBM Plex Mono with tabular digits for seeds, sizes and labels.
Surfaces are glass cards (Liquid Glass on macOS 26, the system material before, opaque under Reduce Transparency, a visible rim under Increase Contrast), as in Hertz and OpenReaction — the settings window and the setup guide. The notch panel is the exception: a column that hangs from the notch, a piece of the same black in both appearances and opaque (`PanelTheme` in the core: neutral/950 ground, neutral/850 rows, neutral/0 and neutral/400 text, the tangerine/300 accent), with the neutral/700 rim, squared off at the top where it meets the notch. Nothing of the wallpaper reaches a label, so every text pair reads at AA over any desktop; a test asserts the pairs and the preview harness proves it over a saturated mesh, grey, near-black and near-white.

## Primary task

Make the desktop look the way you want as you go: open the column, pick a look or shuffle, move a slider — every change lands on the desktop by itself (live apply). Everything else (the library, scheduled shuffle, export, per-display choices) supports that.

## Generators

Every wallpaper is a document: a generator, its parameters, a seed, a base layer, the finishes and the composition, serialisable as JSON (version 3). The panel's Generators section lists Moiré, Relief, Islands, Plate, Circuit, Sky, Dither, Mesh, Pixelize and Pattern, in that order; a gradient or a flat color on its own is the **base layer** (Effects → Base layer: none · Flat · Gradient · Mesh · True black), never a shuffle's result and never a starter. The same document renders the same pixels at the same size on every Mac; the seed is shown in the panel so a look can be reproduced or shared.

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

**Palettes** (`MacPaperCore/Palettes.swift`): 56 preset palettes of 2–5 tones in OKLCH, grouped (Circuit, Cyber, Blueprint, Vapor, VGA, Magma, Rust, Signal, Paper, Sea, Forest, Dusk), plus **Custom** for a document's own colors. Every preset passes the preset rule — the ground reads at 7:1 against white or black text (never the mid luminance where nothing reads), and so does its dark-side fold — and its tones are visibly distinct (ΔE ≥ 0.05 in OKLab). A recipe is named after the preset its colors are from. Every color row also offers **From photo…** (the dominant colors of an image, median cut) and **From accent color** (the Mac's accent color expanded into a palette in OKLCH: the accent, a lighter and a darker step, its complement, a near-black and a near-white). Applying a preset from the Palette section's grid lifts the menu bar by itself (the top shade) when the strip would not read.

**Curated Shuffle** (`MacPaperCore/Curation.swift`). Shuffle only ever lands on a curated recipe: it draws a recipe *family* — an authored look with the parameter bands that are known to be good (the moiré atlas, relief, islands, plate, circuit and sky, plus a pixelized photo when the draft has one; the lattice moiré, pattern grids and dithered bases are manual picks, not shuffle families) — with a preset palette (never a random hue), applies the pins, and passes the candidate through the **quality gate** before it is shown. The gate refuses: a bare gradient or a flat fill as the generator; a palette whose endpoints sit closer than 0.25 L or whose adjacent tones are alike; near-zero texture energy in the structure before any finish (measured where the cells are still pixels, so grain cannot rescue a blank base); too little lightness range at 56 px (no silhouette); more than 60 % of pixels in the grey-brown mid-luminance band; a share of quiet ground outside the family's band; the family's own topology rule (the atlas needs one to six masses at 56 px, islands 20–65 % land in one to five islands with the largest at least 45 % and no crumbs, the plate nodal coverage between 3 and 45 % and no bright central cross, the circuit at least 60 % of its ribbon in paths of three tiles or more and under 40 % in rings, the sky no diffusion bias over 0.025 L, the relief at least three terraces and under 30 crumbs); a menu-bar strip that does not read under the text macOS would draw — every one of sixteen patches along it at 3:1 or better, the strip at 4.5:1 (one repair is tried: the top shade); and a candidate visibly the same as the previous document. Refused candidates are redrawn, up to twelve times, deterministically from the seed — a share code still reproduces. Shuffle never draws a Bayer-screened atlas or circuit (the tone dither stays a knob); the Charcoal preset spans 0.16–0.72 L so its draws read. **A refused candidate is never shown or applied**: when every attempt fails (the pins leave no room), the desktop keeps its current wallpaper and the panel says "Nothing better found — try another palette or unpin something." **macPaper never ships a bare gradient.**

**Recipes and pins.** A recipe is a named document: the wallpaper, a name and the palette's name. The library (`favorites.json`, version 2; version-1 favorites migrate, each named "<palette> · <generator>") starts on a fresh install with the **taste set**: 34 recipes chosen by eye across every family, the seeds the shuffle families are calibrated on. A `.macpaper` file is the recipe document (`{"macpaper":1,"kind":"recipe","name":…,"palette":…,"wallpaper":{…}}`, pretty-printed), exported and imported through save/open panels, opened by double-click from the Finder, dropped onto the panel, or dragged out of the library; a `macpaper://s/<code>` link is the same document deflated and base64url-encoded (a link made of a bare document still opens, named by default). Decoding is bounded like a share code (64 KB, names one line of at most 80 characters). Every parameter row has a **pin**: a pinned parameter — a knob, the palette, the generator, the base, the seed, a finish — is kept by Shuffle; the rest is drawn fresh. Pins are the user's, kept across recipes and launches (`shuffle.pins`), and mirrored into the draft so a share or a recipe file carries them; a pinned palette or photo is carried to the dark side too when the pair has its own.

## Pairs

| Pair | What it is | How it is applied |
| --- | --- | --- |
| Light / dark | Every document has a light and a dark side. The dark side is derived (**Make dark from light**: every color's OKLCH lightness folded down, hue and chroma kept) or edited on its own; a segmented control under Effects switches which side is edited, and the preview shows the side matching the Mac's appearance | Applied as one HEIC with the two images and the `apple_desktop:apr` appearance record (the format macOS's own dynamic desktops use, written with ImageIO), so macOS switches by itself after macPaper quits. Where a display refuses the HEIC (an old macOS, a screen that only takes stills), the two PNGs are kept and swapped on the theme-change notification while macPaper runs |
| Time of day | The same seed at 4, 8 or 16 moments of the day: the document's colors follow a day curve (lightness and warmth up toward noon, down toward midnight), the seed unchanged | One HEIC with the frames and the `apple_desktop:h24` time record (fractions of the day, plus which frame is light and dark), so macOS keeps cycling after quit. No Location: the curve is by clock time, not the sun; a sun-position (`solar`) variant is listed under "Not built" |
| Phone | The desktop still and a 1290×2796 portrait of the same document | **Export → Phone pair** writes both PNGs; the phone one is AirDropped by the user |

A favorite is a document, so it keeps its pair and its frames.

## Seeds and sharing

**Share** puts `macpaper://s/<code>` on the pasteboard, where the code is the whole document (deflated JSON, base64url): every knob, the seed, the finishes, the pair and the composition, never an image (a pixelize or dither document shares without its photo and says so). Opening such a link in macPaper loads it as the draft. **Remix** is a new seed on the loaded document. **Never show this** puts a document on a blocklist shuffle never picks from (and removes it from favorites); the list is cleared in Settings.

## The panel

One column, wherever it opens from. Where it opens decides where it hangs (`PanelAnchor.resolve`, `NotchGeometry.panelFrame`; every rule below is pure geometry over the display's `frame` and `visibleFrame`, and the tests run it on a 1512×982 notched display, a 1440×900 and a 1280×800 display without one, a secondary display with its own menu bar, and the left and right edges):

| Opened by | Placement |
| --- | --- |
| The notch (hover or click), on the display that hosts the notch panel | Centered on the notch, its top squared against it, its bottom corners rounded; the menu-bar row beside the notch is shaded in the column's width by a click-through strip under the menu bar's own window, so the row reads as part of the column through the bar's translucency while its items are never tinted and keep every click |
| The menu-bar item, on any display, notch or not | Under the item like every menu-bar app's window: centered on the item, an 8-point margin under the menu bar (the visible frame's top), rounded all round. Never above the menu bar, never off an edge: the column stays inside the display's visible frame with an 8-point margin on every side, so an item near the right edge gets the column slid left to fit |
| The shortcut | From the notch where the notch panel may show (on, the pointer's display hosts it or the first host does, not hidden by fullscreen); otherwise under the menu-bar item on its display |
| The hot edge of a display without a notch (hover or click at the top center, a 2-point strip 200 points wide so no menu-bar item is covered) | From the top center, a margin under the menu bar |

Height: **`min(content, visibleFrame.height − 16)`, at most 920 points** — as tall as its content when the content is short (Export, Parameters), capped by the display when it is not (Library, Palette). In a capped column the sections column scrolls; the header, the preview, the rail and the footer stay put. The Library and History lists are lazy, so a library of many recipes builds only the rows in view. The content's height is measured before the window shows, so the column opens at its final size, and it follows the content while open (a section switched, a status line shown) with its top edge fixed, animated over the standard duration.

Its width is the setting below, unless a segmented control needs more: every segment is as wide as the control's widest label measured in the segment font, and the column grows to fit the widest control, so no label ever wraps (`PanelLayout`; the tests measure the real labels). The column has an icon rail on its left (the mark; Library, Generators, Palette, Parameters, Effects, Export, History; at the bottom Shuffle and Collapse) and, beside it, the section the rail points at. The pane: a header with the section's title and the **reach** control (where every change lands: every display · this display · this Space only; the display choice is left out while "same on all displays" is on); the preview in the display's aspect, at most 200 points tall (the display's name when there is more than one, "on the desktop" while the draft is what the display shows, the menu-bar readability verdict, the focal point of a framed image); the section; a status line after an action; the update row; and a quiet footer with the seed (click to type one, a die for a new one, a pin), Settings… and Quit. Rows keep one rhythm (72 points: a 13-point semibold label with its pin and a mono readout, the control under them; thin sliders with a round knob, focusable and keyboard-operable), section labels are the mono label, lists are 72-point rows with 56-point thumbnails.

| Section | What it holds |
| --- | --- |
| Library | A name field and **Save** (the draft as a recipe; a blank name takes the derived "Palette · Generator" title, a saved document is renamed); the saved recipes (thumbnail, title, generator · seed · pair, the star to remove, a ⋯ menu: apply, copy link, export, never show, remove); then the built-in starters. Clicking a row loads it; live apply takes it to the desktop |
| Generators | Dither, Mesh, Pattern, Pixelize, one row each with a line of what it does; the current one marked. A flat color or a gradient is the base layer (under Effects), not a generator |
| Palette | The current colors as swatches (add and remove where the generator takes a variable count), From photo… and From accent color, then the grid of preset palettes (`PresetPalettes`, about fifty on the OKLCH ramps, seven per row), the one in use ringed; the row's title is the preset's name or "Custom" |
| Parameters | The edited generator's parameters as rows with pins (gradient: shape, angle, center, blend; mesh: grid, jitter, softness; pattern: kind, scale, angle, ink and paper; pixelize: image, block, colors, framing; dither: image, mode, cell, colors, framing) |
| Effects | Editing (Light / Dark) and the pair (Still · Light / Dark · Time of day with its frame count); the finish stack — grain, top shade (with "Shade the top" while the menu bar reads badly), tint, duotone, gradient map — each pinnable; the notch composition; the base layer (Generator · Flat · Gradient · True black) |
| Export | PNG, SVG, HEIC pair, Phone pair, each with what it makes; Copy link, Remix, Never show this |
| History | What reached a desktop, newest first, one entry per look (a slider moved replaces the entry; a shuffle, a favorite, a new seed adds one; 40 kept): click loads it, the star saves it, the x forgets it, Clear forgets all |

**Live apply.** There is no Apply button: every change to the draft — a slider, a palette, a generator, a loaded recipe — renders and reaches the desktop on its own, 150 ms after the last change, off the main actor, through the same prepare/commit gate as before (the license asked before every desktop call). The last state wins: a change during the wait restarts it; a change while a render is in flight leaves that render's files discarded before any desktop call; applies queue one behind another, so nothing lands out of order. A successful live apply says nothing (the preview's tag reads "on the desktop"); a failure says so in the status line. Restricted, an edit is refused as before and a loaded recipe stays a preview; the license card says why.

**Pins.** A pin beside a parameter locks it against Shuffle: a shuffle keeps every pinned value from the draft (the palette, the seed, a finish, the composition, the pair, or a generator's own parameter, which keeps that generator as well), side by side — a value pinned while editing the dark side survives as the dark side's, the light side keeps its own. Pins are kept in the preferences.

**The menu bar reads.** A preset from the grid, a starter and every shuffle pick go through `Wallpaper.liftingMenuBar`: the smallest top shade, in tenths, at which the menu-bar strip reads on both sides (4.5:1 against the side's text and an even strip, judged on a small render); a full shade always reads, so no look lands with an unreadable menu bar. Every preset in every representative look, and every starter as shipped, is asserted to read on both sides.

| Setting (Settings → General) | Values | Default |
| --- | --- | --- |
| Open from the notch | on / off, with a line saying where the zone is ("Rest the pointer on the notch — the cutout at the top of the display — or click it. The menu bar icon opens the same panel."), or that no display has a notch right now. Off: the menu-bar item and the shortcut open the panel | on |
| Host display | the notch display / the main display / every notched display | the notch display |
| Open on | hover / click / both | both |
| Hover delay | 0.05–1 s in steps of 0.05, a slider with its readout; off while Open on is click | 0.18 s |
| Direction | down (v1 renders down only; left, right are stored for a later release) | down |
| Width | compact / regular / wide (360 / 440 / 560 pt, each grown to fit the widest control's labels) | regular |
| Hide in fullscreen | on / off | on |
| Show panel (the shortcut) | any key with at least one modifier, or none; shown in the menu-bar item's menu | ⌥⌘P on a fresh install; an install upgraded from 0.2 keeps ⌃⌥⌘W (its default then), written once at the first launch that finds no stored shortcut, after the fresh-install evidence has been read |

Behavior:

- Hover opens after the hover delay over the notch and closes 400 ms after the pointer leaves the panel and the notch; a click opens at once and then only a click outside, Escape, the shortcut, the item, Collapse or Hide in fullscreen closes it. A click on the menu-bar item is never a click outside: its mouse-up toggles, so a second click on the item closes and does not reopen. Opening by click while a hover-open is pending cancels the pending open. A hover-opened panel that the pointer enters stays as long as the pointer is inside.
- The menu-bar item toggles the panel under itself whatever the notch settings say; a click while a panel is open on another display closes that one first.
- The shortcut toggles: closes an open panel, else opens one from the notch where the notch panel may show, else under the menu-bar item.
- In fullscreen (Hide in fullscreen on) the panel closes and the notch does nothing until the space leaves fullscreen; the item and the shortcut still open the panel, under the item.
- Reduce Motion: no drop animation, the panel appears in place, and its height changes without animating; the standard drop takes 180 ms otherwise.
- The panel never takes key focus from the app in front unless the user types in it (the seed field, a color field); Escape then returns focus.
- The column's content is the section the rail points at (above); the section is kept across opens, however the column is opened. Collapse on the rail closes the column the way Escape does.

### Finding the notch (first run)

- The setup guide's second step, **"Where the panel lives"**, right after the welcome: a drawn display with a looping animation of the pointer reaching the notch, the glow lighting under it and the column dropping, and the words that the menu-bar icon opens the same panel, and so does the shortcut. On a Mac without a notch (no connected display has one) the step says the panel lives in the menu bar — the icon and the shortcut are the triggers — and the animation reaches the icon instead. Reduce Motion holds the last frame.
- **The glow.** For the first five launches, or until the notch has opened the panel once (by hover or click), a soft tangerine glow — a bright seam under the notch's edge and a fall-off over 40 points — fades in and pulses whenever the pointer comes within 80 points of the notch, and fades out when it leaves, the panel opens, or the notch panel is off. A click-through window at the menu bar's level; the pointer is read by a global mouse-moved monitor (no permission: only keyboard monitors need one) that exists only while the glow is armed and is removed the moment the notch opens the panel. Reduce Motion: the glow shows without pulsing. Two flags beside the first-run flags (`notchHint.launches`, counted after the fresh-install evidence has been read; `notchHint.used`), both earlier-launch evidence.
- The menu-bar item's tooltip says "click for the panel, right-click for the menu".

### Notch-aware composition

A document may compose around the notch of the display it is applied to: **Emerge** (the mesh's brightest control point sits at the cutout's bottom center and the field grows out of it), **Contours** (the pattern's lines part around the notch pill, as a distance field from it), or **Painted pill** (a black pill of the notch's proportion painted at the top center of a display without one, for symmetry with the notched one). The composition is part of the document and renders per display: the notch's position and size come from the display, so the same favorite composes correctly on a 14" and a 16". A display without a notch renders Emerge and Contours from the top center.

## Menu bar

A template symbol (the mark) with no readout. A click opens the panel under the item (above), on whatever display the item is on; a right click or Control-click opens a plain menu: **Show panel** / **Hide panel** with the shortcut as set (first), **Settings…** ⌘, then, in official builds, the update line while an update asks for something (RELEASES.md, "In-app updater"), and **Quit macPaper** ⌘Q. There is no popover: the item and the shortcut are the triggers on a Mac without a notch, when the notch panel is off, and in fullscreen while the notch panel is hidden. A `.macpaper` file opened from the Finder shows the panel under the item.

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
| Same on all displays | Live apply and Shuffle set one document on every display; a shuffled document must pass the quality gate on every display's own context (its pixel size, menu-bar strip and notch), else nothing is applied; off: each display keeps its own, the header offers "this display" and "all displays", Shuffle changes every display to a different document, each gated on its own display | on |
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

Open at login (on once on a fresh install, `SMAppService`, approval state shown; the user can turn it off), the panel settings above, Show setup guide, and About: what macPaper does and where it writes (this Mac only; the only network calls of an official build are the license check, the trial registry and the update check, none in a source build), the lock-screen note, MIT, Copy Diagnostics (version, login state, licensing flavour, displays and their notches, the panel settings, the pin and clock state, the shuffle state, the applied documents).

## Licensing

Official builds follow [LICENSING.md](../../LICENSING.md) through the shared `packages/openapps-licensing`, like Hertz. **The core feature is generating and applying wallpapers.** When restricted (TrialEnded, TrialNeedsConnection, TrialClockBehind, CheckRequired, Revoked, the storage-error forms of TrialUnavailable): generating (a new or typed seed, an import), Shuffle (manual and scheduled), Apply and Export are off, and the panel shows the license card in place of the generator, in LICENSING.md's words with the same actions as Hertz's card (Buy a license, Enter a key, Try again); Settings, favorites browsing and Quit keep working. Every action asks the projected entitlement at the click, never a value a view captured earlier, and again at every resumption after a wait — the image picker, a render, a save panel, each display's desktop call — so work started under the trial and finished after it commits nothing; a refused click says so in the status line. The star (favorites) stays under the card. A trial pill in the panel's header and the Settings title bar shows where the trial stands and opens Settings → License. The already applied wallpaper stays: macPaper never removes what it set, and keeping an already committed wallpaper is allowed while restricted — the pin hands the recorded, committed, owned file over again when macOS replaces it (a Space change, wake, unlock, a display change), and the fallback display keeps the side it has; nothing is rendered or newly applied, and a file the pin's manifest never listed as committed, one listed for another display, or one that is no longer macPaper's own regular file is refused. Builds from source have no licensing and everything on.

## Defaults and recovery

| Situation | Behavior |
| --- | --- |
| Fresh install (no earlier preferences; in official builds both records positively absent) | Open at login on once (and, with the updater, automatic update checks), under its own flag; an upgrade or a setting the user turned off is left alone |
| First launch | Nothing is applied on its own: the panel shows the first taste-set recipe (Mint Circuit · Moiré) as its starting document and the library holds the taste set; the desktop changes on the first edit (live apply), on a loaded recipe, or when shuffle is turned on. The pin has nothing recorded, so it does nothing |
| No display has a notch | Nothing hangs from a notch; the menu-bar item and the shortcut open the panel under the item; Settings says so under Open from the notch, and the setup guide's panel step says the panel lives in the menu bar |
| The notch display is unplugged | The panel closes and comes back on the next notched display that appears; "every notched display" keeps one panel per notched display |
| Fullscreen on the host display | See Hide in fullscreen; detection is from the window list (the front app owns a window covering the screen) on Space and app changes, without Screen Recording or Accessibility |
| `setDesktopImageURL` fails (a screen went away, the file could not be written) | The action reports the error in the panel's status line and keeps the previous document; nothing is retried on its own |
| An imported image cannot be decoded | Pixelize and Dither keep their previous source and say why beside Import |
| A favorite's imported image is gone from `imports/` | The panel says "Image missing — import it again" beside Import and renders the background color; the favorite is kept |
| A display refuses the HEIC pair | The light PNG is applied instead and the theme-change swap takes over for that display while macPaper runs; the panel says which |
| Export folder missing or unwritable | Export asks for a folder with a save panel instead |
| Shuffle due while the Mac sleeps, or overdue at launch | Nothing fires at launch or on wake; the next shuffle is one interval after that moment. Missed shuffles are not caught up |
| Login item registration fails | The toggle reverts and shows the error; Login Items can be opened directly |
| Shortcut cannot be registered (taken by another app) | Settings says so beside the recorder; the panel still opens by hover, click or the menu-bar item |

No permissions: no Accessibility, no Input Monitoring, no Screen Recording, no Location. Hover uses a tracking area on macPaper's own transparent window over the notch; the shortcut uses Carbon's `RegisterEventHotKey`; clicks outside use a global mouse-down monitor, and the first-run glow a global mouse-moved monitor, neither of which needs anything; the pin reads `NSWorkspace.desktopImageURL(for:)`; the clock is a window on the desktop level that ignores the mouse; the theme is `AppleInterfaceThemeChangedNotification`. No telemetry; diagnostics are copied only on request and only to the pasteboard.

## Marketing only

At `/macpaper/`: the tangerine key in the headline, a drawn notch panel over a mesh gradient, feature articles (generators and the dither lab, pairs that macOS keeps switching, the notch, apply-finished: pin, native pixels, true black; seeds and sharing; the clock and the screen saver), the install block, Buy, questions, the closing field. Never claim motion, Now Playing or a separate lock screen. The catalog entry, Buy and the thanks page ship with the first licensed release.

## References

[App README](../../apps/macpaper/README.md) · [Releasing](../../apps/macpaper/RELEASING.md) · [Tokens](../../apps/macpaper/design/tokens.json) · [Licensing](../../LICENSING.md).
