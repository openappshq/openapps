import { ArrowUpRight } from "lucide-react";
import { products } from "../catalog";
import StarButton from "../shared/StarButton";
import { GITHUB_URL } from "../shared/github";

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

export function SiteHeader() {
  return (
    <header className="site-header page-width">
      <a className="brand" href="/" aria-label="OpenApps HQ home">
        <img src="/brand/openapps-hq/app-icon.svg" alt="" width="40" height="40" />
        <ThemedMark name="wordmark" alt="OpenApps HQ" width={150} height={27} />
      </a>
      <nav aria-label="Main navigation">
        <a href="/#apps">Apps</a>
        <StarButton />
      </nav>
    </header>
  );
}

export function SiteFooter() {
  return (
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
  );
}
