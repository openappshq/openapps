# macPaper

A wallpaper maker that lives in the notch: click or hover the notch and a panel drops down with the current wallpaper, a generator to change it, Shuffle, Apply, Favorite and Export. Every wallpaper is made on the Mac from a few parameters and a seed; nothing is downloaded and nothing is uploaded.
Open source under MIT; the official build is paid on the same terms as every OpenApps HQ app ([LICENSING.md](../../LICENSING.md): 3-day in-app trial, no signup, one license for 3 Macs). Installed with Homebrew; the official build checks a signed feed for updates once a day and installs one only when the user says so ([RELEASES.md](../../RELEASES.md)).

Inspired by the idea of a notch-based wallpaper maker; written from scratch, with no code, copy, name or asset from any other product.

## Identity

Signature color: tangerine (`tangerine/300` tile face, `tangerine/500` shade, `tangerine/700` / `tangerine/300` accent in light / dark); the mark is a display outline with the notch as a filled tab and one horizon line inside.
The color is the app's, not a state: success stays green, danger red, warning HQ yellow, so a tangerine control is always an action or the brand.
Type follows the shared system: Bricolage Grotesque for the panel's heading and the settings window's headings, Instrument Sans for interface text, IBM Plex Mono with tabular digits for seeds, sizes and labels.
Surfaces are glass cards (Liquid Glass on macOS 26, the system material before, opaque under Reduce Transparency, a visible rim under Increase Contrast), as in Hertz and OpenReaction. The notch panel is one such card, squared off at the top where it meets the menu bar.

## Primary task

Make the desktop look the way you want in one gesture: open the panel, pick or shuffle, Apply. Everything else (favorites, scheduled shuffle, export, per-display choices) supports that.

## Generators

Every wallpaper is a document: a generator, its parameters, a seed and a grain amount, serialisable as JSON. The same document renders the same pixels at the same size on the same Mac; the seed is shown in the panel so a look can be reproduced or shared.

| Generator | Parameters | Rendering |
| --- | --- | --- |
| Gradient | Linear, radial or conic; 2–6 color stops; angle (linear, conic) or center (radial, conic) | Per pixel, software |
| Mesh | Columns × rows of control points (2–5 each), a palette of up to 6 colors, jitter and softness; the seed places the points and picks their colors | Inverse-distance blend of the control points, software (no Metal, no GPU: the result is the same on every Mac) |
| Pattern | Dots, lines, checks or noise; foreground and background colors; scale; angle (lines); the seed drives noise | Software raster |
| Solid | One color | Flat fill |
| Pixelize | An imported image (PNG, JPEG, HEIC, TIFF), block size 4–64 px, optional palette reduction to 2–32 colors; fill or fit the display | The image is scaled to cover the display, averaged per block, optionally quantised (median cut), then filled block by block |

Film grain (0–100 %) is a finish on every generator, seeded, monochrome.
Renders are made at the display's pixel size (points × backing scale); previews render at a fraction of it (`renderScale`) so a slider drag never waits on a 6-megapixel image. A render cache keyed by document and size keeps the last few full-size renders within a byte limit.

## Notch panel

The panel is anchored to the notch of the display that hosts it and opens downwards from it, exactly as wide as the notch (plus the width setting), with the same corner radius as the notch's lower corners. Without a notch the panel opens from the top center of the host display and the menu-bar popover stays the primary surface.

| Setting | Values | Default |
| --- | --- | --- |
| Notch panel | on / off (off: the menu-bar popover only) | on |
| Host display | the notch display / the main display / every notched display | the notch display |
| Open on | hover / click / both | both |
| Direction | down (v1 renders down only; left, right are stored for a later release) | down |
| Width | narrow / notch width / wide (adds 0 / 120 / 240 pt on each side) | notch width |
| Hide in fullscreen | on / off | on |
| Hotkey | any key with at least one modifier, or none | ⌃⌥⌘ W |

Behavior:

- Hover opens after 180 ms over the notch and closes 400 ms after the pointer leaves the panel and the notch; a click opens at once and then only a click outside, Escape, the hotkey or Hide in fullscreen closes it. Opening by click while a hover-open is pending cancels the pending open. A hover-opened panel that the pointer enters stays as long as the pointer is inside.
- The hotkey toggles the panel on the host display. With the panel off it opens the menu-bar popover instead.
- In fullscreen (Hide in fullscreen on) the panel closes and hover does nothing until the space leaves fullscreen; the hotkey still opens the popover.
- Reduce Motion: no drop animation, the panel appears in place; the standard drop takes 180 ms otherwise.
- The panel never takes key focus from the app in front unless the user types in it (the seed field, a color field); Escape then returns focus.
- The panel's content, top to bottom: the current wallpaper's preview in the display's aspect ratio (with a "this display" label when displays differ); the generator segmented control; the generator's parameters; a row of actions: **Shuffle**, **Apply** (this display · all displays in a menu, or one button while "same on all displays" is on), Favorite (a star, filled while the document is a favorite), Export (PNG / SVG); a footer with the seed, Settings… and Quit.

