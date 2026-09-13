import { motion } from "motion/react";
import { enter } from "@openklack/ui/transitions";
import { useState } from "react";
import { Button } from "@heroui/react";
import { Check, Copy, Download, Star, Trash2, Upload } from "lucide-react";
import { type Desktop, type Preset, packLabel } from "./useDesktop";

export function Presets({ desktop, active }: { desktop: Desktop; active: Preset }) {
  const prefs = desktop.snapshot!.preferences;
  const [editing, setEditing] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [deleting, setDeleting] = useState<string | null>(null);
  async function duplicate(preset: Preset) {
    const copy = {
      ...structuredClone(preset),
      id: crypto.randomUUID(),
      name: `${preset.name.slice(0, 100)} copy`,
      favorite: false,
    };
    await desktop.save((p) => ({ ...p, presets: [...p.presets, copy] }));
  }
  return (
    <section aria-labelledby="presets-title">
      <div className="section-heading">
        <div>
          <h1 id="presets-title">Presets</h1>
          <p>Save a keyboard you love, then come back to it.</p>
        </div>
        <Button
          variant="secondary"
          isDisabled={desktop.busy}
          onPress={() => void desktop.importSounds()}
        >
          <Upload size={15} />
          Import preset
        </Button>
      </div>
      <div className="preset-list">
        {prefs.presets.map((preset) => {
          const pack = desktop.packs.find((p) => p.id === preset.packId);
          const rules = prefs.appRules.filter((r) => r.presetId === preset.id).length;
          return (
            <motion.article
              layout="position"
              {...enter}
              className={`preset-card ${preset.id === active.id ? "selected" : ""}`}
              key={preset.id}
            >
              <div className="preset-summary">
                <div
                  className="mini-key"
                  style={{ "--key-color": pack?.color } as React.CSSProperties}
                  aria-hidden="true"
                >
                  <span>{preset.name.charAt(0)}</span>
                </div>
                <div>
                  <h2>{preset.name}</h2>
                  <p>
                    {pack ? packLabel(pack) : "Unavailable sound"} · {Math.round(preset.volume)}%
                    volume
                  </p>
                  <p>
                    {Object.keys(preset.overrides).length} key assignments
                    {rules ? ` · Used by ${rules} app rules` : ""}
                  </p>
                </div>
                <Button
                  isIconOnly
                  variant="ghost"
                  aria-label={`${preset.favorite ? "Remove" : "Add"} ${preset.name} ${preset.favorite ? "from" : "to"} menu-bar favorites`}
                  aria-pressed={preset.favorite}
                  isDisabled={desktop.busy}
                  onPress={() =>
                    void desktop.changePreset(preset.id, { favorite: !preset.favorite })
                  }
                >
                  <motion.span
                    animate={{ scale: preset.favorite ? [1, 1.2, 1] : 1 }}
                    className="favorite-icon"
                  >
                    <Star size={18} fill={preset.favorite ? "currentColor" : "none"} />
                  </motion.span>
                </Button>
              </div>
              <div className="preset-actions">
                <Button
                  variant="secondary"
                  isDisabled={desktop.busy || preset.id === active.id}
                  onPress={() => void desktop.save((p) => ({ ...p, activePresetId: preset.id }))}
                >
                  {preset.id === active.id ? (
                    <>
                      <Check size={14} />
                      Default preset
                    </>
                  ) : (
                    "Use as default"
                  )}
                </Button>
                <Button
                  variant="ghost"
                  isDisabled={desktop.busy}
                  onPress={() => {
                    setName(preset.name);
                    setEditing(preset.id);
                  }}
                >
                  Rename
                </Button>
                <Button
                  variant="ghost"
                  isDisabled={desktop.busy}
                  onPress={() => void duplicate(preset)}
                >
                  <Copy size={14} />
                  Duplicate
                </Button>
                <Button
                  variant="ghost"
                  isDisabled={desktop.busy}
                  onPress={() => void desktop.exportPreset(preset.id)}
                >
                  <Download size={14} />
                  Export
                </Button>
                <Button
                  isIconOnly
                  variant="ghost"
                  className="delete-action"
                  aria-label={`Delete ${preset.name}`}
                  isDisabled={desktop.busy || prefs.presets.length === 1}
                  onPress={() => setDeleting(preset.id)}
                >
                  <Trash2 size={15} />
                </Button>
              </div>
              {editing === preset.id && (
                <motion.form
                  {...enter}
                  className="inline-form"
                  onSubmit={(e) => {
                    e.preventDefault();
                    void desktop.changePreset(preset.id, { name: name.trim() }).then((saved) => {
                      if (saved) setEditing(null);
                    });
                  }}
                >
                  <label>
                    Preset name
                    <input
                      autoFocus
                      required
                      maxLength={120}
                      value={name}
                      onChange={(e) => setName(e.target.value)}
                    />
                  </label>
                  <Button type="submit" variant="primary" isDisabled={desktop.busy}>
                    Save name
                  </Button>
                  <Button variant="ghost" onPress={() => setEditing(null)}>
                    Cancel
                  </Button>
                </motion.form>
              )}
              {deleting === preset.id && (
                <div className="delete-confirm">
                  <p>
                    Delete “{preset.name}”?{" "}
                    {rules > 0
                      ? "Its app rules will keep their mute setting and return to the default sound."
                      : "Its recordings will stay in your library."}
                  </p>
                  <div>
                    <Button
                      variant="danger"
                      isDisabled={desktop.busy}
                      onPress={() =>
                        void desktop
                          .save((p) => ({
                            ...p,
                            presets: p.presets.filter((v) => v.id !== preset.id),
                            activePresetId:
                              p.activePresetId === preset.id
                                ? p.presets.find((v) => v.id !== preset.id)!.id
                                : p.activePresetId,
                            appRules: p.appRules.map((r) =>
                              r.presetId === preset.id ? { ...r, presetId: null } : r,
                            ),
                          }))
                          .then((saved) => {
                            if (saved) setDeleting(null);
                          })
                      }
                    >
                      Delete preset
                    </Button>
                    <Button variant="ghost" onPress={() => setDeleting(null)}>
                      Keep preset
                    </Button>
                  </div>
                </div>
              )}
            </motion.article>
          );
        })}
      </div>
      <div className="quiet-note">
        <p>
          Presets carry the sound pack, key assignments, and playback levels. App rules stay
          separate. Export includes recordings and credits, so another Mac can sound exactly like
          yours.
        </p>
      </div>
    </section>
  );
}
