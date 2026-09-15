import { ArrowUpRight } from "lucide-react";
import CopyRow from "./CopyRow";
import { HOMEBREW_URL } from "./licensing";

/**
 * The install, as the one line it is: `brew install --cask …` with a Copy
 * button, and the single prerequisite named under it. Shown wherever a
 * Download button used to be, because the cask is how the app ships.
 */
export default function InstallCommand({ command }: { command: string }) {
  return (
    <div className="install-command">
      <CopyRow value={command} label="install command" className="install-command-row" />
      <p className="install-command-note">
        Requires{" "}
        <a href={HOMEBREW_URL} target="_blank" rel="noopener noreferrer">
          Homebrew <ArrowUpRight size={12} aria-hidden="true" />
        </a>
        . Paste it into Terminal.
      </p>
    </div>
  );
}
