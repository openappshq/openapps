import { ArrowRight, Code2, Gift, Laptop, ShieldCheck } from "lucide-react";
import type { ReactNode } from "react";
import { SiteFooter, SiteHeader } from "./SiteChrome";
import { products, type Product } from "../catalog";
import { MACS_PER_LICENSE, PRICE, TRIAL_DAYS } from "../shared/licensing";
import "./styles.css";

const principles: { icon: ReactNode; title: string; body: string }[] = [
  {
    icon: <Gift size={20} />,
    title: `${PRICE}, once`,
    body: `Per app, for ${MACS_PER_LICENSE} Macs. No subscriptions, no accounts.`,
  },
  { icon: <Code2 size={20} />, title: "Open source", body: "MIT licensed, built in the open." },
  {
    icon: <ShieldCheck size={20} />,
    title: "Private by default",
    body: "No telemetry. Nothing leaves your Mac.",
  },
  {
    icon: <Laptop size={20} />,
    title: "Native",
    body: "Real Mac apps that feel like they belong.",
  },
];

function AppCard({ app }: { app: Product }) {
  return (
    <li>
      <a className="app-card" data-accent={app.accent} href={`${app.route}/`}>
        <img className="app-tile" src={app.icon} alt="" width="72" height="72" />
        <h3>{app.name}</h3>
        <p>{app.description}</p>
        <dl className="app-meta">
          <div>
            <dt className="sr-only">Platform</dt>
            <dd>{app.platform}</dd>
          </div>
          <div>
            <dt className="sr-only">Price</dt>
            <dd>
              Open source · {PRICE} official build · Free {TRIAL_DAYS}-day trial
            </dd>
          </div>
          <div>
            <dt className="sr-only">Status</dt>
            <dd>
              <span className="status-dot" /> {app.status}
            </dd>
          </div>
        </dl>
        <span className="app-cta" aria-hidden="true">
          Explore <ArrowRight size={16} />
        </span>
      </a>
    </li>
  );
}

export default function App() {
  return (
    <>
      <a className="skip-link" href="#apps">
        Skip to the apps
      </a>
      <SiteHeader />
      <main>
        <section className="hero page-width" aria-labelledby="hero-title">
          <span className="eyebrow">A small studio for small apps</span>
          <h1 id="hero-title">
            Small <span className="hero-accent">apps</span>.
            <br />
            <span className="hero-quiet">Room for personality.</span>
          </h1>
          <p>
            Free, open-source Mac apps that do one thing well and stay out of your way. No accounts,
            no telemetry, no nonsense.
          </p>
        </section>
        <section className="apps-section page-width" id="apps" aria-labelledby="apps-title">
          <div className="section-heading">
            <h2 id="apps-title">The apps</h2>
            <span className="eyebrow">{products.length} and counting</span>
          </div>
          <ul className="app-grid">
            {products.map((app) => (
              <AppCard key={app.id} app={app} />
            ))}
          </ul>
        </section>
        <section className="principles page-width" aria-labelledby="principles-title">
          <h2 id="principles-title" className="sr-only">
            How we make apps
          </h2>
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
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
