import { Terminal } from "lucide-react";
import InstallCommand from "../../shared/InstallCommand";
import { TRIAL_DAYS, type AppLicensing } from "../../shared/licensing";

/**
 * The install block: the one Terminal line with Copy, Homebrew as the
 * alternative, where the app lands and how it updates, or a quiet coming-soon
 * plate until the app is on sale. It opens the same gate as Buy (the paid
 * product and the cask; the install script is published with the cask), so
 * the command never appears for a build that cannot be bought.
 */
export default function HertzInstall({
  licensing,
}: {
  licensing: Pick<
    AppLicensing,
    | "name"
    | "brewCask"
    | "brewCommand"
    | "installCommand"
    | "installScriptSourceUrl"
    | "permissions"
  >;
}) {
  const { name, brewCommand, installCommand, installScriptSourceUrl, permissions } = licensing;
  if (!installCommand || !brewCommand) {
    return (
      <div className="hertz-install">
        <span className="button-link is-disabled" aria-disabled="true">
          Install for Mac <Terminal size={18} aria-hidden="true" />
          <small>Coming soon</small>
        </span>
        <p className="hertz-install-note">
          The Mac release is being cut. Until then, build it from source with{" "}
          <code>swift run Hertz</code>; source builds need no license.
        </p>
      </div>
    );
  }
  return (
    <div className="hertz-install">
      <InstallCommand
        command={installCommand}
        name={name}
        sourceUrl={installScriptSourceUrl}
        brewCommand={brewCommand}
        permissions={permissions}
      />
      <p className="hertz-install-note">
        Hertz lands in <code>/Applications</code> and opens in your menu bar; nothing to grant.
        Your {TRIAL_DAYS}-day trial starts then. Hertz checks for updates itself and tells you;
        installing one is your call.
      </p>
    </div>
  );
}
