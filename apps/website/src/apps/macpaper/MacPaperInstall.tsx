import { Terminal } from "lucide-react";
import InstallCommand from "../../shared/InstallCommand";
import { TRIAL_DAYS, type AppLicensing } from "../../shared/licensing";

/**
 * The install block: the one Homebrew line with Copy, where the app lands and
 * how it updates, or a quiet coming-soon plate until the app is on sale. It
 * opens the same gate as Buy (the paid product and the cask), so the command
 * never appears for a build that cannot be bought.
 */
export default function MacPaperInstall({
  licensing,
}: {
  licensing: Pick<AppLicensing, "brewCask" | "brewCommand">;
}) {
  const { brewCask, brewCommand } = licensing;
  if (!brewCask || !brewCommand) {
    return (
      <div className="mp-install">
        <span className="button-link is-disabled" aria-disabled="true">
          Install with Homebrew <Terminal size={18} aria-hidden="true" />
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
      <InstallCommand command={brewCommand} />
      <p className="mp-install-note">
        Installs into <code>/Applications</code> and opens macPaper from the notch, or in your menu
        bar on a Mac without one; nothing to grant. Your {TRIAL_DAYS}-day trial starts then.
        macPaper checks for updates itself and tells you; installing one is your call, or run{" "}
        <code>brew upgrade --cask {brewCask.split("/").pop()}</code>.
      </p>
    </div>
  );
}
