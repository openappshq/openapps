import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button } from "@heroui/react";
import { Download, RefreshCw } from "lucide-react";
import { Toggle } from "./controls";
import { Updates } from "./Updates";
import type { Desktop } from "./useDesktop";

export function General({ desktop }: { desktop: Desktop }) {
  const { setError } = desktop;
  const [startup, setStartup] = useState<boolean>();
  const [report, setReport] = useState("");
  const [exported, setExported] = useState(false);
  useEffect(() => {
    let disposed = false;
    void invoke<boolean>("startup_state")
      .then((enabled) => {
        if (!disposed) setStartup(enabled);
      })
      .catch((e: unknown) => {
        if (!disposed) setError(String(e));
      });
    return () => {
      disposed = true;
    };
  }, [setError]);
  return (
    <section className="general-settings">
      <div className="section-heading">
        <div>
          <h1>General</h1>
          <p>A small utility. At home on your Mac.</p>
        </div>
      </div>
      <div className="settings-panel">
        <Toggle
          label="Open at login"
          description="Start quietly in the menu bar. Your settings window stays closed."
          selected={startup ?? false}
          disabled={desktop.busy || startup === undefined}
          onChange={(enabled) =>
            void desktop.perform(async () =>
              setStartup(await invoke<boolean>("startup_state", { enabled })),
            )
          }
        />
      </div>
      <Updates onError={setError} disabled={desktop.busy} />
      <div className="section-heading">
        <div>
          <h2>Local diagnostics</h2>
          <p>Review what you share. Nothing is sent automatically.</p>
        </div>
      </div>
      <div className="settings-panel diagnostics-panel">
        <p>
          This report contains engine status, memory used by sounds, and aggregate timing and input
          counts since launch. It excludes typed text, key identities, app names, and file paths.
        </p>
        <p>
          Timing measures delivery to the audio callback. It does not measure speaker or Bluetooth
          latency. Muting, silent clips, and canceled sounds can make input and playback totals
          differ.
        </p>
        <div className="actions">
          <Button
            variant="secondary"
            isDisabled={desktop.busy}
            onPress={() =>
              void desktop.perform(async () => {
                setReport(await invoke<string>("get_diagnostics"));
                setExported(false);
              })
            }
          >
            <RefreshCw size={15} />
            {report ? "Refresh report" : "Prepare report"}
          </Button>
          {report && (
            <Button
              variant="secondary"
              isDisabled={desktop.busy}
              onPress={() =>
                void desktop.perform(async () => {
                  if (await invoke<boolean>("export_diagnostics", { report })) setExported(true);
                })
              }
            >
              <Download size={15} />
              Save reviewed report
            </Button>
          )}
        </div>
        {report && (
          <label className="diagnostics-report">
            Report contents
            <textarea readOnly value={report} rows={18} spellCheck={false} />
          </label>
        )}
        {exported && (
          <p role="status">The reviewed report is saved. You can attach it to an issue yourself.</p>
        )}
      </div>
      <div className="quiet-note">
        <p>Free and open source · macOS 14 or later</p>
      </div>
    </section>
  );
}
