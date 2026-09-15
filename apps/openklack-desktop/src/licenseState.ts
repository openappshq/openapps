/** The licensing runtime's view of this Mac, and the short labels derived from it. */

export type LicenseView = {
  revision: number;
  ready: boolean;
  environment: "test" | "live";
  state:
    | "unlicensed"
    | "trial"
    | "trialEnded"
    | "trialOffline"
    | "clockBehind"
    | "licensed"
    | "grace"
    | "checkRequired"
    | "revoked";
  daysLeft?: number;
  daysOffline?: number;
  coreFeature: boolean;
  clockChanged: boolean;
  journalUnreadable: boolean;
  trialStorageError: boolean;
  graceWarning: boolean;
  checking: boolean;
  lastSuccessAt: number | null;
  lastError: string | null;
  pendingKey: string | null;
  buyUrl: string;
  supportUrl: string;
};

/** "N days left", rounded up; the backend sends 0 in the final 24 hours. */
export function trialLeft(daysLeft = 0) {
  if (daysLeft < 1) return "less than a day left";
  return `${daysLeft} ${daysLeft === 1 ? "day" : "days"} left`;
}

export type LicensePill = {
  label: string;
  /** Sounds are off, or will be unless the user acts: the pill shows it as a warning. */
  warning: boolean;
};

/**
 * The pill in the window header, next to the sound button. Nothing while the license is still
 * being read, nothing once the Mac is licensed, and otherwise the same short reasons the menu
 * bar shows. Source builds have no license view and therefore no pill.
 */
export function licensePill(view: LicenseView | undefined): LicensePill | null {
  if (!view?.ready) return null;
  switch (view.state) {
    case "trial":
      return { label: `Free trial · ${trialLeft(view.daysLeft)}`, warning: false };
    case "trialEnded":
      return { label: "Trial ended", warning: true };
    case "trialOffline":
      return { label: "Connect to continue your free trial", warning: true };
    case "clockBehind":
      return { label: "Mac clock is behind", warning: true };
    case "checkRequired":
    case "revoked":
      return { label: "License needed", warning: true };
    case "grace":
      return view.graceWarning
        ? {
            label: `Connect within ${view.daysLeft ?? 0} ${view.daysLeft === 1 ? "day" : "days"}`,
            warning: true,
          }
        : null;
    default:
      return null;
  }
}
