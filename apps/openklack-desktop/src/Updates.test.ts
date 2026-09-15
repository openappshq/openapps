import { expect, test } from "vite-plus/test";
import { BREW_UPGRADE, updateMessage, type UpdateStatus } from "./updateStatus";

const fresh: UpdateStatus = {
  revision: 0,
  supported: true,
  configured: true,
  locationBlocked: false,
  currentVersion: "0.1.0",
  settings: { checkAutomatically: false, installAutomatically: false },
  phase: "idle",
  available: null,
  received: 0,
  total: null,
  error: null,
  lastCheckedAt: null,
};

test("a fresh install says automatic updates are off and points at Homebrew", () => {
  expect(updateMessage(fresh)).toContain("Automatic updates are off");
  expect(updateMessage(fresh)).toContain(BREW_UPGRADE);
});

test("source builds, unconfigured builds and blocked locations explain why updates are unavailable", () => {
  expect(updateMessage({ ...fresh, supported: false })).toBe(
    "Builds from source don’t include app updates.",
  );
  expect(updateMessage({ ...fresh, configured: false })).toBe(
    "This build isn’t set up for app updates.",
  );
  expect(updateMessage({ ...fresh, locationBlocked: true, phase: "ready" })).toBe(
    "Move OpenKlack to Applications to enable updates.",
  );
});

test("a staged update installs on the next quit or restart", () => {
  expect(updateMessage({ ...fresh, phase: "ready" })).toBe(
    "Update ready. It installs when OpenKlack quits or restarts.",
  );
});
