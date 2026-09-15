import { Button, Link } from "@heroui/react";
import { useState } from "react";
import { motion } from "motion/react";
import { enter } from "@openapps/ui/transitions";
import { Check } from "lucide-react";
import Questions from "../../../shared/Questions";
import HqBadge from "../../../shared/HqBadge";
import BuyButtons from "../../../shared/BuyButtons";
import InstallLink from "../../../shared/InstallLink";
import { licensingFor, MACS_PER_LICENSE, OFFLINE_GRACE, TRIAL_DAYS } from "../../../shared/licensing";
import SoundStudio from "../SoundStudio";
import Marquee from "../../../shared/Marquee";
import KeyToken from "../../../shared/KeyToken";
import { soundpacks } from "../soundpacks";
import { SiteHeader, SiteFooter } from "../SiteChrome";
import { Legend } from "../../../shared/MarketingChrome";

import "../styles.css";

const { price: PRICE } = licensingFor("openklack");

const questions = [
  [
    "What does OpenKlack actually do?",
    "OpenKlack adds recorded mechanical keyboard sounds to your keystrokes. The Mac app works across your apps from the menu bar. This browser playground lets you try sounds while its keyboard or typing test is focused.",
  ],
  [
    "What do I need to run it?",
    "macOS 14 or later on Apple Silicon. The download is signed and notarized. OpenKlack asks for Input Monitoring on first launch, which is how it hears keystrokes to play a sound for them.",
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
    "What does the official build send anywhere?",
    `Official builds of OpenKlack include a ${TRIAL_DAYS}-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use the app are never sent. Builds from source never contact the license service.`,
  ],
  [
    `What does the ${PRICE} buy?`,
    `A license for the official, signed and notarized build, for up to ${MACS_PER_LICENSE} Macs, forever. One price, no subscription, no account. It also keeps the project going.`,
  ],
  [
    "How does the free trial work?",
    `Download OpenKlack and it works right away for ${TRIAL_DAYS} days on that Mac. No signup, no email, no card. When the trial ends, OpenKlack goes quiet until you buy a license or build from source; nothing is charged. There’s one trial per Mac.`,
  ],
  [
    "Does it work offline?",
    `Yes. Official builds check the license once a day, and a Mac that is offline keeps working for ${OFFLINE_GRACE} since its last successful check. Builds from source never check at all.`,
  ],
  [
    "I sold or lost a Mac. Can I free up its seat?",
    "Yes. Settings › License › Remove this Mac frees a seat while you still have the machine. If the Mac is gone, contact support and we will release it for you.",
  ],
  [
    "Is building from source really free?",
    "Yes. OpenKlack is MIT licensed. Clone the repository and build it yourself; source builds need no license, no key and no trial. Only the official builds are licensed.",
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

export default function App() {
  const [previewTheme, setPreviewTheme] = useState("light");
  return (
    <>
      <Link className="skip-link" href="#playground">
        Skip to sound playground
      </Link>
      <SiteHeader />
      <main>
        <section className="hero" aria-labelledby="hero-title">
          <div className="page-width">
            <div className="hero-kicker">
              <HqBadge />
            </div>
            <motion.h1 {...enter} id="hero-title">
              Your keyboard.
              <br />
              With <KeyToken>character</KeyToken>
            </motion.h1>
            <div className="hero-grid">
              <div className="hero-intro">
                <p>
                  The deep thock. The crisp click. Give every keystroke a sound you love, with the
                  keyboard you already own.
                </p>
                <div className="hero-actions">
                  <BuyButtons app="openklack" />
                </div>
              </div>
            </div>
          </div>
        </section>
        <div className="studio-section">
          <div className="page-width">
            <SoundStudio />
          </div>
        </div>
        <section className="switch-strip" aria-label="The sound library">
          <Marquee
            label="Every switch in the library"
            items={soundpacks.map((pack) => (
              <span className="marquee-pack" key={pack.id}>
                <span
                  className="marquee-chip"
                  style={{ "--chip": pack.color } as React.CSSProperties}
                />
                <span className="marquee-switch">
                  {pack.name}
                  <small>
                    {pack.brand} · {pack.kind}
                  </small>
                </span>
              </span>
            ))}
          />
        </section>
        <section
          className="desktop-section"
          id="desktop"
          aria-labelledby="desktop-title"
        >
          <div className="page-width">
            <div className="section-heading reveal">
              <div>
                <Legend>The Mac app</Legend>
                <h2 id="desktop-title">
                  Small app.
                  <br />
                  Daily delight.
                </h2>
              </div>
              <div className="section-intro">
                <p>Pick a sound and close the window. It keeps playing.</p>
              </div>
            </div>
            <div className="app-showcase reveal">
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
            <div className="feature-row reveal-group">
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
            <div className="menu-story reveal-group">
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
                </ul>
              </div>
              <div className="menu-preview">
                <img
                  src="/brand/openklack/features/menu.svg"
                  alt="OpenKlack in the Mac menu bar, with mute, volume, and favorite sounds"
                  width="480"
                  height="390"
                  loading="lazy"
                />
              </div>
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
        <section className="closing-wrap">
          <div className="closing-section page-width">
          <div>
            <h2>
              Make some
              <br />
              good noise.
            </h2>
            <InstallLink app="openklack" className="button-link inverse" />
          </div>
            <img src="/brand/openklack/symbol-paper.svg" alt="" width="300" height="300" />
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
