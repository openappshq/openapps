import { useCallback, useEffect, useEffectEvent, useRef, useState } from "react";
import { createAudio, type PlayingSound } from "./audio";
import {
  acceptsKeyboardEvent,
  createInput,
  defaults,
  readSettings,
  voiceForKey,
  type InputSource,
  type KeyVoice,
} from "./keyboard";

const storageKey = "openklack:settings:v2";

export function useStudio() {
  const [settings, setSettings] = useState(() => {
    try {
      return readSettings(
        localStorage.getItem(storageKey) ?? localStorage.getItem("openklack:settings:v1"),
      );
    } catch {
      return defaults;
    }
  });
  const [audio] = useState(createAudio);
  const [input] = useState(createInput);
  const [enabled, setEnabled] = useState(false);
  const [enabling, setEnabling] = useState(false);
  const [ready, setReady] = useState(false);
  const [selectedKey, setSelectedKey] = useState<string | null>(null);
  const [help, setHelp] = useState(false);
  const [error, setError] = useState("");
  const [saveError, setSaveError] = useState(false);
  const [loadingPackId, setLoadingPackId] = useState<string | null>(null);
  const [auditionId, setAuditionId] = useState<string | null>(null);
  const [reducedMotion, setReducedMotion] = useState(
    () => matchMedia("(prefers-reduced-motion: reduce)").matches,
  );
  const latest = useRef({ settings, selectedKey, enabled });
  const heldVoices = useRef(new Map<string, KeyVoice>());
  const timers = useRef(new Set<ReturnType<typeof setTimeout>>());
  const previewSounds = useRef<PlayingSound[]>([]);
  const operation = useRef(0);

  useEffect(() => {
    latest.current = { settings, selectedKey, enabled };
    audio.configure(settings.volume, enabled);
  }, [settings, selectedKey, enabled, audio]);
  /* oxlint-disable react/set-state-in-effect -- Report localStorage write failures from the persistence effect. */
  useEffect(() => {
    try {
      localStorage.setItem(storageKey, JSON.stringify(settings));
      setSaveError(false);
    } catch {
      setSaveError(true);
    }
  }, [settings]);
  /* oxlint-enable react/set-state-in-effect */
  useEffect(() => {
    const query = matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReducedMotion(query.matches);
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  useEffect(() => {
    // Fetch only the current pack initially; overrides load when typing sound is enabled.
    void audio.load(latest.current.settings.packId).catch(() => {});
  }, [audio]);

  const press = useCallback(
    (code: string, source: InputSource) => {
      if (!input.press(code, source)) return;
      if (latest.current.selectedKey !== null) setSelectedKey(code);
      const voice = voiceForKey(latest.current.settings, code);
      heldVoices.current.set(code, voice);
      audio.play(voice, code, true, latest.current.settings);
    },
    [audio, input],
  );
  const release = useCallback(
    (code: string, source: InputSource) => {
      if (!input.release(code, source)) return;
      const voice = heldVoices.current.get(code);
      if (voice) audio.play(voice, code, false, latest.current.settings);
      heldVoices.current.delete(code);
    },
    [audio, input],
  );
  const stopPreview = useCallback(() => {
    operation.current++;
    setLoadingPackId(null);
    setEnabling(false);
    timers.current.forEach(clearTimeout);
    timers.current.clear();
    previewSounds.current.forEach((sound) => audio.stop(sound));
    previewSounds.current = [];
    input.clear("preview");
    setAuditionId(null);
  }, [audio, input]);
  const onKeyboard = useEffectEvent((event: KeyboardEvent) => {
    if (help || !(event.target instanceof Element) || !event.target.closest(".keyboard-canvas"))
      return;
    if (event.code === "Escape" && selectedKey) {
      setSelectedKey(null);
      return;
    }
    if (!acceptsKeyboardEvent(event)) return;
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
      if (event.code.startsWith("Meta")) {
        input.clear("keyboard");
        heldVoices.current.clear();
      }
    };
    const clear = () => {
      input.clear();
      heldVoices.current.clear();
      stopPreview();
    };
    const pointerUp = () => {
      for (const code of [...input.pressed]) release(code, "pointer");
    };
    const visibility = () => {
      if (document.hidden) clear();
    };
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    window.addEventListener("blur", clear);
    document.addEventListener("visibilitychange", visibility);
    window.addEventListener("pointerup", pointerUp);
    window.addEventListener("pointercancel", pointerUp);
    return () => {
      window.removeEventListener("keydown", down);
      window.removeEventListener("keyup", up);
      window.removeEventListener("blur", clear);
      document.removeEventListener("visibilitychange", visibility);
      window.removeEventListener("pointerup", pointerUp);
      window.removeEventListener("pointercancel", pointerUp);
      clear();
    };
  }, [input, release, stopPreview]);
  const sceneReady = useCallback(() => setReady(true), []);

  function after(delay: number, callback: () => void) {
    const timer = setTimeout(() => {
      timers.current.delete(timer);
      callback();
    }, delay);
    timers.current.add(timer);
  }
  function playSequence(packId: string, key: string | null) {
    setAuditionId(packId);
    const keys = key ? [key, key, key] : ["KeyA", "KeyS", "KeyD", "Space", "Enter", "Backspace"];
    const voice = { packId, volume: 100 };
    keys.forEach((code, index) => {
      after(index * 170, () => {
        input.press(code, "preview");
        const sound = audio.play(voice, code, true, latest.current.settings, true);
        if (sound) previewSounds.current.push(sound);
      });
      after(index * 170 + 80, () => {
        input.release(code, "preview");
        const sound = audio.play(voice, code, false, latest.current.settings, true);
        if (sound) previewSounds.current.push(sound);
      });
    });
    after(keys.length * 170 + 200, () => setAuditionId(null));
  }
  async function choosePack(packId: string, previewOnly = false) {
    stopPreview();
    const request = operation.current;
    const targetKey = selectedKey;
    setError("");
    setLoadingPackId(packId);
    try {
      const current = latest.current.settings;
      const required = previewOnly
        ? [packId]
        : [
            packId,
            current.packId,
            ...Object.values(current.overrides).map((voice) => voice.packId),
          ];
      await audio.unlock(required);
      if (request !== operation.current) return;
      if (!previewOnly) {
        setSettings((current) =>
          targetKey
            ? {
                ...current,
                overrides: {
                  ...current.overrides,
                  [targetKey]: { packId, volume: current.overrides[targetKey]?.volume ?? 100 },
                },
              }
            : { ...current, packId },
        );
        setEnabled(true);
      }
      playSequence(packId, targetKey);
    } catch (cause) {
      if (request === operation.current)
        setError(
          cause instanceof Error ? cause.message : "Sound couldn’t load. Try that pack again.",
        );
    } finally {
      if (request === operation.current) setLoadingPackId(null);
    }
  }
  async function enableSound(next: boolean) {
    stopPreview();
    if (!next) {
      setEnabled(false);
      return;
    }
    const request = operation.current;
    setEnabling(true);
    setError("");
    try {
      await audio.unlock([
        settings.packId,
        ...Object.values(settings.overrides).map((voice) => voice.packId),
      ]);
      if (request === operation.current) setEnabled(true);
    } catch (cause) {
      if (request === operation.current)
        setError(
          cause instanceof Error ? cause.message : "Sound couldn’t load. Try enabling it again.",
        );
    } finally {
      if (request === operation.current) setEnabling(false);
    }
  }
  function resetKey(code: string) {
    setSettings((current) => {
      const overrides = { ...current.overrides };
      delete overrides[code];
      return { ...current, overrides };
    });
  }
  return {
    settings,
    setSettings,
    input,
    enabled,
    enabling,
    ready,
    selectedKey,
    setSelectedKey,
    help,
    setHelp,
    error,
    saveError,
    loadingPackId,
    auditionId,
    reducedMotion,
    press,
    release,
    sceneReady,
    choosePack,
    enableSound,
    stopPreview,
    resetKey,
  };
}
