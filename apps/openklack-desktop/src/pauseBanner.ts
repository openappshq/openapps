/** The pauses a temporary resume can override; the others always win. */
export const RESUMABLE_REASONS = [
  "Paused for this app",
  "Microphone in use",
  "Checking microphone activity",
];

/**
 * The banner's line while a temporary resume keeps playback on. `reason` is what the resume
 * overrides, as reported by the engine; `appName` is the muted app's name from its rule.
 */
export function resumedBannerText(reason: string, appName?: string): string {
  if (reason === "Paused for this app") return `Playing in ${appName?.trim() || "this app"} anyway`;
  return "Playing while the microphone is in use";
}
