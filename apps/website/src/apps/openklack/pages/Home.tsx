import { Accordion, Button, Link } from "@heroui/react";
import { useState } from "react";
import { motion } from "motion/react";
import { enter } from "@openapps/ui/transitions";
import { ArrowDown, Check, Download } from "lucide-react";
import HqBadge from "../../../shared/HqBadge";
import SoundStudio from "../SoundStudio";
import { SiteHeader, SiteFooter } from "../SiteChrome";

import "../styles.css";

const questions = [
  [
    "What does OpenKlack actually do?",
    "OpenKlack adds recorded mechanical keyboard sounds to your keystrokes. The Mac app works across your apps from the menu bar. This browser playground lets you try sounds while its keyboard or typing test is focused.",
  ],
  [
    "Can I download the Mac app yet?",
    "The native Mac app is in development. We’re testing reliability, permissions, and everyday use before offering a signed, notarized download. Launch support is planned for macOS 14 or later on Apple Silicon.",
  ],
  [
    "Can I give individual keys a different sound?",
    "Yes—in the Mac app, choose Customize a key, then pick its sound. You can also import your own recordings or compatible sound packs.",
  ],
  [
    "Does it record what I type?",
    "OpenKlack does not save your keystrokes or typed text. The desktop app processes key events locally to play sounds. No account or automatic telemetry is part of the app; diagnostic reports are local and shared only by you.",
  ],
  [
    "Where do the sounds come from?",
    "This collection contains 18 packs distributed by Thock, with recordings originally from Mechvibes and kbsim. Each pack keeps its credits and license. Credits and licenses are included with the sound files.",
  ],
  [
    "What about Windows, Linux, or mobile?",
    "We’re making the Mac experience dependable first. Other desktop platforms can follow when the experience holds up. Mobile is deferred: iOS doesn’t let an app add sounds to another app’s existing keyboard.",
  ],
];

function Question({ question, answer }: { question: string; answer: string }) {
  return (
    <Accordion className="faq-item">
      <Accordion.Item id={question}>
        <Accordion.Heading>
          <Accordion.Trigger className="faq-trigger">
            {question}
            <Accordion.Indicator />
          </Accordion.Trigger>
        </Accordion.Heading>
        <Accordion.Panel>
          <Accordion.Body>
            <p>{answer}</p>
          </Accordion.Body>
        </Accordion.Panel>
      </Accordion.Item>
    </Accordion>
  );
}

export default function App() {
  const [previewTheme, setPreviewTheme] = useState("light");
  return (
    <>
      <Link className="skip-link" href="#playground">
        Skip to sound playground
      </Link>
      <SiteHeader />
      <main>
        <section className="hero page-width" aria-labelledby="hero-title">
          <div className="hero-kicker">
            <HqBadge />
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
              <div className="hero-actions">
                <Link className="button-link primary" href="/OpenKlack/download/">
                  Download for Mac <Download size={18} />
                </Link>
                <Link className="text-link" href="#playground">
                  Try the sounds <ArrowDown size={18} />
                </Link>
              </div>
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
              initial={{ opacity: 0, transform: "translateY(8px)" }}
              whileInView={{ opacity: 1, transform: "translateY(0)" }}
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
                  Pick a sound and close the window. OpenKlack keeps playing from your menu bar.
                </p>
              </div>
            </motion.div>
            <div className="app-showcase">
              <div className="showcase-topline">
                <span>OPENKLACK / SOUND LIBRARY</span>
                <div className="theme-choice" role="group" aria-label="App preview appearance">
                  {["light", "dark"].map((theme) => (
                    <Button
                      variant="ghost"
                      key={theme}
                      aria-pressed={previewTheme === theme}
                      onPress={() => setPreviewTheme(theme)}
                    >
                      {theme}
                    </Button>
                  ))}
                </div>
              </div>
              <img
                className="settings-preview"
                data-theme={previewTheme}
                src={`/brand/openklack/ui/settings-${previewTheme}.png`}
                alt={`${previewTheme === "light" ? "Light" : "Dark"} OpenKlack app design: sound selection, stars, volume, and live keyboard`}
                width="2000"
                height="1200"
                loading="lazy"
              />
            </div>
            <div className="feature-row">
              <article>
                <span className="feature-number">01</span>
                <h3>Your favorite sounds.</h3>
                <p>Choose from 18 recordings. Star your favorites or import your own.</p>
              </article>
              <article>
                <span className="feature-number">02</span>
                <h3>Knows when to hush.</h3>
                <p>Pauses when your microphone is in use. You can also mute specific apps.</p>
              </article>
              <article>
                <span className="feature-number">03</span>
                <h3>Entirely yours.</h3>
                <p>No account or telemetry. Your settings save automatically on your Mac.</p>
              </article>
            </div>
            <div className="menu-story">
              <div>
                <h3>
                  A tiny home
                  <br />
                  for your sound.
                </h3>
                <p>Mute, adjust the volume, or switch to a favorite sound from your menu bar.</p>
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
                initial={{ opacity: 0, transform: "translateY(8px)" }}
                whileInView={{ opacity: 1, transform: "translateY(0)" }}
                viewport={{ once: true, amount: 0.25 }}
                className="menu-preview"
              >
                <img
                  src="/brand/openklack/features/menu.svg"
                  alt="OpenKlack in the Mac menu bar, with mute, volume, and favorite sounds"
                  width="480"
                  height="390"
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
            <h2>
              Make some
              <br />
              good noise.
            </h2>
            <Link className="button-link inverse" href="/OpenKlack/download/">
              Download for Mac <Download size={20} />
            </Link>
          </div>
          <img src="/brand/openklack/symbol-paper.svg" alt="" width="260" height="260" />
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
