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

Every wallpaper is a document: a generator, its parameters, a seed, the finishes and the composition, serialisable as JSON. The same document renders the same pixels at the same size on every Mac; the seed is shown in the panel so a look can be reproduced or shared.

| Generator | Parameters | Rendering |
| --- | --- | --- |
| Gradient | Linear, radial or conic; 2–6 color stops; angle (linear, conic) or center (radial, conic); interpolation in sRGB or OKLCH ("smooth", the default for new documents: no grey dip between saturated colors) | Per pixel, software |
| Mesh | Columns × rows of control points (2–5 each), a palette of up to 6 colors, jitter and softness; the seed places the points and picks their colors | Inverse-distance blend of the control points, software (no Metal, no GPU: the result is the same on every Mac) |
| Pattern | Dots, lines, checks or noise; foreground and background colors; scale; angle (lines, checks); the seed drives noise | Software raster |
| Solid | One color; **True black** sets `#000000` with every finish, composition and pair off, and the render is exact zeros on both sides (Liquid Glass reads best on it) | Flat fill |
| Pixelize | An imported image (PNG, JPEG, HEIC, TIFF), block size 4–64 px, optional palette reduction to 2–32 colors; framing (below) | The image is placed per the framing, averaged per block straight from the source pixels, optionally quantised (median cut), then filled block by block |
| Dither | An imported image; Bayer 2/4/8, Floyd–Steinberg, blue noise (a 64×64 void-and-cluster tile), halftone (dot size by luminance on a rotated grid) or ASCII (a built-in 5×7 glyph ramp, no font); cell size (widened on very large displays so the sample grid stays under 2.5 million cells: cell 1 on a 5K is cell 3); 2 colors (ink/paper) or a reduced palette of up to 16; framing | Software, from the source pixels; the same seed and image give the same bytes |

**Framing** (pixelize and dither, per display): fill (cover, cropped around a focal point the user drags on the preview), fit (letterboxed in a color) or stretch. Every render is made at the display's exact pixel size (points × backing scale), so a 5120×1440 ultrawide gets a 5120×1440 plate, never an upscale.

**Finishes**, in this order after the generator, each off by default: tint (one color, amount), duotone (shadow and highlight colors), gradient map (2–6 stops over luminance), film grain (0–100 %, seeded, monochrome), and **top shade** (a shading of the menu-bar strip toward the menu bar's own tone — lighter on the light side, darker on the dark side — so its text reads). The panel reads the menu-bar strip of every render against the text the side gets (dark text in the light appearance, light text in the dark one) and says **"Menu bar: reads" / "Menu bar: low contrast"** (4.5:1 and an even strip); the low-contrast state offers "Shade the top" with one click. Renders are made at the display's pixel size; previews render at a fraction of it (`renderScale`) so a slider drag never waits on a 6-megapixel image. A render cache keyed by document and size keeps the last few full-size renders within a byte limit.

**Colors.** Every color row offers **From photo…** (the dominant colors of an image, median cut, pasted into the row), **From accent color** (the Mac's accent color expanded into a palette in OKLCH: the accent, a lighter and a darker step, its complement, a near-black and a near-white), and the built-in palettes. Random documents and the accent palette interpolate in OKLCH so nothing lands in the grey.

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
| Shuffle | Off, or every 15 min / 30 min / hour / 3 hours / 6 hours / day; a shuffle renders a new document (a random generator and seed, or one of the favorites) and applies it | off |
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
