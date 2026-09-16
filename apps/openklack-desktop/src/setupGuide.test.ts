import { expect, test } from "vite-plus/test";
import fixture from "../fixtures/preferences-v1.json";
import {
  guideLicenseLine,
  guideLoginLine,
  guidePermissionNote,
  offersPermissionHelper,
  offersSetupGuide,
  SETUP_GUIDE_STEPS,
  setupGuideStep,
  withSetupGuideCompleted,
  withSetupGuideStep,
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

test("the guide starts at Welcome until a step has been saved", () => {
  expect(setupGuideStep(preferences)).toBe(0);
  expect(setupGuideStep({ onboardingStep: undefined })).toBe(0);
});

test("moving through the guide is saved without touching anything else", () => {
  const midway = withSetupGuideStep(preferences, 1);
  expect(midway.onboardingStep).toBe(1);
  expect({ ...midway, onboardingStep: undefined }).toEqual({
    ...preferences,
    onboardingStep: undefined,
  });
  expect(preferences.onboardingStep).toBeUndefined();
  // The relaunch macOS asks for after Input Monitoring is granted comes back to that step.
  expect(setupGuideStep(midway)).toBe(1);
  // Back to Welcome is the default again, kept off the wire like an untouched setting.
  expect(withSetupGuideStep(midway, 0)).toEqual(preferences);
  expect("onboardingStep" in withSetupGuideStep(midway, 0)).toBe(false);
});

test("a saved step never lands past the last step or on nonsense", () => {
  const last = SETUP_GUIDE_STEPS.length - 1;
  expect(setupGuideStep({ onboardingStep: 99 })).toBe(last);
  expect(withSetupGuideStep(preferences, 99).onboardingStep).toBe(last);
  expect(setupGuideStep({ onboardingStep: -1 })).toBe(0);
  expect(setupGuideStep({ onboardingStep: 1.5 })).toBe(0);
  expect(setupGuideStep({ onboardingStep: Number.NaN })).toBe(0);
});

test("finishing the guide forgets the step, so Settings shows it again from Welcome", () => {
  const completed = withSetupGuideCompleted(withSetupGuideStep(preferences, 2));
  expect(completed.onboardingCompleted).toBe(true);
  expect("onboardingStep" in completed).toBe(false);
  expect(setupGuideStep(completed)).toBe(0);
  expect(setupGuideStep({ onboardingCompleted: true, onboardingStep: 2 })).toBe(0);
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

test("the permission note points at the list and the floating helper until the grant", () => {
  expect(guidePermissionNote(false)).toBe(
    "In System Settings, turn on OpenKlack in the list. Not in the list? Drag the icon from the floating window into it.",
  );
  expect(guidePermissionNote(true)).toContain("quit and reopen OpenKlack");
  expect(guidePermissionNote(true)).not.toContain("floating window");
});

test("the helper is offered again only while it is away and there is something to grant", () => {
  expect(offersPermissionHelper(false, false)).toBe(true);
  expect(offersPermissionHelper(false, true)).toBe(false);
  expect(offersPermissionHelper(true, false)).toBe(false);
  expect(offersPermissionHelper(true, true)).toBe(false);
});

test("the guide describes Open at login as it really is", () => {
  expect(guideLoginLine(true)).toBe("OpenKlack opens at login. Change this in Settings.");
  expect(guideLoginLine(false)).toContain("Turn on Open at login");
  expect(guideLoginLine(undefined)).toBe("Open at login is in Settings.");
});
