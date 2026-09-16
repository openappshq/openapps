import { expect, test } from "vite-plus/test";
import { BREW_UPGRADE, updateMessage, type UpdateStatus } from "./updateStatus";

/** Automatic checks off: an upgrade that kept the old default, or a user who turned them off. */
const checksOff: UpdateStatus = {
  revision: 0,
  supported: true,
  configured: true,
  locationBlocked: false,
  backup: null,
  currentVersion: "0.1.0",
  settings: { checkAutomatically: false, installAutomatically: false },
  phase: "idle",
  available: null,
  received: 0,
  total: null,
  error: null,
  lastCheckedAt: null,
};

test("with automatic checks off the app points at Homebrew and Check now", () => {
  expect(updateMessage(checksOff)).toContain("Automatic checks are off");
  expect(updateMessage(checksOff)).toContain(BREW_UPGRADE);
  expect(updateMessage(checksOff)).toContain("check now");
});

test("with automatic checks on (the fresh-install default) the app only checks and tells", () => {
  const checking = {
    ...checksOff,
    settings: { checkAutomatically: true, installAutomatically: false },
  };
  expect(updateMessage(checking)).toBe(
    "OpenKlack checks for updates once a day and tells you when one is available.",
  );
  // A found update is the user's to install unless automatic installs are on.
  expect(updateMessage({ ...checking, phase: "available" })).toBe(
    "Download it now, or update with Homebrew.",
  );
  expect(
    updateMessage({
      ...checking,
      phase: "available",
      settings: { checkAutomatically: true, installAutomatically: true },
    }),
  ).toBe("Downloading shortly…");
});

test("source builds, unconfigured builds and blocked locations explain why updates are unavailable", () => {
  expect(updateMessage({ ...checksOff, supported: false })).toBe(
    "Builds from source don’t include app updates.",
  );
  expect(updateMessage({ ...checksOff, configured: false })).toBe(
    "This build isn’t set up for app updates.",
  );
  expect(updateMessage({ ...checksOff, locationBlocked: true, phase: "ready" })).toBe(
    "Move OpenKlack to Applications to enable updates.",
  );
});

test("a staged update installs on the next quit or restart", () => {
  expect(updateMessage({ ...checksOff, phase: "ready" })).toBe(
    "Update ready. It installs when OpenKlack quits or restarts.",
  );
});
