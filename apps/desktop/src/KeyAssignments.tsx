import { Button } from "@heroui/react";
import { RotateCcw } from "lucide-react";
import { keyCodes, keyLabel } from "@openklack/keyboard-layout";
import { Level, Toggle } from "./controls";
import { packLabel, type Desktop, type Preset, type Pack } from "./useDesktop";

export function KeyAssignments({
  desktop,
  preset,
  pack,
  selected: key,
  onSelect: setKey,
}: {
  desktop: Desktop;
  preset: Preset;
  pack: Pack;
  selected: string;
  onSelect: (key: string) => void;
}) {
  const { packs, busy } = desktop;
  const assignment = preset.overrides[key];
  const change = (patch: Partial<Preset>) => void desktop.changePreset(preset.id, patch);
  return (
    <section className="key-settings settings-panel" aria-label="Key assignment">
      <div className="section-heading">
        <div>
          <h2>Key sounds</h2>
          <p>Give a key its own sound. The rest keep your default.</p>
        </div>
        <span className="count-label">{Object.keys(preset.overrides).length} customized</span>
      </div>
      <div className="assignment-fields">
        <label>
          Key
          <select value={key} onChange={(e) => setKey(e.target.value)}>
            {[
              ...new Set([
                ...keyCodes.filter(
                  (code) =>
                    !code.startsWith("Numpad") && code !== "PrintScreen" && code !== "NumLock",
                ),
                ...Object.keys(preset.overrides),
                key,
              ]),
            ].map((code) => (
              <option key={code} value={code}>
                {keyLabel(code)}
              </option>
            ))}
          </select>
        </label>
        <label>
          Sound
          <select
            value={assignment?.packId ?? ""}
            disabled={busy}
            onChange={(e) => {
              const overrides = { ...preset.overrides };
              if (e.target.value)
                overrides[key] = {
                  packId: e.target.value,
                  volume: assignment?.volume ?? 100,
                };
              else delete overrides[key];
              change({ overrides });
            }}
          >
            <option value="">Default · {packLabel(pack)}</option>
            {packs.map((p) => (
              <option key={p.id} value={p.id}>
                {packLabel(p)} · {p.version.slice(0, 6)}
              </option>
            ))}
          </select>
        </label>
        <Button
          isIconOnly
          variant="secondary"
          isDisabled={busy || !assignment}
          aria-label={`Reset ${keyLabel(key)} to the default sound`}
          onPress={() => {
            const overrides = { ...preset.overrides };
            delete overrides[key];
            change({ overrides });
          }}
        >
          <RotateCcw size={15} />
        </Button>
      </div>
      {assignment && (
        <Level
          label={`${keyLabel(key)} volume`}
          value={assignment.volume}
          disabled={busy}
          onChange={(volume) =>
            change({
              overrides: { ...preset.overrides, [key]: { ...assignment, volume } },
            })
          }
        />
      )}
      <details className="playback-details">
        <summary>Playback details</summary>
        <div className="playback-options">
          <Level
            label="Key release volume"
            value={preset.releaseVolume}
            disabled={busy}
            onChange={(value) => change({ releaseVolume: value })}
          />
          <Toggle
            label="Vary each keystroke"
            description="Cycle through recorded variations for a more natural feel."
            selected={preset.variation}
            disabled={busy}
            onChange={(variation) => change({ variation })}
          />
        </div>
        <p>Recording levels are matched across packs. Holding a key does not repeat its sound.</p>
      </details>
    </section>
  );
}
