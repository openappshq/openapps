import { Terminal } from "lucide-react";
import InstallCommand from "../../shared/InstallCommand";
import { brewInstallCommand } from "../../shared/licensing";

/**
 * The install for a free app: the one Homebrew line with Copy, where the app
 * lands and how it updates, or a quiet coming-soon plate until the cask is
 * published. There is no license, so there is nothing else to offer.
 */
export default function HertzInstall({ cask }: { cask: string | undefined }) {
  if (!cask) {
    return (
      <div className="hertz-install">
        <span className="button-link is-disabled" aria-disabled="true">
          Install with Homebrew <Terminal size={18} aria-hidden="true" />
          <small>Coming soon</small>
        </span>
        <p className="hertz-install-note">
          The first release is being cut. Until then, build it from source with{" "}
          <code>swift run Hertz</code>.
        </p>
      </div>
    );
  }
  return (
    <div className="hertz-install">
      <InstallCommand command={brewInstallCommand(cask)} />
      <p className="hertz-install-note">
        Installs into <code>~/Applications</code> and opens Hertz in your menu bar; no admin
        password. Update with <code>brew upgrade --cask {cask.split("/").pop()}</code>; the app never
        checks on its own.
      </p>
    </div>
  );
}
