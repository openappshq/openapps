import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button } from "@heroui/react";
import { Download, RefreshCw } from "lucide-react";
import { Level, Toggle } from "./controls";
import { Updates } from "./Updates";
import type { Desktop } from "./useDesktop";

export function General({
  desktop,
  theme,
  onThemeChange,
}: {
  desktop: Desktop;
  theme: string;
  onThemeChange: (theme: string) => void;
}) {
  const snapshot = desktop.snapshot!;
  const preset = snapshot.preferences.presets.find(
    (p) => p.id === snapshot.preferences.activePresetId,
  )!;
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
          <h1>Settings</h1>
          <p>A small utility. At home on your Mac.</p>
        </div>
      </div>
      <div className="settings-panel">
        <div className="section-heading">
          <div>
            <h2>Make yourself at home</h2>
            <p>One identity, in your light.</p>
          </div>
        </div>
        <div className="appearance-options" role="group" aria-label="Appearance">
          {["system", "light", "dark"].map((mode) => (
            <Button
              key={mode}
              variant="secondary"
              aria-pressed={theme === mode}
              onPress={() => onThemeChange(mode)}
            >
              <span className={`theme-swatch ${mode}`} aria-hidden="true">
                <i />
                <i />
                <i />
              </span>
              {mode[0].toUpperCase() + mode.slice(1)}
            </Button>
          ))}
        </div>
        <p className="inline-hint">Animations follow your Mac’s Reduce Motion setting.</p>
      </div>
      <div className="settings-panel playback-panel">
        <h2>Playback</h2>
        <Level
          label="Master volume"
          value={preset.volume}
          disabled={desktop.busy}
          onChange={(volume) => void desktop.changePreset(preset.id, { volume })}
        />
        <Level
          label="Key release volume"
          value={preset.releaseVolume}
          disabled={desktop.busy}
          onChange={(releaseVolume) => void desktop.changePreset(preset.id, { releaseVolume })}
        />
        <Toggle
          label="Vary each keystroke"
          description="Use alternate recordings where available. Key release volume affects packs with recorded releases."
          selected={preset.variation}
          disabled={desktop.busy}
          onChange={(variation) => void desktop.changePreset(preset.id, { variation })}
        />
        <p className="inline-hint">
          Sound follows your Mac’s active output, including speakers when headphones disconnect.
        </p>
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
      <div className="settings-panel">
        <h2>Permissions</h2>
        <p className="inline-hint">
          {snapshot.runtime.inputPermission
            ? "Input Monitoring is enabled."
            : "Input Monitoring is needed to hear keys in other apps."}{" "}
          Your typing stays on this Mac.
        </p>
        <p className="inline-hint">
          {snapshot.runtime.secureInput
            ? "Secure input is active. Sounds return when macOS clears it."
            : "Secure input is inactive."}
        </p>
        <div className="actions">
          <Button
            variant="secondary"
            onPress={() => void desktop.perform(() => invoke("request_input_permission"))}
          >
            Open Input Monitoring
          </Button>
        </div>
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
