import { products } from "../catalog";

/** Where the site is served; checkout returns here. */
export const SITE_ORIGIN = "https://openapps.space";
/** Dodo Payments static checkout. Test mode uses `https://test.checkout.dodopayments.com`. */
export const DODO_CHECKOUT_ORIGIN = "https://checkout.dodopayments.com";
/** Placeholder until the user sets a real support address. */
export const SUPPORT_URL = "mailto:support@openapps.space";

export const PRICE = "$5";
export const TRIAL_DAYS = 3;
export const MACS_PER_LICENSE = 3;
export const OFFLINE_GRACE = "a week";

/** Dodo product IDs per app. A `PLACEHOLDER_` value renders a disabled "Coming soon" button. */
export const dodoProducts: Record<string, { paid: string; trial: string }> = {
  openreaction: { paid: "pdt_0NnbAzI0N8T63rCLtnBxv", trial: "pdt_0NnbAzM7iVdlBBksxe0s4" },
  openklack: { paid: "pdt_0NnbAzPn7LOJRuOC74G1Q", trial: "pdt_0NnbAzTpBJLGJo3JmjbaX" },
};

export const isPlaceholder = (productId: string) => /^PLACEHOLDER_/.test(productId);

/**
 * Static payment link. Dodo appends `payment_id`, `status`, `email` and, for
 * products with license keys, `license_key` to the redirect URL.
 */
export function checkoutUrl(
  productId: string,
  redirectUrl: string,
  origin = DODO_CHECKOUT_ORIGIN,
): string | null {
  if (!productId || isPlaceholder(productId)) return null;
  const params = new URLSearchParams({ quantity: "1", redirect_url: redirectUrl });
  return `${origin}/buy/${encodeURIComponent(productId)}?${params}`;
}

export interface AppLicensing {
  id: string;
  name: string;
  /** Custom URL scheme the Mac app registers, e.g. `openreaction://activate?key=…`. */
  scheme: string;
  /** The app's page on this site, e.g. `/openreaction/`. */
  pageUrl: string;
  thanksUrl: string;
  /** Null while the product is still a placeholder. */
  buyUrl: string | null;
  trialUrl: string | null;
  supportUrl: string;
}

export function licensingFor(appId: string, origin = SITE_ORIGIN): AppLicensing {
  const product = products.find((p) => p.id === appId);
  if (!product) throw new Error(`Unknown app: ${appId}`);
  const ids = dodoProducts[appId] ?? {
    paid: `PLACEHOLDER_${appId}_PAID`,
    trial: `PLACEHOLDER_${appId}_TRIAL`,
  };
  const thanksUrl = `${origin}${product.route}/thanks/`;
  return {
    id: appId,
    name: product.name,
    scheme: appId,
    pageUrl: `${product.route}/`,
    thanksUrl,
    buyUrl: checkoutUrl(ids.paid, thanksUrl),
    trialUrl: checkoutUrl(ids.trial, thanksUrl),
    supportUrl: SUPPORT_URL,
  };
}
