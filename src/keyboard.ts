import { defaultPackId, isPackId } from "./soundpacks";

export type Finish = "graphite" | "chalk" | "sage";
export type KeyVoice = { packId: string; volume: number };
export type Settings = {
  packId: string;
  finish: Finish;
  volume: number;
  releaseVolume: number;
  variation: boolean;
  overrides: Record<string, KeyVoice>;
};
export const defaults: Settings = {
  packId: defaultPackId,
  finish: "graphite",
  volume: 65,
  releaseVolume: 65,
  variation: true,
  overrides: {},
};
export const keyCodes = [
  ...Array.from("ABCDEFGHIJKLMNOPQRSTUVWXYZ", (letter) => "Key" + letter),
  ...Array.from("1234567890", (digit) => "Digit" + digit),
  "Space",
  "Enter",
  "Backspace",
  "Tab",
  "Escape",
  "CapsLock",
  "ShiftLeft",
  "ShiftRight",
  "ControlLeft",
  "ControlRight",
  "AltLeft",
  "AltRight",
  "MetaLeft",
  "MetaRight",
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
  ...Array.from({ length: 12 }, (_, i) => "F" + (i + 1)),
  "PrintScreen",
  "Delete",
  "Home",
  "End",
  "PageUp",
  "PageDown",
];
const legacy: Record<string, string> = {
  deep: "novelkeys-cream",
  crisp: defaultPackId,
  clicky: "cherry-mx-blue-pbt",
};
const percent = (value: unknown, fallback: number) =>
  typeof value === "number" && Number.isFinite(value)
    ? Math.min(100, Math.max(0, value))
    : fallback;
const record = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

export function readSettings(raw: string | null): Settings {
  try {
    const value: unknown = JSON.parse(raw ?? "null");
    if (!record(value)) return defaults;
    const overrides: Record<string, KeyVoice> = {};
    if (record(value.overrides))
      for (const [code, voice] of Object.entries(value.overrides)) {
        if (!keyCodes.includes(code)) continue;
        if (record(voice) && isPackId(voice.packId))
          overrides[code] = { packId: voice.packId, volume: percent(voice.volume, 100) };
        else if (typeof voice === "string" && Object.hasOwn(legacy, voice))
          overrides[code] = { packId: legacy[voice], volume: 100 };
      }
    return {
      packId: isPackId(value.packId)
        ? value.packId
        : typeof value.profile === "string" && Object.hasOwn(legacy, value.profile)
          ? legacy[value.profile]
          : defaults.packId,
      finish: ["graphite", "chalk", "sage"].includes(value.finish as string)
        ? (value.finish as Finish)
        : defaults.finish,
      volume: percent(value.volume, defaults.volume),
      releaseVolume: percent(value.releaseVolume, defaults.releaseVolume),
      variation: typeof value.variation === "boolean" ? value.variation : true,
      overrides,
    };
  } catch {
    return defaults;
  }
}
export const voiceForKey = (settings: Settings, code: string): KeyVoice =>
  settings.overrides[code] ?? { packId: settings.packId, volume: 100 };

export function keyLabel(code: string) {
  const labels: Record<string, string> = {
    MetaLeft: "⌘ Left",
    MetaRight: "⌘ Right",
    ControlLeft: "Ctrl Left",
    ControlRight: "Ctrl Right",
    AltLeft: "Option Left",
    AltRight: "Option Right",
    ShiftLeft: "Shift Left",
    ShiftRight: "Shift Right",
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
  return labels[code] ?? code.replace(/^(Key|Digit)/, "");
}

export type InputSource = "keyboard" | "pointer" | "preview";
export function createInput() {
  const sources = {
    keyboard: new Set<string>(),
    pointer: new Set<string>(),
    preview: new Set<string>(),
  };
  const pressed = new Set<string>();
  const pulses: string[] = [];
  return {
    pressed,
    pulses,
    press(code: string, source: InputSource) {
      sources[source].add(code);
      if (pressed.has(code)) return false;
      pressed.add(code);
      if (pulses.length === 10) pulses.shift();
      pulses.push(code);
      return true;
    },
    release(code: string, source: InputSource) {
      sources[source].delete(code);
      if (Object.values(sources).some((keys) => keys.has(code))) return false;
      return pressed.delete(code);
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
      }
    },
  };
}
export type KeyboardInput = ReturnType<typeof createInput>;

export function acceptsKeyboardEvent(event: KeyboardEvent) {
  if (!keyCodes.includes(event.code) || event.repeat || event.isComposing) return false;
  const target = event.target;
  if (!(target instanceof Element)) return true;
  if (target.closest('input, textarea, select, [contenteditable="true"], [role="dialog"]'))
    return false;
  const control = target.closest('button, [role="slider"], [role="radio"], [role="switch"]');
  return !(control && /^(Space|Enter|Arrow|Home|End|Page)/.test(event.code));
}
