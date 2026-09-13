import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export type Preset = {
  id: string;
  name: string;
  packId: string;
  volume: number;
  releaseVolume: number;
  variation: boolean;
  favorite: boolean;
  overrides: Record<string, { packId: string; volume: number }>;
};
export type Preferences = {
  schemaVersion: number;
  muted: boolean;
  pauseOnMicrophone: boolean;
  activePresetId: string;
  presets: Preset[];
  appRules: { bundleId: string; name: string; presetId: string | null; mute: boolean }[];
};
export type Snapshot = {
  version: string;
  revision: number;
  preferences: Preferences;
  runtime: {
    inputPermission: boolean;
    microphone: number;
    secureInput: boolean;
    audioReady: boolean;
    audioError: string | null;
    configurationError: string | null;
    frontmostApp: string;
    outputSampleRate: number;
    temporaryResume: boolean;
  };
  pauseReason: string | null;
  effectivePresetId: string;
  recoveryNotices: string[];
};
export type Pack = {
  id: string;
  originalId: string;
  version: string;
  name: string;
  brand: string;
  kind: string;
  color: string;
  description: string;
  author: string;
  credits: string;
  supportsKeyUp: boolean;
};
export const packLabel = (pack: Pack) => `${pack.brand} ${pack.name}`.trim();

export function useDesktop() {
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const current = useRef<Snapshot | undefined>(undefined);
  const [packs, setPacks] = useState<Pack[]>([]);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const operation = useRef(Promise.resolve());
  const [preview, setPreview] = useState<string | null>(null);
  const previewTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  function accept(state: Snapshot) {
    if (current.current && state.revision < current.current.revision) return;
    current.current = state;
    setSnapshot(state);
  }
  async function refresh() {
    const [state, catalog] = await Promise.all([
      invoke<Snapshot>("get_state"),
      invoke<Pack[]>("get_catalog"),
    ]);
    accept(state);
    setPacks(
      catalog.sort(
        (a, b) => packLabel(a).localeCompare(packLabel(b)) || a.version.localeCompare(b.version),
      ),
    );
  }
  useEffect(() => {
    let disposed = false;
    const cleanup: (() => void)[] = [];
    async function subscribe() {
      const subscriptions = await Promise.all([
        listen<Snapshot>("state", ({ payload }) => {
          if (!disposed) accept(payload);
        }),
        listen("preview-stopped", () => {
          if (!disposed) {
            clearTimeout(previewTimer.current);
            setPreview(null);
          }
        }),
      ]);
      cleanup.push(...subscriptions);
      if (disposed) cleanup.forEach((off) => off());
      else await refresh();
    }
    void subscribe().catch((e: unknown) => {
      if (!disposed) setError(String(e));
    });
    return () => {
      disposed = true;
      cleanup.forEach((off) => off());
      clearTimeout(previewTimer.current);
    };
  }, []);

  function perform<T>(task: () => Promise<T>): Promise<T | undefined> {
    const result = operation.current.then(async () => {
      setBusy(true);
      setError("");
      setNotice("");
      try {
        return await task();
      } catch (e) {
        setError(String(e));
      } finally {
        setBusy(false);
      }
    });
    operation.current = result.then(() => {});
    return result;
  }
  async function save(change: (preferences: Preferences) => Preferences) {
    return perform(async () => {
      const state = current.current;
      if (!state) return;
      try {
        accept(
          await invoke<Snapshot>("save_preferences", {
            preferences: change(state.preferences),
            expectedRevision: state.revision,
          }),
        );
        return true;
      } catch (e) {
        await refresh();
        throw e;
      }
    });
  }
  function changePreset(id: string, patch: Partial<Preset>) {
    return save((prefs) => ({
      ...prefs,
      presets: prefs.presets.map((p) => (p.id === id ? { ...p, ...patch } : p)),
    }));
  }
  async function audition(id: string) {
    return perform(async () => {
      clearTimeout(previewTimer.current);
      if (preview === id) {
        await invoke("stop_preview");
        setPreview(null);
      } else {
        const duration = await invoke<number>("preview_pack", { packId: id });
        setPreview(id);
        previewTimer.current = setTimeout(() => setPreview(null), duration);
      }
    });
  }
  async function importSounds() {
    return perform(async () => {
      const result = await invoke<{ packIds: string[]; preset: Preset | null } | null>(
        "import_sounds",
      ).finally(refresh);
      if (!result) return;
      setNotice(
        result.preset
          ? `Imported “${result.preset.name}”. Select it in Presets when you are ready.`
          : "Sounds imported. Find them in All sounds; your active preset has stayed the same.",
      );
    });
  }
  async function exportPreset(id: string) {
    return perform(async () => {
      if (await invoke<boolean>("export_preset", { presetId: id }))
        setNotice("Preset exported with its recordings and credits.");
    });
  }
  async function checkPackUpdates() {
    return perform(async () => {
      const added = await invoke<number>("refresh_official_packs");
      await refresh();
      setNotice(
        added
          ? `${added} new pack versions added to All sounds. Apply one to update a preset.`
          : "You have every pack version included with this app. Existing presets keep their saved versions.",
      );
    });
  }
  return {
    snapshot,
    packs,
    error,
    setError,
    notice,
    busy,
    preview,
    perform,
    save,
    changePreset,
    audition,
    importSounds,
    exportPreset,
    checkPackUpdates,
  };
}
export type Desktop = ReturnType<typeof useDesktop>;
