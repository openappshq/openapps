import "@fontsource/ibm-plex-mono/500.css";
import "../styles.css";
import { motion } from "motion/react";
import { Link } from "@heroui/react";
import {
  Archive,
  BookOpen,
  ClipboardPaste,
  FolderOpen,
  Keyboard,
  ListChecks,
  LockKeyhole,
  PanelRight,
  Search,
} from "lucide-react";
import type { ReactNode } from "react";
import { enter } from "@openapps/ui/transitions";
import EdgeDeckScene from "../EdgeDeckScene";
import DeckStates from "../DeckStates";
import OpenNotesInstall from "../OpenNotesInstall";
import KeyToken from "../../../shared/KeyToken";
import HqBadge from "../../../shared/HqBadge";
import { MarketingHeader, MarketingFooter, Legend } from "../../../shared/MarketingChrome";
import Questions from "../../../shared/Questions";
import BuyButtons from "../../../shared/BuyButtons";
import InstallLink from "../../../shared/InstallLink";
import { installAction } from "../../../shared/installAction";
import {
  licensingFor,
  MACS_PER_LICENSE,
  OFFLINE_GRACE,
  TRIAL_DAYS,
} from "../../../shared/licensing";

const licensing = licensingFor("opennotes");
const { price: PRICE } = licensing;

/* Windows at a level and the system hotkey API, so the default "Apple Silicon"
   line would undersell it and a permissions line would be wrong. */
const REQUIREMENTS = (
  <>
    macOS 14+ <span aria-hidden="true">·</span> No permissions
  </>
);

const states: [string, string][] = [
  [
    "Rest",
    "a thin pill on the right edge of the screen, one coloured dash per note. A few pixels wide, on every Space, over full-screen apps and Stage Manager; it never asks for your attention",
  ],
  [
    "Reach",
    "move the pointer to the edge and the tabs fan out, each labelled with its note. Click one, or the + under them for a new note",
  ],
  [
    "Write",
    "the note slides out at full size over whatever you are in, keeps saving as you type, and Escape puts it back in the deck",
  ],
  [
    "Capture",
    "from any app, the hotkey opens a new note in the deck without switching. Type, press Escape, it is saved",
  ],
  ["Side", "the deck docks to the right by default; move it to the left if that is your side"],
];

const features: { icon: ReactNode; title: string; body: ReactNode }[] = [
  {
    icon: <PanelRight size={20} />,
    title: "On the edge, over everything.",
    body: "The deck lives on the edge of your screen at a window level above full-screen apps and every Stage Manager stage, on every Space. It is there when a Keynote is up and gone the moment you look away.",
  },
  {
    icon: <Keyboard size={20} />,
    title: "One key from anywhere.",
    body: "A global hotkey opens a new note in the deck from whatever you are doing. No switching to a notes app to find where the thought goes; type, press Escape, it is kept.",
  },
  {
    icon: <FolderOpen size={20} />,
    title: "Files you can see.",
    body: (
      <>
        Every note is a plain <code>.md</code> file in a folder you choose,{" "}
        <code>~/Documents/OpenNotes</code> by default. Put the folder in iCloud Drive, Dropbox or an
        Obsidian vault and that is your sync; edit a file from outside and the note updates. No
        database, no account, nothing of ours in between.
      </>
    ),
  },
  {
    icon: <ClipboardPaste size={20} />,
    title: "Paste means paste.",
    body: "Pasting keeps the text and drops the formatting. No smart quotes, no curly dashes, no fonts smuggled in from a web page, so a command pasted out of a note runs.",
  },
  {
    icon: <ListChecks size={20} />,
    title: "Markdown-lite, live.",
    body: (
      <>
        <code>#</code> headings, <code>-</code> lists, <code>- [ ]</code> checklists,{" "}
        <code>**bold**</code>: styled as you type, no preview pane, still plain text on disk. A
        handwriting-ish or a mono face, and a colour per note.
      </>
    ),
  },
  {
    icon: <Archive size={20} />,
    title: "Archive, don't delete.",
    body: "Done with a note? Archive it: it leaves the deck and stays searchable, with ten seconds to undo. OpenNotes never destroys a file; the archive is a folder you can open.",
  },
  {
    icon: <Search size={20} />,
    title: "All Notes.",
    body: "One window for everything: search titles and bodies, filter Active or Archived, open a note, archive it, reveal it in Finder, or export a selection as .md, .txt or one file.",
  },
  {
    icon: <BookOpen size={20} />,
    title: "Read-only after the trial.",
    body: `Try it for ${TRIAL_DAYS} days. When the trial ends nothing is taken: the deck stays on the edge, every note stays readable and exportable, and the files are yours in Finder as they always were. Creating and editing wait for a license.`,
  },
  {
    icon: <LockKeyhole size={20} />,
    title: "Asks for nothing.",
    body: "No Accessibility, no Input Monitoring, no Screen Recording, no account, no telemetry. The hotkey goes through macOS's own hotkey API and the deck is a window at a level; the only network calls are the license check and the update check.",
  },
];

