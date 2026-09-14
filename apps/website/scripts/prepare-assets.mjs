import { cp, mkdir } from "node:fs/promises";

const publicDir = new URL("../public/", import.meta.url);
await mkdir(publicDir, { recursive: true });
await Promise.all([
  cp(new URL("../../../packages/ui/assets/", import.meta.url), publicDir, { recursive: true }),
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
