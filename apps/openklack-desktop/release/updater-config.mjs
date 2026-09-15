#!/usr/bin/env node
// Writes the Tauri config overlay for an official build: release/tauri.release.json
// plus the version and the updater plugin's public key and feed.
//
//   node release/updater-config.mjs <out.json> <version> [public key file] [feed url]
//
// The public key defaults to release/updater-public-key.txt, the feed to the
// official one. `tauri build` needs the key to create updater artifacts, and
// the app pins it at run time.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const [
  out,
  version,
  keyFile = join(here, "updater-public-key.txt"),
  feed = "https://openapps.space/updates/openklack/latest.json",
] = process.argv.slice(2);
if (!out || !/^\d+\.\d+\.\d+$/.test(version ?? "")) {
  console.error("usage: updater-config.mjs <out.json> <version> [public key file] [feed url]");
  process.exit(2);
}
const pubkey = readFileSync(keyFile, "utf8").trim();
if (pubkey.startsWith("NOT GENERATED") || !pubkey) {
  console.error(`error: ${keyFile} has no update key yet (RELEASES.md)`);
  process.exit(1);
}
const release = JSON.parse(readFileSync(join(here, "tauri.release.json"), "utf8"));
writeFileSync(
  out,
  JSON.stringify({ ...release, version, plugins: { updater: { pubkey, endpoints: [feed] } } }),
);