## Menu bar

A template symbol (the mark) with no readout. Clicking opens the popover with the same content as the notch panel, 360 pt wide. The popover is the only surface when the notch panel is off, when no display has a notch and the host display setting is "the notch display", and in fullscreen while the panel is hidden.

## Wallpapers settings

| Setting | Behavior | Default |
| --- | --- | --- |
| Shuffle | Off, or every 15 min / 30 min / hour / 3 hours / 6 hours / day; a shuffle renders a new document (a random generator and seed, or one of the favorites) and applies it | off |
| Favorites only | Shuffle picks from the favorites; with none saved it falls back to random and the settings row says so | off |
| Same on all displays | Apply and Shuffle set one document on every display; off: each display keeps its own, Apply offers "this display" and "all displays", Shuffle changes every display to a different document | on |
| Export folder | Where PNG and SVG exports land; Choose… opens an open panel | ~/Pictures/macPaper |

Favorites are documents (JSON), not images, kept in `~/Library/Application Support/OpenApps/macpaper/favorites.json`; a favorite renders again for any display size. Imported images for Pixelize are copied into `imports/` under the same folder so a favorite keeps working after the original moves.

Applying writes the render as PNG into `applied/` under the same folder, one file per display and per apply (macOS ignores a new image at the URL it already shows, so every apply is a new file), then asks `NSWorkspace` to set it for that screen; older applied files are pruned to the last three per display. The user's own wallpaper is never read or touched beyond that call.

## General settings

Open at login (on once on a fresh install, `SMAppService`, approval state shown; the user can turn it off), the notch settings above, Show setup guide, and About: what macPaper does and where it writes (this Mac only; the only network calls of an official build are the license check, the trial registry and the update check, none in a source build), MIT, Copy Diagnostics (version, login state, licensing flavour, displays and their notches, the panel settings, the shuffle state, the applied documents).

## Licensing (placeholder until the licensing ticket)

Official builds follow [LICENSING.md](../../LICENSING.md) through the shared `packages/openapps-licensing`, like Hertz. **The core feature is generating and applying wallpapers.** When restricted (TrialEnded, TrialNeedsConnection, TrialClockBehind, CheckRequired, Revoked, the storage-error forms of TrialUnavailable): generating, Shuffle (manual and scheduled), Apply and Export are off, and the panel and the popover show the license card in place of the generator, in LICENSING.md's words with the same actions as Hertz's card (Buy a license, Enter a key, Try again); Settings, favorites browsing and Quit keep working. The already applied wallpaper stays: macPaper never removes what it set. Builds from source have no licensing and everything on.

## Defaults and recovery

| Situation | Behavior |
| --- | --- |
| Fresh install (no earlier preferences; in official builds both records positively absent) | Open at login on once (and, with the updater, automatic update checks), under its own flag; an upgrade or a setting the user turned off is left alone |
| First launch | Nothing is applied on its own: the panel shows a seeded gradient as its starting document; the desktop changes only on Apply or when shuffle is turned on |
| No display has a notch | Host "the notch display" leaves the panel closed; the popover carries everything; Settings says so under Host display |
| The notch display is unplugged | The panel closes and comes back on the next notched display that appears; "every notched display" keeps one panel per notched display |
| Fullscreen on the host display | See Hide in fullscreen; detection is from the host screen's visible frame (the menu bar gone) on space changes, without Screen Recording or Accessibility |
| `setDesktopImageURL` fails (a screen went away, the file could not be written) | The action reports the error in the panel beside the Apply button and keeps the previous document; nothing is retried on its own |
| An imported image cannot be decoded | Pixelize keeps its previous source and says why beside Import |
| Export folder missing or unwritable | Export asks for a folder with a save panel instead |
| Shuffle due while the Mac sleeps | The next shuffle happens on wake; missed shuffles are not caught up |
| Login item registration fails | The toggle reverts and shows the error; Login Items can be opened directly |
| Hotkey cannot be registered (taken by another app) | Settings says so beside the recorder; the panel still opens by hover, click or the menu bar |

No permissions: no Accessibility, no Input Monitoring, no Screen Recording, no Location. Hover uses a tracking area on macPaper's own transparent window over the notch; the hotkey uses Carbon's `RegisterEventHotKey`; clicks outside use a global mouse-down monitor, which needs nothing. No telemetry; diagnostics are copied only on request and only to the pasteboard.

## Marketing only

At `/macpaper/`: the tangerine key in the headline, a drawn notch panel over a mesh gradient, three feature articles (generators, the notch, shuffle and favorites), the install block, Buy, questions, the closing field. The catalog entry, Buy and the thanks page ship with the first licensed release.

## References

[App README](../../apps/macpaper/README.md) · [Releasing](../../apps/macpaper/RELEASING.md) · [Tokens](../../apps/macpaper/design/tokens.json) · [Licensing](../../LICENSING.md).
