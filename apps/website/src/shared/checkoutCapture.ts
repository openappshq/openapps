/** Query parameters Dodo appends to the checkout return URL. */
export const CHECKOUT_PARAMS = ["license_key", "email", "status", "payment_id"] as const;

/** Where the inline script parks the captured parameters, in memory only. */
export const CHECKOUT_GLOBAL = "__openappsCheckout";

export type CapturedCheckout = Partial<Record<(typeof CHECKOUT_PARAMS)[number], string | null>>;

/**
 * Inline script for the head of every checkout return page. It runs before
 * any stylesheet or module is requested, so the key and email never reach a
 * Referer header: the parameters move into a window property and the address
 * bar is replaced with the clean URL. Plain ES5, no dependencies.
 */
export const CHECKOUT_CAPTURE_SCRIPT = `(function () {
  try {
    var names = ${JSON.stringify(CHECKOUT_PARAMS)};
    var params = new URLSearchParams(location.search);
    var captured = {};
    var found = false;
    for (var i = 0; i < names.length; i++) {
      if (params.has(names[i])) {
        found = true;
        captured[names[i]] = params.get(names[i]);
        params.delete(names[i]);
      }
    }
    if (!found) return;
    window.${CHECKOUT_GLOBAL} = captured;
    var query = params.toString();
    history.replaceState(history.state, "", location.pathname + (query ? "?" + query : "") + location.hash);
  } catch (error) {}
})();`;

/** Head markup that must precede every other tag on a checkout return page. */
export const CHECKOUT_HEAD = `<meta name="referrer" content="no-referrer" />\n    <script>${CHECKOUT_CAPTURE_SCRIPT}</script>`;
