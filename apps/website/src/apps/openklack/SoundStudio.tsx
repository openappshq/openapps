import { Button, Label, Slider } from "@heroui/react";
import { SoundBrowser } from "@openklack/ui/sound-browser";
import "@openklack/ui/browser.css";
import { lazy, Suspense, useState } from "react";
import { Play, Square, Volume2, VolumeX, Check, Star } from "lucide-react";
import { TypingTest } from "@openklack/ui/typing";
import "@openklack/ui/typing.css";
import { packLabel, soundpacks } from "./soundpacks";
import { useStudio } from "./useStudio";
import "./studio.css";

const KeyboardScene = lazy(() => import("./KeyboardScene"));
const essentials = [
  "novelkeys-cream",
  "cherry-mx-blue-pbt",
  "topre-unknown",
  "ibm-buckling-spring",
];

export default function SoundStudio() {
  const studio = useStudio();
  const { settings, setSettings } = studio;
  const [browse, setBrowse] = useState(false);
  const [search, setSearch] = useState("");
  const [kind, setKind] = useState("All");
  const starting = [...new Set([settings.packId, ...settings.favoritePackIds, ...essentials])];
  const filtered = soundpacks
    .filter(
      (p) =>
        (browse ||
          starting.slice(0, Math.max(4, settings.favoritePackIds.length + 1)).includes(p.id)) &&
        (kind === "All" || p.kind === kind) &&
        `${p.brand} ${p.name} ${p.kind}`.toLowerCase().includes(search.trim().toLowerCase()),
    )
    .sort(
      (a, b) =>
        Number(settings.favoritePackIds.includes(b.id)) -
        Number(settings.favoritePackIds.includes(a.id)),
    );
  const choices = (
    <div
      className={`sound-grid ${browse ? "expanded" : ""}`}
      tabIndex={browse ? 0 : undefined}
      role="group"
      aria-label="Sound recordings"
    >
      {filtered.map((p) => {
        const active = settings.packId === p.id;
        const playing = studio.auditionId === p.id;
        const loading = studio.loadingPackId === p.id;
        return (
          <div className={`sound-card ${active ? "active" : ""}`} key={p.id}>
            <Button
              variant="ghost"
              className="choose-sound"
              aria-pressed={active}
              aria-label={`Use ${packLabel(p.id)}`}
              isDisabled={studio.loadingPackId !== null}
              onPress={() => {
                if (!active) void studio.choosePack(p.id);
              }}
            >
              <span>
                <strong>{p.name === "Unknown" ? "Classic" : p.name}</strong>
                <small>{p.brand}</small>
              </span>
              {active && <Check size={17} aria-label="In use" />}
            </Button>
            <Button
              variant="ghost"
              className="preview-pack star-sound"
              aria-pressed={settings.favoritePackIds.includes(p.id)}
              aria-label={`${settings.favoritePackIds.includes(p.id) ? "Unstar" : "Star"} ${packLabel(p.id)}`}
              onPress={() =>
                setSettings((s) => ({
                  ...s,
                  favoritePackIds: s.favoritePackIds.includes(p.id)
                    ? s.favoritePackIds.filter((id) => id !== p.id)
                    : [...s.favoritePackIds, p.id],
                }))
              }
            >
              <Star
                size={16}
                fill={settings.favoritePackIds.includes(p.id) ? "currentColor" : "none"}
              />
            </Button>
            <Button
              variant="ghost"
              className="preview-pack"
              aria-label={`${playing ? "Stop" : "Preview"} ${packLabel(p.id)}`}
              onPress={() => (playing ? studio.stopPreview() : void studio.choosePack(p.id, true))}
            >
              {loading ? (
                <span className="loading-sound">…</span>
              ) : playing ? (
                <Square size={16} />
              ) : (
                <Play size={16} />
              )}
            </Button>
          </div>
        );
      })}
    </div>
  );
  return (
    <section id="playground" className="studio-shell" aria-label="Interactive sound playground">
      <div className="studio-topline">
        <h2>Pick a sound. Start typing.</h2>
        <div className="studio-controls">
          <Slider
            className="compact-volume"
            minValue={0}
            maxValue={100}
            value={settings.volume}
            onChange={(value) => setSettings((s) => ({ ...s, volume: Number(value) }))}
          >
            <Label className="sr-only">Volume</Label>
            <Volume2 size={16} aria-hidden="true" />
            <Slider.Track>
              <Slider.Fill />
              <Slider.Thumb />
            </Slider.Track>
            <Slider.Output>{settings.volume}%</Slider.Output>
          </Slider>
          <Button
            variant="ghost"
            className={`sound-power ${studio.enabled ? "enabled" : ""}`}
            isDisabled={studio.enabling}
            aria-pressed={studio.enabled}
            onPress={async () => {
              await studio.enableSound(!studio.enabled);
              document
                .querySelector<HTMLTextAreaElement>("#playground [data-sound-input]")
                ?.focus({ preventScroll: true });
            }}
          >
            {studio.enabled ? <Volume2 size={16} /> : <VolumeX size={16} />}
            {studio.enabling ? "Preparing…" : studio.enabled ? "Sound on" : "Enable sound"}
          </Button>
        </div>
      </div>
      <section className="sound-library" aria-label="Choose a sound">
        <div className="library-heading">
          <Button
            variant="ghost"
            className="browse-sounds"
            aria-expanded={browse}
            onPress={() => {
              setBrowse(!browse);
              setSearch("");
              setKind("All");
            }}
          >
            {browse ? "Show essentials" : `Browse all ${soundpacks.length} sounds`}
          </Button>
        </div>
        {browse ? (
          <SoundBrowser search={search} onSearch={setSearch} kind={kind} onKind={setKind}>
            {choices}
          </SoundBrowser>
        ) : (
          choices
        )}
        {!filtered.length && (
          <div className="no-sounds">
            <p>No sounds match “{search}”.</p>
            <Button variant="ghost" onPress={() => setSearch("")}>
              Clear search
            </Button>
          </div>
        )}
        {studio.saveError && (
          <p className="studio-error" role="status">
            This browser couldn’t save your sound choice.
          </p>
        )}
        {studio.error && (
          <p className="studio-error" role="alert">
            {studio.error}
          </p>
        )}
      </section>
      <TypingTest />
      <div className="keyboard-stage">
        <Suspense fallback={<div className="scene-fallback">Preparing your keyboard…</div>}>
          <KeyboardScene
            input={studio.input}
            selected={null}
            assignments={[]}
            lighting
            reducedMotion={studio.reducedMotion}
            onPress={studio.press}
            onRelease={studio.release}
          />
        </Suspense>
      </div>
    </section>
  );
}
