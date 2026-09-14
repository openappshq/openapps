# Brand assets

Exported directly from [OpenApps HQ · Tactile Studio in Figma](https://www.figma.com/design/2fvzpabR06HanNwQIxxtm1/OpenApps-HQ-%C2%B7-Tactile-Studio?node-id=2-92) on 14 September 2026.
The exported vector paths are preserved without redrawing or optimization.

Each brand directory contains:

- `symbol-ink.svg` and `symbol-paper.svg`: flat marks for light and dark grounds.
- `wordmark-ink.svg` and `wordmark-paper.svg`: outlined lettering, requiring no font installation.
- `app-icon.svg`: the tactile application tile with its original shadow.
- `app-icon-1120.png`: the native 4× export, including transparent shadow padding around the 1024-pixel frame.

`figma-export.json` records original export names and SHA-256 checksums.
The PNG dimensions are 1120 × 1120; these are presentation assets, not ready-made macOS `.icns` bundles.
In `openklack/ui`, `settings-light.png` and `settings-dark.png` are captures of the installed Mac app from September 14, 2026. Other UI PNGs are historical Figma proposals. The website uses the current app captures and the code-generated `features/menu.svg` illustration. These are not part of the original Figma export checksum manifest.

Keep a clear space of 24 units around the flat 128-unit symbol.
Use the flat mark at small sizes, with a minimum of 16 pixels.
Use Ink on white or HQ yellow, and Paper on cobalt or charcoal.
Preserve proportions and the detached geometry.

The website copies these originals into its ignored public asset directory before development and builds.
Make identity changes in Figma, export again, and update the provenance manifest.

`openklack/menu-template@2x.png` is a native 36 × 36 Figma export of node `2:112`, used as an 18-point macOS template image.
`openklack/github-cover.png` is the 1440 × 640 cover authored in Figma at node `3:769` for the repository README.

The macOS application icon resources are generated from `openklack/app-icon-1120.png` with `pnpm desktop:icons`.
The generator uses the Tauri icon command and retains the five resources used by the Mac build.

The `openklack/features` SVGs are code-generated README illustrations, not Figma exports or application screenshots.
Regenerate them with `node scripts/generate-readme-visuals.mjs`.
