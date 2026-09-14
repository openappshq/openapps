import { motion } from "motion/react";
import { enter } from "@openapps/ui/transitions";
import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button, Link } from "@heroui/react";
import { ArrowLeft, Settings2, ShieldCheck, Volume2, VolumeX, X } from "lucide-react";
import { useDesktop } from "./useDesktop";
import { KeyAssignments } from "./KeyAssignments";
import { CurrentPreset } from "./CurrentPreset";
import klackMark from "../../../design/assets/openklack/symbol-paper.svg";
import { SoundLibrary } from "./SoundLibrary";
import { AppRules } from "./AppRules";
import { General } from "./General";

type Page = "library" | "keyboard" | "rules" | "general";

export default function App() {
  const desktop = useDesktop();
  const { snapshot, packs, busy } = desktop;
  const [page, setPage] = useState<Page>("library");
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
    source: "",
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
      <Link className="skip-link" href="#content">
        Skip to settings
      </Link>
      <div className="main-column">
        <div className="topbar">
          <Button
            variant="ghost"
            className="app-brand"
            onPress={() => setPage("library")}
            aria-label="OpenKlack sounds"
          >
            <img src={klackMark} alt="" />
            <strong>OpenKlack</strong>
          </Button>
          {page !== "library" && page !== "keyboard" && (
            <Button
              variant="ghost"
              onPress={() => setPage(page === "rules" ? "general" : "library")}
            >
              <ArrowLeft size={16} />
              {page === "rules" ? "Settings" : "Sounds"}
            </Button>
          )}
          {(snapshot.pauseReason || snapshot.runtime.temporaryResume) && (
            <div className="status" role="status">
              {snapshot.pauseReason ??
                (snapshot.runtime.temporaryResume ? "Temporarily resumed" : "")}
            </div>
          )}
          <Button
            variant="secondary"
            isDisabled={busy}
            aria-pressed={!prefs.muted}
            onPress={() => void desktop.save((p) => ({ ...p, muted: !p.muted }))}
          >
            {prefs.muted ? <VolumeX size={15} /> : <Volume2 size={15} />}
            {prefs.muted ? "Sound off" : "Sound on"}
          </Button>
          <Button
            isIconOnly
            variant="ghost"
            aria-label="Settings"
            aria-pressed={page === "general"}
            onPress={() => setPage(page === "general" ? "library" : "general")}
          >
            <Settings2 size={19} />
          </Button>
        </div>
        <main id="content" tabIndex={-1}>
          {!snapshot.runtime.inputPermission && (
            <section className="permission">
              <ShieldCheck size={23} />
              <div>
                <h2>Enable keyboard sounds</h2>
                <p>
                  Allow Input Monitoring so OpenKlack can respond to your keyboard. Your typing is
                  never saved.
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
              <p>{snapshot.pauseReason}.</p>
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
                {snapshot.runtime.configurationError} Your settings are preserved. Import the
                original sounds, or choose another sound below.
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
                {effective?.id !== preset.id && (
                  <p className="inline-hint">
                    An app rule is active. Changes here apply to your default sound.
                  </p>
                )}
                <CurrentPreset
                  desktop={desktop}
                  preset={preset}
                  pack={pack}
                  selected={key}
                  onSelect={setKey}
                  editing={page === "keyboard"}
                  onEdit={() => setPage(page === "keyboard" ? "library" : "keyboard")}
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
            {page === "rules" && <AppRules desktop={desktop} />}
            {page === "general" && (
              <General
                desktop={desktop}
                preset={preset}
                onApps={() => setPage("rules")}
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
        </main>
      </div>
    </div>
  );
}
