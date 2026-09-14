import { useState } from "react";
import { Button } from "@heroui/react";
import { invoke } from "@tauri-apps/api/core";
import { X } from "lucide-react";
import type { Desktop, Preferences } from "./useDesktop";

export function AppRules({ desktop }: { desktop: Desktop }) {
  const prefs = desktop.snapshot!.preferences;
  const [removed, setRemoved] = useState<Preferences["appRules"][number] | null>(null);
  async function addApp() {
    const app = await desktop.perform(() =>
      invoke<{ bundleId: string; name: string } | null>("choose_application"),
    );
    if (app)
      await desktop.save((p) => ({
        ...p,
        appRules: [
          ...p.appRules.filter((rule) => rule.bundleId !== app.bundleId),
          { ...app, presetId: null, mute: true },
        ],
      }));
  }
  return (
    <section>
      <div className="section-heading">
        <h1>Muted apps</h1>
        <Button variant="primary" isDisabled={desktop.busy} onPress={() => void addApp()}>
          Add app
        </Button>
      </div>
      <p className="section-description">Pause sounds while these apps are in front.</p>
      <div className="rules-list">
        {prefs.appRules.map((rule) => (
          <div className="rule-row" key={rule.bundleId}>
            <div>
              <strong>{rule.name || rule.bundleId}</strong>
              {!rule.mute && <p>Existing custom sound rule</p>}
            </div>
            <Button
              isIconOnly
              variant="ghost"
              aria-label={`Remove ${rule.name || rule.bundleId}`}
              isDisabled={desktop.busy}
              onPress={() =>
                void desktop
                  .save((p) => ({
                    ...p,
                    appRules: p.appRules.filter((r) => r.bundleId !== rule.bundleId),
                  }))
                  .then((saved) => {
                    if (saved) setRemoved(rule);
                  })
              }
            >
              <X size={16} />
            </Button>
          </div>
        ))}
      </div>
      {!prefs.appRules.length && (
        <p className="empty-state">No apps muted. Add an app to pause sounds there.</p>
      )}
      {removed && (
        <div className="pause-banner" role="status">
          <p>Removed {removed.name || removed.bundleId}.</p>
          <Button
            variant="secondary"
            isDisabled={desktop.busy}
            onPress={() =>
              void desktop
                .save((p) => ({
                  ...p,
                  appRules: [...p.appRules.filter((r) => r.bundleId !== removed.bundleId), removed],
                }))
                .then((saved) => {
                  if (saved) setRemoved(null);
                })
            }
          >
            Undo
          </Button>
        </div>
      )}
    </section>
  );
}
