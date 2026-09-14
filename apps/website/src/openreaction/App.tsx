import { useId, useState, type ReactNode } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Button } from "@heroui/react";
import {
  AppWindow,
  ArrowDown,
  ArrowUpRight,
  Check,
  Copy,
  EyeOff,
  Keyboard,
  LockKeyhole,
  Plus,
  ShieldCheck,
  Sparkles,
} from "lucide-react";
import ReactionDemo from "./demo/ReactionDemo";

const REPO = "https://github.com/openappshq/openklack";
const APP_DIR = `${REPO}/tree/main/apps/openreaction`;

const enter = {
  initial: { opacity: 0, y: 8 },
  whileInView: { opacity: 1, y: 0 },
  viewport: { once: true, amount: 0.3 },
};

const steps: { title: string; body: ReactNode; keys: string[] }[] = [
  {
    title: "Type a colon.",
    body: "Start a shortcode anywhere you write. After two letters, suggestions appear right at your caret.",
    keys: [":", "t", "a"],
  },
  {
    title: "Pick one.",
    body: "Arrow keys move between suggestions. Return or Tab inserts. Esc waves it away.",
    keys: ["←", "→", "Return"],
  },
  {
    title: "Or close it.",
    body: "Know the name? Type the closing colon and an exact match drops straight in.",
    keys: [":tada:", "→", "🎉"],
  },
];

const features: { icon: ReactNode; title: string; body: string }[] = [
  {
    icon: <AppWindow size={22} />,
    title: "Works where you write.",
    body: "Notes, Mail, Messages, your browser, your editor. If it’s a standard text field on your Mac, shortcodes just work.",
  },
  {
    icon: <LockKeyhole size={22} />,
    title: "Stays out of the way.",
    body: "Password fields are skipped. Apps with their own shortcodes, like Slack and Discord, are left to do their thing.",
  },
  {
    icon: <Sparkles size={22} />,
    title: "Feels like your Mac.",
    body: "A native picker that follows light and dark, respects Reduce Motion, and uses Liquid Glass on macOS 26.",
  },
  {
    icon: <ShieldCheck size={22} />,
    title: "Yours alone.",
    body: "No account. No telemetry. Shortcodes are matched on your Mac, and nothing you type is stored or sent.",
  },
];

const questions: [string, string][] = [
  [
    "Can I download it yet?",
    "Not yet. OpenReaction is in development, and we want it dependable in everyday use before offering a signed, notarized download. Until then, you can build it from source.",
  ],
  [
    "Does it read what I type?",
    "It watches for a colon followed by shortcode letters, so it can show suggestions. That matching happens in memory on your Mac. Nothing you type is logged, stored, or sent anywhere, and the code is open for anyone to check.",
  ],
  [
    "Why doesn’t it work in Slack or Discord?",
    "Those apps already turn :shortcodes: into emoji. OpenReaction steps aside there so you never get two pickers fighting over the same colon.",
  ],
  [
    "Where do the emoji and shortcodes come from?",
    "The shortcodes come from gemoji, GitHub’s open emoji database (MIT), so the names you know from GitHub and Slack work, like :+1:, :tada:, and :sparkles:. The Mac app also uses your Mac’s own emoji names and search keywords when available; this page uses gemoji only.",
  ],
  [
    "What about GIFs and stickers?",
    "They’re planned, not built. We’re getting emoji right first. When GIFs and stickers arrive, they’ll follow the same privacy rules.",
  ],
  [
    "Which Macs are supported?",
    "macOS 14 Sonoma or later. On macOS 26 Tahoe, the picker uses Liquid Glass. OpenReaction is Mac-only for now.",
  ],
];

const buildCommands = `git clone ${REPO}.git
cd openklack/apps/openreaction
./scripts/bundle.sh
open build/OpenReaction.app`;

