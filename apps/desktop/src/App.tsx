import { motion } from "motion/react";
import { enter } from "@openklack/ui/transitions";
import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button } from "@heroui/react";
import {
  AudioLines,
  BookOpen,
  Check,
  Keyboard,
  Play,
  RotateCcw,
  Settings2,
  ShieldCheck,
  Square,
  Volume2,
  VolumeX,
  X,
  SlidersHorizontal,
} from "lucide-react";
import { useDesktop, packLabel } from "./useDesktop";
import { Level, Toggle } from "./controls";
import { keyCodes, keyLabel } from "@openklack/keyboard-layout";
import { SoundLibrary } from "./SoundLibrary";
import { Presets } from "./Presets";
import { AppRules } from "./AppRules";
import { KeyboardPreview } from "./KeyboardPreview";
import { General } from "./General";

const pages = [
  { id: "keyboard", label: "Keyboard", icon: Keyboard },
  { id: "presets", label: "Presets", icon: BookOpen },
  { id: "rules", label: "App rules", icon: Settings2 },
  { id: "general", label: "General", icon: SlidersHorizontal },
] as const;

export default function App() {
  const desktop = useDesktop();
  const { snapshot, packs, busy } = desktop;
  const [page, setPage] = useState<(typeof pages)[number]["id"]>("keyboard");
  const [key, setKey] = useState("Space");
  const errorMessage = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (desktop.error) errorMessage.current?.scrollIntoView({ block: "nearest" });
  }, [desktop.error]);
  useEffect(() => {
    window.scrollTo({ top: 0 });
  }, [page]);
  const prefs = snapshot?.preferences;
  const preset = prefs?.presets.find((p) => p.id === prefs.activePresetId);
  const pack = packs.find((p) => p.id === preset?.packId) ?? {
    id: preset?.packId ?? "",
    name: "Unavailable sound",
    brand: "",
    color: "#d9ddcd",
    originalId: "",
    version: "",
    kind: "",
    description: "",
    author: "",
    credits: "",
    supportsKeyUp: false,
  };
  const effective = prefs?.presets.find((p) => p.id === snapshot?.effectivePresetId);
  if (!snapshot || !prefs || !preset)
    return (
      <main className="starting">
        <div className="brand-mark">K</div>
        <h1>OpenKlack</h1>
        <p role={desktop.error ? "alert" : "status"}>{desktop.error || "Preparing your sounds…"}</p>
        {desktop.error && (
          <Button variant="secondary" onPress={() => location.reload()}>
            Try again
          </Button>
        )}
      </main>
    );
  const assignment = preset.overrides[key];
  const change = (patch: Parameters<typeof desktop.changePreset>[1]) =>
    void desktop.changePreset(preset.id, patch);
  return (
    <div className="app-shell">
      <a className="skip-link" href="#content">
        Skip to settings
      </a>
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark">K</span>
          <strong>OpenKlack</strong>
        </div>
        <nav aria-label="Settings">
          {pages.map(({ id, label, icon: Icon }) => (
            <Button
              key={id}
              variant="ghost"
              className={`nav-item ${page === id ? "active" : ""}`}
              aria-current={page === id ? "page" : undefined}
              onPress={() => setPage(id)}
            >
              {page === id && (
                <motion.span
                  className="nav-highlight"
                  layoutId="desktop-navigation"
                  aria-hidden="true"
                />
              )}
              <Icon size={17} />
              <span>{label}</span>
            </Button>
          ))}
        </nav>
        <div className="sidebar-note">
          <span className="small-key" aria-hidden="true">
            ⌘
          </span>
          <p>
            A little character.
            <br />
            Every keystroke.
          </p>
        </div>
        <div className="sidebar-bottom">
          <span>Open source. Yours.</span>
          <span className="mono">macOS / {snapshot.version}</span>
        </div>
      </aside>
      <div className="main-column">
        <div className="topbar">
          <div className="status" role="status">
            <span className={`status-dot ${snapshot.pauseReason ? "paused" : ""}`} />
            {snapshot.pauseReason ??
              (snapshot.runtime.temporaryResume ? "Temporarily resumed" : "Sound is on")}
          </div>
          <Button
            variant="secondary"
            isDisabled={busy}
            aria-pressed={prefs.muted}
            onPress={() => void desktop.save((p) => ({ ...p, muted: !p.muted }))}
          >
            {prefs.muted ? <VolumeX size={15} /> : <Volume2 size={15} />}
            {prefs.muted ? "Unmute" : "Mute"}
          </Button>
        </div>
        <main id="content" tabIndex={-1}>
          {!snapshot.runtime.inputPermission && (
            <section className="permission">
              <ShieldCheck size={23} />
              <div>
                <h2>Sound in every app starts here.</h2>
                <p>
                  Allow Input Monitoring to hear your keys across your Mac. Typed text is never
                  saved.
                </p>
              </div>
              <Button
                variant="primary"
                isDisabled={busy}
                onPress={() => void desktop.perform(() => invoke("request_input_permission"))}
              >
                Enable Input Monitoring
              </Button>
            </section>
          )}
          {["Paused for this app", "Microphone in use", "Checking microphone activity"].includes(
            snapshot.pauseReason ?? "",
          ) && (
            <div className="pause-banner">
              <p>{snapshot.pauseReason}. Your preset is ready when you are.</p>
              <Button
                variant="secondary"
                onPress={() => void desktop.perform(() => invoke("resume_temporarily"))}
              >
                Resume temporarily
              </Button>
            </div>
          )}
          <div className="feedback" role="status">
            {desktop.notice}
          </div>
          {desktop.error && (
            <div className="error" role="alert" ref={errorMessage}>
              <p>{desktop.error}</p>
              <Button
                isIconOnly
                variant="ghost"
                aria-label="Dismiss error"
                onPress={() => desktop.setError("")}
              >
                <X size={16} />
              </Button>
            </div>
          )}
          {snapshot.runtime.audioError && (
            <div className="error" role="alert">
              <p>
                {snapshot.runtime.audioError} Check your Mac’s audio output; OpenKlack retries
                automatically.
              </p>
            </div>
          )}
          {snapshot.recoveryNotices.map((notice) => (
            <p key={notice} className="inline-hint" role="status">
              {notice}
            </p>
          ))}
          {snapshot.runtime.configurationError && (
            <div className="error" role="alert">
              <p>
                {snapshot.runtime.configurationError} Your preset is preserved. Import its original
                sounds, or choose another sound below.
              </p>
              <Button
                variant="secondary"
                isDisabled={busy}
                onPress={() => void desktop.perform(() => invoke("retry_sounds"))}
              >
                Retry sounds
              </Button>
            </div>
          )}
          <motion.div key={page} {...enter} className="page-transition">
            {page === "keyboard" && (
              <>
                <header className="page-heading">
                  <div>
                    <span className="eyebrow">Your everyday keyboard</span>
                    <h1>{preset.name}</h1>
                  </div>
                  <Button variant="ghost" onPress={() => setPage("presets")}>
                    Manage presets<span aria-hidden="true">↗</span>
                  </Button>
                </header>
                {effective?.id !== preset.id && (
                  <p className="inline-hint">
                    An app rule is using “{effective?.name}”. You are editing the default preset, “
                    {preset.name}”.
                  </p>
                )}
                <KeyboardPreview
                  onError={desktop.setError}
                  canPick={snapshot.runtime.inputPermission && !snapshot.runtime.secureInput}
                  selected={key}
                  assignments={Object.keys(preset.overrides)}
                  onSelect={setKey}
                />
                <section className="sound-settings" aria-label="Preset playback">
                  <div className="current-sound">
                    <div
                      className="mini-key"
                      style={{ "--key-color": pack.color } as React.CSSProperties}
                      aria-hidden="true"
                    >
                      <span>+</span>
                    </div>
                    <div>
                      <span className="eyebrow">Default sound</span>
                      <h2>{packLabel(pack)}</h2>
                      <p>
                        {pack.supportsKeyUp
                          ? "Recorded press + release"
                          : "Recorded press · silent release"}
                      </p>
                    </div>
                    <Button
                      isIconOnly
                      variant="ghost"
                      isDisabled={busy}
                      aria-label={
                        desktop.preview === pack.id ? "Stop preview" : "Preview default sound"
                      }
                      onPress={() => void desktop.audition(pack.id)}
                    >
                      {desktop.preview === pack.id ? <Square size={17} /> : <Play size={17} />}
                    </Button>
                  </div>
                  <Level
                    label="Volume"
                    value={preset.volume}
                    disabled={busy}
                    onChange={(value) => change({ volume: value })}
                  />
                </section>
                <section className="key-settings settings-panel" aria-label="Key assignment">
                  <div className="section-heading">
                    <div>
                      <h2>Key sounds</h2>
                      <p>Give a key its own sound. The rest keep your default.</p>
                    </div>
                    <span className="count-label">
                      {Object.keys(preset.overrides).length} customized
                    </span>
                  </div>
                  <div className="assignment-fields">
                    <label>
                      Key
                      <select value={key} onChange={(e) => setKey(e.target.value)}>
                        {[
                          ...new Set([
                            ...keyCodes.filter(
                              (code) =>
                                !code.startsWith("Numpad") &&
                                code !== "PrintScreen" &&
                                code !== "NumLock",
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
                    <p>
                      Recording levels are matched across packs. Holding a key does not repeat its
                      sound.
                    </p>
                  </details>
                </section>
                <SoundLibrary desktop={desktop} preset={preset} />
              </>
            )}
            {page === "presets" && <Presets desktop={desktop} active={preset} />}
            {page === "rules" && <AppRules desktop={desktop} />}
            {page === "general" && <General desktop={desktop} />}
          </motion.div>
          <footer>
            <span>
              <Check size={13} />
              Saved on this Mac
            </span>
            <span>
              <AudioLines size={13} />
              Close settings. Keep your sound.
            </span>
          </footer>
        </main>
      </div>
    </div>
  );
}
