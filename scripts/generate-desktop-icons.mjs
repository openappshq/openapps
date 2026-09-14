import { execFileSync } from "node:child_process";
import { copyFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const output = mkdtempSync(join(tmpdir(), "openklack-icons-"));
try {
  execFileSync(
    "pnpm",
    [
      "--filter",
      "@openapps/openklack-desktop",
      "tauri",
      "icon",
      join(root, "design/assets/openklack/app-icon-1120.png"),
      "--output",
      output,
    ],
    { cwd: root, stdio: "inherit" },
  );
  for (const name of ["32x32.png", "128x128.png", "128x128@2x.png", "icon.png", "icon.icns"]) {
    copyFileSync(join(output, name), join(root, "apps/openklack-desktop/src-tauri/icons", name));
  }
} finally {
  rmSync(output, { recursive: true, force: true });
}
