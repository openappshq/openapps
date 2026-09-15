import { StateIcon } from "@openapps/ui/state-icon";
import { withoutThemeTransitions } from "@openapps/ui/theme";
import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button, Link } from "@heroui/react";
import {
  ArrowLeft,
  Hourglass,
  KeyRound,
  Settings2,
  ShieldCheck,
  Volume2,
  VolumeX,
  Pause,
  WifiOff,
  X,
} from "lucide-react";
import { useDesktop } from "./useDesktop";
import { useLicense } from "./useLicense";
import { licensePill } from "./licenseState";
import { offersSetupGuide, withSetupGuideCompleted } from "./setupGuide";
import { KeyAssignments } from "./KeyAssignments";
import { CurrentPreset } from "./CurrentPreset";
import klackMark from "../../../design/assets/openklack/symbol-paper.svg";
import { SoundLibrary } from "./SoundLibrary";
import { AppRules } from "./AppRules";
import { General } from "./General";
import { Onboarding } from "./Onboarding";

type Page = "library" | "keyboard" | "rules" | "general";

export default function App() {
  const desktop = useDesktop();
  const { snapshot, packs, busy } = desktop;
  const license = useLicense(!!snapshot?.licensingEnabled, desktop.setError);
  const [animatePower, setAnimatePower] = useState(false);
  const [page, setPage] = useState<Page>("library");
  // A request to land on Settings → License; counted so each click scrolls there again.
  const licenseRequested = useRef(false);
  const [licenseRequests, setLicenseRequests] = useState(0);
  // `undefined` follows the saved preference: official builds open the guide once.
  const [guide, setGuide] = useState<boolean>();
  const [key, setKey] = useState("Space");
  const [theme, setTheme] = useState(() => {
    const saved = localStorage.getItem("openklack-theme");
    return saved === "light" || saved === "dark" ? saved : "system";
  });
  useEffect(() => {
    const system = matchMedia("(prefers-color-scheme: dark)");
    const apply = () =>
      withoutThemeTransitions(() => {
        document.documentElement.dataset.theme =
          theme === "system" ? (system.matches ? "dark" : "light") : theme;
      });
    apply();
    system.addEventListener("change", apply);
    return () => system.removeEventListener("change", apply);
  }, [theme]);
  const errorMessage = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (desktop.error) errorMessage.current?.scrollIntoView({ block: "nearest" });
  }, [desktop.error]);
  useEffect(() => {
    if (licenseRequested.current) {
      licenseRequested.current = false;
      const section = document.getElementById("license");
      section?.scrollIntoView({ block: "start" });
      section?.focus({ preventScroll: true });
    } else window.scrollTo({ top: 0 });
  }, [page, licenseRequests]);
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
  const pill = licensePill(license.view);
  const showGuide = snapshot ? (guide ?? offersSetupGuide(snapshot)) : false;
  function openLicense() {
    licenseRequested.current = true;
    setPage("general");
    setLicenseRequests((count) => count + 1);
  }
  function finishGuide() {
    setGuide(false);
    if (!prefs?.onboardingCompleted) void desktop.save(withSetupGuideCompleted);
  }
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
      {showGuide && (
        <Onboarding
          official={snapshot.licensingEnabled}
          inputPermission={snapshot.runtime.inputPermission}
          busy={busy}
          onRequestPermission={() => void desktop.perform(() => invoke("request_input_permission"))}
          onDone={finishGuide}
        />
      )}
      <div className="main-column" inert={showGuide}>
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
          <Button
            variant="secondary"
            isDisabled={busy}
            className="power-button"
            aria-pressed={!prefs.muted}
            onPress={(event) => {
              setAnimatePower(event.pointerType !== "keyboard");
              void desktop.save((p) => ({ ...p, muted: !p.muted }));
            }}
          >
            <StateIcon
              state={prefs.muted ? "off" : snapshot.pauseReason ? "paused" : "on"}
              static={!animatePower}
            >
              {prefs.muted ? (
                <VolumeX size={16} />
              ) : snapshot.pauseReason ? (
                <Pause size={16} />
              ) : (
                <Volume2 size={16} />
              )}
            </StateIcon>
            {prefs.muted ? "Sound off" : snapshot.pauseReason ? "Sound paused" : "Sound on"}
          </Button>
          {pill && (
            <Button
              variant="secondary"
              className="status-pill"
              data-warning={pill.warning}
              aria-label={`${pill.label}. Open License`}
              onPress={openLicense}
            >
              {pill.warning ? (
                license.view?.state === "trialEnded" || license.view?.state === "revoked" ? (
                  <KeyRound size={16} aria-hidden="true" />
                ) : (
                  <WifiOff size={16} aria-hidden="true" />
                )
              ) : (
                <Hourglass size={16} aria-hidden="true" />
              )}
              {pill.label}
            </Button>
          )}
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
          {!prefs.muted &&
            snapshot.runtime.inputPermission &&
            !snapshot.runtime.configurationError &&
            !snapshot.runtime.audioError &&
            (snapshot.pauseReason || snapshot.runtime.temporaryResume) && (
              <div className="pause-banner" role="status">
                <Pause size={16} aria-hidden="true" />
                <p>{snapshot.pauseReason ?? "Temporarily resumed"}</p>
                {[
                  "Paused for this app",
                  "Microphone in use",
                  "Checking microphone activity",
                ].includes(snapshot.pauseReason ?? "") && (
                  <Button
                    variant="ghost"
                    onPress={() => void desktop.perform(() => invoke("resume_temporarily"))}
                  >
                    Resume temporarily
                  </Button>
                )}
                {snapshot.runtime.licenseBlocked && page !== "general" && (
                  <Button variant="ghost" onPress={openLicense}>
                    Open License
                  </Button>
                )}
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
          <div className="page-content">
            {(page === "library" || page === "keyboard") && (
              <>
                {effective?.id !== preset.id && (
                  <p className="inline-hint">
                    An app rule is active. Changes here apply to your default sound.
                  </p>
                )}
                <div className="sound-workspace" data-editing={page === "keyboard"}>
                  {page === "library" && <SoundLibrary desktop={desktop} preset={preset} />}
                  <CurrentPreset
                    desktop={desktop}
                    preset={preset}
                    pack={pack}
                    selected={key}
                    onSelect={setKey}
                    editing={page === "keyboard"}
                    onEdit={() => setPage(page === "keyboard" ? "library" : "keyboard")}
                  />
                  {page === "keyboard" && (
                    <KeyAssignments
                      desktop={desktop}
                      preset={preset}
                      pack={pack}
                      selected={key}
                      onSelect={setKey}
                    />
                  )}
                </div>
              </>
            )}
            {page === "rules" && <AppRules desktop={desktop} />}
            {page === "general" && (
              <General
                desktop={desktop}
                license={license}
                preset={preset}
                onApps={() => setPage("rules")}
                onShowGuide={() => setGuide(true)}
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
          </div>
        </main>
      </div>
    </div>
  );
}
