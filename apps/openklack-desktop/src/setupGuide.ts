/** When the setup guide opens on its own, and how finishing it is remembered. */
import { trialLeft, type LicenseView } from "./licenseState";
import type { Preferences, Snapshot } from "./useDesktop";

/**
 * Official builds show the guide once, on first launch, until it is finished or skipped. A
 * build from source has no trial to explain and never opens it on its own; Settings can still
 * show it.
 */
export function offersSetupGuide(
  snapshot: Pick<Snapshot, "licensingEnabled" | "preferences">,
): boolean {
  return snapshot.licensingEnabled && !snapshot.preferences.onboardingCompleted;
}

/** The preferences to save once the guide is finished or skipped; everything else is kept. */
export function withSetupGuideCompleted(preferences: Preferences): Preferences {
  return { ...preferences, onboardingCompleted: true };
}

/**
 * What the guide says about the trial: only what the license view actually reports. Nothing
 * while the view is missing (a source build) or not read yet.
 */
export function guideLicenseLine(view: LicenseView | undefined): string | null {
  if (!view?.ready) return null;
  switch (view.state) {
    case "trial":
      return `Your free trial is running, with ${trialLeft(view.daysLeft)}. No signup needed.`;
    case "trialEnded":
      return "Your free trial has ended. Settings → License is where to buy for $5 or paste a key.";
    case "licensed":
    case "grace":
      return "This Mac is licensed.";
    default:
      return "Official builds include a free 3-day trial. Settings → License shows where it stands.";
  }
}

/** What the guide says about Open at login: the real setting, or a pointer when it is unknown. */
export function guideLoginLine(openAtLogin: boolean | undefined): string {
  if (openAtLogin === true) return "OpenKlack opens at login. Change this in Settings.";
  if (openAtLogin === false)
    return "Turn on Open at login in Settings to have OpenKlack start with your Mac.";
  return "Open at login is in Settings.";
}
