import { Button } from "@heroui/react";
import { Level } from "./controls";
import { KeyboardPreview } from "./KeyboardPreview";
import { type Desktop, type Preset, type Pack } from "./useDesktop";

export function CurrentPreset({
  desktop,
  preset,
  pack,
  selected,
  onSelect,
  editing,
  onEdit,
}: {
  desktop: Desktop;
  preset: Preset;
  pack: Pack;
  selected: string;
  onSelect: (key: string) => void;
  editing: boolean;
  onEdit: () => void;
}) {
  return (
    <section className="current-sound" aria-label="Current sound">
      <div className="current-sound-heading">
        <div>
          <p>{pack.brand}</p>
          <h1>{pack.name === "Unknown" ? "Classic" : pack.name}</h1>
        </div>
        <Level
          label="Volume"
          value={preset.volume}
          disabled={desktop.busy}
          onChange={(volume) => void desktop.changePreset(preset.id, { volume })}
        />
      </div>
      <KeyboardPreview
        onError={desktop.setError}
        canPick={
          desktop.snapshot!.runtime.inputPermission && !desktop.snapshot!.runtime.secureInput
        }
        selected={selected}
        assignments={Object.keys(preset.overrides)}
        onSelect={onSelect}
        compact={!editing}
      />
      <div className="keyboard-actions">
        <Button variant="ghost" aria-pressed={editing} onPress={onEdit}>
          {editing ? "Done" : "Customize a key"}
        </Button>
      </div>
    </section>
  );
}
