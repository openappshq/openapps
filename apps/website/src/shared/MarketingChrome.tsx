import { Link } from "@heroui/react";
import { ArrowUpRight } from "lucide-react";
import type { ReactNode } from "react";
import { products } from "../catalog";
import StarButton from "./StarButton";
import { GITHUB_URL } from "./github";

function Brand({ id, name, wordmark = true }: { id: string; name: string; wordmark?: boolean }) {
  return (
    <>
      <img className="brand-tile" src={`/brand/${id}/app-icon.svg`} alt="" width="44" height="44" />
      {!wordmark ? (
        <span className="brand-name">{name}</span>
      ) : (
        <span className="brand-wordmark">
          <img
            className="mark-light"
            src={`/brand/${id}/wordmark-ink.svg`}
            alt={name}
            width="150"
            height="28"
          />
          <img
            className="mark-dark"
            src={`/brand/${id}/wordmark-paper.svg`}
            alt={name}
            width="150"
            height="28"
          />
        </span>
      )}
    </>
  );
}

/** Section legend: the mono label printed in the gutter beside a section. */
export function Legend({ index, children }: { index?: string; children: ReactNode }) {
  return (
    <span className="legend">
      {index && <span className="legend-index">{index}</span>}
      {children}
    </span>
  );
}

export function MarketingHeader({
  productId,
  links,
  action,
}: {
  productId?: string;
  links: { label: string; href: string }[];
  action?: { label: string; href: string; icon?: ReactNode };
}) {
  const product = products.find((item) => item.id === productId);
  const name = product?.name ?? "OpenApps HQ";
  return (
    <header className="site-header page-width" id="top">
      <Link
        className="brand"
        href={product ? `${product.route}/` : "/"}
        aria-label={`${name} home`}
      >
        <Brand id={product?.id ?? "openapps-hq"} name={name} wordmark={product?.wordmark !== false} />
      </Link>
      <nav aria-label="Main navigation">
        <div className="section-links">
          {links.map(({ label, href }) => (
            <Link key={href} href={href}>
              {label}
            </Link>
          ))}
        </div>
        <StarButton />
        {action && (
          <Link className="button-link small primary" href={action.href}>
            {action.label}
            {action.icon}
          </Link>
        )}
      </nav>
    </header>
  );
}

/**
 * Every app's footer points at the others by their own icon, muted until
 * hovered: the family is visible from anywhere without competing with the page
 * you are on. A product page lists its siblings; HQ lists them all.
 */
export function MarketingFooter({ productId }: { productId?: string } = {}) {
  const siblings = products.filter((product) => product.id !== productId);
  return (
    <footer className="site-footer page-width">
      <Link className="brand footer-brand" href="/" aria-label="Explore all OpenApps">
        <Brand id="openapps-hq" name="OpenApps HQ" />
      </Link>
      <nav aria-label={productId ? "The other OpenApps" : "All OpenApps"}>
        {siblings.map((product) => (
          <Link className="app-link" key={product.id} href={`${product.route}/`}>
            <img src={`/brand/${product.id}/app-icon.svg`} alt="" width="24" height="24" />
            {product.name}
          </Link>
        ))}
        <Link href={GITHUB_URL} target="_blank" rel="noreferrer">
          GitHub <ArrowUpRight size={14} />
        </Link>
      </nav>
      <p className="footer-note">Open source. Made for Mac.</p>
    </footer>
  );
}
