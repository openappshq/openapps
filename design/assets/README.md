# Brand assets

Direct Figma exports, September 14, 2026; preserve vector paths and outlined wordmarks.
[Manifest](figma-export.json): original names, node IDs, dates, dimensions, status, checksums; file paths are relative to this directory.
For refresh/check commands, see [design updates](../README.md#updates).

| Per-brand file             | Use                                                                             |
| -------------------------- | ------------------------------------------------------------------------------- |
| `symbol-{ink,paper}.svg`   | Flat mark; minimum 16px, preferred below 32px and in menus                      |
| `wordmark-{ink,paper}.svg` | Outlined lettering; preserve tracking                                           |
| `app-icon.svg`             | Tactile tile with shadow                                                        |
| `app-icon-1120.png`        | 4× export including shadow padding around a 1024px frame; not an `.icns` bundle |

Keep 24 units clear around the 128-unit symbol.
Use Ink on white/HQ yellow, Paper on cobalt/charcoal; preserve proportions and split geometry, with effects only on tiles.
The website copies masters to ignored public assets during dev/build.

## OpenKlack files

- `menu-template@2x.png`: 36px template used at 18pt, separate from the application icon.
- `github-cover.png`: Figma cover.
- `ui/settings-{light,dark}.png`: 2000 × 1200 renders of the actual React app with sample state, September 14; display at most 1000px wide.
  Remaining menu PNGs are historical Figma proposals.
- `features/*.svg`: code-generated illustrations, not screenshots or Figma exports.

Captures/illustrations are outside the Figma checksum manifest.
Use the labeled [archive](../archive/README.md) for obsolete layouts.
Generate Mac icons with `pnpm openklack:icons`; keyboard, sound, and typing illustrations with `node scripts/generate-readme-visuals.mjs`.
Edit `features/menu.svg` directly.
