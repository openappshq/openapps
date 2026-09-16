# OpenNotes brand placeholders

Stand-ins until the app lands with its own masters. The catalog's `brandSource`
points here so the site can build; once `apps/opennotes/design/assets` exists,
set `brandSource: "apps/opennotes/design/assets"` in `apps/website/src/catalog.ts`
and delete this folder. The coral steps in `../tokens.css` are provisional for
the same reason: the app's `tokens.json` wins when it arrives.

| File               | What it is                                                              |
| ------------------ | ----------------------------------------------------------------------- |
| `symbol-ink.svg`   | A sticky note with a folded corner beside the deck's edge pill, in ink  |
| `symbol-paper.svg` | The same mark in paper                                                  |
| `app-icon.svg`     | The tactile tile: coral/500 shadow, coral/300 face, the ink mark on top |

Authored by hand, not exported from Figma; nothing here is in the checksum
manifest under `design/assets/`.
