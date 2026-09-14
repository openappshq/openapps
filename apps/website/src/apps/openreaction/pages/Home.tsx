import "@fontsource/ibm-plex-mono/500.css";
import "../styles.css";
import { motion } from "motion/react";
import { Link } from "@heroui/react";
import { AppWindow, ArrowDown, ArrowUpRight, LockKeyhole, ShieldCheck } from "lucide-react";
import { enter } from "@openapps/ui/transitions";
import ReactionDemo from "../demo/ReactionDemo";
import HqBadge from "../../../shared/HqBadge";
import { MarketingHeader, MarketingFooter } from "../../../shared/MarketingChrome";
import Questions from "../../../shared/Questions";
import BuyButtons from "../../../shared/BuyButtons";
import {
  MACS_PER_LICENSE,
  OFFLINE_GRACE,
  PRICE,
  SUPPORT_URL,
  TRIAL_DAYS,
} from "../../../shared/licensing";
import { GITHUB_URL } from "../../../shared/github";

const questions = [
  [
    "Can I download it yet?",
    "OpenReaction is in development. Licenses and trials will be available with the signed, notarized release. Until then, build from source for free on macOS 14 or later — no key or trial needed.",
  ],
  [
    "How do licenses and trials work?",
    `Pay ${PRICE} once for the official build on ${MACS_PER_LICENSE} Macs, forever. No subscription or account. The free ${TRIAL_DAYS}-day trial needs only an email and covers one Mac; it stops when it expires, with no automatic charge. Remove a Mac in Settings › License to free a seat, or contact support if you no longer have it.`,
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
    "No. Shortcodes are matched in memory on your Mac, never logged or sent. Official builds send only the license key and activation ID to Dodo Payments at activation and daily checks — no Mac name, typing, or usage data. No telemetry.",
  ],
  [
    "What about Slack and Discord?",
    "OpenReaction steps aside in apps that already support shortcodes, so you only get one picker.",
  ],
];

export default function App() {
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
        action={{ label: "Get started", href: "#get-started", icon: <ArrowDown size={16} /> }}
      />
      <main>
        <section className="hero page-width" aria-labelledby="hero-title">
          <div className="hero-kicker">
            <HqBadge />
          </div>
          <div className="hero-grid">
            <motion.h1 {...enter} id="hero-title">
              Type <span className="code-word">:tada</span>
              <br />
              <span>Get 🎉</span>
            </motion.h1>
            <div className="hero-intro">
              <p>
                Emoji shortcodes, wherever you write on your Mac. Type a name. Pick an emoji. Keep
                going.
              </p>
              <div className="hero-actions">
                <BuyButtons app="openreaction" />
                <Link className="text-link" href="#try">
                  Try the demo <ArrowDown size={18} />
                </Link>
              </div>
              <span className="hero-note">Open source · Mac app in development</span>
            </div>
          </div>
        </section>

        <section className="page-width demo-shell" id="try" aria-labelledby="try-title">
          <div className="demo-heading">
            <h2 id="try-title">Give it a try.</h2>
          </div>
          <ReactionDemo />
        </section>

        <section className="mac-section" id="mac" aria-labelledby="mac-title">
          <div className="page-width">
            <div className="section-heading">
              <h2 id="mac-title">Built for your Mac.</h2>
            </div>
            <div className="feature-grid">
              <article>
                <span className="feature-icon">
                  <AppWindow size={22} />
                </span>
                <h3>In the apps you use.</h3>
                <p>
                  Notes, Mail, Messages, and more. Suggestions appear right where you’re typing.
                </p>
              </article>
              <article>
                <span className="feature-icon">
                  <LockKeyhole size={22} />
                </span>
                <h3>Knows when to step aside.</h3>
                <p>Skips password fields and apps that already have their own shortcode picker.</p>
              </article>
              <article>
                <span className="feature-icon">
                  <ShieldCheck size={22} />
                </span>
                <h3>Stays on your Mac.</h3>
                <p>No accounts or telemetry. Shortcodes stay on your Mac.</p>
              </article>
            </div>
          </div>
        </section>

        <section className="faq-section page-width" id="questions" aria-labelledby="faq-title">
          <div>
            <h2 id="faq-title">Good questions.</h2>
          </div>
          <Questions items={questions} />
        </section>

        <section
          className="closing-section page-width"
          id="get-started"
          aria-labelledby="start-title"
        >
          <div>
            <h2 id="start-title">
              Less hunting.
              <br />
              More 🎉.
            </h2>
            <Link
              className="button-link inverse"
              href={`${GITHUB_URL}/tree/main/apps/openreaction`}
              target="_blank"
              rel="noreferrer"
            >
              Build from source <ArrowUpRight size={20} />
            </Link>
            <p className="closing-note">Free to build. Mac release in development.</p>
            <Link className="text-link" href={SUPPORT_URL}>
              Purchase questions? Contact support.
            </Link>
          </div>
          <img src="/brand/openreaction/symbol-ink.svg" alt="" width="220" height="220" />
        </section>
      </main>
      <MarketingFooter />
    </>
  );
}
