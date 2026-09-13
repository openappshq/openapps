import { motion, AnimatePresence } from "motion/react";
import { lazy, Suspense, useMemo, useState } from "react";
import { Button, Label, Modal, Radio, RadioGroup, Slider, Switch } from "@heroui/react";
import {
  ArrowDown,
  ArrowUpRight,
  AudioLines,
  Check,
  ChevronDown,
  Info,
  Keyboard as KeyboardIcon,
  LoaderCircle,
  Play,
  RotateCcw,
  Search,
  SlidersHorizontal,
  Square,
  Volume2,
  VolumeX,
  X,
} from "lucide-react";
import { keyCodes, keyLabel, voiceForKey, type Finish } from "./keyboard";
import { getPack, packLabel, soundpacks, type SoundPack } from "./soundpacks";
import { useStudio } from "./useStudio";

const Keyboard = lazy(() => import("./KeyboardScene"));
const kinds = ["All", "Linear", "Tactile", "Clicky"] as const;
const finishNames: Finish[] = ["graphite", "chalk", "sage"];
const displayName = (pack: SoundPack) => (pack.name === "Unknown" ? "Unknown model" : pack.name);

function Level({
  label,
  value,
  onChange,
  className = "",
}: {
  label: string;
  value: number;
  onChange: (value: number) => void;
  className?: string;
}) {
  return (
    <Slider
      className={`level ${className}`}
      minValue={0}
      maxValue={100}
      value={value}
      onChange={(value) => onChange(Number(value))}
    >
      <div className="level-label">
        <Label>{label}</Label>
        <Slider.Output>
          {value}
          <span>%</span>
        </Slider.Output>
      </div>
      <Slider.Track>
        <Slider.Fill />
        <Slider.Thumb />
      </Slider.Track>
    </Slider>
  );
}

