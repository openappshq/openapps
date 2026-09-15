import { ArrowRight, ArrowUpRight, Code2, Gift, Laptop, ShieldCheck } from "lucide-react";
import type { ReactNode } from "react";
import { Link } from "@heroui/react";
import { motion } from "motion/react";
import { enter } from "@openapps/ui/transitions";
import { MarketingHeader, MarketingFooter, Legend } from "../shared/MarketingChrome";
import KeyToken from "../shared/KeyToken";
import { products, type Product } from "../catalog";
import { MACS_PER_LICENSE, TRIAL_DAYS } from "../shared/licensing";
import { GITHUB_URL } from "../shared/github";
import "./styles.css";

const principles: { icon: ReactNode; title: string; body: string }[] = [
  {
    icon: <Gift size={18} />,
    title: "Pay once",
    body: `One price per app, for ${MACS_PER_LICENSE} Macs, or nothing at all. No subscriptions, no accounts.`,
  },
  { icon: <Code2 size={18} />, title: "Open source", body: "MIT licensed, built in the open." },
  {
    icon: <ShieldCheck size={18} />,
    title: "Private by default",
    body: "Your typing stays on your Mac.",
  },
  {
    icon: <Laptop size={18} />,
    title: "Native",
    body: "Real Mac apps that feel like they belong.",
  },
];

/** One app, set as a wide key rather than a card in a grid. */
function AppRow({ app, index }: { app: Product; index: number }) {
  return (
    <li>
      <Link className="app-row" data-accent={app.accent} href={`${app.route}/`}>
        <span className="app-row-index">{String(index + 1).padStart(2, "0")}</span>
        <img className="app-tile keycap" src={app.icon} alt="" width="64" height="64" />
        <span className="app-row-text">
          <span className="app-row-name">{app.name}</span>
          <span className="app-row-desc">{app.description}</span>
        </span>
        <span className="app-row-meta">
          <span className="app-row-spec">{app.platform}</span>
          <span className="app-row-spec">
            {app.free ? "Free · Homebrew" : `${app.price} · ${TRIAL_DAYS}-day trial`}
          </span>
        </span>
        <span className="app-row-go" aria-hidden="true">
          <ArrowRight size={18} />
        </span>
      </Link>
    </li>
  );
}

export default function App() {
  return (
    <>
      <Link className="skip-link" href="#apps">
        Skip to the apps
      </Link>
      <MarketingHeader links={[{ label: "The apps", href: "#apps" }]} />
      <main>
        <section className="hq-hero hero" aria-labelledby="hero-title">
          <div className="page-width">
            <motion.h1 {...enter} id="hero-title">
              Small <KeyToken>apps</KeyToken>
              <br />
              <span className="hero-quiet">Room for personality.</span>
            </motion.h1>
            <div className="hero-grid">
              <div className="hero-intro">
                <p>
                  Open-source Mac apps that do one thing well and stay out of your way. No accounts
                  or telemetry.
                </p>
                <div className="hero-actions">
                  <Link className="button-link primary" href="#apps">
                    See the apps <ArrowRight size={18} aria-hidden="true" />
                  </Link>
                  <Link
                    className="button-link secondary"
                    href={GITHUB_URL}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Browse the source <ArrowUpRight size={18} aria-hidden="true" />
                  </Link>
                  <p className="buy-note">
                    {products.length} apps <span aria-hidden="true">·</span> macOS{" "}
                    <span aria-hidden="true">·</span> MIT licensed
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>
        <section className="apps-section" id="apps" aria-labelledby="apps-title">
          <div className="page-width">
            <div className="section-heading reveal">
              <div>
                <Legend index="01">The apps</Legend>
                <h2 id="apps-title">Small things, made well.</h2>
              </div>
            </div>
            <ul className="app-list reveal-group">
              {products.map((app, index) => (
                <AppRow key={app.id} app={app} index={index} />
              ))}
            </ul>
          </div>
        </section>
        <section className="principles" aria-labelledby="principles-title">
          <div className="page-width">
            <div className="principles-field reveal">
              <div className="principles-head">
                <Legend index="02">Principles</Legend>
                <h2 id="principles-title">
                  Small on purpose.
                  <br />
                  Yours to keep.
                </h2>
              </div>
              <ul>
                {principles.map((principle) => (
                  <li key={principle.title}>
                    <span className="principle-icon">{principle.icon}</span>
                    <div>
                      <h3>{principle.title}</h3>
                      <p>{principle.body}</p>
                    </div>
                  </li>
                ))}
              </ul>
              <img
                className="principles-mark"
                src="/brand/openapps-hq/symbol-ink.svg"
                alt=""
                width="300"
                height="300"
              />
            </div>
          </div>
        </section>
      </main>
      <MarketingFooter />
    </>
  );
}
