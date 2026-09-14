import { products } from "../catalog";

/** Where the site is served; checkout returns here. */
export const SITE_ORIGIN = "https://openapps.space";
/** Dodo Payments static checkout origins. Anything else in the environment is ignored. */
export const DODO_CHECKOUT_ORIGINS = {
  live: "https://checkout.dodopayments.com",
  test: "https://test.checkout.dodopayments.com",
} as const;
/** Placeholder until the user sets a real support address. */
export const SUPPORT_URL = "mailto:support@openapps.space";

export const TRIAL_DAYS = 3;
export const MACS_PER_LICENSE = 3;
export const OFFLINE_GRACE = "a week";

export interface DodoConfig {
  checkoutOrigin: string;
  /** Product IDs per app; an app without both IDs renders "Coming soon". */
  products: Record<string, { paid: string; trial: string }>;
}

type Env = Record<string, string | boolean | undefined>;

const PRODUCT_ID = /^pdt_[A-Za-z0-9]+$/;

const envValue = (env: Env, name: string) => {
  const value = env[name];
  return typeof value === "string" ? value.trim() : "";
};

/**
 * Reads Dodo settings from build-time environment variables:
 * `VITE_DODO_CHECKOUT_ORIGIN` (live checkout when unset) and, per app,
 * `VITE_<APP>_DODO_PAID_PRODUCT_ID` and `VITE_<APP>_DODO_TRIAL_PRODUCT_ID`.
 * Malformed values are treated as unset, so a typo disables the buttons
 * instead of linking to a broken checkout.
 */
export function dodoConfigFrom(env: Env): DodoConfig {
  const raw = envValue(env, "VITE_DODO_CHECKOUT_ORIGIN");
  const origin = raw.replace(/\/+$/, "");
  const known = Object.values(DODO_CHECKOUT_ORIGINS) as string[];
  const config: DodoConfig = {
    checkoutOrigin: known.includes(origin) ? origin : DODO_CHECKOUT_ORIGINS.live,
    products: {},
  };
  if (raw && !known.includes(origin)) {
    // An unknown origin could send buyers anywhere; sell nothing until it is fixed.
    return config;
  }
  for (const product of products) {
    const prefix = `VITE_${product.id.toUpperCase()}_DODO`;
    const paid = envValue(env, `${prefix}_PAID_PRODUCT_ID`);
    const trial = envValue(env, `${prefix}_TRIAL_PRODUCT_ID`);
    if (PRODUCT_ID.test(paid) && PRODUCT_ID.test(trial)) {
      config.products[product.id] = { paid, trial };
    }
  }
  return config;
}

export const dodoConfig = dodoConfigFrom(import.meta.env);

/**
 * Whether an app is on sale. Set false to pull one: the buy and trial buttons
 * go quiet even when product IDs are configured, because a key with nothing to
 * activate helps no one.
 */
export const officialBuilds: Record<string, boolean> = {
  openreaction: true,
  openklack: true,
};

/**
 * Static payment link. Dodo appends `payment_id`, `status`, `email` and, for
 * products with license keys, `license_key` to the redirect URL.
 */
export function checkoutUrl(
  productId: string | undefined,
  redirectUrl: string,
  origin: string = DODO_CHECKOUT_ORIGINS.live,
): string | null {
  if (!productId || !PRODUCT_ID.test(productId)) return null;
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
  /** What this app costs, once. */
  price: string;
  /** Where paid checkout returns. */
  thanksUrl: string;
  /** Where trial checkout returns; a separate path so the page knows the kind. */
  trialThanksUrl: string;
  /** False only while an app is off sale. */
  officialBuildAvailable: boolean;
  /** Null while product IDs are not configured or the app is off sale. */
  buyUrl: string | null;
  trialUrl: string | null;
  supportUrl: string;
}

export interface LicensingOptions {
  origin?: string;
  /** Overrides `officialBuilds` (tests and previews). */
  officialBuildAvailable?: boolean;
  /** Overrides the environment's Dodo settings (tests). */
  dodo?: DodoConfig;
}

export function licensingFor(appId: string, options: LicensingOptions = {}): AppLicensing {
  const product = products.find((p) => p.id === appId);
  if (!product) throw new Error(`Unknown app: ${appId}`);
  const origin = options.origin ?? SITE_ORIGIN;
  const dodo = options.dodo ?? dodoConfig;
  const ids = dodo.products[appId];
  const available = (options.officialBuildAvailable ?? officialBuilds[appId] ?? false) && !!ids;
  const thanksUrl = `${origin}${product.route}/thanks/`;
  const trialThanksUrl = `${origin}${product.route}/thanks/trial/`;
  return {
    id: appId,
    name: product.name,
    scheme: appId,
    pageUrl: `${product.route}/`,
    price: product.price,
    thanksUrl,
    trialThanksUrl,
    officialBuildAvailable: available,
    buyUrl: available ? checkoutUrl(ids?.paid, thanksUrl, dodo.checkoutOrigin) : null,
    trialUrl: available ? checkoutUrl(ids?.trial, trialThanksUrl, dodo.checkoutOrigin) : null,
    supportUrl: SUPPORT_URL,
  };
}
