/** The updater's native status, and the one line Settings shows for it. */

export type UpdateSettings = {
  checkAutomatically: boolean;
  installAutomatically: boolean;
};

export type UpdateStatus = {
  revision: number;
  supported: boolean;
  configured: boolean;
  locationBlocked: boolean;
  /** A previous copy kept next to the app after an update failed and could not be undone. */
  backup: string | null;
  currentVersion: string;
  settings: UpdateSettings;
  phase:
    | "idle"
    | "checking"
    | "current"
    | "available"
    | "downloading"
    | "verifying"
    | "ready"
    | "error";
  available: { version: string; notes: string | null } | null;
  received: number;
  total: number | null;
  error: string | null;
  lastCheckedAt: number | null;
};

export const BREW_UPGRADE = "brew upgrade --cask openklack";

/** The one line under the update controls, from the native status. */
export function updateMessage(status: UpdateStatus | undefined): string {
  if (!status) return "Loading update settings…";
  if (!status.supported) return "Builds from source don’t include app updates.";
  if (!status.configured) return "This build isn’t set up for app updates.";
  if (status.locationBlocked) return "Move OpenKlack to Applications to enable updates.";
  switch (status.phase) {
    case "checking":
      return "Checking for updates…";
    case "current":
      return "You have the latest version.";
    case "available":
      return status.settings.installAutomatically
        ? "Downloading shortly…"
        : "Download it now, or update with Homebrew.";
    case "downloading":
      return `Downloading ${(status.received / 1_000_000).toFixed(1)} MB…`;
    case "verifying":
      return "Verifying the download…";
    case "ready":
      return "Update ready. It installs when OpenKlack quits or restarts.";
    case "error":
      return status.available ? "Could not download the update." : "Could not check for updates.";
    default:
      return status.settings.checkAutomatically
        ? "OpenKlack checks for updates once a day and tells you when one is available."
        : `Automatic checks are off. Update with ${BREW_UPGRADE}, or check now.`;
  }
}
