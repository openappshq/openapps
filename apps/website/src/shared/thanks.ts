import { CHECKOUT_GLOBAL, type CapturedCheckout } from "./checkoutCapture";

/** What Dodo appends to the redirect URL after checkout. */
export interface CheckoutReturn {
  keys: string[];
  email: string | null;
  /** Dodo's payment status, e.g. `succeeded`; null when absent. */
  status: string | null;
}

/** Query parameters that carry checkout details and must not stay in the address bar. */
const SENSITIVE_PARAMS = ["license_key", "email", "payment_id", "status"];

/** Builds the return from raw parameters; `license_key` may hold several comma-separated keys. */
export function checkoutReturnFrom(captured: CapturedCheckout): CheckoutReturn {
  const keys = (captured.license_key ?? "")
    .split(",")
    .map((key) => key.trim())
    .filter(Boolean);
  return { keys, email: captured.email?.trim() || null, status: captured.status ?? null };
}

/** Parses the checkout return from a query string. */
export function parseCheckoutReturn(search: string): CheckoutReturn {
  const params = new URLSearchParams(search);
  return checkoutReturnFrom({
    license_key: params.get("license_key"),
    email: params.get("email"),
    status: params.get("status"),
  });
}

/**
 * Reads what the head's inline script captured before any resource loaded.
 * Falls back to the query string (dev server and tests, where the generated
 * head is absent) and scrubs it the same way.
 */
export function readCheckoutReturn(
  win: Window & { [CHECKOUT_GLOBAL]?: CapturedCheckout },
): CheckoutReturn {
  const captured = win[CHECKOUT_GLOBAL];
  if (captured) return checkoutReturnFrom(captured);
  const { location, history } = win;
  const result = parseCheckoutReturn(location.search);
  const cleaned = cleanedUrl(location.href);
  if (cleaned !== location.pathname + location.search + location.hash) {
    history.replaceState(history.state, "", cleaned);
  }
  return result;
}

export type LicenseKind = "paid" | "trial";

/** The app's deep link, which only pre-fills the key; the user confirms before activating. */
export function activateUrl(scheme: string, key: string, kind: LicenseKind = "paid"): string {
  const suffix = kind === "trial" ? "&kind=trial" : "";
  return `${scheme}://activate?key=${encodeURIComponent(key)}${suffix}`;
}

/** The URL to leave in the address bar: same page, checkout details removed. */
export function cleanedUrl(url: string): string {
  const next = new URL(url);
  for (const name of SENSITIVE_PARAMS) next.searchParams.delete(name);
  return next.pathname + (next.search ? next.search : "") + next.hash;
}
