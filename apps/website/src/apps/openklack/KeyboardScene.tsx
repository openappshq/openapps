import Keyboard3D from "@openklack/ui/keyboard";
import "@openklack/ui/keyboard.css";
import type { KeyboardInput, InputSource } from "./keyboard";

export default function KeyboardScene({
  input,
  selected,
  assignments,
  lighting,
  reducedMotion,
  onPress,
  onRelease,
}: {
  input: KeyboardInput;
  selected: string | null;
  assignments?: string[];
  lighting?: boolean;
  reducedMotion: boolean;
  onPress: (key: string, source: InputSource) => void;
  onRelease: (key: string, source: InputSource) => void;
}) {
  return (
    <div
      className="keyboard-canvas"
      tabIndex={0}
      aria-label="Interactive OpenKlack keyboard. Type or click a key."
    >
      <Keyboard3D
        assetBase="/openklack"
        input={input}
        selected={selected}
        assignments={assignments}
        lighting={lighting}
        reducedMotion={reducedMotion}
        onPress={(key) => onPress(key, "pointer")}
        onRelease={(key) => onRelease(key, "pointer")}
      />
    </div>
  );
}
