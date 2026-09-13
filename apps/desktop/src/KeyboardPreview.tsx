import { useEffect, useRef, useState, type CSSProperties, type KeyboardEvent } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Button } from "@heroui/react";

import { rows, neighboringKey, keyLabel } from "@openklack/keyboard-layout";
const keys = rows.flat();

export function KeyboardPreview({
  onError,
  selected,
  assignments,
  onSelect,
  canPick,
}: {
  onError: (message: string) => void;
  selected: string;
  assignments: string[];
  onSelect: (code: string) => void;
  canPick: boolean;
}) {
  const [pressed, setPressed] = useState<Set<string>>(new Set());
  const [pointerKey, setPointerKey] = useState<string | null>(null);
  const stage = useRef<HTMLDivElement>(null);
  const choosing = useRef(false);
  const [picking, setPicking] = useState(false);
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
      setPressed(new Set());
      if (!visible || document.hidden) {
        cancelPicking();
      }
    };
    const observer = new IntersectionObserver(([entry]) => {
      visible = entry!.isIntersecting;
      reportVisibility();
      if (!visible) {
        setPressed(new Set());
        setPointerKey(null);
      }
    });
    if (stage.current) observer.observe(stage.current);
    document.addEventListener("visibilitychange", reportVisibility);
    window.addEventListener("blur", cancelPicking);
    void Promise.allSettled([
      listen<{ key: string; down: boolean }>("key", ({ payload }) => {
        if (disposed || !visible || document.hidden) return;
        if (payload.down && choosing.current && document.hasFocus()) {
          cancelPicking();
          onSelect(payload.key);
        }
        setPressed((previous) => {
          const next = new Set(previous);
          if (payload.down) next.add(payload.key);
          else next.delete(payload.key);
          return next;
        });
      }),
      listen("keys-reset", () => {
        if (!disposed) {
          setPressed(new Set());
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
      document.removeEventListener("visibilitychange", reportVisibility);
      window.removeEventListener("blur", cancelPicking);
      void invoke("set_keyboard_visible", { visible: false }).catch(() => {});
      cleanup.forEach((off) => off());
    };
  }, [onError, onSelect]);
  function navigate(event: KeyboardEvent<HTMLButtonElement>, code: string) {
    if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
    event.preventDefault();
    const next = neighboringKey(code, event.key);
    onSelect(next);
    event.currentTarget
      .closest(".keyboard-case")
      ?.querySelector<HTMLButtonElement>(`[data-key="${next}"]`)
      ?.focus();
  }
  return (
    <div ref={stage} className={`keyboard-stage ${pressed.size || pointerKey ? "is-playing" : ""}`}>
      <div className="keyboard-glow" aria-hidden="true" />
      <div className="keyboard-case" aria-label="Keyboard key selector. Use arrow keys to move.">
        <div className="case-engraving" aria-hidden="true">
          OpenKlack <span>01 / everyday instrument</span>
        </div>
        {rows.map((row, i) => (
          <div className={`keyboard-row row-${i}`} key={i}>
            {row.map(([code, legend, width = 1]) => (
              <button
                type="button"
                data-key={code}
                key={code}
                className={`keycap ${pressed.has(code) || pointerKey === code ? "pressed" : ""} ${selected === code ? "selected" : ""} ${assignments.includes(code) ? "assigned" : ""} ${code === "Escape" ? "accent-key" : ""}`}
                style={{ flex: width } as CSSProperties}
                tabIndex={
                  selected === code || (code === "Space" && !keys.some((k) => k[0] === selected))
                    ? 0
                    : -1
                }
                aria-label={`Select ${keyLabel(code)}${assignments.includes(code) ? ", custom sound" : ""}`}
                aria-pressed={selected === code}
                onClick={() => onSelect(code)}
                onPointerDown={() => {
                  setPointerKey(code);
                  void invoke("preview_key", { key: code }).catch((e: unknown) =>
                    onError(String(e)),
                  );
                }}
                onPointerUp={() => setPointerKey(null)}
                onPointerLeave={() => setPointerKey(null)}
                onPointerCancel={() => setPointerKey(null)}
                onKeyDown={(event) => navigate(event, code)}
              >
                <span>{legend || "space"}</span>
                {assignments.includes(code) && <i aria-hidden="true" />}
              </button>
            ))}
          </div>
        ))}
      </div>
      <div className="keyboard-caption">
        <p role="status">
          {picking
            ? "Press one physical key to select it."
            : "Type to see it come alive. Select a key to give it a different sound."}
        </p>
        <Button
          variant="ghost"
          isDisabled={!canPick}
          aria-pressed={picking}
          onPress={() => choose(!picking)}
        >
          {picking ? "Cancel key selection" : "Choose by typing"}
        </Button>
      </div>
    </div>
  );
}
