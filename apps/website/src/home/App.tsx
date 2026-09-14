import { ArrowRight, ArrowUpRight, Code2, Gift, Laptop, ShieldCheck } from "lucide-react";
import type { ReactNode } from "react";
import StarButton from "../shared/StarButton";
import { GITHUB_URL } from "../shared/github";
import { products, type Product } from "../catalog";
import "./styles.css";

const principles: { icon: ReactNode; title: string; body: string }[] = [
  { icon: <Gift size={20} />, title: "Free", body: "No trials, no upsells, no accounts." },
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

/** The ink mark in light mode, the paper mark in dark mode. */
function ThemedMark({
  name,
  alt,
  width,
  height,
}: {
  name: string;
  alt: string;
  width: number;
  height: number;
}) {
  return (
    <picture>
      <source
        srcSet={`/brand/openapps-hq/${name}-paper.svg`}
        media="(prefers-color-scheme: dark)"
      />
      <img src={`/brand/openapps-hq/${name}-ink.svg`} alt={alt} width={width} height={height} />
    </picture>
  );
}

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
            <dd>Free & open source</dd>
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
      <header className="site-header page-width">
        <a className="brand" href="/" aria-label="OpenApps HQ home">
          <img src="/brand/openapps-hq/app-icon.svg" alt="" width="40" height="40" />
          <ThemedMark name="wordmark" alt="OpenApps HQ" width={150} height={27} />
        </a>
        <nav aria-label="Main navigation">
          <a href="#apps">Apps</a>
          <StarButton />
        </nav>
      </header>
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
      <footer className="site-footer page-width">
        <div className="hq-lockup">
          <ThemedMark name="symbol" alt="" width={40} height={40} />
          <p>
            <strong>OpenApps HQ</strong> / 2026
          </p>
        </div>
        <div className="footer-links">
          {products.map((app) => (
            <a key={app.id} href={`${app.route}/`}>
              {app.name}
            </a>
          ))}
          <a href={GITHUB_URL} target="_blank" rel="noreferrer">
            GitHub <ArrowUpRight size={14} />
          </a>
        </div>
      </footer>
    </>
  );
}
