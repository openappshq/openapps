export type Key = [code: string, legend: string, width?: number];
import layout from "./layout.json";
export const rows = layout as Key[][];
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

export const keyPan = (code: string) => (positions.find((p) => p.code === code)?.x ?? 0.5) * 2 - 1;

export type InputSource = "keyboard" | "pointer" | "preview";
export function createInput() {
  const sources = {
    keyboard: new Set<string>(),
    pointer: new Set<string>(),
    preview: new Set<string>(),
  };
  const pressed = new Set<string>();
  const listeners = new Set<() => void>();
  const notify = () => listeners.forEach((listener) => listener());
  const pulses: string[] = [];
  return {
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    pressed,
    pulses,
    press(code: string, source: InputSource) {
      sources[source].add(code);
      if (pressed.has(code)) return false;
      pressed.add(code);
      if (pulses.length === 10) pulses.shift();
      pulses.push(code);
      notify();
      return true;
    },
    release(code: string, source: InputSource) {
      sources[source].delete(code);
      if (Object.values(sources).some((keys) => keys.has(code))) return false;
      const released = pressed.delete(code);
      if (released) notify();
      return released;
    },
    clear(source?: InputSource) {
      if (source) {
        for (const code of sources[source]) this.release(code, source);
      } else {
        sources.keyboard.clear();
        sources.pointer.clear();
        sources.preview.clear();
        pressed.clear();
        pulses.length = 0;
        notify();
      }
    },
  };
}
export type KeyboardInput = ReturnType<typeof createInput>;
