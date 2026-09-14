import { readFile, writeFile } from "node:fs/promises";
const output = new URL("../design/assets/openklack/features/", import.meta.url);
const rows = JSON.parse(
  await readFile(new URL("../packages/keyboard-layout/src/layout.json", import.meta.url), "utf8"),
);
const escape = (value) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;");
const text = (x, y, value, size = 13, color = "#626262", weight = 400) =>
  `<text x="${x}" y="${y}" font-size="${size}" fill="${color}" font-weight="${weight}">${escape(value)}</text>`;
const box = (x, y, w, h, fill = "#f3f3f3", r = 8) =>
  `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="${fill}"/>`;
async function svg(name, title, content) {
  await writeFile(
    new URL(`${name}.svg`, output),
    `<svg xmlns="http://www.w3.org/2000/svg" width="440" height="210" viewBox="0 0 440 210" role="img" aria-label="${title}"><title>${title}</title><rect width="440" height="210" rx="16" fill="#fff"/><g font-family="Arial,sans-serif">${content}</g></svg>\n`,
  );
}
let keyboard = box(20, 24, 400, 158, "#dedfe4", 12);
rows.forEach((row, index) => {
  const unit = 384 / row.reduce((n, key) => n + key[2], 0);
  let x = 28;
  row.forEach(([code, label, width]) => {
    const w = unit * width - 3;
    const y = 32 + index * 23;
    const selected = ["Space", "KeyA", "KeyS", "KeyD", "Escape"].includes(code);
    keyboard += box(x, y + 2, w, 19, selected ? "#2038d8" : "#bdbfc7", 3);
    keyboard += box(x, y, w, 18, selected ? "#304bff" : "#f8f8f8", 3);
    keyboard += text(
      x + 3,
      y + 11,
      label || "OPENKLACK",
      label.length > 3 ? 5 : 7,
      selected ? "#fff" : "#424754",
    );
    x += unit * width;
  });
});
keyboard += text(22, 200, "OPENKLACK 01", 10) + text(301, 200, "YOUR KIND OF CLICK", 9, "#304bff");
await svg("keyboard", "Original OpenKlack keyboard illustration", keyboard);
let sounds = text(24, 32, "Find your sound", 20, "#141414", 700);
[
  ["Cream", "NovelKeys", true],
  ["Blue PBT", "Cherry MX", false],
  ["Buckling Spring", "IBM", false],
].forEach(([name, brand, active], i) => {
  const y = 49 + i * 49;
  sounds +=
    box(20, y, 400, 43, active ? "#edf0ff" : "#f3f3f3") +
    text(32, y + 18, name, 13, "#141414", 700) +
    text(32, y + 33, brand, 10) +
    text(355, y + 26, active ? "★" : "☆", 19, "#2038d8") +
    text(389, y + 25, "▷", 18);
});
await svg("sounds", "Sound choices with favorites and previews", sounds);
await svg(
  "menu",
  "OpenKlack menu controls illustration",
  box(80, 12, 280, 186, "#f3f3f3", 12) +
    text(100, 39, "Sound is on", 12) +
    text(100, 65, "Mute", 14, "#141414", 700) +
    text(100, 94, "Volume", 12) +
    box(100, 107, 240, 4, "#d9d9d9", 2) +
    box(100, 107, 150, 4, "#304bff", 2) +
    '<circle cx="250" cy="109" r="7" fill="#fff" stroke="#858585"/>' +
    text(100, 144, "✓  Cherry MX Blue PBT", 13, "#141414") +
    text(100, 178, "More sounds", 13, "#141414") +
    text(327, 178, "›", 18),
);
await svg(
  "typing",
  "Typing playground illustration",
  box(20, 20, 400, 169, "#f3f3f3", 12) +
    box(34, 32, 69, 25, "#fff", 5) +
    text(42, 49, "Free type", 12, "#141414") +
    text(121, 49, "15s     30s     60s", 12) +
    `<g font-family="monospace">${text(34, 99, "find a little rhythm", 23, "#141414")}${text(34, 130, "in the everyday", 23, "#858585")}</g>` +
    box(305, 109, 2, 26, "#304bff", 0) +
    text(34, 172, "YOUR TEXT STAYS HERE. YOUR SOUND IS YOURS.", 10),
);
