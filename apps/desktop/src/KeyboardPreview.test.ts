import { expect, test } from "vite-plus/test";
import { neighboringKey, keyLabel } from "@openklack/keyboard-layout";
import fixture from "../fixtures/preferences-v1.json";
import type { Preferences } from "./useDesktop";

test("keyboard navigation follows staggered rows and the wide spacebar", () => {
  expect(neighboringKey("KeyA", "ArrowUp")).toBe("KeyQ");
  expect(neighboringKey("Space", "ArrowUp")).toBe("KeyB");
  expect(neighboringKey("Escape", "ArrowUp")).toBe("Escape");
  expect(neighboringKey("MetaLeft", "ArrowRight")).toBe("Space");
});

test("native settings assignments have readable logical key labels", () => {
  const preferences: Preferences = fixture;
  expect(Object.keys(preferences.presets[0]!.overrides).map(keyLabel)).toEqual(["Space", "å"]);
});
