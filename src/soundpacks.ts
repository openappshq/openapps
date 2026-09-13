import catalog from "./soundpacks.json";

export type SoundPack = {
  id: string;
  name: string;
  brand: string;
  kind: "Linear" | "Tactile" | "Clicky";
  description: string;
  color: string;
  author: string;
  supportsKeyUp: boolean;
  sampleCount: number;
  source: string;
  sourceId: string;
  license: { type: string; url: string };
  sprite: Record<string, [number, number]>;
  sounds: Record<string, { down: string[]; up: string[] }>;
};
export const soundpacks = catalog as unknown as SoundPack[];
export const defaultPackId = "cherry-mx-brown-pbt";
const byId = new Map(soundpacks.map((pack) => [pack.id, pack]));
export const isPackId = (value: unknown): value is string =>
  typeof value === "string" && byId.has(value);
export const getPack = (id: string) => byId.get(id) ?? byId.get(defaultPackId)!;
export const packLabel = (id: string) => {
  const pack = getPack(id);
  return `${pack.brand} ${pack.name}`;
};

export function sampleFor(
  pack: SoundPack,
  code: string,
  down: boolean,
  vary = true,
  random = Math.random,
) {
  const phase = down ? "down" : "up";
  const samples = (pack.sounds[code] ?? pack.sounds.default)[phase];
  if (!samples.length) return;
  return samples[vary ? Math.floor(random() * samples.length) : 0];
}
