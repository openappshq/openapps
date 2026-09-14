// Renders each product's disk-image background from the same artwork the
// download pages draw, so the installer and the website can never drift apart.
// Run after changing `apps/website/src/shared/dmgArtwork.ts`.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { DMG, DMG_COLORS, dmgArtworkSvg } from "../apps/website/src/shared/dmgArtwork.ts";

const root = fileURLToPath(new URL("../", import.meta.url));

/**
 * Where each product's background belongs. OpenKlack's is read straight out of
 * `tauri.conf.json`; OpenReaction has no disk-image step yet, so its file sits
 * with the rest of that app's design assets until one exists.
 */
const targets = {
  openklack: "apps/openklack-desktop/src-tauri/dmg-background.png",
  openreaction: "apps/openreaction/design/assets/dmg-background.png",
};

for (const [app, colors] of Object.entries(DMG_COLORS)) {
  const target = targets[app];
  if (!target) throw new Error(`No installer path for ${app}`);
  const out = join(root, target);
  mkdirSync(dirname(out), { recursive: true });

  // Rendered at 2x and written with a 144 dpi density, which is how a disk
  // image background reaches a Retina display without being resampled.
  const png = await sharp(Buffer.from(dmgArtworkSvg(colors)), { density: 144 })
    .resize(DMG.width * 2, DMG.height * 2, { fit: "fill" })
    .png({ compressionLevel: 9 })
    .withMetadata({ density: 144 })
    .toBuffer();
  writeFileSync(out, png);
  console.log(`${target}: ${DMG.width * 2}x${DMG.height * 2} (${(png.length / 1024).toFixed(1)} kB)`);
}
