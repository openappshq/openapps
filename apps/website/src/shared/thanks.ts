/** What Dodo appends to the redirect URL after checkout. */
export interface CheckoutReturn {
  keys: string[];
  email: string | null;
  /** Dodo's payment status, e.g. `succeeded`; null when absent. */
  status: string | null;
}

/** Query parameters that carry checkout details and must not stay in the address bar. */
const SENSITIVE_PARAMS = ["license_key", "email", "payment_id", "status"];

/** Parses the checkout return; `license_key` may hold several keys separated by commas. */
export function parseCheckoutReturn(search: string): CheckoutReturn {
  const params = new URLSearchParams(search);
  const keys = (params.get("license_key") ?? "")
    .split(",")
    .map((key) => key.trim())
    .filter(Boolean);
  return { keys, email: params.get("email")?.trim() || null, status: params.get("status") };
}

/** The app's deep link, which only pre-fills the key; the user confirms before activating. */
export function activateUrl(scheme: string, key: string): string {
  return `${scheme}://activate?key=${encodeURIComponent(key)}`;
}

/** The URL to leave in the address bar: same page, checkout details removed. */
export function cleanedUrl(url: string): string {
  const next = new URL(url);
  for (const name of SENSITIVE_PARAMS) next.searchParams.delete(name);
  return next.pathname + (next.search ? next.search : "") + next.hash;
}
