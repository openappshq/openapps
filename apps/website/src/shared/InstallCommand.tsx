import { ArrowUpRight } from "lucide-react";
import CopyRow from "./CopyRow";
import InstallGuide from "./InstallGuide";

/**
 * The install, as the one line it is: `curl … | sh` with a Copy button, one
 * sentence on what the script does with a link to its source, and the Homebrew
 * line under it for people who already have brew. Above it, "How do I install
 * this?" opens the same install as steps with pictures, for anyone who has
 * never opened Terminal. Shown wherever a Download button used to be. The
 * script and the cask are published together, so the caller gates both on the
 * cask; the guide only ever appears with the line it explains.
 */
export default function InstallCommand({
  command,
  name,
  sourceUrl,
  brewCommand,
  permissions,
  arrival,
}: {
  /** `curl -fsSL https://openapps.space/install/<id> | sh`. */
  command: string;
  /** The app's name, for the sentence that says what the script does. */
  name: string;
  /** Where the script can be read before it is run. */
  sourceUrl: string;
  /** `brew install --cask …`, offered as the alternative when given. */
  brewCommand?: string | null;
  /** What macOS asks for on first launch, from the catalog; the guide names it. */
  permissions?: readonly string[];
  /** Where the app shows up once it opens, from the catalog; the guide's last step says it. */
  arrival?: string;
}) {
  return (
    <div className="install-command">
      <InstallGuide
        name={name}
        command={command}
        brewCommand={brewCommand}
        permissions={permissions}
        arrival={arrival}
      />
      <CopyRow value={command} label="install command" className="install-command-row" />
      <p className="install-command-note">
        Paste it into Terminal. It downloads the signed release, checks it, puts {name} in
        Applications and opens it. No Homebrew, no password.{" "}
        <a href={sourceUrl} target="_blank" rel="noopener noreferrer">
          Read the script <ArrowUpRight size={12} aria-hidden="true" />
        </a>
      </p>
      {brewCommand && (
        <p className="install-command-note">
          Prefer Homebrew? <code>{brewCommand}</code>
        </p>
      )}
    </div>
  );
}
