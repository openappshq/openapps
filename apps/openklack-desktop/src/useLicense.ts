import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { LicenseView } from "./licenseState";

/**
 * One subscription to the licensing runtime's view for the whole window: the header pill and
 * the License section read the same state. Nothing is subscribed in a source build, where the
 * commands don't exist.
 */
export function useLicense(enabled: boolean, onError: (error: string) => void) {
  const [view, setView] = useState<LicenseView>();
  const accept = useCallback((next: LicenseView) => {
    setView((current) => (current && current.revision > next.revision ? current : next));
  }, []);
  useEffect(() => {
    if (!enabled) return;
    let disposed = false;
    let off: (() => void) | undefined;
    async function subscribe() {
      off = await listen<LicenseView>("license", ({ payload }) => {
        if (!disposed) accept(payload);
      });
      if (disposed) {
        off();
        return;
      }
      const current = await invoke<LicenseView>("license_status");
      if (!disposed) accept(current);
    }
    void subscribe().catch((error: unknown) => {
      if (!disposed) onError(String(error));
    });
    return () => {
      disposed = true;
      off?.();
    };
  }, [enabled, accept, onError]);
  return { view, accept };
}

export type LicenseState = ReturnType<typeof useLicense>;
