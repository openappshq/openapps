import { Download, Terminal } from "lucide-react";
import type { ReactNode } from "react";
import InstallCommand from "./InstallCommand";
import { installLabel, licensingFor, TRIAL_DAYS, type AppLicensing } from "./licensing";

/**
 * The two ways in. Every app carries its own trial, so installing and starting
 * one are a single act - but the button stays short and the trial is stated
 * under it, where a long label would only have weakened the call.
 *
 * The install is a Homebrew command, shown in full with a Copy button. A direct
 * download, when one is configured, keeps its button beside it; without one the
 * command is the primary action and nothing points at a page that just repeats it.
 */
export default function BuyButtons({
  app,
  small = false,
  licensing = licensingFor(app),
}: {
  app: string;
  small?: boolean;
  /** Overrides the environment's licensing (tests). */
  licensing?: AppLicensing;
}) {
  const { buyUrl, brewCommand, downloadUrl, downloadPageUrl, price } = licensing;
  const size = small ? " small" : "";
  // Homebrew only: the command is the primary action, so Buy takes the primary plate.
  const buyStyle = brewCommand && !downloadUrl ? "primary" : "secondary";

  return (
    <div className="buy-buttons">
      {brewCommand && <InstallCommand command={brewCommand} />}
      {(downloadUrl || !brewCommand) && (
        <a className={`button-link primary${size}`} href={downloadPageUrl}>
          {installLabel(licensing)}{" "}
          {downloadUrl ? (
            <Download size={18} aria-hidden="true" />
          ) : (
            <Terminal size={18} aria-hidden="true" />
          )}
        </a>
      )}
      <Action href={buyUrl} className={`button-link ${buyStyle}${size}`}>
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

/** A checkout link, or a quiet plate until the app can actually be bought and installed. */
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
        <small>Coming soon</small>
      </span>
    );
  }
  return (
    <a className={className} href={href}>
      {children}
    </a>
  );
}
