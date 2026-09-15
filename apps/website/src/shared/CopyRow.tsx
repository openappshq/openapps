import { Check, Copy } from "lucide-react";
import { useEffect, useRef, useState } from "react";

/**
 * One line of text the visitor needs verbatim - a license key, a Terminal
 * command - with a Copy button beside it. Where the clipboard is refused the
 * text is selected instead, so ⌘C still works and nothing is lost.
 */
export default function CopyRow({
  value,
  label,
  className,
}: {
  value: string;
  /** What the button copies, for its accessible name: "license key", "install command". */
  label: string;
  className: string;
}) {
  const [state, setState] = useState<"idle" | "copied" | "manual">("idle");
  const code = useRef<HTMLElement>(null);
  useEffect(() => {
    if (state !== "copied") return;
    const timer = setTimeout(() => setState("idle"), 1800);
    return () => clearTimeout(timer);
  }, [state]);

  const select = () => {
    const node = code.current;
    if (!node) return;
    node.focus();
    const range = document.createRange();
    range.selectNodeContents(node);
    const selection = getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
  };
  const copy = async () => {
    try {
      if (!navigator.clipboard) throw new Error("Clipboard unavailable");
      await navigator.clipboard.writeText(value);
      setState("copied");
    } catch {
      setState("manual");
      select();
    }
  };

  return (
    <div className={`copy-row ${className}`}>
      <code ref={code} tabIndex={-1}>
        {value}
      </code>
      <button
        type="button"
        aria-label={state === "copied" ? "Copied" : `Copy ${label}`}
        onClick={() => void copy()}
      >
        {state === "copied" ? (
          <Check size={16} aria-hidden="true" />
        ) : (
          <Copy size={16} aria-hidden="true" />
        )}
        {state === "copied" ? "Copied" : "Copy"}
      </button>
      {state === "manual" && (
        <p className="copy-row-help" role="status">
          Copying isn’t allowed here. The {label} is selected: press ⌘C to copy it manually.
        </p>
      )}
    </div>
  );
}
