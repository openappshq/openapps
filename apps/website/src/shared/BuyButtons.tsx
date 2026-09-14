import { ShoppingBag, Timer } from "lucide-react";
import { licensingFor, PRICE, TRIAL_DAYS } from "./licensing";

function Action({
  href,
  className,
  children,
}: {
  href: string | null;
  className: string;
  children: React.ReactNode;
}) {
  if (!href) {
    return (
      <span className={`${className} is-disabled`} aria-disabled="true">
        {children}
        <small>Coming soon</small>
      </span>
    );
  }
  return (
    <a className={className} href={href}>
      {children}
    </a>
  );
}

/** "Buy" and "Try" checkout buttons for an app; disabled until its Dodo products exist. */
export default function BuyButtons({ app, small = false }: { app: string; small?: boolean }) {
  const { buyUrl, trialUrl } = licensingFor(app);
  const size = small ? " small" : "";
  return (
    <div className="buy-buttons">
      <Action href={buyUrl} className={`button-link primary${size}`}>
        <ShoppingBag size={18} aria-hidden="true" /> Buy for {PRICE}
      </Action>
      <Action href={trialUrl} className={`button-link secondary${size}`}>
        <Timer size={18} aria-hidden="true" /> Try free for {TRIAL_DAYS} days
      </Action>
    </div>
  );
}
