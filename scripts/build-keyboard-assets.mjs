import { readFile, writeFile, mkdir } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";

const source = new URL("../design/keyboard/source/", import.meta.url);
const output = new URL("../packages/openklack-ui/assets/keyboard/", import.meta.url);
await mkdir(output, { recursive: true });

const glb = await readFile(new URL("keyboard.glb", source));
const jsonLength = glb.readUInt32LE(12);
const model = JSON.parse(glb.subarray(20, 20 + jsonLength).toString());
const aliases = {
  "keys.311": "F1",
  "keys.310": "F2",
  "keys.309": "F3",
  "keys.308": "F4",
  "keys.307": "F5",
  "keys.306": "F6",
  "keys.305": "F7",
  "keys.304": "F8",
  "keys.303": "F9",
  "keys.302": "F10",
  "keys.301": "F11",
  "keys.300": "F12",
  "keys.299": "PrintScreen",
  "keys.276": "Delete",
  "keys.313": "Home",
  "keys.314": "PageUp",
  "keys.316": "PageDown",
  "keys.317": "End",
  "keys.318": "AltRight",
  "keys.319": "Space",
};
for (const index of model.scenes[model.scene].nodes) {
  const node = model.nodes[index];
  if (node.name === "static") continue;
  const keyCode = aliases[node.name] ?? node.name;
  node.extras = { ...node.extras, keyCode };
  node.name = node.name === "keys.319" ? "SpacePlate" : keyCode;
}
const json = Buffer.from(JSON.stringify(model));
const padded = Buffer.alloc(Math.ceil(json.length / 4) * 4, 32);
json.copy(padded);
const binary = glb.subarray(20 + jsonLength);
const header = Buffer.from(glb.subarray(0, 20));
header.writeUInt32LE(20 + padded.length + binary.length, 8);
header.writeUInt32LE(padded.length, 12);
const result = Buffer.concat([header, padded, binary]);
assert.deepEqual(result.subarray(20 + padded.length), binary);
await writeFile(new URL("openklack.glb", output), result);
console.log("openklack.glb: key metadata updated; geometry and UV buffers unchanged");

execFileSync(
  process.env.BLENDER_BIN ||
    (process.platform === "darwin"
      ? "/Applications/Blender.app/Contents/MacOS/Blender"
      : "blender"),
  ["-b", "--python", new URL("bake-keyboard.py", import.meta.url).pathname],
  { stdio: "inherit" },
);
