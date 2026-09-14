/** Bindings from `wrangler.jsonc`. */
declare namespace Cloudflare {
  interface Env {
    ASSETS: Fetcher;
    DB: D1Database;
    TRIAL_RATE_LIMIT: RateLimit;
  }
  interface GlobalProps {
    mainModule: typeof import("./index.ts");
  }
}

type Env = Cloudflare.Env;
