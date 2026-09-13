export type Key = [code: string, legend: string, width?: number];
export const rows: Key[][] = [
  [
    ["Escape", "esc"],
    ...Array.from({ length: 12 }, (_, n): Key => [`F${n + 1}`, `F${n + 1}`]),
    ["Delete", "del"],
    ["Home", "home"],
  ],
  [
    ["Backquote", "`"],
    ...Array.from("1234567890", (n): Key => [`Digit${n}`, n]),
    ["Minus", "−"],
    ["Equal", "="],
    ["Backspace", "delete", 2],
    ["PageUp", "pg up"],
  ],
  [
    ["Tab", "tab", 1.5],
    ...Array.from("QWERTYUIOP", (n): Key => [`Key${n}`, n]),
    ["BracketLeft", "["],
    ["BracketRight", "]"],
    ["Backslash", "\\", 1.5],
    ["PageDown", "pg dn"],
  ],
  [
    ["CapsLock", "caps", 1.75],
    ...Array.from("ASDFGHJKL", (n): Key => [`Key${n}`, n]),
    ["Semicolon", ";"],
    ["Quote", "'"],
    ["Enter", "return", 2.25],
    ["End", "end"],
  ],
  [
    ["ShiftLeft", "shift", 2.25],
    ...Array.from("ZXCVBNM", (n): Key => [`Key${n}`, n]),
    ["Comma", ","],
    ["Period", "."],
    ["Slash", "/"],
    ["ShiftRight", "shift", 1.75],
    ["ArrowUp", "↑"],
    ["Fn", "fn"],
  ],
  [
    ["ControlLeft", "ctrl", 1.25],
    ["AltLeft", "⌥", 1.25],
    ["MetaLeft", "⌘", 1.25],
    ["Space", "", 6.25],
    ["MetaRight", "⌘"],
    ["AltRight", "⌥"],
    ["ControlRight", "ctrl"],
    ["ArrowLeft", "←"],
    ["ArrowDown", "↓"],
    ["ArrowRight", "→"],
  ],
];
const positions = rows.flatMap((row, y) => {
  let x = 0;
  const total = row.reduce((sum, key) => sum + (key[2] ?? 1), 0);
  return row.map(([code, , width = 1]) => {
    const center = (x + width / 2) / total;
    x += width;
    return { code, x: center, y };
  });
});

export function neighboringKey(code: string, direction: string) {
  const index = positions.findIndex((p) => p.code === code);
  const current = positions[index]!;
  if (direction === "ArrowLeft" || direction === "ArrowRight")
    return positions[
      (index + (direction === "ArrowLeft" ? -1 : 1) + positions.length) % positions.length
    ]!.code;
  const row = Math.max(
    0,
    Math.min(rows.length - 1, current.y + (direction === "ArrowUp" ? -1 : 1)),
  );
  return positions
    .filter((p) => p.y === row)
    .reduce((closest, p) =>
      Math.abs(p.x - current.x) < Math.abs(closest.x - current.x) ? p : closest,
    ).code;
}

export const keyCodes = [
  "Space",
  "Enter",
  "Backspace",
  "Tab",
  "Escape",
  "CapsLock",
  ...Array.from("ABCDEFGHIJKLMNOPQRSTUVWXYZ", (letter) => `Key${letter}`),
  ...Array.from("1234567890", (digit) => `Digit${digit}`),
  "ShiftLeft",
  "ShiftRight",
  "ControlLeft",
  "ControlRight",
  "AltLeft",
  "AltRight",
  "MetaLeft",
  "MetaRight",
  "Fn",
  "ArrowLeft",
  "ArrowRight",
  "ArrowUp",
  "ArrowDown",
  "Backquote",
  "Minus",
  "Equal",
  "BracketLeft",
  "BracketRight",
  "Backslash",
  "Semicolon",
  "Quote",
  "Comma",
  "Period",
  "Slash",
  ...Array.from({ length: 20 }, (_, i) => `F${i + 1}`),
  "Delete",
  "Home",
  "End",
  "PageUp",
  "PageDown",
  "NumpadEnter",
  "NumpadAdd",
  "NumpadSubtract",
  "NumpadMultiply",
  "NumpadDivide",
  "NumpadDecimal",
  "NumLock",
  "PrintScreen",
  ...Array.from({ length: 10 }, (_, i) => `Numpad${i}`),
];
const legends: Record<string, string> = {
  Backquote: "`",
  Minus: "−",
  Equal: "=",
  BracketLeft: "[",
  BracketRight: "]",
  Backslash: "\\",
  Semicolon: ";",
  Quote: "'",
  Comma: ",",
  Period: ".",
  Slash: "/",
  ArrowUp: "↑",
  ArrowDown: "↓",
  ArrowLeft: "←",
  ArrowRight: "→",
};
export const keyLabel = (key: string) =>
  legends[key] ??
  key
    .replace(/^(Key|Digit|Char:)/, "")
    .replace("Meta", "Command ")
    .replace("Alt", "Option ")
    .replace(/(Shift|Control)(Left|Right)/, "$1 $2");
