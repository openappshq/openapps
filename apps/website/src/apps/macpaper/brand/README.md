# macPaper brand, mirrored

Byte-for-byte copies of `apps/macpaper/design/assets/` (the app branch, contract
of 2026-09-16) so the catalog copy step and the pages have the real masters
before the app lands on `main`. Same files and frames as every other app
(`app-icon.svg` on a 280 tile, `symbol-{ink,paper}.svg` on the 128 grid).

When the app lands: point `brandSource` in `apps/website/src/catalog.ts` at
`apps/macpaper/design/assets` and delete this folder.
