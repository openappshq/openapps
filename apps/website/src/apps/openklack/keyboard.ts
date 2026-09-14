import { keyCodes } from "@openklack/keyboard-layout";
export { keyCodes, keyLabel } from "@openklack/keyboard-layout";
import { defaultPackId, isPackId } from "./soundpacks";

export type Finish = "graphite" | "chalk" | "sage";
export type KeyVoice = { packId: string; volume: number };
export type Settings = {
  packId: string;
  favoritePackIds: string[];
  finish: Finish;
  volume: number;
  releaseVolume: number;
  variation: boolean;
  tone: number;
  pitch: number;
  width: number;
  lighting: boolean;
  overrides: Record<string, KeyVoice>;
};
export const defaults: Settings = {
  packId: defaultPackId,
  favoritePackIds: [],
  finish: "graphite",
  volume: 65,
  releaseVolume: 65,
  variation: true,
  tone: 0,
  pitch: 0,
  width: 0,
  lighting: true,
  overrides: {},
};
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
    return {
      ...defaults,
      packId: isPackId(value.packId)
        ? value.packId
        : typeof value.profile === "string" && Object.hasOwn(legacy, value.profile)
          ? legacy[value.profile]
          : defaults.packId,
      volume: percent(value.volume, defaults.volume),
      favoritePackIds: Array.isArray(value.favoritePackIds)
        ? [...new Set(value.favoritePackIds.filter(isPackId))]
        : [],
    };
  } catch {
    return defaults;
  }
}
export const voiceForKey = (settings: Settings, code: string): KeyVoice =>
  settings.overrides[code] ?? { packId: settings.packId, volume: 100 };

export { createInput, type InputSource, type KeyboardInput } from "@openklack/keyboard-layout";

export function acceptsKeyboardEvent(event: KeyboardEvent) {
  if (!keyCodes.includes(event.code) || event.repeat || event.isComposing) return false;
  const target = event.target;
  if (!(target instanceof Element)) return true;
  if (target.matches("[data-sound-input]")) return true;
  if (target.closest('input, textarea, select, [contenteditable="true"], [role="dialog"]'))
    return false;
  const control = target.closest('button, [role="slider"], [role="radio"], [role="switch"]');
  return !(control && /^(Space|Enter|Arrow|Home|End|Page)/.test(event.code));
}
