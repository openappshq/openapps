import { useCallback, useEffect, useEffectEvent, useRef, useState } from "react";
import type { ReactNode } from "react";
import "./key-token.css";

/**
 * Watches the real keyboard, without ever touching it. Purely observational:
 * nothing is preventDefault-ed, keys typed into a field or with a modifier held
 * are ignored, and held keys do not repeat. Anything that would change what a
 * key does belongs nowhere near a marketing page.
 */
function useTypedKeys(onKey: (key: string) => void) {
  const handle = useEffectEvent((event: KeyboardEvent) => {
    if (event.metaKey || event.ctrlKey || event.altKey || event.repeat) return;
    const target = event.target as HTMLElement | null;
    if (target && (/^(input|textarea|select)$/i.test(target.tagName) || target.isContentEditable))
      return;
    if (event.key.length !== 1) return;
    onKey(event.key);
  });
  useEffect(() => {
    const listener = (event: KeyboardEvent) => handle(event);
    addEventListener("keydown", listener, { passive: true });
    return () => removeEventListener("keydown", listener);
  }, []);
}

let echoId = 0;
type Echo = { id: number; char: string; burst?: boolean };

/** What a keystroke should throw: a character, and optionally a celebration. */
export type Thrown = { echo?: string; burst?: string } | void;

/**
 * The key in the headline, wired to the keyboard in front of you. Press a key
 * anywhere on the page and the cap seats, then throws that character off the
 * top. The cap's own word never changes, so the heading keeps its accessible
 * name and the echoes stay decoration.
 */
export default function KeyToken({
  children,
  className = "",
  onType,
}: {
  children: ReactNode;
  className?: string;
  /**
   * Called with each observed character. Return `{ echo }` to throw something
   * other than the key itself, and `{ burst }` to celebrate a match.
   */
  onType?: (key: string) => Thrown;
}) {
  const [echoes, setEchoes] = useState<Echo[]>([]);
  const [pressed, setPressed] = useState(false);
  const [reduced, setReduced] = useState(true);
  const release = useRef<ReturnType<typeof setTimeout>>(undefined);

  useEffect(() => {
    const query = matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReduced(query.matches);
    update();
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);

  const drop = useCallback((id: number) => {
    setEchoes((current) => current.filter((echo) => echo.id !== id));
  }, []);

  useTypedKeys((key) => {
    const thrown = onType?.(key) || {};
    if (reduced) return;
    setPressed(true);
    clearTimeout(release.current);
    release.current = setTimeout(() => setPressed(false), 110);
    const next: Echo[] = [{ id: echoId++, char: thrown.echo ?? key }];
    if (thrown.burst) next.push({ id: echoId++, char: thrown.burst, burst: true });
    // Capped so holding down a hand of keys cannot pile up nodes.
    setEchoes((current) => [...current, ...next].slice(-8));
  });
  useEffect(() => () => clearTimeout(release.current), []);

  return (
    <span className={`key-token ${className}`} data-pressed={pressed || undefined}>
      {children}
      <span className="key-echoes" aria-hidden="true">
        {echoes.map((echo) => (
          <span
            key={echo.id}
            className={echo.burst ? "key-burst" : "key-echo"}
            style={{ "--drift": `${(echo.id % 5) - 2}` } as React.CSSProperties}
            onAnimationEnd={() => drop(echo.id)}
          >
            {echo.char}
          </span>
        ))}
      </span>
    </span>
  );
}
