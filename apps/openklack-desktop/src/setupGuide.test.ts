import { expect, test } from "vite-plus/test";
import fixture from "../fixtures/preferences-v1.json";
import {
  guideLicenseLine,
  guideLoginLine,
  offersSetupGuide,
  withSetupGuideCompleted,
} from "./setupGuide";
import type { LicenseView } from "./licenseState";
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

const view = (patch: Partial<LicenseView>): LicenseView => ({
  revision: 1,
  ready: true,
  environment: "live",
  state: "trial",
  daysLeft: 3,
  coreFeature: true,
  clockChanged: false,
  journalUnreadable: false,
  trialStorageError: false,
  graceWarning: false,
  checking: false,
  lastSuccessAt: null,
  lastError: null,
  pendingKey: null,
  buyUrl: "",
  supportUrl: "",
  ...patch,
});

test("the guide only claims the trial state the license view reports", () => {
  expect(guideLicenseLine(view({ daysLeft: 3 }))).toBe(
    "Your free trial is running, with 3 days left. No signup needed.",
  );
  expect(guideLicenseLine(view({ daysLeft: 0 }))).toContain("less than a day left");
  expect(guideLicenseLine(view({ state: "trialEnded", coreFeature: false }))).toContain(
    "has ended",
  );
  expect(guideLicenseLine(view({ state: "licensed" }))).toBe("This Mac is licensed.");
  expect(guideLicenseLine(view({ state: "grace" }))).toBe("This Mac is licensed.");
  expect(guideLicenseLine(view({ state: "checkRequired", coreFeature: false }))).toContain(
    "shows where it stands",
  );
  expect(guideLicenseLine(view({ ready: false }))).toBeNull();
  expect(guideLicenseLine(undefined)).toBeNull();
});

test("the guide describes Open at login as it really is", () => {
  expect(guideLoginLine(true)).toBe("OpenKlack opens at login. Change this in Settings.");
  expect(guideLoginLine(false)).toContain("Turn on Open at login");
  expect(guideLoginLine(undefined)).toBe("Open at login is in Settings.");
});
