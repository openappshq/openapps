import { lazy, Suspense, useCallback, useEffect, useEffectEvent, useRef, useState } from "react";
import {
  Button,
  Description,
  Label,
  Modal,
  Radio,
  RadioGroup,
  Slider,
  Switch,
} from "@heroui/react";
import {
  ArrowUpRight,
  AudioLines,
  Check,
  ChevronDown,
  Keyboard as KeyboardIcon,
  Play,
  RotateCcw,
  SlidersHorizontal,
  Volume2,
  VolumeX,
  X,
} from "lucide-react";
import { createAudio } from "./audio";
import {
  acceptsKeyboardEvent,
  createInput,
  defaults,
  isProfile,
  keyCodes,
  keyLabel,
  profileForKey,
  profiles,
  readSettings,
  type Finish,
  type InputSource,
  type Profile,
} from "./keyboard";

const Keyboard = lazy(() => import("./KeyboardScene"));
const storageKey = "openklack:settings:v1";
const profileNames = Object.keys(profiles) as Profile[];
const finishNames: Finish[] = ["graphite", "chalk", "sage"];

function SoundOptions({
  value,
  onChange,
  detailed = false,
}: {
  value: Profile;
  onChange: (profile: Profile) => void;
  detailed?: boolean;
}) {
  return (
    <RadioGroup
      aria-label="Sound profile"
      orientation={detailed ? "vertical" : "horizontal"}
      value={value}
      onChange={(value) => {
        if (isProfile(value)) onChange(value);
      }}
      className={detailed ? "sound-list" : "sound-segments"}
    >
      {profileNames.map((name) => (
        <Radio key={name} value={name} className="sound-option">
          <Radio.Content className="sound-option-content">
            {detailed && (
              <Radio.Control>
                <Radio.Indicator />
              </Radio.Control>
            )}
            <span>
              {profiles[name].label}
              {detailed && <Description>{profiles[name].description}</Description>}
            </span>
            {detailed && <AudioLines size={18} className="profile-wave" />}
          </Radio.Content>
        </Radio>
      ))}
    </RadioGroup>
  );
}

