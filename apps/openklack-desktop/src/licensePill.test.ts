import { expect, test } from "vite-plus/test";
import { licensePill, trialLeft, type LicenseView } from "./licenseState";

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
  buyUrl: "https://example.com/buy",
  supportUrl: "https://example.com/support",
  ...patch,
});

test("a running trial counts the days down to less than a day", () => {
  expect(licensePill(view({ daysLeft: 3 }))).toEqual({
    label: "Free trial · 3 days left",
    warning: false,
  });
  expect(licensePill(view({ daysLeft: 1 }))?.label).toBe("Free trial · 1 day left");
  expect(licensePill(view({ daysLeft: 0 }))?.label).toBe("Free trial · less than a day left");
  expect(trialLeft(undefined)).toBe("less than a day left");
});

test("states that stop or threaten sounds use the menu bar's short reasons as warnings", () => {
  expect(licensePill(view({ state: "trialEnded", coreFeature: false }))).toEqual({
    label: "Trial ended",
    warning: true,
  });
  expect(licensePill(view({ state: "trialOffline", coreFeature: false }))?.label).toBe(
    "Connect to continue your free trial",
  );
  expect(licensePill(view({ state: "clockBehind", coreFeature: false }))?.label).toBe(
    "Mac clock is behind",
  );
  expect(licensePill(view({ state: "checkRequired", coreFeature: false }))?.label).toBe(
    "License needed",
  );
  expect(licensePill(view({ state: "revoked", coreFeature: false }))).toEqual({
    label: "License needed",
    warning: true,
  });
  expect(licensePill(view({ state: "grace", graceWarning: true, daysLeft: 2 }))).toEqual({
    label: "Connect within 2 days",
    warning: true,
  });
});

test("licensed Macs, quiet grace, unread licenses and source builds show no pill", () => {
  expect(licensePill(view({ state: "licensed" }))).toBeNull();
  expect(licensePill(view({ state: "grace", graceWarning: false }))).toBeNull();
  expect(licensePill(view({ state: "unlicensed" }))).toBeNull();
  expect(licensePill(view({ ready: false }))).toBeNull();
  expect(licensePill(undefined)).toBeNull();
});
