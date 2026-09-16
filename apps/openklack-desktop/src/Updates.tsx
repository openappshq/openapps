import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Button, ProgressBar } from "@heroui/react";
import { Disclosure, Toggle } from "./controls";
import { Download, RefreshCw, RotateCw } from "lucide-react";
import { updateMessage, type UpdateSettings, type UpdateStatus } from "./updateStatus";

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

  const run = (command: string, args?: Record<string, unknown>) =>
    void invoke<UpdateStatus>(command, args)
      .then(accept)
      .catch((e: unknown) => onError(String(e)));
  const usable = !!status?.supported && status.configured;
  const working = !!status && ["checking", "downloading", "verifying"].includes(status.phase);
  const settings = status?.settings;
  const changeSettings = (change: Partial<UpdateSettings>) =>
    settings && run("set_update_settings", { settings: { ...settings, ...change } });

  return (
    <section className="app-updates" aria-label="App updates">
      {status?.available && status.phase !== "current" && (
        <h3>Version {status.available.version} is available</h3>
      )}
      {usable && settings && (
        <>
          <Toggle
            label="Check for updates automatically"
            description="Once a day and when OpenKlack opens. OpenKlack only checks and tells you; installing is your call unless the next switch is on."
            selected={settings.checkAutomatically}
            disabled={disabled}
            onChange={(checkAutomatically) => changeSettings({ checkAutomatically })}
          />
          <Toggle
            label="Download and install automatically"
            description="Downloads in the background and installs the next time OpenKlack quits or restarts. Off by default."
            selected={settings.installAutomatically}
            disabled={disabled}
            onChange={(installAutomatically) => changeSettings({ installAutomatically })}
          />
        </>
      )}
      <p role="status">{updateMessage(status)}</p>
      {status?.phase === "downloading" && (
        <ProgressBar
          className="update-progress"
          aria-label="Update download"
          isIndeterminate={!status.total}
          maxValue={status.total ?? 100}
          value={status.total ? Math.min(status.received, status.total) : 0}
        >
          <ProgressBar.Track>
            <ProgressBar.Fill />
          </ProgressBar.Track>
        </ProgressBar>
      )}
      {status?.error && (
        <p className="inline-error" role="alert">
          {status.error}
        </p>
      )}
      {status?.backup && (
        <p className="inline-error" role="alert">
          The last update could not be completed. A previous copy of OpenKlack is kept at{" "}
          {status.backup}; move it back to Applications if this version misbehaves.
        </p>
      )}
      {status?.available?.notes && (
        <Disclosure title="What’s new">
          <p className="update-notes">{status.available.notes}</p>
        </Disclosure>
      )}
      {usable && (
        <div className="actions">
          {status.phase === "ready" ? (
            <Button
              variant="primary"
              isDisabled={disabled}
              onPress={() =>
                void invoke("restart_to_update").catch((e: unknown) => onError(String(e)))
              }
            >
              <RotateCw size={15} /> Update ready — Restart
            </Button>
          ) : (
            <>
              <Button
                variant="secondary"
                isDisabled={disabled || working}
                onPress={() => run("check_for_updates")}
              >
                <RefreshCw size={15} /> Check now
              </Button>
              {status.available && !status.locationBlocked && (
                <Button
                  variant="primary"
                  isDisabled={disabled || working}
                  onPress={() => run("download_update")}
                >
                  <Download size={15} /> Download update
                </Button>
              )}
            </>
          )}
        </div>
      )}
    </section>
  );
}
