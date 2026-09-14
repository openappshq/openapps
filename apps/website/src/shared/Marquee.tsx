import type { ReactNode } from "react";
import "./marquee.css";

/**
 * A full-bleed strip of the product's own catalogue, drifting past. The track
 * holds the items twice and travels exactly half its width, so the loop is
 * seamless; the copy is hidden from assistive tech and the real list carries
 * the label.
 */
export default function Marquee({
  label,
  items,
  seconds = 64,
  reverse = false,
}: {
  label: string;
  items: ReactNode[];
  /** One full pass. Longer is calmer; this is ambient, not a ticker. */
  seconds?: number;
  reverse?: boolean;
}) {
  const row = (hidden: boolean) => (
    <ul className="marquee-row" aria-hidden={hidden || undefined}>
      {items.map((item, i) => (
        <li key={i}>{item}</li>
      ))}
    </ul>
  );
  return (
    <div className="marquee" role="group" aria-label={label}>
      <div className="marquee-track" data-reverse={reverse || undefined} style={{ "--pass": `${seconds}s` } as React.CSSProperties}>
        {row(false)}
        {row(true)}
      </div>
    </div>
  );
}
