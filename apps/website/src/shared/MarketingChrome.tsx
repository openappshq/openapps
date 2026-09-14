import { Link } from "@heroui/react";
import { ArrowUpRight } from "lucide-react";
import type { ReactNode } from "react";
import { products } from "../catalog";
import StarButton from "./StarButton";
import { GITHUB_URL } from "./github";

function Brand({ id, name }: { id: string; name: string }) {
  return (
    <>
      <img className="brand-tile" src={`/brand/${id}/app-icon.svg`} alt="" width="44" height="44" />
      {id === "openreaction" ? (
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
        <Brand id={product?.id ?? "openapps-hq"} name={name} />
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

export function MarketingFooter() {
  return (
    <footer className="site-footer page-width">
      <Link className="brand footer-brand" href="/" aria-label="Explore all OpenApps">
        <Brand id="openapps-hq" name="OpenApps HQ" />
      </Link>
      <nav aria-label="All OpenApps">
        {products.map((product) => (
          <Link key={product.id} href={`${product.route}/`}>
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
