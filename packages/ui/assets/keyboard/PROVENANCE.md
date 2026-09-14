# Keyboard asset provenance

The geometry comes from the user-supplied capture of https://www.raycast.com/keyboard and is used in this local prototype at the user's request.
It is not original OpenKlack geometry and is not covered by this repository's MIT license.
Public redistribution requires permission or replacement geometry.

- `openklack.glb` derives from https://www.raycast.com/_next/static/immutable/media/keyboard.3ro93waeap5n5.glb; the geometry and UV bytes are unchanged, with logical key metadata added.
- `base.png` and `rgb.png` are new OpenKlack material/lighting bakes made on that geometry and UV layout.
- Untouched downloaded textures and source hashes are retained in `design/keyboard/source/` as references.

`pnpm keyboard:assets` builds the model metadata and runs the Blender material/lighting bake.
The editable scene, legend atlas, and workflow are in `design/keyboard/`.
The renderer loads the derived files directly. Audio comes from the separately licensed sound catalog.
