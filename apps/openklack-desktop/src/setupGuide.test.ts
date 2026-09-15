import { expect, test } from "vite-plus/test";
import fixture from "../fixtures/preferences-v1.json";
import { offersSetupGuide, withSetupGuideCompleted } from "./setupGuide";
import type { Preferences } from "./useDesktop";

const preferences: Preferences = fixture;

test("an official build offers the guide until it has been completed or skipped", () => {
  expect(offersSetupGuide({ licensingEnabled: true, preferences })).toBe(true);
  expect(
    offersSetupGuide({ licensingEnabled: true, preferences: withSetupGuideCompleted(preferences) }),
  ).toBe(false);
});

test("a build from source never opens the guide on its own", () => {
  expect(offersSetupGuide({ licensingEnabled: false, preferences })).toBe(false);
});

test("completing the guide is saved in the preferences without touching anything else", () => {
  const completed = withSetupGuideCompleted(preferences);
  expect(completed.onboardingCompleted).toBe(true);
  expect({ ...completed, onboardingCompleted: undefined }).toEqual({
    ...preferences,
    onboardingCompleted: undefined,
  });
  expect(preferences.onboardingCompleted).toBeUndefined();
});
