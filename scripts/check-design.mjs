import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const design = new URL("../design/", import.meta.url);
const read = (file) => JSON.parse(readFileSync(new URL(file, design), "utf8"));
const tokens = read("tokens.json");
const snapshot = read("references/figma-system.json");
const manifest = read("assets/figma-export.json");
assert.equal(tokens.source, snapshot.source);
assert.equal(tokens.source, manifest.figmaFile);
const variables = new Map(snapshot.variables.map((variable) => [variable.id, variable]));
assert.equal(variables.size, snapshot.variables.length, "Duplicate Figma variable IDs");
assert.equal(
  variables.size,
  Object.keys(tokens.palette).length +
    Object.keys(tokens.color.light).length +
    Object.keys(tokens.metrics).length +
    Object.keys(tokens.typography).length,
  "Token count differs from the Figma snapshot",
);
assert.deepEqual(Object.keys(tokens.color.light).sort(), Object.keys(tokens.color.dark).sort());

for (const variable of variables.values()) {
  const collection = snapshot.collections.find((item) => item.id === variable.collectionId);
  assert.ok(collection, `Missing collection: ${variable.collectionId}`);
  for (const mode of collection.modes) {
    const value = variable.valuesByMode[mode.modeId];
    const expected =
      collection.name === "Color"
        ? tokens.color[mode.name.toLowerCase()][variable.name]
        : tokens[collection.name.toLowerCase()][variable.name];
    let actual = value;
    if (variable.type === "COLOR") {
      if (value.type !== "VARIABLE_ALIAS")
        assert.equal(value.a ?? 1, 1, `Palette alpha is not supported: ${variable.name}`);
      actual =
        value.type === "VARIABLE_ALIAS"
          ? variables.get(value.id)?.name
          : `#${[value.r, value.g, value.b]
              .map((channel) =>
                Math.round(channel * 255)
                  .toString(16)
                  .padStart(2, "0"),
              )
              .join("")}`;
    }
    assert.notEqual(expected, undefined, `Missing token: ${collection.name}/${variable.name}`);
    assert.deepEqual(actual, expected, `${collection.name}/${mode.name}/${variable.name}`);
  }
}

const assets = [
  ...manifest.assets,
  manifest.menuTemplate,
  manifest.githubCover,
  ...manifest.references,
  manifest.snapshot,
];
for (const asset of assets) {
  const data = readFileSync(new URL(asset.file, new URL("assets/", design)));
  assert.equal(createHash("sha256").update(data).digest("hex"), asset.sha256, asset.file);
}
console.log(
  `Design verified: ${variables.size} variables in all modes; ${assets.length} asset/snapshot checksums.`,
);
