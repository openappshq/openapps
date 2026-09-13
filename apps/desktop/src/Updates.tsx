import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Button } from "@heroui/react";
import { Download, RefreshCw } from "lucide-react";

type UpdateStatus = {
  revision: number;
  configured: boolean;
  currentVersion: string;
  phase:
    | "idle"
    | "checking"
    | "available"
    | "current"
    | "downloading"
    | "verifying"
    | "installing"
    | "restarting"
    | "error";
  available: { version: string; notes: string | null } | null;
  received: number;
  total: number | null;
  error: string | null;
};

export function Updates({
  onError,
  disabled,
}: {
  onError: (error: string) => void;
  disabled: boolean;
}) {
  const [status, setStatus] = useState<UpdateStatus>();
  const accept = useCallback((next: UpdateStatus) => {
    setStatus((current) => (current && current.revision > next.revision ? current : next));
  }, []);
  useEffect(() => {
    let disposed = false;
    let off: (() => void) | undefined;
    async function subscribe() {
      off = await listen<UpdateStatus>("app-update", ({ payload }) => {
        if (!disposed) accept(payload);
      });
      if (disposed) {
        off();
        return;
      }
      const current = await invoke<UpdateStatus>("updater_status");
      if (!disposed) accept(current);
    }
    void subscribe().catch((error: unknown) => {
      if (!disposed) onError(String(error));
    });
    return () => {
      disposed = true;
      off?.();
    };
  }, [accept, onError]);

  const working =
    status &&
    ["checking", "downloading", "verifying", "installing", "restarting"].includes(status.phase);
  const messages: Record<string, string> = {
    idle: "Check when you want. Updates are never installed automatically.",
    checking: "Checking for updates…",
    current: "You have the latest version.",
    available: "OpenKlack will restart after installation. Your saved presets stay on this Mac.",
    downloading: `Downloading ${((status?.received ?? 0) / 1_000_000).toFixed(1)} MB…`,
    verifying: "Verifying the download…",
    installing: "Installing the update…",
    restarting: "Restarting OpenKlack…",
    error: status?.available
      ? "Could not finish installing the update."
      : "Could not check for updates.",
  };
  return (
    <>
      <div className="section-heading">
        <div>
          <h2>App updates</h2>
          <p>
            {status ? `OpenKlack ${status.currentVersion}` : "Check manually. Install when ready."}
          </p>
        </div>
      </div>
      <section className="settings-panel diagnostics-panel" aria-label="App updates">
        {status?.available && <h3>Version {status.available.version} is available</h3>}
        <p role="status">
          {!status
            ? "Loading update settings…"
            : status.configured
              ? messages[status.phase]
              : "This build does not include an update service."}
        </p>
        {status?.phase === "downloading" && (
          <progress
            className="update-progress"
            aria-label="Update download"
            max={status.total ?? undefined}
            value={status.total ? Math.min(status.received, status.total) : undefined}
          />
        )}
        {status?.error && (
          <p className="inline-error" role="alert">
            {status.error}
          </p>
        )}
        {status?.available?.notes && (
          <details>
            <summary>What’s new</summary>
            <p className="update-notes">{status.available.notes}</p>
          </details>
        )}
        <div className="actions">
          <Button
            variant="secondary"
            isDisabled={disabled || !!working || !status?.configured}
            onPress={() =>
              void invoke<UpdateStatus>("check_for_updates")
                .then(accept)
                .catch((e: unknown) => onError(String(e)))
            }
          >
            <RefreshCw size={15} /> Check for updates
          </Button>
          {status?.available && (
            <Button
              variant="primary"
              isDisabled={disabled || !!working}
              onPress={() =>
                void invoke<UpdateStatus>("install_update", { version: status.available!.version })
                  .then(accept)
                  .catch((e: unknown) => onError(String(e)))
              }
            >
              <Download size={15} /> Download and install
            </Button>
          )}
        </div>
      </section>
    </>
  );
}
