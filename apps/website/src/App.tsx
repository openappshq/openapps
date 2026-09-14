import { useState, useId } from "react";
import { motion, AnimatePresence } from "motion/react";
import { enter } from "@openklack/ui/transitions";
import { ArrowDown, ArrowUpRight, Check, Plus } from "lucide-react";
import SoundStudio from "./SoundStudio";
import HqBadge from "./shared/HqBadge";
import StarButton from "./shared/StarButton";

const questions = [
  [
    "What does OpenKlack actually do?",
    "OpenKlack adds recorded mechanical keyboard sounds to your keystrokes. The Mac app works across your apps from the menu bar. This browser playground lets you try the sounds while its keyboard is focused.",
  ],
  [
    "Can I download the Mac app yet?",
    "The native Mac app is in development. We’re testing reliability, permissions, and everyday use before offering a signed, notarized download. Launch support is planned for macOS 14 or later on Apple Silicon.",
  ],
  [
    "Can I give individual keys a different sound?",
    "Yes. Try Customize a key in the playground, choose a key, and apply a sound from the library. The desktop app also supports saved presets and importing your own audio or compatible sound packs.",
  ],
  [
    "Does it record what I type?",
    "OpenKlack does not save your keystrokes or typed text. The desktop app processes key events locally to play sounds. No account or automatic telemetry is part of the app; diagnostic reports are local and shared only by you.",
  ],
  [
    "Where do the sounds come from?",
    "This collection contains 18 packs distributed by Thock, with recordings originally from Mechvibes and kbsim. Each pack keeps its credits and license. You can read the sound credits below the playground.",
  ],
  [
    "What about Windows, Linux, or mobile?",
    "We’re making the Mac experience dependable first. Other desktop platforms can follow when the experience holds up. Mobile is deferred: iOS doesn’t let an app add sounds to another app’s existing keyboard.",
  ],
];

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

