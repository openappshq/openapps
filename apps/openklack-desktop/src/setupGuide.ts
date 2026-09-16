/** When the setup guide opens on its own, where it resumes, and how finishing it is remembered. */
import { trialLeft, type LicenseView } from "./licenseState";
import type { Preferences, Snapshot } from "./useDesktop";

/** The guide's steps, in order. A saved step is only ever one of these. */
export const SETUP_GUIDE_STEPS = ["Welcome", "Keyboard access", "Tips"] as const;
/** The step the floating drag-to-grant helper belongs to; it is taken down when this step is left. */
export const KEYBOARD_ACCESS_STEP = SETUP_GUIDE_STEPS.indexOf("Keyboard access");

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

/**
 * Where the guide starts: the step saved while it was unfinished, so the relaunch macOS asks for
 * after Input Monitoring is granted comes back to the same step. Welcome once the guide has been
 * finished or skipped, or when nothing usable was saved. Never past the last step.
 */
export function setupGuideStep(
  preferences: Pick<Preferences, "onboardingCompleted" | "onboardingStep">,
): number {
  if (preferences.onboardingCompleted) return 0;
  return clampStep(preferences.onboardingStep);
}

/** The preferences to save as the user moves through the guide; everything else is kept. */
export function withSetupGuideStep(preferences: Preferences, step: number): Preferences {
  const next: Preferences = { ...preferences, onboardingStep: clampStep(step) };
  // Welcome is the default, kept off the wire like every other untouched setting.
  if (next.onboardingStep === 0) delete next.onboardingStep;
  return next;
}

/**
 * The preferences to save once the guide is finished or skipped; everything else is kept. The
 * step is forgotten, so showing the guide again from Settings starts at Welcome.
 */
export function withSetupGuideCompleted(preferences: Preferences): Preferences {
  return withSetupGuideStep({ ...preferences, onboardingCompleted: true }, 0);
}

function clampStep(step: number | undefined): number {
  if (typeof step !== "number" || !Number.isInteger(step) || step < 0) return 0;
  return Math.min(step, SETUP_GUIDE_STEPS.length - 1);
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
      return "Your free trial has ended. Settings → License is where to buy a license or paste a key.";
    case "licensed":
    case "grace":
      return "This Mac is licensed.";
    default:
      return "Official builds include a free 3-day trial. Settings → License shows where it stands.";
  }
}

/**
 * The Keyboard access step's note under the permission line. Before the grant it points at the
 * list in System Settings and at the floating helper for when OpenKlack is missing from it;
 * after, at the relaunch macOS sometimes wants.
 */
export function guidePermissionNote(inputPermission: boolean): string {
  if (inputPermission)
    return "If the sounds don’t start right away, quit and reopen OpenKlack: macOS sometimes asks for that after the permission changes.";
  return "In System Settings, turn on OpenKlack in the list. Not in the list? Drag the icon from the floating window into it.";
}

/**
 * Whether the step offers to bring the floating helper back: only while there is something
 * to grant and the helper is not already on screen.
 */
export function offersPermissionHelper(inputPermission: boolean, helperVisible: boolean): boolean {
  return !inputPermission && !helperVisible;
}

/** What the guide says about Open at login: the real setting, or a pointer when it is unknown. */
export function guideLoginLine(openAtLogin: boolean | undefined): string {
  if (openAtLogin === true) return "OpenKlack opens at login. Change this in Settings.";
  if (openAtLogin === false)
    return "Turn on Open at login in Settings to have OpenKlack start with your Mac.";
  return "Open at login is in Settings.";
}
