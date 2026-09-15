/** When the setup guide opens on its own, and how finishing it is remembered. */
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