export default function App() {
  const [previewTheme, setPreviewTheme] = useState("light");
  return (
    <>
      <a className="skip-link" href="#playground">
        Skip to sound playground
      </a>
      <header className="site-header page-width" id="top">
        <a className="brand" href="#top" aria-label="OpenKlack home">
          <img
            className="brand-symbol"
            src="/brand/openklack/symbol-ink.svg"
            alt=""
            width="36"
            height="36"
          />
          <img
            className="brand-wordmark"
            src="/brand/openklack/wordmark-ink.svg"
            alt="OpenKlack"
            width="150"
            height="34"
          />
        </a>
        <nav aria-label="Main navigation">
          <a href="#desktop">The Mac app</a>
          <a href="#questions">Questions</a>
          <StarButton />
          <motion.a
            whileHover={{ y: -2 }}
            whileTap={{ scale: 0.98 }}
            className="button-link small primary"
            href="#playground"
          >
            Try the sounds <ArrowDown size={16} />
          </motion.a>
        </nav>
      </header>
      <main>
        <section className="hero page-width" aria-labelledby="hero-title">
          <div className="hero-kicker">
            <HqBadge /> <span>Sound on. Smile on.</span>
          </div>
          <div className="hero-grid">
            <motion.h1 {...enter} id="hero-title">
              Your keyboard.
              <br />
              <span>With character.</span>
            </motion.h1>
            <div className="hero-intro">
              <img
                src="/brand/openklack/app-icon.svg"
                alt="OpenKlack app icon"
                width="92"
                height="92"
              />
              <p>
                The deep thock. The crisp click. Give every keystroke a sound you love, with the
                keyboard you already own.
              </p>
              <a className="text-link" href="#playground">
                Find your sound <ArrowDown size={18} />
              </a>
              <span className="hero-note">Free & open source. Made for Mac.</span>
            </div>
          </div>
        </section>
        <div className="page-width">
          <SoundStudio />
        </div>
        <section className="desktop-section" id="desktop" aria-labelledby="desktop-title">
          <div className="page-width">
            <motion.div
              initial={{ opacity: 0, y: 8 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.3 }}
              className="section-heading"
            >
              <div>
                <span className="eyebrow">02 / Beyond the browser</span>
                <h2 id="desktop-title">
                  Small app.
                  <br />
                  Daily delight.
                </h2>
              </div>
              <div className="section-intro">
                <span className="release-label">
                  <span className="status-dot" /> Mac app in development
                </span>
                <p>
                  Pick your sound. Close the window. OpenKlack lives in your menu bar, adding a
                  little character to the things you do every day.
                </p>
              </div>
            </motion.div>
            <div className="app-showcase">
              <div className="showcase-topline">
                <span>OPENKLACK / SOUND LIBRARY</span>
                <div className="theme-choice" role="group" aria-label="App preview appearance">
                  {["light", "dark"].map((theme) => (
                    <button
                      key={theme}
                      aria-pressed={previewTheme === theme}
                      onClick={() => setPreviewTheme(theme)}
                    >
                      {theme}
                    </button>
                  ))}
                </div>
              </div>
              <motion.img
                key={previewTheme}
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                className="settings-preview"
                src={`/brand/openklack/ui/settings-${previewTheme}.png`}
                alt={`${previewTheme === "light" ? "Light" : "Dark"} OpenKlack app design: sound library, pack previews, explicit Apply control, and live keyboard`}
                width="1208"
                height="968"
                loading="lazy"
              />
              <span className="preview-caption">A look at the new app design.</span>
            </div>
            <div className="feature-row">
              <article>
                <span className="feature-number">01</span>
                <h3>Find your signature.</h3>
                <p>
                  A curated starting point, a deeper catalog to explore. Mix sounds by key, save a
                  preset, or bring your own recordings.
                </p>
              </article>
              <article>
                <span className="feature-number">02</span>
                <h3>Knows when to hush.</h3>
                <p>
                  Automatic pause for microphone activity, with a visible reason and an easy way to
                  resume. App rules keep you in control.
                </p>
              </article>
              <article>
                <span className="feature-number">03</span>
                <h3>Entirely yours.</h3>
                <p>
                  No account. No automatic telemetry. Your sounds and settings stay on your Mac,
                  with portable presets when you want to share.
                </p>
              </article>
            </div>
            <div className="menu-story">
              <div>
                <span className="eyebrow">Within reach. Out of the way.</span>
                <h3>
                  A tiny home
                  <br />
                  for your sound.
                </h3>
                <p>
                  Volume, favorites, and a moment of quiet. The everyday controls live one click
                  away, so the settings window can stay closed.
                </p>
                <ul>
                  <li>
                    <Check size={18} /> Native input and audio
                  </li>
                  <li>
                    <Check size={18} /> Follows your Mac’s audio output
                  </li>
                  <li>
                    <Check size={18} /> Free official builds planned
                  </li>
                </ul>
              </div>
              <motion.div
                initial={{ opacity: 0, y: 16 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, amount: 0.25 }}
                className="menu-preview"
              >
                <span className="menu-preview-label">When it’s time to listen.</span>
                <img
                  src="/brand/openklack/ui/menu-paused.png"
                  alt="Proposed menu bar controls showing automatic pause, resume, volume, preset, and favorites"
                  width="416"
                  height="608"
                  loading="lazy"
                />
              </motion.div>
            </div>
          </div>
        </section>
        <section className="faq-section page-width" id="questions" aria-labelledby="faq-title">
          <div>
            <span className="eyebrow">03 / A few good questions</span>
            <h2 id="faq-title">
              Before <br />
              you click.
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
              Make some
              <br />
              good noise.
            </h2>
            <motion.a
              whileHover={{ y: -2 }}
              whileTap={{ scale: 0.98 }}
              className="button-link inverse"
              href="#playground"
            >
              Back to the playground <ArrowUpRight size={20} />
            </motion.a>
          </div>
          <img src="/brand/openklack/symbol-paper.svg" alt="" width="260" height="260" />
        </section>
      </main>
      <footer className="site-footer page-width">
        <div className="hq-lockup">
          <img src="/brand/openapps-hq/symbol-ink.svg" alt="" width="40" height="40" />
          <div>
            <img
              src="/brand/openapps-hq/wordmark-ink.svg"
              alt="OpenApps HQ"
              width="150"
              height="27"
            />
            <p>Small apps. Room for personality.</p>
          </div>
        </div>
        <div>
          <span>OpenKlack / 2026</span>
          <a href="/home/">All OpenApps HQ apps</a>
          <a href="https://github.com/openappshq/openklack" target="_blank" rel="noreferrer">
            GitHub <ArrowUpRight size={14} />
          </a>
        </div>
      </footer>
    </>
  );
}