const questions = [
  [
    "What do I need to run it?",
    "macOS 14 Sonoma or later; one Terminal line installs it, or Homebrew. The release is signed with our release certificate. Building from source stays free and needs no key.",
  ],
  [
    "Where are my notes?",
    "In a folder on your Mac, one plain Markdown file per note, ~/Documents/OpenNotes unless you pick another. Open it in Finder, in Obsidian, in any editor; OpenNotes watches the folder and shows outside edits. There is no database and nothing is encrypted by us: the folder is protected the way the rest of your files are, by FileVault.",
  ],
  [
    "Does it sync?",
    "The folder does. Put it in iCloud Drive, Dropbox, Syncthing or a git repository and your notes go where the folder goes. OpenNotes runs no server and has no account, so there is nothing of ours to sign into and nothing of ours that can overwrite a newer note.",
  ],
  [
    "How do licenses and trials work?",
    `Install OpenNotes and it works right away for ${TRIAL_DAYS} days on that Mac, with no signup. To keep it, pay ${PRICE} once for ${MACS_PER_LICENSE} Macs, forever. No subscription or account, and nothing is charged when the trial ends: OpenNotes goes read-only. The deck stays on the edge, every note stays readable and exportable, and the files are untouched; creating and editing notes wait until you buy a license or build from source. Remove a Mac in Settings › License to free a seat, or contact support if you no longer have it.`,
  ],
  [
    "Can I use it offline?",
    `Official builds check the license once a day and work offline for ${OFFLINE_GRACE} after the last successful check. Free source builds never contact the license service.`,
  ],
  [
    "What permissions does it need?",
    "None. The hotkey is registered through macOS's own hotkey API, the one that needs no Input Monitoring; the deck and the notes are ordinary windows set to a level above full-screen apps, which needs no Accessibility; the folder is one you named. Nothing to grant, nothing to revoke.",
  ],
  [
    "Does it really show over full-screen apps?",
    "Yes: the deck is a window that joins every Space and sits above full-screen windows on the same display, so it is there over a full-screen Keynote, a full-screen Zoom or a Stage Manager stage. If you would rather it stayed out of a full-screen app, turn that off in Settings.",
  ],
  [
    "What happens to a note I archive?",
    "The file moves into an Archive folder beside the others. It leaves the deck, stays searchable in All Notes, and comes back with one click. Ten seconds after archiving, an undo puts it straight back. OpenNotes never deletes a file for you.",
  ],
  [
    "What does the official build send anywhere?",
    `Official builds of OpenNotes include a ${TRIAL_DAYS}-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, your notes, and how you use the app are never sent. Builds from source never contact the license service. Official builds also fetch our signed update feed once a day to tell you about a new version; that request carries no identifiers, and installing is your call.`,
  ],
  [
    "Why is it not notarized?",
    "The app is signed with the OpenApps HQ Release certificate, the same one for every release, but not sent to Apple. The install script and the cask clear the download quarantine, so it opens without a Gatekeeper prompt; a zip downloaded by hand needs right-click → Open once.",
  ],
  [
    "Can I take my notes somewhere else?",
    "They already are somewhere else: plain Markdown files in your folder. Copy them, open them in another app, or export a selection from All Notes as .md, .txt or one combined file. Uninstall OpenNotes and every note is still there.",
  ],
];