export default function App() {
  const [settings, setSettings] = useState(() => {
    try {
      return readSettings(localStorage.getItem(storageKey));
    } catch {
      return defaults;
    }
  });
  const [audio] = useState(createAudio);
  const [input] = useState(createInput);
  const [enabled, setEnabled] = useState(false);
  const [audioLoading, setAudioLoading] = useState(false);
  const [ready, setReady] = useState(false);
  const [editor, setEditor] = useState(false);
  const [selected, setSelected] = useState("Space");
  const [help, setHelp] = useState(false);
  const [error, setError] = useState("");
  const [saveError, setSaveError] = useState(false);
  const [reducedMotion, setReducedMotion] = useState(
    () => matchMedia("(prefers-reduced-motion: reduce)").matches,
  );
  const latest = useRef({ settings, enabled, editor });
  const editorRef = useRef<HTMLElement>(null);
  const customizeRef = useRef<HTMLButtonElement>(null);
  const sampleTimers = useRef(new Set<ReturnType<typeof setTimeout>>());
  useEffect(() => {
    latest.current = { settings, enabled, editor };
    audio.configure(settings.volume, enabled);
  }, [settings, enabled, editor, audio]);
  useEffect(() => {
    try {
      localStorage.setItem(storageKey, JSON.stringify(settings));
      setSaveError(false);
    } catch {
      setSaveError(true);
    }
  }, [settings]);
  useEffect(() => {
    const query = matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReducedMotion(query.matches);
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  useEffect(() => {
    if (editor) editorRef.current?.focus();
  }, [editor]);

  const press = useCallback(
    (code: string, source: InputSource) => {
      if (!input.press(code, source)) return;
      if (latest.current.editor) setSelected(code);
      audio.play(code, true, profileForKey(latest.current.settings, code));
    },
    [audio, input],
  );
  const release = useCallback(
    (code: string, source: InputSource) => {
      if (input.release(code, source))
        audio.play(code, false, profileForKey(latest.current.settings, code));
    },
    [audio, input],
  );
  const closeEditor = useCallback(() => {
    setEditor(false);
    customizeRef.current?.focus();
  }, []);
  const onKeyboard = useEffectEvent((event: KeyboardEvent) => {
    if (event.code === "Escape" && editor) {
      closeEditor();
      return;
    }
    if (help || !acceptsKeyboardEvent(event)) return;
    if (
      !event.metaKey &&
      !event.ctrlKey &&
      ["Space", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.code)
    )
      event.preventDefault();
    press(event.code, "keyboard");
  });
  useEffect(() => {
    const down = (event: KeyboardEvent) => onKeyboard(event);
    const up = (event: KeyboardEvent) => {
      release(event.code, "keyboard");
      if (event.code.startsWith("Meta")) input.clear("keyboard");
    };
    const clear = () => input.clear();
    const clearPointer = () => {
      for (const code of [...input.pressed]) release(code, "pointer");
    };
    const visibility = () => {
      if (document.hidden) clear();
    };
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    window.addEventListener("blur", clear);
    document.addEventListener("visibilitychange", visibility);
    window.addEventListener("pointerup", clearPointer);
    window.addEventListener("pointercancel", clearPointer);
    return () => {
      window.removeEventListener("keydown", down);
      window.removeEventListener("keyup", up);
      window.removeEventListener("blur", clear);
      document.removeEventListener("visibilitychange", visibility);
      window.removeEventListener("pointerup", clearPointer);
      window.removeEventListener("pointercancel", clearPointer);
      sampleTimers.current.forEach(clearTimeout);
      clear();
    };
  }, [input, press, release]);
  const sceneReady = useCallback(() => setReady(true), []);

  async function enableSound(next: boolean) {
    if (!next) {
      setEnabled(false);
      return;
    }
    setAudioLoading(true);
    setError("");
    try {
      await audio.unlock();
      setEnabled(true);
    } catch {
      setError("Sound couldn’t load. Try enabling it again.");
    } finally {
      setAudioLoading(false);
    }
  }
  async function preview(profile: Profile, code = "Space") {
    setError("");
    try {
      await audio.unlock();
      setEnabled(true);
      audio.configure(latest.current.settings.volume, true);
      audio.play(code, true, profile);
      input.press(code, "pointer");
      const timer = setTimeout(() => {
        input.release(code, "pointer");
        audio.play(code, false, profile);
        sampleTimers.current.delete(timer);
      }, 100);
      sampleTimers.current.add(timer);
    } catch {
      setError("Sound couldn’t load. Try enabling it again.");
    }
  }
  function setProfile(profile: Profile) {
    setSettings((current) => ({ ...current, profile }));
    void preview(profile);
  }
  function setOverride(profile: Profile) {
    setSettings((current) => ({
      ...current,
      overrides: { ...current.overrides, [selected]: profile },
    }));
    void preview(profile, selected);
  }
  const override = settings.overrides[selected];
  const activeProfile = profileForKey(settings, selected);

  return (
    <div className="app-shell">
      <header className="site-header">
        <a className="wordmark" href="/" aria-label="OpenKlack home">
          <span className="brand-key">
            <AudioLines size={23} strokeWidth={1.8} />
          </span>
          openklack<span className="beta-label">PLAYGROUND</span>
        </a>
        <div className="header-actions">
          <Button variant="ghost" className="how-button" onPress={() => setHelp(true)}>
            How it works <ArrowUpRight size={15} />
          </Button>
          <span className="header-divider" />
          <Switch
            isSelected={enabled}
            onChange={enableSound}
            isDisabled={audioLoading}
            className="sound-switch"
            aria-label="Keyboard sound"
          >
            <Switch.Content>
              <span className="sound-switch-label">
                {audioLoading ? "Loading…" : enabled ? "Sound on" : "Sound off"}
              </span>
              <Switch.Control>
                <Switch.Thumb />
              </Switch.Control>
            </Switch.Content>
          </Switch>
        </div>
      </header>

      <main className={`playground${editor ? " is-editing" : ""}`}>
        <div className="play-area">
          <section className="intro" aria-labelledby="page-title">
            <p className="eyebrow">A LITTLE JOY, EVERY KEYSTROKE</p>
            <h1 id="page-title">
              {editor ? (
                <>
                  A little character
                  <br />
                  in every key.
                </>
              ) : (
                <>
                  Your keys.
                  <br className="mobile-break" /> Your kind of click.
                </>
              )}
            </h1>
            <p className="subtitle">
              {editor
                ? "Keep the sound you love. Give a few keys their own voice."
                : "Mechanical sounds. A keyboard that feels like you."}
            </p>
            <div className="typing-prompt">
              {ready ? <span className="live-dot" /> : <span className="loading-dot" />}
              <span>
                {!ready
                  ? "Setting your keyboard on the desk…"
                  : editor
                    ? "Press or click a key to make it yours."
                    : "Go on, type something."}
              </span>
            </div>
          </section>

          <section className="keyboard-stage" aria-label="Keyboard playground">
            <div className="keyboard-shadow" />
            <Suspense fallback={<div className="scene-fallback">Loading your keyboard…</div>}>
              <Keyboard
                input={input}
                finish={settings.finish}
                selected={editor ? selected : null}
                reducedMotion={reducedMotion}
                onPress={press}
                onRelease={release}
                onReady={sceneReady}
              />
            </Suspense>
            <div className="keyboard-caption">
              <span>
                THE REFERENCE <span className="caption-slash">/</span>{" "}
                {settings.finish.toUpperCase()}
              </span>
              <span>75% LAYOUT</span>
            </div>
          </section>

          <section className="control-dock" aria-label="Keyboard settings">
            <div className="dock-group sound-group">
              <span className="control-label">Your sound</span>
              <SoundOptions value={settings.profile} onChange={setProfile} />
            </div>
            <div className="dock-group finish-group">
              <span className="control-label">
                Keycaps <span className="finish-name">{settings.finish}</span>
              </span>
              <RadioGroup
                aria-label="Keycap finish"
                orientation="horizontal"
                value={settings.finish}
                onChange={(value) => {
                  if (finishNames.includes(value as Finish))
                    setSettings((current) => ({ ...current, finish: value as Finish }));
                }}
                className="swatches"
              >
                {finishNames.map((finish) => (
                  <Radio
                    key={finish}
                    value={finish}
                    className={`swatch swatch-${finish}`}
                    aria-label={finish}
                  >
                    <Radio.Content aria-label={finish}>
                      <Check size={13} />
                    </Radio.Content>
                  </Radio>
                ))}
              </RadioGroup>
            </div>
            <Slider
              minValue={0}
              maxValue={100}
              value={settings.volume}
              onChange={(value) =>
                setSettings((current) => ({ ...current, volume: Number(value) }))
              }
              className="dock-volume"
            >
              <div className="volume-heading">
                <Label>Volume</Label>
                <Slider.Output>{settings.volume}%</Slider.Output>
              </div>
              <div className="volume-track">
                {settings.volume === 0 ? <VolumeX size={17} /> : <Volume2 size={17} />}
                <Slider.Track>
                  <Slider.Fill />
                  <Slider.Thumb aria-label="Volume" />
                </Slider.Track>
              </div>
            </Slider>
            <Button
              ref={customizeRef}
              variant="secondary"
              className="customize-button"
              onPress={() => (editor ? closeEditor() : setEditor(true))}
              aria-expanded={editor}
              aria-controls="key-editor"
            >
              <SlidersHorizontal size={16} /> {editor ? "Close editor" : "Customize keys"}
              {Object.keys(settings.overrides).length > 0 && (
                <span className="override-count">{Object.keys(settings.overrides).length}</span>
              )}
            </Button>
          </section>
          {!enabled && (
            <Button
              variant="ghost"
              size="sm"
              className="enable-hint"
              onPress={() => enableSound(true)}
              isPending={audioLoading}
            >
              <Volume2 size={15} /> Enable sound to hear your keyboard
            </Button>
          )}
          {error && (
            <p role="alert" className="status-error">
              {error}
            </p>
          )}
          {saveError && (
            <p role="status" className="status-error">
              Your changes work here, but this browser couldn’t save them.
            </p>
          )}
        </div>

        {editor && (
          <aside
            className="key-editor"
            id="key-editor"
            aria-labelledby="editor-title"
            tabIndex={-1}
            ref={editorRef}
          >
            <div className="editor-heading">
              <h2 id="editor-title">KEY SOUND</h2>
              <Button
                isIconOnly
                variant="ghost"
                size="sm"
                onPress={closeEditor}
                aria-label="Close key editor"
              >
                <X size={18} />
              </Button>
            </div>
            <div className="selected-key">
              <span>{keyLabel(selected)}</span>
            </div>
            <label className="key-selector-label" htmlFor="key-selector">
              Choose a key
            </label>
            <div className="key-selector">
              <select
                id="key-selector"
                value={selected}
                onChange={(event) => setSelected(event.target.value)}
              >
                {keyCodes.map((code) => (
                  <option key={code} value={code}>
                    {keyLabel(code)}
                  </option>
                ))}
              </select>
              <ChevronDown size={15} />
            </div>
            <p className="key-description">Give {keyLabel(selected)} its own voice.</p>
            <SoundOptions value={activeProfile} onChange={setOverride} detailed />
            <Button
              variant="secondary"
              className="preview-button"
              onPress={() => preview(activeProfile, selected)}
            >
              <Play size={14} fill="currentColor" /> Preview {keyLabel(selected)}
            </Button>
            <p className="global-note">
              The rest of your keyboard stays on <strong>{profiles[settings.profile].label}</strong>
              .
            </p>
            <div className="editor-bottom">
              <Button
                variant="ghost"
                size="sm"
                className="reset-button"
                isDisabled={!override}
                onPress={() =>
                  setSettings((current) => {
                    const overrides = { ...current.overrides };
                    delete overrides[selected];
                    return { ...current, overrides };
                  })
                }
              >
                <RotateCcw size={14} /> Use keyboard sound instead
              </Button>
              <Button onPress={closeEditor} className="done-button">
                Done <Check size={15} />
              </Button>
              <span className="saved-note">
                {saveError ? "Changes for this visit" : "Saved on this device"}
              </span>
            </div>
          </aside>
        )}
      </main>

      <footer className="site-footer">
        <span>Just type. Stay a while.</span>
        <span>
          <KeyboardIcon size={14} /> Sound plays while this tab is active.
        </span>
      </footer>

      <Modal isOpen={help} onOpenChange={setHelp}>
        <Modal.Backdrop>
          <Modal.Container size="sm">
            <Modal.Dialog className="help-dialog">
              <Modal.CloseTrigger />
              <Modal.Header>
                <span className="brand-key">
                  <AudioLines size={23} />
                </span>
                <Modal.Heading>Make yourself heard.</Modal.Heading>
              </Modal.Header>
              <Modal.Body>
                <p>
                  Turn sound on, then type or click the keyboard. Each press has its own movement,
                  light, and sound.
                </p>
                <p>
                  Choose a sound for the whole keyboard, or open <strong>Customize keys</strong> to
                  give individual keys a different voice. Your choices are saved on this device.
                </p>
                <p>
                  OpenKlack works in this page while it’s focused. Typing in other apps needs a
                  future desktop companion.
                </p>
                <p className="reference-note">
                  This prototype uses Raycast’s keyboard model and recording from the supplied
                  reference. Deep, Crisp, and Clicky are three treatments of that recording.
                </p>
              </Modal.Body>
              <Modal.Footer>
                <Button onPress={() => setHelp(false)}>Back to the keyboard</Button>
              </Modal.Footer>
            </Modal.Dialog>
          </Modal.Container>
        </Modal.Backdrop>
      </Modal>
    </div>
  );
}
