import { cp, mkdir } from "node:fs/promises";
import { basename } from "node:path";
import { openreactionFiles, openreactionSourceDir } from "./openreaction-source.mjs";

const publicDir = new URL("../public/", import.meta.url);
await mkdir(publicDir, { recursive: true });
await Promise.all([
  cp(
    new URL("../../../packages/soundpacks/sounds/", import.meta.url),
    new URL("sounds/", publicDir),
    { recursive: true },
  ),
  cp(
    new URL("../../../design/assets/openklack/", import.meta.url),
    new URL("brand/openklack/", publicDir),
    { recursive: true },
  ),
  cp(
    new URL("../../../design/assets/openapps-hq/", import.meta.url),
    new URL("brand/openapps-hq/", publicDir),
    { recursive: true },
  ),
]);

// The /openreaction/ page needs the app's brand marks and its vendored emoji database.
const openreaction = openreactionSourceDir();
if (!openreaction) {
  throw new Error(
    "OpenReaction sources not found: expected apps/openreaction or OPENREACTION_SOURCE_DIR.",
  );
}
await mkdir(new URL("brand/openreaction/", publicDir), { recursive: true });
await mkdir(new URL("data/openreaction/", publicDir), { recursive: true });
await Promise.all([
  ...openreactionFiles.brand.map((file) =>
    cp(new URL(file, openreaction), new URL(`brand/openreaction/${basename(file)}`, publicDir)),
  ),
  cp(
    new URL(openreactionFiles.emoji, openreaction),
    new URL("data/openreaction/emoji.json", publicDir),
  ),
]);
