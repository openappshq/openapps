import "@fontsource/ibm-plex-mono/500.css";
import "../styles.css";
import { motion } from "motion/react";
import { Link } from "@heroui/react";
import {
  Archive,
  BookOpen,
  Calculator,
  ClipboardPaste,
  Cloud,
  EyeOff,
  FolderOpen,
  Keyboard,
  Link2,
  ListChecks,
  LockKeyhole,
  PanelRight,
  Search,
  Type,
  Workflow,
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
    "the edge of every note's paper peeking a few pixels out of the screen edge, in its own colour, in the deck's order — no tray, nothing written on it. On every Space, over full-screen apps and Stage Manager; it never asks for your attention",
  ],
  [
    "Reach",
    "move the pointer to the edge and the edges widen in place into the fan, a paper per note with its title, each leaning a little; what does not fit scrolls. Click one, or the + under them for a new note. Drag a tab up or down to reorder; drop text, a link or files on the deck and a note opens with them in it",
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
        Every note is a plain <code>.md</code> file in one folder: <code>~/Documents/OpenNotes</code>
        , iCloud Drive with one click in Settings, or any folder you pick, an Obsidian vault
        included. Edit a file from outside and the note updates; nothing is ever moved or deleted
        by the app. No database, no account, nothing of ours in between.
      </>
    ),
  },
  {
    icon: <Cloud size={20} />,
    title: "iCloud Drive, as a folder.",
    body: "Choose iCloud Drive and every Mac signed in to the same iCloud sees the same notes; an iOS Markdown app can open the folder too. A note not downloaded yet shows greyed until you open it, iCloud's own conflict versions become conflict copies beside the file, and switching copies your notes rather than moving them. No sync of ours, no account.",
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
        note with a checklist shows its count on its tab, <code>3/7</code>, and a thin line that
        fills as the list gets done.
      </>
    ),
  },
  {
    icon: <Type size={20} />,
    title: "Any font. Thirteen papers.",
    body: "Sans, Serif, Mono, or any font installed on your Mac, per note or as the default. Thirteen paper colours tuned for light and dark, or pick your own from the colour panel. New notes take a random paper unless you fix one. The font and colour live in the file's front matter, so they travel with it.",
  },
  {
    icon: <Calculator size={20} />,
    title: "Sums as you write.",
    body: (
      <>
        End a line with <code>=</code> and the answer appears after it: <code>3 * $95 =</code>,{" "}
        <code>12% of 80 =</code>, <code>sum =</code> over the lines above. Nothing is written to
        the file until you press Tab on that line. Plain arithmetic in Swift, nothing sent
        anywhere.
      </>
    ),
  },
  {
    icon: <Link2 size={20} />,
    title: "Links that open.",
    body: (
      <>
        <code>https://</code>, <code>www.</code>, <code>mailto:</code> and <code>~/</code> paths
        are underlined as you type; ⌘-click opens one, and a small chip names where it goes.
        Nothing is fetched, so a link in a note is never a request.
      </>
    ),
  },
  {
    icon: <Archive size={20} />,
    title: "Archive, don't delete.",
    body: "Done with a note? Archive it: it leaves the deck and stays in the folder and in search, with ten seconds to undo. Auto-archive can retire untouched notes after 7, 30 or 90 days. Delete lives only under Archived, asks first, and moves the file to the Trash: OpenNotes never deletes a file for good.",
  },
  {
    icon: <Search size={20} />,
    title: "All Notes.",
    body: "One window for everything: search titles and bodies, filter Active or Archived, drag to reorder, open a note, pin or archive it, reveal it in Finder, or export it as .md or .txt.",
  },
  {
    icon: <ListChecks size={20} />,
    title: "Select many. Delete only to the Trash.",
    body: "Check rows in All Notes (⇧-click a range, ⌘A for all on view) and archive them at once (one undo for the batch), or pin, recolour, change the font, export or reveal them together. Archived notes can go: Delete… asks first and moves the files to the Trash, where Finder can put them back. OpenNotes never deletes a file for good.",
  },
  {
    icon: <Workflow size={20} />,
    title: "Shortcuts, and a link any app can open.",
    body: (
      <>
        Four Shortcuts actions, Create Note, Append to Note, Get Note Text and Open Note, that
        Spotlight and Siri answer to as well; and <code>opennotes://new?text=…</code>,{" "}
        <code>open?title=…</code> and <code>append?title=…&amp;text=…</code> from anything that
        can open a link.
      </>
    ),
  },
  {
    icon: <EyeOff size={20} />,
    title: "Out of your screen shares, on request.",
    body: "Turn on “Keep notes out of screen sharing” (on by default on a fresh install) and OpenNotes asks macOS to leave the deck and All Notes out of screen captures while you see them as usual. It is a request, not a guarantee: some capture tools ignore it.",
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
    "The folder does. Choose iCloud Drive in Settings and your notes go to every Mac signed in to the same iCloud (and to any iOS Markdown app that opens iCloud Drive); or put the folder in Dropbox, Syncthing or a git repository. OpenNotes runs no server and has no account, so there is nothing of ours to sign into, and a note that changed outside is never overwritten: it keeps that version and yours continues in a conflict copy beside it.",
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
    "Yes: the deck is a window that joins every Space and sits above full-screen windows on the same display, so it is there over a full-screen Keynote, a full-screen Zoom or a Stage Manager stage. A note opens only when you click its tab or press the hotkey; hovering fans the deck out and nothing more.",
  ],
  [
    "Can I keep my notes out of a screen share?",
    "You can ask. With “Keep notes out of screen sharing” on, the deck and All Notes carry the flag macOS offers for leaving a window out of screen captures, while they stay on your own screen as before. Apple documents that flag as a request, and some capture tools ignore it, so OpenNotes does not call it privacy: check what your sharing tool shows before you count on it.",
  ],
  [
    "What happens to a note I archive?",
    "The file stays where it is with archived: true in its front matter. It leaves the deck, stays searchable in All Notes → Archived, and Restore brings it back. For ten seconds after archiving, an undo in the deck puts it straight back. Delete… on an archived note asks first and moves the file to the Trash, where Finder can put it back; OpenNotes never deletes a file for good.",
  ],
  [
    "Can other apps make notes?",
    "Yes. OpenNotes registers opennotes:// links (new, open, append) and four Shortcuts actions, so a Shortcut, a script or another app can add a note or read one. Every write goes through the same door the hotkey uses and asks the license first; nothing is created while the app is read-only.",
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
    "They already are somewhere else: plain Markdown files in your folder. Copy them, open them in another app, or export one from All Notes as .md or .txt. Uninstall OpenNotes and every note is still there.",
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
                  A deck of sticky notes docked to the edge of your screen. Paper edges at rest; a
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
