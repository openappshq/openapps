import { motion } from "motion/react";
import { enter } from "@openklack/ui/transitions";
import { useState } from "react";
import { Button } from "@heroui/react";
import { invoke } from "@tauri-apps/api/core";
import { Plus, Trash2 } from "lucide-react";
import { Toggle } from "./controls";
import type { Desktop, Preferences } from "./useDesktop";

export function AppRules({ desktop }: { desktop: Desktop }) {
  const { preferences: prefs, runtime } = desktop.snapshot!;
  const [bundleId, setBundleId] = useState("");
  const [appName, setAppName] = useState("");
  const [presetId, setPresetId] = useState("");
  const [mute, setMute] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);
  const [removed, setRemoved] = useState<Preferences["appRules"][number] | null>(null);
  return (
    <section>
      <div className="section-heading">
        <div>
          <h1>App rules</h1>
          <p>Sound that follows your day, with you in control.</p>
        </div>
      </div>
      <div className="settings-panel">
        <Toggle
          label="Pause when the microphone is in use"
          description="Includes calls and dictation. When activity is uncertain, stay quiet until it clears."
          selected={prefs.pauseOnMicrophone}
          disabled={desktop.busy || runtime.microphone === 3}
          onChange={(value) => void desktop.save((p) => ({ ...p, pauseOnMicrophone: value }))}
        />
        {runtime.microphone === 3 && (
          <p className="inline-hint">
            Microphone activity detection is unavailable on this Mac. App rules and manual mute
            still work.
          </p>
        )}
        <p className="inline-hint">
          Only activity status is checked. OpenKlack never opens or records your microphone.
        </p>
      </div>
      <div className="section-heading">
        <div>
          <h2>App rules</h2>
          <p>Choose a sound or stay quiet whenever an app is in front.</p>
        </div>
      </div>
      {prefs.appRules.length > 0 && (
        <div className="rules-list">
          {prefs.appRules.map((rule) => (
            <motion.div layout="position" {...enter} className="rule-row" key={rule.bundleId}>
              <div>
                <strong>{rule.name || rule.bundleId}</strong>
                <p>
                  {rule.mute
                    ? "Mute sounds"
                    : (prefs.presets.find((p) => p.id === rule.presetId)?.name ??
                      "Use default preset")}
                </p>
              </div>
              <Button
                variant="ghost"
                isDisabled={desktop.busy}
                onPress={() => {
                  setEditing(rule.bundleId);
                  setBundleId(rule.bundleId);
                  setAppName(rule.name);
                  setPresetId(rule.presetId ?? "");
                  setMute(rule.mute);
                }}
              >
                Edit
              </Button>
              <Button
                isIconOnly
                variant="ghost"
                aria-label={`Remove rule for ${rule.name || rule.bundleId}`}
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
                <Trash2 size={15} />
              </Button>
            </motion.div>
          ))}
        </div>
      )}
      {removed && (
        <div className="pause-banner">
          <p>Removed the rule for {removed.name || removed.bundleId}.</p>
          <Button
            variant="secondary"
            isDisabled={desktop.busy}
            onPress={() =>
              void desktop
                .save((p) => ({ ...p, appRules: [...p.appRules, removed] }))
                .then((saved) => {
                  if (saved) setRemoved(null);
                })
            }
          >
            Undo removal
          </Button>
        </div>
      )}
      <form
        className="rule-form settings-panel"
        onSubmit={(e) => {
          e.preventDefault();
          const id = bundleId.trim();
          if (!id) {
            desktop.setError("Choose an app before saving this rule.");
            return;
          }
          void desktop
            .save((p) => ({
              ...p,
              appRules: [
                ...p.appRules.filter((r) => r.bundleId !== (editing ?? id)),
                { bundleId: id, name: appName, presetId: presetId || null, mute },
              ],
            }))
            .then((saved) => {
              if (!saved) return;
              setBundleId("");
              setAppName("");
              setEditing(null);
              setPresetId("");
              setMute(false);
            });
        }}
      >
        <h3>{editing ? "Edit app rule" : "Add an app rule"}</h3>
        <div className="actions">
          <Button
            variant="secondary"
            isDisabled={desktop.busy}
            onPress={() =>
              void desktop.perform(async () => {
                const chosen = await invoke<{ bundleId: string; name: string } | null>(
                  "choose_application",
                );
                if (chosen) {
                  setBundleId(chosen.bundleId);
                  setAppName(chosen.name);
                }
              })
            }
          >
            Choose an app…
          </Button>
          <span className="chosen-app">{appName || bundleId || "No app selected"}</span>
        </div>
        <details>
          <summary>Enter an app identifier manually</summary>
          <label>
            App bundle ID
            <input
              value={bundleId}
              onChange={(e) => {
                setBundleId(e.target.value);
                setAppName("");
              }}
              placeholder="com.apple.Terminal"
              spellCheck={false}
              autoCorrect="off"
              maxLength={256}
            />
          </label>
        </details>
        <div className="form-row">
          <label>
            Preset
            <select value={presetId} onChange={(e) => setPresetId(e.target.value)} disabled={mute}>
              {[
                <option value="" key="default">
                  Use default preset
                </option>,
                ...prefs.presets.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                )),
              ]}
            </select>
          </label>
          <label className="check-label">
            <input type="checkbox" checked={mute} onChange={(e) => setMute(e.target.checked)} />
            Mute in this app
          </label>
        </div>
        <div className="actions">
          <Button type="submit" variant="primary" isDisabled={desktop.busy}>
            <Plus size={15} />
            {editing ? "Save rule" : "Add rule"}
          </Button>
          {editing && (
            <Button
              variant="ghost"
              onPress={() => {
                setEditing(null);
                setBundleId("");
              }}
            >
              Cancel
            </Button>
          )}
        </div>
      </form>
      <div className="quiet-note">
        <p>
          Manual mute always wins. Locking your Mac pauses sound; changing audio outputs follows
          your Mac’s current output. App rules use app identity, never window titles or what you
          type.
        </p>
      </div>
    </section>
  );
}
