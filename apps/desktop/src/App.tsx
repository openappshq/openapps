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
  Settings2,
  ShieldCheck,
  Volume2,
  VolumeX,
  X,
  SlidersHorizontal,
  Library,
} from "lucide-react";
import { useDesktop } from "./useDesktop";
import { KeyAssignments } from "./KeyAssignments";
import { CurrentPreset } from "./CurrentPreset";
import klackMark from "../../../design/assets/openklack/symbol-paper.svg";
import { SoundLibrary } from "./SoundLibrary";
import { Presets } from "./Presets";
import { AppRules } from "./AppRules";
import { General } from "./General";

const pages = [
  { id: "library", label: "Sound library", icon: Library },
  { id: "presets", label: "My presets", icon: BookOpen },
  { id: "keyboard", label: "Key assignments", icon: Keyboard },
  { id: "rules", label: "Rules", icon: Settings2 },
  { id: "general", label: "Settings", icon: SlidersHorizontal },
] as const;

export default function App() {
  const desktop = useDesktop();
  const { snapshot, packs, busy } = desktop;
  const [page, setPage] = useState<(typeof pages)[number]["id"]>("library");
  const [key, setKey] = useState("Space");
  const [theme, setTheme] = useState(() => {
    const saved = localStorage.getItem("openklack-theme");
    return saved === "light" || saved === "dark" ? saved : "system";
  });
  useEffect(() => {
    const system = matchMedia("(prefers-color-scheme: dark)");
    const apply = () => {
      document.documentElement.dataset.theme =
        theme === "system" ? (system.matches ? "dark" : "light") : theme;
    };
    apply();
    system.addEventListener("change", apply);
    return () => system.removeEventListener("change", apply);
  }, [theme]);
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
        <div className="brand-mark">
          <img src={klackMark} alt="" />
        </div>
        <h1>OpenKlack</h1>
        <p role={desktop.error ? "alert" : "status"}>{desktop.error || "Preparing your sounds…"}</p>
        {desktop.error && (
          <Button variant="secondary" onPress={() => location.reload()}>
            Try again
          </Button>
        )}
      </main>
    );
  return (
    <div className="app-shell">
      <a className="skip-link" href="#content">
        Skip to settings
      </a>
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark">
            <img src={klackMark} alt="OpenKlack" />
          </span>
          <strong>
            Your kind of
            <br />
            click.
          </strong>
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
        <div className="sidebar-bottom">
          <div className="status" role="status">
            <span className={`status-dot ${snapshot.pauseReason ? "paused" : ""}`} />
            <span>{snapshot.pauseReason ?? "Ready to play"}</span>
          </div>
          <span className="mono">AN OPENAPPS HQ APP</span>
          <span>Free. Open. Yours.</span>
        </div>
      </aside>
      <div className="main-column">
        <div className="topbar">
          <span className="topbar-title">OpenKlack</span>
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
            {(page === "library" || page === "keyboard") && (
              <>
                <header className="page-heading">
                  <h1>{page === "library" ? "Sound library" : "Key assignments"}</h1>
                  <Button
                    variant="secondary"
                    isDisabled={busy}
                    onPress={() => void desktop.importSounds()}
                  >
                    Import sounds
                  </Button>
                </header>
                {effective?.id !== preset.id && (
                  <p className="inline-hint">
                    An app rule is using “{effective?.name}”. You are editing “{preset.name}”.
                  </p>
                )}
                <CurrentPreset
                  desktop={desktop}
                  preset={preset}
                  pack={pack}
                  selected={key}
                  onSelect={setKey}
                  compact={page === "library"}
                />
                {page === "library" ? (
                  <SoundLibrary desktop={desktop} preset={preset} />
                ) : (
                  <KeyAssignments
                    desktop={desktop}
                    preset={preset}
                    pack={pack}
                    selected={key}
                    onSelect={setKey}
                  />
                )}
              </>
            )}
            {page === "presets" && <Presets desktop={desktop} active={preset} />}
            {page === "rules" && <AppRules desktop={desktop} />}
            {page === "general" && (
              <General
                desktop={desktop}
                theme={theme}
                onThemeChange={(value) => {
                  try {
                    localStorage.setItem("openklack-theme", value);
                    setTheme(value);
                  } catch {
                    desktop.setError("Your appearance could not be saved. Please try again.");
                  }
                }}
              />
            )}
          </motion.div>
          <footer>
            <span>
              <Check size={13} />
              {busy
                ? "Saving changes…"
                : desktop.error
                  ? "Review the error above"
                  : "Saved on this Mac"}
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
