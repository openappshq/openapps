# OpenNotes brand assets

Authored by hand for OpenNotes on 2026-09-16 in the OpenApps HQ Tactile Studio grammar ([design/assets/README.md](../../../../design/assets/README.md)): the 128-unit symbol keeps 24 units clear, the 280-unit app icon is the same tile-with-shadow construction as the other apps. They are not in the Figma export manifest yet; add them there when the Figma masters exist, and then regenerate the committed `AppIcon.icns` and menu-bar images with `scripts/make-icons.sh`.

| File | Use |
| --- | --- |
| `symbol-ink.svg` | The sticky with a folded corner, ink; the menu-bar template image is rendered from it |
| `symbol-paper.svg` | The same in paper, for cobalt and charcoal grounds |
| `app-icon.svg` | The sticky on a `coral/300` tile with a `coral/500` shade; rendered into `AppIcon.icns` |

Colors come from [`tokens.json`](../tokens.json) (coral ramp derived for OpenNotes; contrast checks recorded there). Nothing here derives from any other notes app.
