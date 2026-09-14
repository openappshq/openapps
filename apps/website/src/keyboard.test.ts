/// <reference types="node" />
import { existsSync } from "node:fs";
import { expect, test } from "vite-plus/test";
import { createInput, defaults, readSettings, voiceForKey } from "./keyboard";
import { getPack, sampleFor, soundpacks } from "./soundpacks";

test("physical, pointer and preview holds remain independent and repeats do not retrigger", () => {
  const input = createInput();
  expect(input.press("KeyA", "keyboard")).toBe(true);
  expect(input.press("KeyA", "keyboard")).toBe(false);
  expect(input.press("KeyA", "pointer")).toBe(false);
  expect(input.press("KeyA", "preview")).toBe(false);
  expect(input.pulses).toEqual(["KeyA"]);
  input.clear("preview");
  expect(input.release("KeyA", "pointer")).toBe(false);
  expect(input.pressed.has("KeyA")).toBe(true);
  input.clear("keyboard");
  expect(input.pressed.size).toBe(0);
  input.press("Space", "keyboard");
  input.clear();
  expect(input.pressed.size).toBe(0);
  expect(input.pulses).toEqual([]);
});

test("the simple demo restores volume and valid stars, with no hidden legacy key overrides", () => {
  const settings = readSettings(
    JSON.stringify({
      packId: "drop-holy-panda",
      volume: 500,
      tone: 50,
      pitch: 2,
      overrides: { Space: { packId: "cherry-mx-blue-pbt", volume: 45 } },
      favoritePackIds: ["cherry-mx-blue-pbt", "invalid", "cherry-mx-blue-pbt", null],
    }),
  );
  expect(settings.volume).toBe(100);
  expect(settings.favoritePackIds).toEqual(["cherry-mx-blue-pbt"]);
  expect(settings.overrides).toEqual({});
  expect(settings.tone).toBe(0);
  expect(voiceForKey(settings, "Space")).toEqual({ packId: "drop-holy-panda", volume: 100 });
  expect(readSettings(JSON.stringify(settings))).toEqual(settings);
  expect(readSettings("{")).toEqual(defaults);
  expect(readSettings('{"profile":"deep"}').packId).toBe("novelkeys-cream");
});

test("all 18 packs retain real sample regions, per-key mappings and release semantics", () => {
  expect(soundpacks).toHaveLength(18);
  expect(soundpacks.reduce((count, pack) => count + pack.sampleCount, 0)).toBe(793);
  for (const pack of soundpacks) {
    for (const extension of ["ogg", "mp3"])
      expect(
        existsSync(
          new URL(`../../../packages/soundpacks/sounds/${pack.id}.${extension}`, import.meta.url),
        ),
      ).toBe(true);
    expect(pack.license.type).toBe("MIT");
    expect(Object.keys(pack.sprite)).toHaveLength(pack.sampleCount);
    for (const region of Object.values(pack.sprite)) {
      expect(region).toHaveLength(2);
      expect(region[0]).toBeGreaterThanOrEqual(0);
      expect(region[1]).toBeGreaterThan(0);
    }
    for (const events of Object.values(pack.sounds))
      for (const sample of [...events.down, ...events.up])
        expect(pack.sprite[sample]).toBeDefined();
    expect(Object.values(pack.sounds).some((events) => events.up.length > 0)).toBe(
      pack.supportsKeyUp,
    );
  }
  const cherry = getPack("cherry-mx-brown-pbt");
  expect(sampleFor(cherry, "KeyA", true)).toBe("30.wav");
  expect(sampleFor(cherry, "Backspace", true)).toBe("14.wav");
  expect(sampleFor(cherry, "Space", false)).toBeUndefined();
  expect(cherry.sounds.MetaLeft.down).toHaveLength(2);
  const panda = getPack("drop-holy-panda");
  expect(sampleFor(panda, "Backspace", true)).toBe("401.wav");
  expect(sampleFor(panda, "Backspace", false)).toBe("451.wav");
  expect(sampleFor(panda, "KeyA", true, true, () => 0.9)).toBe("5.wav");
  expect(sampleFor(panda, "KeyA", true, false, () => 0.9)).toBe("1.wav");
  expect(
    sampleFor(
      { ...panda, sounds: { ...panda.sounds, KeyA: { down: ["1.wav"], up: [] } } },
      "KeyA",
      false,
    ),
  ).toBeUndefined();
});