export default function App() {
  return (
    <>
      <Link className="skip-link" href="#deck">
        Skip to how the deck works
      </Link>
      <MarketingHeader
        productId="opennotes"
        links={[
          { label: "The deck", href: "#deck" },
          { label: "The Mac app", href: "#app" },
          { label: "Install", href: "#install" },
          { label: "Questions", href: "#questions" },
        ]}
        action={installAction("opennotes")}
      />
      <main>
        <section className="hero" aria-labelledby="hero-title">
          <div className="page-width">
            <div className="hero-kicker">
              <HqBadge />
            </div>
            <motion.h1 {...enter} id="hero-title">
              Notes on the <KeyToken>edge</KeyToken>.
            </motion.h1>
            <div className="hero-grid on-hero-grid">
              <div className="hero-intro">
                <p>
                  A deck of sticky notes docked to the edge of your screen. A thin pill at rest; a
                  fan when you reach for it; one note out to write, over anything, full-screen apps
                  included. Every note is a Markdown file in a folder you can see.
                </p>
                <div className="hero-actions">
                  <BuyButtons app="opennotes" requirements={REQUIREMENTS} />
                </div>
              </div>
              <div className="on-hero-stage">
                <EdgeDeckScene />
              </div>
            </div>
          </div>
        </section>

        <section className="deck-section" id="deck" aria-labelledby="deck-title">
          <div className="page-width deck-grid">
            <div className="deck-text">
              <div className="reveal">
                <Legend index="01">The deck</Legend>
                <h2 id="deck-title">Out of the way. Never out of reach.</h2>
                <p className="deck-lead">
                  Stickies cover the desktop and vanish in full screen. OpenNotes keeps them on the
                  edge, where the pointer can find them and nothing else has to.
                </p>
              </div>
              <dl className="deck-states reveal-group">
                {states.map(([name, detail]) => (
                  <div key={name}>
                    <dt>{name}</dt>
                    <dd>{detail}</dd>
                  </div>
                ))}
              </dl>
            </div>
            <div className="deck-stage reveal">
              <DeckStates />
            </div>
          </div>
        </section>

        <section className="mac-section" id="app" aria-labelledby="app-title">
          <div className="page-width">
            <div className="section-heading reveal">
              <div>
                <Legend index="02">The Mac app</Legend>
                <h2 id="app-title">Sticky notes. Plain files.</h2>
              </div>
            </div>
            <div className="feature-grid reveal-group">
              {features.map((feature) => (
                <article key={feature.title}>
                  <span className="feature-icon">{feature.icon}</span>
                  <h3>{feature.title}</h3>
                  <p>{feature.body}</p>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section className="install-section" id="install" aria-labelledby="install-title">
          <div className="page-width">
            <div className="section-heading reveal">
              <div>
                <Legend index="03">Install</Legend>
                <h2 id="install-title">One line.</h2>
              </div>
            </div>
            <div className="reveal">
              {/* Live on the same gate as Buy (VITE_OPENNOTES_DODO_PAID_PRODUCT_ID and
                  VITE_OPENNOTES_BREW_CASK); "Coming soon" until both are set. */}
              <OpenNotesInstall licensing={licensing} />
            </div>
          </div>
        </section>

        <section className="faq-wrap" id="questions" aria-labelledby="faq-title">
          <div className="faq-section page-width">
            <div>
              <h2 id="faq-title">Good questions.</h2>
            </div>
            <Questions items={questions} />
          </div>
        </section>

        <section className="closing-wrap" aria-labelledby="start-title">
          <div className="closing-section page-width">
            <div>
              <h2 id="start-title">
                Reach.
                <br />
                Write.
                <br />
                Back.
              </h2>
              <InstallLink app="opennotes" className="button-link inverse" />
            </div>
            <img src="/brand/opennotes/symbol-ink.svg" alt="" width="300" height="300" />
          </div>
        </section>
      </main>
      <MarketingFooter productId="opennotes" />
    </>
  );
}
