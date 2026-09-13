import sprite from "./sound-sprite.json";

export const profiles = {
  deep: { label: "Deep", description: "Low, warm, and rounded.", rate: 0.82, frequency: 2400 },
  crisp: { label: "Crisp", description: "Clean, bright, and balanced.", rate: 1, frequency: 9500 },
  clicky: {
    label: "Clicky",
    description: "Light, sharp, and lively.",
    rate: 1.24,
    frequency: 18000,
  },
} as const;
export type Profile = keyof typeof profiles;
export type Finish = "graphite" | "chalk" | "sage";
export type Settings = {
  profile: Profile;
  finish: Finish;
  volume: number;
  overrides: Record<string, Profile>;
};
export const defaults: Settings = {
  profile: "deep",
  finish: "graphite",
  volume: 65,
  overrides: {},
};
export const keyCodes = [
  ...new Set([...Object.keys(sprite), "MetaLeft", "MetaRight", "ControlRight", "AltRight"]),
];
export const isProfile = (value: unknown): value is Profile =>
  typeof value === "string" && Object.hasOwn(profiles, value);

export function readSettings(raw: string | null): Settings {
  try {
    const value = JSON.parse(raw ?? "null");
    if (!value || typeof value !== "object") return defaults;
    return {
      profile: isProfile(value.profile) ? value.profile : defaults.profile,
      finish: ["graphite", "chalk", "sage"].includes(value.finish) ? value.finish : defaults.finish,
      volume:
        typeof value.volume === "number" && Number.isFinite(value.volume)
          ? Math.max(0, Math.min(100, value.volume))
          : defaults.volume,
      overrides: Object.fromEntries(
        Object.entries(value.overrides ?? {}).filter(
          ([code, profile]) => keyCodes.includes(code) && isProfile(profile),
        ),
      ),
    } as Settings;
  } catch {
    return defaults;
  }
}

export const profileForKey = (settings: Settings, code: string) =>
  settings.overrides[code] ?? settings.profile;
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

export type InputSource = "keyboard" | "pointer";
export function createInput() {
  const sources = { keyboard: new Set<string>(), pointer: new Set<string>() };
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
      if (sources.keyboard.has(code) || sources.pointer.has(code)) return false;
      return pressed.delete(code);
    },
    clear(source?: InputSource) {
      if (source) {
        for (const code of sources[source]) this.release(code, source);
      } else {
        sources.keyboard.clear();
        sources.pointer.clear();
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
