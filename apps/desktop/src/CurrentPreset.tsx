import { Button } from "@heroui/react";
import { Play, Square } from "lucide-react";
import { Level } from "./controls";
import { KeyboardPreview } from "./KeyboardPreview";
import { packLabel, type Desktop, type Preset, type Pack } from "./useDesktop";

export function CurrentPreset({
  desktop,
  preset,
  pack,
  selected,
  onSelect,
  compact,
}: {
  desktop: Desktop;
  preset: Preset;
  pack: Pack;
  selected: string;
  onSelect: (key: string) => void;
  compact: boolean;
}) {
  return (
    <section
      className={`current-preset ${compact ? "compact-preset" : ""}`}
      aria-label="Current preset"
    >
      <div className="preset-overview">
        <span className="eyebrow">Current preset</span>
        <h2>{preset.name}</h2>
        <p>
          {packLabel(pack)} · {pack.kind.toLowerCase()}
        </p>
        <div className="preset-playback">
          <Button
            isIconOnly
            variant="ghost"
            isDisabled={desktop.busy}
            aria-label={desktop.preview === pack.id ? "Stop preview" : "Preview current preset"}
            onPress={() => void desktop.audition(pack.id)}
          >
            {desktop.preview === pack.id ? <Square size={18} /> : <Play size={18} />}
          </Button>
          <Level
            label="Volume"
            value={preset.volume}
            disabled={desktop.busy}
            onChange={(volume) => void desktop.changePreset(preset.id, { volume })}
          />
        </div>
      </div>
      <KeyboardPreview
        onError={desktop.setError}
        canPick={
          desktop.snapshot!.runtime.inputPermission && !desktop.snapshot!.runtime.secureInput
        }
        selected={selected}
        assignments={Object.keys(preset.overrides)}
        onSelect={onSelect}
        compact={compact}
      />
    </section>
  );
}
