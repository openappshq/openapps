import { Modal } from "@heroui/react";
import { CircleHelp } from "lucide-react";
import type { ReactNode } from "react";
import CopyRow from "./CopyRow";
import { ArriveScene, PasteScene, PermissionScene, SpotlightScene } from "./installGuideArt";
import "./install-guide.css";

/**
 * "How do I install this?" for people who have never opened Terminal: a text
 * link above the install line that opens the install as numbered steps, each
 * with a small picture. Everything that varies by app - its name, its command,
 * the Homebrew line, the permission macOS will ask for - comes in from the
 * catalog through the caller; the steps themselves are the same for every app.
 *
 * The dialog is HeroUI's: it traps focus, closes on Escape or a click outside,
 * gives focus back to the link, and is labelled by its heading. Its entrance
 * follows reduced-motion like every other transition on the site.
 */
interface GuideProps {
  name: string;
  /** `curl … | sh`, copied from inside the guide too. */
  command: string;
  /** `brew install --cask …`, for the last step; leave it out and the step goes. */
  brewCommand?: string | null;
  /** What macOS will ask for on first launch; none for an app that needs nothing. */
  permissions?: readonly string[];
  /** Where the app shows up once it opens, as the predicate of "It …"; the menu bar unless the catalog says otherwise. */
  arrival?: string;
}

const MENU_BAR = "appears in your menu bar, the strip at the top of your screen";

export default function InstallGuide(props: GuideProps) {
  return (
    <Modal>
      {/* A real button rather than HeroUI's div: it is a link in a sentence, and it reads as one. */}
      <Modal.Trigger<"button">
        className="install-guide-link"
        render={(triggerProps) => <button {...triggerProps} type="button" />}
      >
        <CircleHelp size={15} aria-hidden="true" />
        How do I install this?
      </Modal.Trigger>
      <Modal.Backdrop variant="blur">
        <Modal.Container size="lg" scroll="inside">
          <Modal.Dialog className="install-guide">
            <InstallGuideContent {...props} />
            <Modal.CloseTrigger className="install-guide-close" />
          </Modal.Dialog>
        </Modal.Container>
      </Modal.Backdrop>
    </Modal>
  );
}

/**
 * What the dialog says: the heading and the numbered steps. On its own so the
 * steps can be rendered and checked without the overlay, which only exists in
 * a browser.
 */
export function InstallGuideContent({
  name,
  command,
  brewCommand,
  permissions = [],
  arrival = MENU_BAR,
}: GuideProps) {
  return (
    <>
      <Modal.Header className="install-guide-header">
        <span className="eyebrow">About a minute</span>
        <Modal.Heading level={2} className="install-guide-heading">
          Install {name}
        </Modal.Heading>
        <p className="install-guide-lead">
          One line in Terminal does the whole install. Terminal is the Mac's own text window; here
          is where to find it and what to type.
        </p>
      </Modal.Header>
      <Modal.Body className="install-guide-body">
        <ol className="install-guide-steps">
          <Step title="Open Terminal" art={<SpotlightScene />}>
            Press <Keys keys={["⌘", "Space"]} />, type <strong>Terminal</strong>, then press{" "}
            <Keys keys={["Return"]} />. A window with a blinking cursor opens.
          </Step>
          <Step
            title="Copy the install line"
            art={<CopyRow value={command} label="install command" className="install-guide-copy" />}
          >
            Click Copy. The whole line is copied, exactly as it needs to be.
          </Step>
          <Step title="Paste it into Terminal" art={<PasteScene command={command} />}>
            Click inside the Terminal window, press <Keys keys={["⌘", "V"]} /> to paste, then press{" "}
            <Keys keys={["Return"]} />.
          </Step>
          <Step title="Wait about ten seconds" art={<ArriveScene name={name} />}>
            The script downloads {name}, checks it, puts it in Applications and opens it. It{" "}
            {arrival}.
          </Step>
          {permissions.length > 0 && (
            <Step title="Say yes to macOS" art={<PermissionScene />}>
              macOS will ask for <strong>{list(permissions)}</strong> — {name}’s setup guide walks
              you through it.
            </Step>
          )}
          {brewCommand && (
            <Step title="Prefer Homebrew?">
              If you already use it, this does the same thing: <code>{brewCommand}</code>
            </Step>
          )}
        </ol>
      </Modal.Body>
    </>
  );
}

function Step({ title, art, children }: { title: string; art?: ReactNode; children: ReactNode }) {
  return (
    <li className="install-guide-step">
      <div className="install-guide-step-text">
        <h3>{title}</h3>
        <p>{children}</p>
      </div>
      {art && <div className="install-guide-step-art">{art}</div>}
    </li>
  );
}

/** Keys as keycaps: "⌘ Space", not "Cmd+Space". */
function Keys({ keys }: { keys: readonly string[] }) {
  return (
    <span className="install-guide-keys">
      {keys.map((key) => (
        <kbd key={key}>{key}</kbd>
      ))}
    </span>
  );
}

/** "Accessibility and Input Monitoring"; "A, B and C" for more. */
function list(items: readonly string[]): string {
  if (items.length <= 1) return items.join("");
  return `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`;
}
