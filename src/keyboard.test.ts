import { expect, test } from "vite-plus/test";
import sprite from "./sound-sprite.json";
import { createInput, defaults, profileForKey, readSettings } from "./keyboard";

test("typing survives repeat, overlapping input, blur, and saved per-key overrides", () => {
  const input = createInput();
  expect(input.press("KeyA", "keyboard")).toBe(true);
  expect(input.press("KeyA", "keyboard")).toBe(false);
  expect(input.press("KeyA", "pointer")).toBe(false);
  expect(input.pulses).toEqual(["KeyA"]);
  expect(input.release("KeyA", "pointer")).toBe(false);
  expect(input.pressed.has("KeyA")).toBe(true);
  input.clear("keyboard");
  expect(input.pressed.size).toBe(0);
  input.press("Space", "keyboard");
  input.clear();
  expect(input.pressed.size).toBe(0);
  expect(input.pulses).toEqual([]);

  const settings = readSettings(
    JSON.stringify({
      profile: "deep",
      finish: "sage",
      volume: 500,
      overrides: { Space: "clicky", KeyA: "invalid", Unknown: "crisp" },
    }),
  );
  expect(settings.volume).toBe(100);
  expect(settings.overrides).toEqual({ Space: "clicky" });
  expect(profileForKey(settings, "Space")).toBe("clicky");
  expect(profileForKey(settings, "KeyA")).toBe("deep");
  expect(readSettings("{")).toEqual(defaults);
  expect(readSettings(JSON.stringify(settings))).toEqual(settings);

  for (const ranges of Object.values(sprite))
    for (const [start, end] of ranges) {
      expect(start).toBeGreaterThanOrEqual(0);
      expect(end).toBeGreaterThan(start);
      expect(end).toBeLessThanOrEqual(18300);
    }
});
