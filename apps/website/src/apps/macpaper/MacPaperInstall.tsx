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
export default function MacPaperInstall({
  licensing,
}: {
  licensing: Pick<
    AppLicensing,
    "name" | "brewCask" | "brewCommand" | "installCommand" | "installScriptSourceUrl"
  >;
}) {
  const { name, brewCommand, installCommand, installScriptSourceUrl } = licensing;
  if (!installCommand || !brewCommand) {
    return (
      <div className="mp-install">
        <span className="button-link is-disabled" aria-disabled="true">
          Install for Mac <Terminal size={18} aria-hidden="true" />
          <small>Coming soon</small>
        </span>
        <p className="mp-install-note">
          The Mac release is being cut. Until then, build it from source in{" "}
          <code>apps/macpaper</code>; source builds need no license.
        </p>
      </div>
    );
  }
  return (
    <div className="mp-install">
      <InstallCommand
        command={installCommand}
        name={name}
        sourceUrl={installScriptSourceUrl}
        brewCommand={brewCommand}
      />
      <p className="mp-install-note">
        macPaper lands in <code>/Applications</code> and opens from the notch, or in your menu bar
        on a Mac without one; nothing to grant. Your {TRIAL_DAYS}-day trial starts then. macPaper
        checks for updates itself and tells you; installing one is your call.
      </p>
    </div>
  );
}
