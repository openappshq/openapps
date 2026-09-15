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
  /** Paid product ID per app; an app without one can't be bought. */
  products: Record<string, { paid: string }>;
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
 * `VITE_<APP>_DODO_PAID_PRODUCT_ID`. Malformed values are treated as unset,
 * so a typo disables the button instead of linking to a broken checkout.
 * Trials start in the app, so there is no trial product.
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
    const paid = envValue(env, `VITE_${product.id.toUpperCase()}_DODO_PAID_PRODUCT_ID`);
    if (PRODUCT_ID.test(paid)) config.products[product.id] = { paid };
  }
  return config;
}

export const dodoConfig = dodoConfigFrom(import.meta.env);

/** Where the install command's one prerequisite comes from. */
export const HOMEBREW_URL = "https://brew.sh";

/** A cask token as `brew` takes it: `owner/tap/name`, lowercase, no dots. */
const BREW_CASK = /^[a-z0-9-]+\/[a-z0-9-]+\/[a-z0-9-]+$/;

/**
 * Reads each app's Homebrew cask from `VITE_<APP>_BREW_CASK`, e.g.
 * `openappshq/tap/openreaction`. Anything that is not a full `owner/tap/name`
 * token is treated as unset, so a typo shows "Coming soon" rather than a
 * command that fails in Terminal.
 */
export function brewCasksFrom(env: Env): Record<string, string> {
  const casks: Record<string, string> = {};
  for (const product of products) {
    const value = envValue(env, `VITE_${product.id.toUpperCase()}_BREW_CASK`);
    if (BREW_CASK.test(value)) casks[product.id] = value;
  }
  return casks;
}

export const brewCasks = brewCasksFrom(import.meta.env);

/** The exact line a visitor pastes into Terminal. */
export function brewInstallCommand(cask: string): string {
  return `brew install --cask ${cask}`;
}

/**
 * Reads each app's optional direct Mac installer from
 * `VITE_<APP>_MAC_DOWNLOAD_URL`. Only absolute `https:` URLs count; anything
 * else is treated as unset. Homebrew is the install path; this only adds a
 * download link beside it.
 */
export function macDownloadUrlsFrom(env: Env): Record<string, string> {
  const urls: Record<string, string> = {};
  for (const product of products) {
    const value = envValue(env, `VITE_${product.id.toUpperCase()}_MAC_DOWNLOAD_URL`);
    if (URL.canParse(value) && new URL(value).protocol === "https:") urls[product.id] = value;
  }
  return urls;
}

export const macDownloadUrls = macDownloadUrlsFrom(import.meta.env);

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
  /** The app's download page on this site, e.g. `/openreaction/download/`. */
  downloadPageUrl: string;
  /**
   * True only when both the paid product ID and the Homebrew cask are
   * configured. There is no on/off list in code: pulling an app from sale means
   * unsetting its cask variable and rebuilding.
   */
  available: boolean;
  /** The Homebrew cask, e.g. `openappshq/tap/openreaction`; null unless `available`. */
  brewCask: string | null;
  /** `brew install --cask <cask>`; null unless `available`. */
  brewCommand: string | null;
  /** An optional direct installer; null unless `available` and a URL is configured. */
  downloadUrl: string | null;
  /** Paid checkout; null unless `available`. */
  buyUrl: string | null;
  supportUrl: string;
}

/**
 * What the buttons that lead to the install say: a download when there is a
 * direct installer, Homebrew otherwise. The wording never promises a file the
 * page cannot offer.
 */
export function installLabel(licensing: Pick<AppLicensing, "downloadUrl">): string {
  return licensing.downloadUrl ? "Download for Mac" : "Install with Homebrew";
}

export interface LicensingOptions {
  origin?: string;
  /** Overrides the environment's Dodo settings (tests). */
  dodo?: DodoConfig;
  /** Overrides the environment's Homebrew casks (tests). */
  casks?: Record<string, string>;
  /** Overrides the environment's installer URLs (tests). */
  downloads?: Record<string, string>;
}

export function licensingFor(appId: string, options: LicensingOptions = {}): AppLicensing {
  const product = products.find((p) => p.id === appId);
  if (!product) throw new Error(`Unknown app: ${appId}`);
  const origin = options.origin ?? SITE_ORIGIN;
  const dodo = options.dodo ?? dodoConfig;
  const ids = dodo.products[appId];
  const cask = (options.casks ?? brewCasks)[appId];
  const installer = (options.downloads ?? macDownloadUrls)[appId];
  // Fail closed: a paid product and a cask to install, or nothing. A direct
  // download alone never opens the gate; it is only offered beside brew.
  const available = !!ids && !!cask;
  const thanksUrl = `${origin}${product.route}/thanks/`;
  return {
    id: appId,
    name: product.name,
    scheme: appId,
    pageUrl: `${product.route}/`,
    price: product.price,
    thanksUrl,
    downloadPageUrl: `${product.route}/download/`,
    available,
    brewCask: available ? cask! : null,
    brewCommand: available ? brewInstallCommand(cask!) : null,
    downloadUrl: available && installer ? installer : null,
    buyUrl: available ? checkoutUrl(ids?.paid, thanksUrl, dodo.checkoutOrigin) : null,
    supportUrl: SUPPORT_URL,
  };
}
