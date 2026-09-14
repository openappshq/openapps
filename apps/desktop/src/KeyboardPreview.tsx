import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Button } from "@heroui/react";
import { useReducedMotion } from "motion/react";
import { createInput } from "@openklack/keyboard-layout";
import "@openklack/ui/keyboard.css";

const Keyboard3D = lazy(() => import("@openklack/ui/keyboard"));

export function KeyboardPreview({
  onError,
  selected,
  assignments,
  onSelect,
  canPick,
  compact = false,
}: {
  onError: (message: string) => void;
  selected: string;
  assignments: string[];
  onSelect: (code: string) => void;
  canPick: boolean;
  compact?: boolean;
}) {
  const [input] = useState(createInput);
  const stage = useRef<HTMLDivElement>(null);
  const choosing = useRef(false);
  const [picking, setPicking] = useState(false);
  const lighting = localStorage.getItem("openklack-lighting") !== "off";
  const reducedMotion = useReducedMotion();
  function choose(enabled: boolean) {
    choosing.current = enabled;
    setPicking(enabled);
  }
  useEffect(() => {
    let visible = true,
      disposed = false;
    const cleanup: (() => void)[] = [];
    const cancelPicking = () => {
      choosing.current = false;
      setPicking(false);
    };
    const reportVisibility = () => {
      void invoke("set_keyboard_visible", { visible: visible && !document.hidden }).catch(
        (e: unknown) => {
          if (!disposed) onError(String(e));
        },
      );
      input.clear();
      if (!visible || document.hidden) cancelPicking();
    };
    const observer = new IntersectionObserver(([entry]) => {
      visible = entry!.isIntersecting;
      reportVisibility();
    });
    if (stage.current) observer.observe(stage.current);
    document.addEventListener("visibilitychange", reportVisibility);
    window.addEventListener("blur", cancelPicking);
    void Promise.allSettled([
      listen<{ key: string; down: boolean }>("key", ({ payload }) => {
        if (disposed || !visible || document.hidden) return;
        if (payload.down && choosing.current && document.hasFocus()) {
          cancelPicking();
          if (payload.key !== "Escape") onSelect(payload.key);
        }
        if (payload.down) input.press(payload.key, "keyboard");
        else input.release(payload.key, "keyboard");
      }),
      listen("keys-reset", () => {
        if (!disposed) {
          input.clear();
          cancelPicking();
        }
      }),
    ]).then((results) => {
      for (const result of results) {
        if (result.status === "fulfilled") cleanup.push(result.value);
        else if (!disposed) onError(String(result.reason));
      }
      if (disposed) cleanup.forEach((off) => off());
    });
    return () => {
      disposed = true;
      observer.disconnect();
      input.clear();
      document.removeEventListener("visibilitychange", reportVisibility);
      window.removeEventListener("blur", cancelPicking);
      void invoke("set_keyboard_visible", { visible: false }).catch(() => {});
      cleanup.forEach((off) => off());
    };
  }, [input, onError, onSelect]);
  return (
    <div ref={stage} className={`keyboard-stage ${compact ? "compact-keyboard" : ""}`}>
      <div className="desktop-keyboard-model">
        <Suspense fallback={<p className="inline-hint">Preparing your keyboard…</p>}>
          <Keyboard3D
            input={input}
            selected={compact ? null : selected}
            assignments={assignments}
            lighting={lighting}
            reducedMotion={!!reducedMotion}
            onPress={(code) => {
              input.press(code, "pointer");
              if (!compact) onSelect(code);
              void invoke("preview_key", { key: code }).catch((e: unknown) => onError(String(e)));
            }}
            onRelease={(code) => input.release(code, "pointer")}
          />
        </Suspense>
      </div>
      <div className="keyboard-caption">
        {!compact && (
          <>
            <p role="status">
              {picking ? "Press a key to select it. Escape cancels." : "Select a key."}
            </p>
            <Button
              variant="ghost"
              isDisabled={!canPick}
              aria-pressed={picking}
              onPress={() => choose(!picking)}
            >
              {picking ? "Cancel selection" : "Choose by typing"}
            </Button>
          </>
        )}
      </div>
    </div>
  );
}
