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

Every wallpaper is a document: a generator, its parameters, a seed, the finishes and the composition, serialisable as JSON. The panel lists Dither, Mesh, Pattern and Pixelize as generators; a gradient or a flat color on its own is the **base layer** (Effects → Base layer: Flat · Gradient · True black), never a shuffle's result and never a starter. The same document renders the same pixels at the same size on every Mac; the seed is shown in the panel so a look can be reproduced or shared.

| Generator | Parameters | Rendering |
| --- | --- | --- |
| Gradient (base layer) | Linear, radial or conic; 2–6 color stops; angle (linear, conic) or center (radial, conic); interpolation in sRGB or OKLCH ("smooth", the default for new documents: no grey dip between saturated colors) | Per pixel, software |
| Mesh | Columns × rows of control points (2–5 each), a palette of up to 6 colors, jitter and softness; the seed places the points and picks their colors | Inverse-distance blend of the control points, software (no Metal, no GPU: the result is the same on every Mac) |
| Pattern | Dots, lines, checks or noise; foreground and background colors; scale; angle (lines, checks); the seed drives noise | Software raster |
| Solid (base layer) | One color; **True black** sets `#000000` with every finish, composition and pair off, and the render is exact zeros on both sides (Liquid Glass reads best on it) | Flat fill |
| Pixelize | An imported image (PNG, JPEG, HEIC, TIFF), block size 4–64 px, optional palette reduction to 2–32 colors; framing (below) | The image is placed per the framing, averaged per block straight from the source pixels, optionally quantised (median cut), then filled block by block |
| Dither | An imported image; Bayer 2/4/8, Floyd–Steinberg, blue noise (a 64×64 void-and-cluster tile), halftone (dot size by luminance on a rotated grid) or ASCII (a built-in 5×7 glyph ramp, no font); cell size (widened on very large displays so the sample grid stays under 2.5 million cells: cell 1 on a 5K is cell 3); 2 colors (ink/paper) or a reduced palette of up to 16; framing | Software, from the source pixels; the same seed and image give the same bytes |

**Framing** (pixelize and dither, per display): fill (cover, cropped around a focal point the user drags on the preview), fit (letterboxed in a color) or stretch. Every render is made at the display's exact pixel size (points × backing scale), so a 5120×1440 ultrawide gets a 5120×1440 plate, never an upscale.

