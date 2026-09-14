import { Button } from "@heroui/react";
import { Choice } from "./controls";
import { RotateCcw } from "lucide-react";
import { keyCodes, keyLabel } from "@openklack/keyboard-layout";
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
          <h2>Customize a key</h2>
        </div>
        <span className="count-label">{Object.keys(preset.overrides).length} customized</span>
      </div>
      <div className="assignment-fields">
        <Choice
          label="Key"
          value={key}
          onChange={setKey}
          options={[
            ...new Set([
              ...keyCodes.filter(
                (code) =>
                  !code.startsWith("Numpad") && code !== "PrintScreen" && code !== "NumLock",
              ),
              ...Object.keys(preset.overrides),
              key,
            ]),
          ].map((code) => ({ id: code, name: keyLabel(code) }))}
        />
        <Choice
          label="Sound"
          value={assignment?.packId ?? "default"}
          disabled={busy}
          options={[
            { id: "default", name: `Default · ${packLabel(pack)}` },
            ...packs.map((p) => ({ id: p.id, name: packLabel(p) })),
          ]}
          onChange={(packId) => {
            const overrides = { ...preset.overrides };
            if (packId === "default") delete overrides[key];
            else overrides[key] = { packId, volume: assignment?.volume ?? 100 };
            change({ overrides });
          }}
        />
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
    </section>
  );
}
