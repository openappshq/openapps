// Writes the D1 database ID from TRIAL_REGISTRY_D1_ID into wrangler.jsonc, so
// the committed config keeps a placeholder and CI supplies the real ID.
import { readFileSync, writeFileSync } from "node:fs";

const PLACEHOLDER = "00000000-0000-0000-0000-000000000000";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const id = (process.env.TRIAL_REGISTRY_D1_ID ?? "").trim();
if (!UUID.test(id) || id === PLACEHOLDER) {
  console.error("Set TRIAL_REGISTRY_D1_ID to the ID printed by `wrangler d1 create`.");
  process.exit(1);
}

const file = new URL("../wrangler.jsonc", import.meta.url);
const config = readFileSync(file, "utf8");
const setting = `"database_id": "${PLACEHOLDER}"`;
if (config.split(setting).length !== 2) {
  console.error(`Expected exactly one ${setting} in wrangler.jsonc.`);
  process.exit(1);
}
writeFileSync(file, config.replace(setting, `"database_id": "${id}"`));
console.log("Configured the trial registry database.");
