import { Download } from "lucide-react";
import type { ReactNode } from "react";
import { licensingFor, TRIAL_DAYS } from "./licensing";

/**
 * The two ways in. Every app carries its own trial, so downloading and starting
 * one are a single act - but the button stays short and the trial is stated
 * under it, where a long label would only have weakened the call.
 */
export default function BuyButtons({ app, small = false }: { app: string; small?: boolean }) {
  const { buyUrl, downloadPageUrl, price } = licensingFor(app);
  const size = small ? " small" : "";

  return (
    <div className="buy-buttons">
      <a className={`button-link primary${size}`} href={downloadPageUrl}>
        Download for Mac <Download size={18} aria-hidden="true" />
      </a>
      <Action href={buyUrl} className={`button-link secondary${size}`}>
        Buy for {price}
      </Action>
      {/* Everything a spec sheet was carrying, in the one line where someone
          is actually deciding. */}
      <p className="buy-note">
        Free {TRIAL_DAYS}-day trial, no signup <span aria-hidden="true">·</span> macOS 14+{" "}
        <span aria-hidden="true">·</span> Apple Silicon
      </p>
    </div>
  );
}

/** A checkout link, or a quiet plate if the app is ever taken off sale. */
function Action({
  href,
  className,
  children,
}: {
  href: string | null;
  className: string;
  children: ReactNode;
}) {
  if (!href) {
    return (
      <span className={`${className} is-disabled`} aria-disabled="true">
        {children}
        <small>Temporarily unavailable</small>
      </span>
    );
  }
  return (
    <a className={className} href={href}>
      {children}
    </a>
  );
}
