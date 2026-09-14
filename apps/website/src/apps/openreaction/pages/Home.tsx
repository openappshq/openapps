import "@fontsource/ibm-plex-mono/500.css";
import "../styles.css";
import { useCallback, useRef } from "react";
import { motion } from "motion/react";
import { Link } from "@heroui/react";
import {
  AppWindow,
  Download,
  LockKeyhole,
  ShieldCheck,
} from "lucide-react";
import { enter } from "@openapps/ui/transitions";
import ReactionDemo from "../demo/ReactionDemo";
import Marquee from "../../../shared/Marquee";
import KeyToken, { type Thrown } from "../../../shared/KeyToken";
import HqBadge from "../../../shared/HqBadge";
import { MarketingHeader, MarketingFooter, Legend } from "../../../shared/MarketingChrome";
import Questions from "../../../shared/Questions";
import BuyButtons from "../../../shared/BuyButtons";
import {
  MACS_PER_LICENSE,
  OFFLINE_GRACE,
  licensingFor,
  TRIAL_DAYS,
} from "../../../shared/licensing";

/** A sample of the catalogue, shown drifting past the page. */
const shortcodes: [string, string][] = [
  ["tada", "🎉"], ["rocket", "🚀"], ["heart", "❤️"], ["fire", "🔥"], ["+1", "👍"],
  ["eyes", "👀"], ["sparkles", "✨"], ["bug", "🐛"], ["ship", "🚢"], ["coffee", "☕"],
  ["brain", "🧠"], ["wave", "👋"], ["clap", "👏"], ["100", "💯"], ["thinking", "🤔"],
  ["party", "🥳"], ["bulb", "💡"], ["lock", "🔒"], ["zap", "⚡"], ["star", "⭐"],
];

const { price: PRICE } = licensingFor("openreaction");

const questions = [
  [
    "What do I need to run it?",
    "macOS 14 or later on Apple Silicon. The download is signed and notarized. Building from source stays free and needs no key.",
  ],
  [
    "How do licenses and trials work?",
    `Download OpenReaction and it works right away for ${TRIAL_DAYS} days on that Mac, with no signup. To keep it, pay ${PRICE} once for ${MACS_PER_LICENSE} Macs, forever. No subscription or account, and nothing is charged when the trial ends. Remove a Mac in Settings › License to free a seat, or contact support if you no longer have it.`,
  ],
  [
    "Can I use it offline?",
    `Official builds check the license once a day and work offline for ${OFFLINE_GRACE} after the last successful check. Free source builds never contact the license service.`,
  ],
  [
    "What permissions does it need?",
    "Input Monitoring detects shortcodes. Accessibility places the picker at your caret and inserts the emoji. You can revoke either in System Settings.",
  ],
  [
    "Does it store what I type?",
    "No. Shortcodes are matched in memory on your Mac, never logged or sent. No telemetry.",
  ],
  [
    "What does the official build send anywhere?",
    `Official builds of OpenReaction include a ${TRIAL_DAYS}-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use the app are never sent. Builds from source never contact the license service.`,
  ],
  [
    "What about Slack and Discord?",
    "OpenReaction steps aside in apps that already support shortcodes, so you only get one picker.",
  ],
];

const byCode = new Map(shortcodes);

export default function App() {
  /* Typing a shortcode anywhere on the page resolves it in the headline - the
     page doing the one thing the app does. The buffer is local and never
     leaves this component. */
  const buffer = useRef("");
  const onType = useCallback((key: string): Thrown => {
    if (key === ":") {
      const code = buffer.current;
      buffer.current = ":";
      const emoji = byCode.get(code.slice(1));
      return emoji ? { burst: emoji } : undefined;
    }
    if (!buffer.current) return undefined;
    if (!/[a-z0-9+_-]/i.test(key)) {
      buffer.current = "";
      return undefined;
    }
    buffer.current += key;
    const emoji = byCode.get(buffer.current.slice(1));
    if (emoji) {
      buffer.current = "";
      return { burst: emoji };
    }
    return undefined;
  }, []);

  return (
    <>
      <Link className="skip-link" href="#try">
        Skip to the demo
      </Link>
      <MarketingHeader
        productId="openreaction"
        links={[
          { label: "Try the demo", href: "#try" },
          { label: "The Mac app", href: "#mac" },
          { label: "Questions", href: "#questions" },
        ]}
        action={{
          label: "Download for Mac",
          href: "/openreaction/download/",
          icon: <Download size={16} />,
        }}
      />
      <main>
        <section className="hero" aria-labelledby="hero-title">
          <div className="page-width">
            <div className="hero-kicker">
              <HqBadge />
            </div>
            <motion.h1 {...enter} id="hero-title">
              Type <KeyToken className="code-word" onType={onType}>:tada</KeyToken>
              <br />
              Get <span className="hero-emoji">🎉</span>
            </motion.h1>
            <div className="hero-grid">
              <div className="hero-intro">
                <p>
                  Emoji shortcodes, wherever you write on your Mac. Type a name. Pick an emoji. Keep
                  going.
                </p>
                <div className="hero-actions">
                  <BuyButtons app="openreaction" />
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className="demo-section" id="try" aria-labelledby="try-title">
          <div className="page-width">
            <div className="demo-heading reveal">
              <h2 id="try-title">Give it a try.</h2>
            </div>
            <div className="demo-shell">
              <ReactionDemo />
            </div>
          </div>
        </section>

        <section className="code-strip" aria-label="Shortcodes">
          <Marquee
            label="Shortcodes and the emoji they insert"
            seconds={52}
            items={shortcodes.map(([code, emoji]) => (
              <span className="marquee-code" key={code}>
                :{code}: <b>{emoji}</b>
              </span>
            ))}
          />
        </section>
        <section className="mac-section" id="mac" aria-labelledby="mac-title">
          <div className="page-width">
            <div className="section-heading reveal">
              <div>
                <Legend>The Mac app</Legend>
                <h2 id="mac-title">Built for your Mac.</h2>
              </div>
            </div>
            <div className="feature-grid reveal-group">
              <article>
                <span className="feature-icon">
                  <AppWindow size={20} />
                </span>
                <h3>In the apps you use.</h3>
                <p>
                  Notes, Mail, Messages, and more. Suggestions appear right where you’re typing.
                </p>
              </article>
              <article>
                <span className="feature-icon">
                  <LockKeyhole size={20} />
                </span>
                <h3>Knows when to step aside.</h3>
                <p>Skips password fields and apps that already have their own shortcode picker.</p>
              </article>
              <article>
                <span className="feature-icon">
                  <ShieldCheck size={20} />
                </span>
                <h3>Stays on your Mac.</h3>
                <p>No accounts or telemetry. Shortcodes stay on your Mac.</p>
              </article>
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

        <section className="closing-wrap" id="get-started" aria-labelledby="start-title">
          <div className="closing-section page-width">
            <div>
              <h2 id="start-title">
                Less hunting.
                <br />
                More <span className="emoji">🎉</span>.
              </h2>
              <Link className="button-link inverse" href="/openreaction/download/">
                Download for Mac <Download size={20} />
              </Link>
            </div>
            <img src="/brand/openreaction/symbol-ink.svg" alt="" width="300" height="300" />
          </div>
        </section>
      </main>
      <MarketingFooter productId="openreaction" />
    </>
  );
}
