import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button, TextArea } from "@heroui/react";
import { ChevronRight } from "lucide-react";
import { Choice, Disclosure, Toggle } from "./controls";
import { Updates } from "./Updates";
import { License } from "./License";
import { packLabel, type Desktop, type Preset } from "./useDesktop";
import type { LicenseState } from "./useLicense";

export function General({
  desktop,
  license,
  preset,
  theme,
  onThemeChange,
  onApps,
  onShowGuide,
}: {
  desktop: Desktop;
  license: LicenseState;
  preset: Preset;
  theme: string;
  onThemeChange: (theme: string) => void;
  onApps: () => void;
  onShowGuide: () => void;
}) {
  const { snapshot, busy, setError } = desktop;
  const [startup, setStartup] = useState<boolean>();
  const [report, setReport] = useState("");
  const [exported, setExported] = useState(false);
  const pack = desktop.packs.find((p) => p.id === preset.packId);
  useEffect(() => {
    let disposed = false;
    void invoke<boolean>("startup_state")
      .then((value) => {
        if (!disposed) setStartup(value);
      })
      .catch((error: unknown) => {
        if (!disposed) setError(String(error));
      });
    return () => {
      disposed = true;
    };
  }, [setError]);
  return (
    <section className="general-settings">
      <h1>Settings</h1>
      <div className="settings-panel">
        <Toggle
          label="Open at login"
          selected={startup ?? false}
          disabled={busy || startup === undefined}
          onChange={(enabled) =>
            void desktop.perform(async () =>
              setStartup(await invoke<boolean>("startup_state", { enabled })),
            )
          }
        />
        <Toggle
          label="Pause when the microphone is in use"
          description="Includes calls, dictation, and recording."
          selected={snapshot!.preferences.pauseOnMicrophone}
          disabled={busy || snapshot!.runtime.microphone === 3}
          onChange={(enabled) => void desktop.save((p) => ({ ...p, pauseOnMicrophone: enabled }))}
        />
        {snapshot!.runtime.microphone === 3 && (
          <p className="inline-hint">
            Microphone detection is unavailable. You can still mute OpenKlack or specific apps.
          </p>
        )}
        <Button variant="ghost" className="settings-link" onPress={onApps}>
          <span>Muted apps</span>
          <ChevronRight size={17} />
        </Button>
        <Choice
          className="setting-row"
          label="Appearance"
          value={theme}
          onChange={onThemeChange}
          options={[
            { id: "system", name: "System" },
            { id: "light", name: "Light" },
            { id: "dark", name: "Dark" },
          ]}
        />
      </div>
      {snapshot!.licensingEnabled && (
        <License license={license} onError={setError} disabled={busy} />
      )}
      <Disclosure title="Sounds & settings files">
        <div className="disclosure-content">
          <div className="actions">
            <Button
              variant="secondary"
              isDisabled={busy}
              onPress={() => void desktop.importSounds()}
            >
              Import sounds or settings
            </Button>
            <Button
              variant="secondary"
              isDisabled={busy}
              onPress={() => void desktop.exportPreset(preset.id)}
            >
              Export settings
            </Button>
          </div>
          <Button variant="ghost" isDisabled={busy} onPress={() => void desktop.checkPackUpdates()}>
            Add new bundled sounds
          </Button>
        </div>
      </Disclosure>
      <Disclosure title="About & help">
        <div className="disclosure-content">
          <p>OpenKlack {snapshot!.version} · OpenApps HQ</p>
          <div className="permission-setting">
            <span>
              {snapshot!.runtime.inputPermission
                ? "Keyboard access enabled"
                : "Keyboard access required"}
            </span>
            <Button
              variant="ghost"
              onPress={() => void desktop.perform(() => invoke("request_input_permission"))}
            >
              Manage access
            </Button>
          </div>
          {snapshot!.runtime.secureInput && (
            <p>macOS Secure Input is active. Keyboard sounds resume when it clears.</p>
          )}
          <div className="actions">
            <Button variant="secondary" onPress={onShowGuide}>
              Show setup guide
            </Button>
          </div>
          <Updates onError={setError} disabled={busy} />
          {pack && (
            <Disclosure title="Sound credits">
              <p>
                {packLabel(pack)} · {pack.author}
              </p>
              <pre className="credits">{pack.credits}</pre>
            </Disclosure>
          )}
          <Disclosure title="Diagnostics">
            <p>Review the report before saving. Nothing is sent automatically.</p>
            <div className="actions">
              <Button
                variant="secondary"
                isDisabled={busy}
                onPress={() =>
                  void desktop.perform(async () => {
                    setReport(await invoke<string>("get_diagnostics"));
                    setExported(false);
                  })
                }
              >
                {report ? "Refresh report" : "View report"}
              </Button>
              {report && (
                <Button
                  variant="secondary"
                  isDisabled={busy}
                  onPress={() =>
                    void desktop.perform(async () => {
                      if (await invoke<boolean>("export_diagnostics", { report }))
                        setExported(true);
                    })
                  }
                >
                  Save report
                </Button>
              )}
            </div>
            {report && (
              <label className="diagnostics-report">
                Report
                <TextArea readOnly value={report} rows={12} spellCheck={false} />
              </label>
            )}
            {exported && <p role="status">Report saved.</p>}
          </Disclosure>
        </div>
      </Disclosure>
    </section>
  );
}
