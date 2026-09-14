# Keyboard asset workflow

The supplied HAR contains Raycast’s published GLB models, baked textures, lighting, glyphs, audio, and compiled JavaScript. It does not contain their Blender project or uncompiled application source.

- `source/`: untouched reference assets, with URLs and SHA-256 hashes in `manifest.json`.
- `openklack-keyboard.blend`: the editable OpenKlack material and lighting scene, using the reference geometry and UVs.
- `legends.svg` and `legends.png`: the generated OpenKlack legend atlas.
- `../../packages/openklack-ui/assets/keyboard/`: derived `openklack.glb`, `base.png`, and `rgb.png` used by both apps.
- `../../target/reference/raycast/`: captured compiled code, outside the tracked application source.

```sh
# Requires Blender 5.2 and the workspace dependencies.
pnpm keyboard:assets
# For another Blender installation: BLENDER_BIN=/path/to/Blender pnpm keyboard:assets
```

The script preserves the GLB geometry/UV bytes, adds logical key metadata, then runs `scripts/bake-keyboard.py`.
The bake script creates ivory keycaps, gray modifiers, cobalt accents, a graphite case, and a softbox lighting rig.
It bakes base and RGB lighting atlases at 2048 × 2048 using Cycles; no runtime recoloring or replacement-label shader is used.
The editable scene is saved before joining meshes for the bake, so individual keys remain editable.
Change materials and lighting in the Python authoring script for reproducible builds. Regeneration overwrites the generated Blender scene and legend files.

The renderer handles key travel and radial blending of the baked textures. It stops rendering when settled or hidden.
The reference audio is not used in OpenKlack. See [provenance](../../packages/openklack-ui/assets/keyboard/PROVENANCE.md) for ownership and redistribution status.