export default function SoundStudio() {
  const studio = useStudio();
  const { settings, setSettings, selectedKey, setSelectedKey } = studio;
  const [filter, setFilter] = useState<(typeof kinds)[number]>("All");
  const [search, setSearch] = useState("");
  const [playbackOpen, setPlaybackOpen] = useState(false);
  const voice = voiceForKey(settings, selectedKey ?? "");
  const activePack = getPack(voice.packId);
  const assignments = Object.entries(settings.overrides);
  const filtered = useMemo(
    () =>
      soundpacks.filter(
        (pack) =>
          (filter === "All" || pack.kind === filter) &&
          `${pack.brand} ${pack.name} ${pack.kind}`
            .toLowerCase()
            .includes(search.toLowerCase().trim()),
      ),
    [filter, search],
  );
  const [candidateId, setCandidateId] = useState<string | null>(null);
  const chosenId = candidateId ?? voice.packId;
  const selectedOverride = selectedKey ? settings.overrides[selectedKey] : undefined;

  return (
    <section
      className="studio-shell"
      id="playground"
      data-keyboard-studio
      aria-label="Interactive sound playground"
    >
      <header className="studio-header">
        <div>
          <span className="eyebrow">01 / The playground</span>
          <h2>Find your kind of click.</h2>
        </div>
        <div className="header-actions">
          <Button
            isIconOnly
            variant="ghost"
            className="about-button"
            aria-label="About OpenKlack"
            onPress={() => studio.setHelp(true)}
          >
            <Info size={19} strokeWidth={1.5} />
          </Button>
          <Button
            className={`power-button ${studio.enabled ? "is-on" : ""}`}
            onPress={async () => {
              await studio.enableSound(!studio.enabled);
              document
                .querySelector<HTMLElement>(".keyboard-canvas")
                ?.focus({ preventScroll: true });
            }}
            isPending={studio.enabling}
            aria-pressed={studio.enabled}
          >
            {studio.enabled ? <Volume2 size={17} /> : <VolumeX size={17} />}{" "}
            {studio.enabling ? "Loading sounds" : studio.enabled ? "Sound on" : "Enable sound"}
          </Button>
        </div>
      </header>

      <div className="studio-main">
        <section className="workbench" aria-labelledby="pack-title">
          <div className="workbench-topline">
            <span className="eyebrow">
              {selectedKey ? `A sound for ${keyLabel(selectedKey)}` : "On your keyboard"}
            </span>
            <span className="edition-label">Live keyboard</span>
          </div>
          <div className="current-sound">
            <div className="current-title">
              <p className="pack-maker">{activePack.brand}</p>
              <motion.h3
                key={activePack.id}
                initial={{ opacity: 0, y: 4 }}
                animate={{ opacity: 1, y: 0 }}
                id="pack-title"
              >
                {displayName(activePack)}
                <span className="title-dot" style={{ background: activePack.color }} />
              </motion.h3>
            </div>
            <div className="current-details">
              <span className="mechanism">
                {activePack.kind}
                <span> / </span>
                {activePack.supportsKeyUp ? "Press + release" : "Press recordings"}
              </span>
              <p>{activePack.description}</p>
              <Button
                variant="ghost"
                className="listen-button"
                onPress={() =>
                  studio.auditionId === activePack.id
                    ? studio.stopPreview()
                    : studio.choosePack(activePack.id, true)
                }
              >
                {studio.auditionId === activePack.id ? (
                  <Square size={12} fill="currentColor" />
                ) : (
                  <Play size={13} fill="currentColor" />
                )}{" "}
                {studio.auditionId === activePack.id ? "Stop preview" : "Listen to this switch"}
              </Button>
            </div>
          </div>

          <div className="keyboard-stage">
            <div className="keyboard-shadow" />
            <Suspense fallback={<div className="scene-fallback">Setting up the keyboard…</div>}>
              <Keyboard
                input={studio.input}
                finish={settings.finish}
                selected={selectedKey}
                reducedMotion={studio.reducedMotion}
                onPress={studio.press}
                onRelease={studio.release}
                onReady={studio.sceneReady}
              />
            </Suspense>
          </div>
          <div className="keyboard-baseline">
            <span className="board-spec">
              75% <span>/</span> ANSI
            </span>
            <span className="typing-cue">
              {studio.ready
                ? selectedKey
                  ? "Press or select a key to edit its sound"
                  : "Click the keyboard, then type."
                : "Loading the keyboard…"}
            </span>
            <span className="board-spec">{settings.finish}</span>
          </div>

          <div className={`assignment-bar ${selectedKey ? "is-editing" : ""}`}>
            <div className="assignment-label">
              <KeyboardIcon size={19} strokeWidth={1.5} />
              <div>
                <span>{selectedKey ? "Editing one key" : "Make it your own"}</span>
                <p>
                  {selectedKey
                    ? "Choose its sound from the library."
                    : "A different switch for your spacebar? Why not."}
                </p>
              </div>
            </div>
            {selectedKey ? (
              <div className="key-target">
                <label className="sr-only" htmlFor="key-target">
                  Key to customize
                </label>
                <select
                  id="key-target"
                  value={selectedKey}
                  onChange={(event) => setSelectedKey(event.target.value)}
                >
                  {keyCodes.map((code) => (
                    <option key={code} value={code}>
                      {keyLabel(code)}
                    </option>
                  ))}
                </select>
                <ChevronDown size={15} />
                <Button
                  isIconOnly
                  variant="ghost"
                  aria-label="Finish editing keys"
                  onPress={() => setSelectedKey(null)}
                >
                  <X size={17} />
                </Button>
              </div>
            ) : (
              <Button
                variant="secondary"
                className="edit-keys-button"
                onPress={() => setSelectedKey("Space")}
              >
                Customize a key <ArrowUpRight size={15} />
              </Button>
            )}
          </div>

          {selectedKey && (
            <div className="key-adjustments">
              <Level
                label={`${keyLabel(selectedKey)} volume`}
                value={voice.volume}
                onChange={(volume) =>
                  setSettings((current) => ({
                    ...current,
                    overrides: {
                      ...current.overrides,
                      [selectedKey]: { ...voiceForKey(current, selectedKey), volume },
                    },
                  }))
                }
              />
              <Button
                variant="ghost"
                className="reset-key"
                isDisabled={!selectedOverride}
                onPress={() => studio.resetKey(selectedKey)}
              >
                <RotateCcw size={14} /> Use keyboard default
              </Button>
            </div>
          )}
          {assignments.length > 0 && (
            <div className="assignments" aria-label="Custom key sounds">
              {assignments.map(([code, custom]) => (
                <motion.div
                  layout="position"
                  initial={{ opacity: 0, scale: 0.96 }}
                  animate={{ opacity: 1, scale: 1 }}
                  className="assignment-chip"
                  key={code}
                >
                  <Button variant="ghost" onPress={() => setSelectedKey(code)}>
                    <kbd>{keyLabel(code)}</kbd>
                    <span>{getPack(custom.packId).name}</span>
                  </Button>
                  <Button
                    isIconOnly
                    variant="ghost"
                    aria-label={`Reset ${keyLabel(code)} to keyboard default`}
                    onPress={() => studio.resetKey(code)}
                  >
                    <X size={12} />
                  </Button>
                </motion.div>
              ))}
            </div>
          )}

          <div className="workbench-controls">
            <div className="finish-control">
              <span className="control-label">Keycaps</span>
              <RadioGroup
                className="swatches"
                aria-label="Keycap finish"
                value={settings.finish}
                orientation="horizontal"
                onChange={(value) => {
                  if (finishNames.includes(value as Finish))
                    setSettings((current) => ({ ...current, finish: value as Finish }));
                }}
              >
                {finishNames.map((finish) => (
                  <Radio
                    key={finish}
                    value={finish}
                    className={`swatch swatch-${finish}`}
                    aria-label={finish}
                  >
                    <Radio.Content aria-label={finish}>
                      <Check size={12} />
                    </Radio.Content>
                  </Radio>
                ))}
              </RadioGroup>
            </div>
            <Level
              label="Volume"
              value={settings.volume}
              onChange={(volume) => setSettings((current) => ({ ...current, volume }))}
              className="master-volume"
            />
            <Button
              variant="ghost"
              className="playback-trigger"
              aria-expanded={playbackOpen}
              aria-controls="playback-settings"
              onPress={() => setPlaybackOpen(!playbackOpen)}
            >
              <SlidersHorizontal size={15} /> Playback <ChevronDown size={13} />
            </Button>
          </div>
          <AnimatePresence initial={false}>
            {playbackOpen && (
              <motion.div
                initial={{ opacity: 0, height: 0 }}
                animate={{ opacity: 1, height: "auto" }}
                exit={{ opacity: 0, height: 0 }}
                className="playback-reveal"
                id="playback-settings"
              >
                <div className="playback-settings">
                  <Level
                    label="Release volume"
                    value={settings.releaseVolume}
                    onChange={(releaseVolume) =>
                      setSettings((current) => ({ ...current, releaseVolume }))
                    }
                  />
                  <div className="variation-setting">
                    <Switch
                      isSelected={settings.variation}
                      onChange={(variation) =>
                        setSettings((current) => ({ ...current, variation }))
                      }
                    >
                      <Switch.Content>
                        <Switch.Control>
                          <Switch.Thumb />
                        </Switch.Control>
                        <span>Sample variation</span>
                      </Switch.Content>
                    </Switch>
                    <p>Use the pack’s alternate samples when available.</p>
                  </div>
                  <p className="release-note">
                    Release volume applies to packs with recorded key-up sounds.
                  </p>
                </div>
              </motion.div>
            )}
          </AnimatePresence>
          <div className="studio-message" role="status">
            {studio.saveError
              ? "Changes work for this visit, but this browser couldn’t save them."
              : selectedKey
                ? `${keyLabel(selectedKey)} uses ${packLabel(voice.packId)}${selectedOverride ? " · Custom assignment" : " · Keyboard default"}`
                : ""}
          </div>
          <div className="error-message" role="alert">
            {studio.error}
          </div>
        </section>

        <aside className="sound-library" aria-labelledby="library-title">
          <div className="library-heading">
            <div>
              <span className="eyebrow">Find your signature</span>
              <h2 id="library-title">
                Sound library<span>{soundpacks.length.toString().padStart(2, "0")}</span>
              </h2>
            </div>
            <AudioLines size={27} strokeWidth={1.2} />
          </div>
          <div className="library-target">
            <span>Apply to</span>
            <Button
              variant="ghost"
              onPress={() => (selectedKey ? setSelectedKey(null) : setSelectedKey("Space"))}
            >
              {selectedKey ? keyLabel(selectedKey) : "Whole keyboard"}
              {selectedKey ? <X size={12} /> : <ChevronDown size={13} />}
            </Button>
          </div>
          <div className="library-search">
            <label className="sr-only" htmlFor="pack-search">
              Search sound library
            </label>
            <Search size={15} strokeWidth={1.5} />
            <input
              id="pack-search"
              type="search"
              placeholder="Find a switch…"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              autoComplete="off"
            />
          </div>
          <div className="library-filters" role="group" aria-label="Filter by switch type">
            {kinds.map((kind) => (
              <Button
                key={kind}
                variant="ghost"
                aria-pressed={filter === kind}
                onPress={() => setFilter(kind)}
              >
                {kind}
              </Button>
            ))}
          </div>
          <div className="library-list">
            <RadioGroup
              aria-label={
                selectedKey ? `Sound for ${keyLabel(selectedKey)}` : "Keyboard sound pack"
              }
              value={chosenId}
              onChange={setCandidateId}
              className="pack-options"
            >
              {filtered.map((pack, index) => (
                <div
                  className={`pack-row ${pack.id === chosenId ? "is-selected" : ""}`}
                  key={pack.id}
                >
                  <span className="pack-number">{String(index + 1).padStart(2, "0")}</span>
                  <Radio value={pack.id} className="pack-radio">
                    <Radio.Content>
                      <span className="switch-swatch" style={{ background: pack.color }} />
                      <span className="pack-row-label">
                        <span className="pack-brand">{pack.brand}</span>
                        <span className="pack-name">{displayName(pack)}</span>
                      </span>
                      {pack.id === voice.packId && <Check size={14} className="pack-check" />}
                    </Radio.Content>
                  </Radio>
                  <Button
                    isIconOnly
                    variant="ghost"
                    className="pack-preview"
                    aria-label={`${studio.auditionId === pack.id ? "Stop preview of" : "Preview"} ${pack.brand} ${pack.name}`}
                    onPress={() =>
                      studio.auditionId === pack.id
                        ? studio.stopPreview()
                        : studio.choosePack(pack.id, true)
                    }
                  >
                    {studio.loadingPackId === pack.id ? (
                      <LoaderCircle size={15} className="loading-icon" />
                    ) : studio.auditionId === pack.id ? (
                      <Square size={11} fill="currentColor" />
                    ) : (
                      <Play size={12} fill="currentColor" />
                    )}
                  </Button>
                </div>
              ))}
            </RadioGroup>
            {filtered.length === 0 && (
              <div className="library-empty">
                <p>No switches match “{search || filter}”.</p>
                <Button
                  variant="secondary"
                  onPress={() => {
                    setSearch("");
                    setFilter("All");
                  }}
                >
                  Clear filters
                </Button>
              </div>
            )}
          </div>
          <div className="library-apply">
            <span>{packLabel(chosenId)}</span>
            <Button
              className="apply-button"
              isPending={studio.loadingPackId === chosenId}
              onPress={() => studio.choosePack(chosenId)}
            >
              Apply to {selectedKey ? keyLabel(selectedKey) : "keyboard"} <Check size={16} />
            </Button>
            <p>Preview freely. Apply when it feels right.</p>
          </div>
          <div className="library-footer">
            <span>{filtered.length} sounds to explore</span>
            <ArrowDown size={13} />
            <a
              href="https://github.com/kamillobinski/thock-soundpacks"
              target="_blank"
              rel="noreferrer"
            >
              Via Thock <ArrowUpRight size={12} />
            </a>
          </div>
        </aside>
      </div>

      <footer className="studio-footer">
        <span>A little sound. A lot of personality.</span>
        <span>Browser demo. Your settings stay on this device.</span>
        <Button variant="ghost" className="mobile-about" onPress={() => studio.setHelp(true)}>
          About OpenKlack
        </Button>
        <a href="/sounds/NOTICE.txt" target="_blank" rel="noreferrer">
          Sound credits <ArrowUpRight size={12} />
        </a>
      </footer>

      <Modal.Backdrop isOpen={studio.help} onOpenChange={studio.setHelp}>
        <Modal.Container size="sm">
          <Modal.Dialog className="help-dialog">
            <Modal.CloseTrigger />
            <Modal.Header>
              <span className="eyebrow">OpenKlack / Sound studio</span>
              <Modal.Heading>A little more character.</Modal.Heading>
            </Modal.Header>
            <Modal.Body>
              <p>
                Enable sound and type, or use a play button to preview a pack. Previewing lets you
                compare sounds without changing your keyboard.
              </p>
              <p>
                The collection includes 18 sound packs from Thock, originally from Mechvibes and
                kbsim. ABS and PBT packs use different keycap recordings. Some packs include
                separate release sounds and alternate samples.
              </p>
              <p>
                Choose <strong>Customize a key</strong> to mix switches across your keyboard. You
                can also lower that key’s volume. Your choices are saved on this device.
              </p>
              <p>
                Typing sounds work while the interactive keyboard is focused. The 3D keyboard uses
                the supplied Raycast reference model.
              </p>
              <a href="/sounds/NOTICE.txt" target="_blank" rel="noreferrer">
                Read sound credits and licenses <ArrowUpRight size={13} />
              </a>
            </Modal.Body>
            <Modal.Footer>
              <Button onPress={() => studio.setHelp(false)}>Back to the studio</Button>
            </Modal.Footer>
          </Modal.Dialog>
        </Modal.Container>
      </Modal.Backdrop>
    </section>
  );
}