function Question({ question, answer }: { question: string; answer: string }) {
  const [open, setOpen] = useState(false);
  const id = useId();
  return (
    <article className="faq-item">
      <h3>
        <button
          className="faq-trigger"
          aria-expanded={open}
          aria-controls={id}
          onClick={() => setOpen(!open)}
        >
          {question}
          <motion.span animate={{ rotate: open ? 45 : 0 }}>
            <Plus size={20} />
          </motion.span>
        </button>
      </h3>
      <div id={id}>
        <AnimatePresence initial={false}>
          {open && (
            <motion.div
              key="answer"
              initial={{ height: 0, opacity: 0 }}
              animate={{ height: "auto", opacity: 1 }}
              exit={{ height: 0, opacity: 0 }}
              style={{ overflow: "hidden" }}
            >
              <p>{answer}</p>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </article>
  );
}

function CopyCommands() {
  const [copied, setCopied] = useState(false);
  return (
    <div className="code-block">
      <pre>
        <code>{buildCommands}</code>
      </pre>
      <Button
        isIconOnly
        variant="ghost"
        className="copy-button"
        aria-label={copied ? "Copied" : "Copy commands"}
        onPress={async () => {
          await navigator.clipboard?.writeText(buildCommands);
          setCopied(true);
          setTimeout(() => setCopied(false), 1600);
        }}
      >
        {copied ? <Check size={16} /> : <Copy size={16} />}
      </Button>
    </div>
  );
}

export default function App() {
  return (
    <>
      <a className="skip-link" href="#try">
        Skip to the demo
      </a>
      <header className="site-header page-width" id="top">
        <a className="brand" href="#top" aria-label="OpenReaction home">
          <img
            className="brand-symbol"
            src="/openreaction/favicon.svg"
            alt=""
            width="32"
            height="32"
          />
          <span className="brand-name">OpenReaction</span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#how">How it works</a>
          <a href="#privacy">Privacy</a>
          <a href="#questions">Questions</a>
          <motion.a
            whileHover={{ y: -2 }}
            whileTap={{ scale: 0.98 }}
            className="button-link small primary"
            href="#get-started"
          >
            Get started <ArrowDown size={16} />
          </motion.a>
        </nav>
      </header>
      <main>
        <section className="hero page-width" aria-labelledby="hero-title">
          <div className="hero-kicker">
            <span className="status-dot" /> An OpenApps HQ original{" "}
            <span>Say it with a colon.</span>
          </div>
          <div className="hero-grid">
            <motion.h1
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              id="hero-title"
            >
              Type <span className="code-word">:tada</span>
              <br />
              <span className="accent">Get 🎉</span>
            </motion.h1>
            <div className="hero-intro">
              <img
                src="/brand/openreaction/app-icon.svg"
                alt="OpenReaction app icon"
                width="92"
                height="92"
              />
              <p>
                The emoji shortcodes you know from Slack and GitHub, in every text field on your
                Mac. A tiny menu-bar app. Nothing to learn.
              </p>
              <a className="text-link" href="#try">
                Try it right here <ArrowDown size={18} />
              </a>
              <span className="hero-note">Free & open source. Made for Mac.</span>
            </div>
          </div>
        </section>

        <section className="page-width demo-shell" id="try" aria-labelledby="try-title">
          <div className="demo-heading">
            <div>
              <span className="eyebrow">01 / Try it here</span>
              <h2 id="try-title">Go on, type a colon.</h2>
            </div>
            <span className="release-label">
              <span className="status-dot" /> Same rules as the Mac app
            </span>
          </div>
          <ReactionDemo />
        </section>

        <section className="how-section page-width" id="how" aria-labelledby="how-title">
          <motion.div {...enter}>
            <span className="eyebrow">02 / How it works</span>
            <h2 id="how-title">Three keys to happy.</h2>
          </motion.div>
          <ol className="steps">
            {steps.map((step, i) => (
              <motion.li key={step.title} {...enter} transition={{ delay: i * 0.06 }}>
                <span className="feature-number">0{i + 1}</span>
                <div className="step-keys" aria-hidden="true">
                  {step.keys.map((key) => (
                    <kbd key={key}>{key}</kbd>
                  ))}
                </div>
                <h3>{step.title}</h3>
                <p>{step.body}</p>
              </motion.li>
            ))}
          </ol>
        </section>

        <section className="mac-section" id="mac" aria-labelledby="mac-title">
          <div className="page-width">
            <motion.div {...enter} className="section-heading">
              <div>
                <span className="eyebrow">03 / Made for your Mac</span>
                <h2 id="mac-title">
                  Everywhere you type.
                  <br />
                  <span>Nowhere it shouldn’t.</span>
                </h2>
              </div>
              <div className="section-intro">
                <span className="release-label">
                  <span className="status-dot" /> Mac app in development
                </span>
                <p>
                  OpenReaction lives in your menu bar and waits for a colon. No window to open, no
                  shortcut to remember.
                </p>
              </div>
            </motion.div>
            <div className="feature-grid">
              {features.map((feature) => (
                <motion.article key={feature.title} {...enter}>
                  <span className="feature-icon">{feature.icon}</span>
                  <h3>{feature.title}</h3>
                  <p>{feature.body}</p>
                </motion.article>
              ))}
            </div>
            <div className="later-note">
              <span className="eyebrow">Coming later</span>
              <p>
                <strong>GIFs and stickers.</strong> Planned, not built yet. Emoji come first, and
                they have to feel effortless before anything else joins them.
              </p>
            </div>
          </div>
        </section>

        <section
          className="privacy-section page-width"
          id="privacy"
          aria-labelledby="privacy-title"
        >
          <motion.div {...enter}>
            <span className="eyebrow">04 / Permissions, plainly</span>
            <h2 id="privacy-title">Two switches. Here’s why.</h2>
            <p className="privacy-intro">
              macOS asks before any app can notice typing or place text in another app. OpenReaction
              needs both, and uses them only for shortcodes.
            </p>
          </motion.div>
          <div className="permission-list">
            <article>
              <span className="feature-icon">
                <Keyboard size={22} />
              </span>
              <div>
                <h3>Input Monitoring</h3>
                <p>
                  So it can notice a colon and the letters after it, plus the arrow, Return, Tab,
                  and Esc keys while the picker is open.
                </p>
              </div>
            </article>
            <article>
              <span className="feature-icon">
                <EyeOff size={22} />
              </span>
              <div>
                <h3>Accessibility</h3>
                <p>
                  So it can find your caret to place the picker, tell when you’re in a password
                  field, and swap <code>:tada</code> for 🎉 in the app you’re using.
                </p>
              </div>
            </article>
            <p className="permission-note">
              <ShieldCheck size={18} /> Matched on your Mac. Never stored, never sent. Turn either
              off any time in System Settings › Privacy & Security.
            </p>
          </div>
        </section>

        <section
          className="start-section page-width"
          id="get-started"
          aria-labelledby="start-title"
        >
          <div>
            <span className="eyebrow">05 / Get started</span>
            <h2 id="start-title">Build it tonight.</h2>
            <p>
              <span className="release-label">
                <span className="status-dot" /> In development
              </span>
            </p>
            <p className="start-copy">
              There’s no notarized download yet. If you’re comfortable with a terminal, you can
              build the app yourself on macOS 14 or later with Xcode 26 (Swift 6.2 or later)
              installed.
            </p>
          </div>
          <div className="start-panel">
            <CopyCommands />
            <p>
              On first launch, grant Input Monitoring and Accessibility when macOS asks, then type{" "}
              <code>:tada</code> anywhere. Set <code>APPLE_SIGNING_IDENTITY</code> before bundling
              to keep those grants across rebuilds.
            </p>
            <a className="text-link" href={APP_DIR} target="_blank" rel="noreferrer">
              View the source <ArrowUpRight size={18} />
            </a>
          </div>
        </section>

        <section className="faq-section page-width" id="questions" aria-labelledby="faq-title">
          <div>
            <span className="eyebrow">06 / A few good questions</span>
            <h2 id="faq-title">
              Before <br />
              you colon.
            </h2>
          </div>
          <div className="faq-list">
            {questions.map(([question, answer]) => (
              <Question key={question} question={question} answer={answer} />
            ))}
          </div>
        </section>

        <section className="closing-section page-width">
          <div>
            <span className="eyebrow">Your next favorite little thing.</span>
            <h2>
              Less hunting.
              <br />
              More 🎉.
            </h2>
            <motion.a
              whileHover={{ y: -2 }}
              whileTap={{ scale: 0.98 }}
              className="button-link inverse"
              href="#try"
            >
              Back to the demo <ArrowUpRight size={20} />
            </motion.a>
          </div>
          <img src="/brand/openreaction/app-icon.svg" alt="" width="240" height="240" />
        </section>
      </main>
      <footer className="site-footer page-width">
        <div className="hq-lockup">
          <img src="/brand/openapps-hq/app-icon.svg" alt="" width="56" height="56" />
          <div>
            <strong>An OpenApps HQ original.</strong>
            <p>Small apps. Room for personality.</p>
          </div>
        </div>
        <div className="footer-links">
          <span>OpenReaction / 2026</span>
          <a href="/home/">All OpenApps HQ apps</a>
          <a href={`${REPO}/blob/main/LICENSE`} target="_blank" rel="noreferrer">
            MIT License
          </a>
          <a href="https://github.com/github/gemoji" target="_blank" rel="noreferrer">
            Emoji data: gemoji (MIT)
          </a>
          <a href={APP_DIR} target="_blank" rel="noreferrer">
            GitHub <ArrowUpRight size={14} />
          </a>
        </div>
      </footer>
    </>
  );
}