**Finishes**, in this order after the generator, each off by default: tint (one color, amount), duotone (shadow and highlight colors), gradient map (2–6 stops over luminance), film grain (0–100 %, seeded, monochrome), and **top shade** (a shading of the menu-bar strip toward the menu bar's own tone — lighter on the light side, darker on the dark side — so its text reads). The panel reads the menu-bar strip of every render against the text the side gets (dark text in the light appearance, light text in the dark one) and says **"Menu bar: reads" / "Menu bar: low contrast"** (4.5:1 and an even strip); the low-contrast state offers "Shade the top" with one click. Renders are made at the display's pixel size; previews render at a fraction of it (`renderScale`) so a slider drag never waits on a 6-megapixel image. A render cache keyed by document and size keeps the last few full-size renders within a byte limit.

**Colors.** Every color row offers **From photo…** (the dominant colors of an image, median cut, pasted into the row), **From accent color** (the Mac's accent color expanded into a palette in OKLCH: the accent, a lighter and a darker step, its complement, a near-black and a near-white), and the preset palettes (the Palette section's grid; a recipe is titled by the preset its colors come from, or "Custom"). Random documents and the accent palette interpolate in OKLCH so nothing lands in the grey.

## Pairs

| Pair | What it is | How it is applied |
| --- | --- | --- |
| Light / dark | Every document has a light and a dark side. The dark side is derived (**Make dark from light**: every color's OKLCH lightness folded down, hue and chroma kept) or edited on its own; a segmented control under Effects switches which side is edited, and the preview shows the side matching the Mac's appearance | Applied as one HEIC with the two images and the `apple_desktop:apr` appearance record (the format macOS's own dynamic desktops use, written with ImageIO), so macOS switches by itself after macPaper quits. Where a display refuses the HEIC (an old macOS, a screen that only takes stills), the two PNGs are kept and swapped on the theme-change notification while macPaper runs |
| Time of day | The same seed at 4, 8 or 16 moments of the day: the document's colors follow a day curve (lightness and warmth up toward noon, down toward midnight), the seed unchanged | One HEIC with the frames and the `apple_desktop:h24` time record (fractions of the day, plus which frame is light and dark), so macOS keeps cycling after quit. No Location: the curve is by clock time, not the sun; a sun-position (`solar`) variant is listed under "Not built" |
| Phone | The desktop still and a 1290×2796 portrait of the same document | **Export → Phone pair** writes both PNGs; the phone one is AirDropped by the user |

A favorite is a document, so it keeps its pair and its frames.

## Seeds and sharing

**Share** puts `macpaper://s/<code>` on the pasteboard, where the code is the whole document (deflated JSON, base64url): every knob, the seed, the finishes, the pair and the composition, never an image (a pixelize or dither document shares without its photo and says so). Opening such a link in macPaper loads it as the draft. **Remix** is a new seed on the loaded document. **Never show this** puts a document on a blocklist shuffle never picks from (and removes it from favorites); the list is cleared in Settings.

## Notch panel

The panel is a tall column anchored to the notch of the display that hosts it: centered on the notch, its top squared against it, its bottom corners rounded, most of the screen tall (the screen's height under the notch less a 24-point margin, at most 920 points) and a fixed height while it is open, so switching sections never moves the window; the menu-bar row beside the notch is shaded in the column's width by a click-through strip under the menu bar's own window, so the row reads as part of the column through the bar's translucency while its items are never tinted and keep every click. Without a notch the column opens under the menu-bar item as the popover does — its trailing edge on the item's, rounded all round, a 6-point gap under the menu bar — or from the top center when the item is on another display (the hover zone is then a 2-point strip at the top edge, so no menu-bar item is covered), and the menu-bar popover stays the primary surface.

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

| Setting | Values | Default |
| --- | --- | --- |
| Notch panel | on / off (off: the menu-bar popover only) | on |
| Host display | the notch display / the main display / every notched display | the notch display |
| Open on | hover / click / both | both |
| Direction | down (v1 renders down only; left, right are stored for a later release) | down |
| Width | compact / regular / wide (360 / 440 / 560 pt, each grown to fit the widest control's labels) | regular |
| Hide in fullscreen | on / off | on |
| Hotkey | any key with at least one modifier, or none | ⌃⌥⌘ W |

Behavior:

- Hover opens after 180 ms over the notch and closes 400 ms after the pointer leaves the panel and the notch; a click opens at once and then only a click outside, Escape, the hotkey or Hide in fullscreen closes it. Opening by click while a hover-open is pending cancels the pending open. A hover-opened panel that the pointer enters stays as long as the pointer is inside.
- The hotkey toggles the panel on the host display. With the panel off it opens the menu-bar popover instead.
- In fullscreen (Hide in fullscreen on) the panel closes and hover does nothing until the space leaves fullscreen; the hotkey still opens the popover.
- Reduce Motion: no drop animation, the panel appears in place; the standard drop takes 180 ms otherwise.
- The panel never takes key focus from the app in front unless the user types in it (the seed field, a color field); Escape then returns focus.
- The column's content is the section the rail points at (above); the section is kept across opens and shared with the popover. Collapse on the rail closes the column the way Escape does.

### Notch-aware composition

A document may compose around the notch of the display it is applied to: **Emerge** (the mesh's brightest control point sits at the cutout's bottom center and the field grows out of it), **Contours** (the pattern's lines part around the notch pill, as a distance field from it), or **Painted pill** (a black pill of the notch's proportion painted at the top center of a display without one, for symmetry with the notched one). The composition is part of the document and renders per display: the notch's position and size come from the display, so the same favorite composes correctly on a 14" and a 16". A display without a notch renders Emerge and Contours from the top center.

## Menu bar

A template symbol (the mark) with no readout. Clicking opens the popover with the same column as the notch panel, the regular width, as tall as the screen allows, dark in both appearances. The popover is the only surface when the notch panel is off, when no display has a notch and the host display setting is "the notch display", and in fullscreen while the panel is hidden.

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
| Shuffle | Off, or every 15 min / 30 min / hour / 3 hours / 6 hours / day; a shuffle renders a new document (a random mesh or pattern and seed, or one of the favorites, with the pinned parameters kept from the draft; never a flat color or a gradient on its own) and applies it | off |
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
