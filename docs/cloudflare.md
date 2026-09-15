# Website hosting on Cloudflare

`openapps.space` is one Cloudflare Worker, `openapps-site` in [`apps/site-worker`](../apps/site-worker):

- **Static assets** from the site build in `dist/`. `html_handling: auto-trailing-slash` serves each page at its trailing-slash URL (`/openklack` redirects to `/openklack/`). `not_found_handling: 404-page` serves `404.html` with a `404`, and that page sends visitors to `/`, as on static hosting before. Asset requests never run Worker code and are free.
- **Headers** come from `dist/_headers`, generated from the catalog by `apps/website/headers.ts`: baseline security headers everywhere, immutable caching for hashed `/assets/*`, and `noindex`, `no-store` and `no-referrer` on checkout return pages.
- **`POST /api/trial`**, the trial registry from [LICENSING.md](../LICENSING.md#trial-registry). Only `/api/*` runs the Worker (`run_worker_first`). It uses the D1 database `trial-registry` (table `trials`, migrations in `apps/site-worker/migrations`) and the Workers rate limiting binding `TRIAL_RATE_LIMIT`: 30 requests per IP per 60 seconds, per Cloudflare location, answered with `429` and `Retry-After: 60`. The IP is only the rate limit key. Nothing about a request is stored except the row itself, and Workers Logs stay off (`observability.enabled: false`). Don't turn on Workers Logs, Logpush or Tail Workers for this Worker.

## Local development

No Cloudflare account is needed. Everything runs in `workerd` with a local D1 database under `apps/site-worker/.wrangler/`.

```sh
pnpm install
pnpm build        # the site, into dist/
pnpm site:dev     # applies local migrations, then serves http://127.0.0.1:8787
pnpm site:test    # Worker tests in the Workers runtime (Vitest + @cloudflare/vitest-plugin)
```

Development builds of the apps use `http://127.0.0.1:8787/api/trial`:

```sh
curl -X POST http://127.0.0.1:8787/api/trial \
  -d '{"app":"openklack","device":"'"$(printf x | shasum -a 256 | cut -d' ' -f1)"'","env":"test"}'
# {"started_at":"2026-09-14T21:55:35.374Z","now":"2026-09-14T21:55:35.374Z"}
```

Inspect or reset the local registry:

```sh
cd apps/site-worker
pnpm exec wrangler d1 execute trial-registry --local --command "SELECT * FROM trials"
rm -rf .wrangler/state   # forget every local trial
```

`wrangler dev` simulates the rate limit locally, so 31 quick requests from one IP get a `429`.

## Deploys

[`.github/workflows/site.yml`](../.github/workflows/site.yml):

| Event | Job | Result |
| --- | --- | --- |
| Every PR and push | `checks` | Worker typecheck and tests, with no credentials. Site lint, test and build already run in `openklack.yml` |
| Push to `main`, or a manual run on `main` | `deploy` | Builds with the `website-live` variables, applies D1 migrations to the live database, then `wrangler deploy`. Skipped until the repository variable `CLOUDFLARE_DEPLOY_ENABLED` is `true` |

**Turning deploys on.** Until the Cloudflare account, the D1 database and the `website-live` environment exist, `deploy` is skipped so `main` stays green. After finishing the setup above, set the repository variable `CLOUDFLARE_DEPLOY_ENABLED` to `true` (Settings → Secrets and variables → Actions → Variables), then run the workflow manually on `main` once.

**Credential boundary.** The Cloudflare token exists only as a secret of the `website-live` environment, which only `main` may use. Pull requests never receive it, never run remote migrations and never upload a version: code reaches Cloudflare only after it's merged. There are no PR previews, and the Worker has `preview_urls: false`. Review previews locally with `pnpm build && pnpm site:dev`. If hosted previews are wanted later, they need their own Cloudflare account (or a token that can't reach the live Worker, database or domain), a separate environment with required reviewers, and a trigger that deploys only merged code, never a PR's workflow.

The committed `wrangler.jsonc` holds a placeholder `database_id`. The deploy job writes the real ID from `website-live`'s `TRIAL_REGISTRY_D1_ID` variable (`apps/site-worker/scripts/set-database-id.mjs`), so account-specific IDs stay out of the repository.

Migrations run before the deploy, so they must stay backwards compatible with the Worker version that is still live: add, don't rename or drop.

## One-time setup

### Cloudflare

In the production account (the OpenApps account, with the user added as a member):

1. Create the database and note its ID:
   ```sh
   pnpm --dir apps/site-worker exec wrangler d1 create trial-registry
   ```
   Choose a location hint near most buyers, or leave it automatic.
2. Create an API token for the deploy job only (My Profile → API Tokens → Custom token), limited to this account and zone, with:
   - Account → Workers Scripts → Edit
   - Account → D1 → Edit
   - Account → Account Settings → Read
   - Zone → Workers Routes → Edit, for `openapps.space`
   - Zone → DNS → Edit, for `openapps.space` (the Worker's custom domain creates its DNS record)
   - Zone → Zone → Read, for `openapps.space`
3. Note the account ID (Workers & Pages → Overview, right-hand column).

### GitHub

Repository → Settings → Environments:

| Environment | Deployment branches | Secrets | Variables |
| --- | --- | --- | --- |
| `website-live` | `main` only | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | `TRIAL_REGISTRY_D1_ID` (live database), `VITE_DODO_CHECKOUT_ORIGIN` (empty or `https://checkout.dodopayments.com`), `VITE_OPENKLACK_DODO_PAID_PRODUCT_ID`, `VITE_OPENREACTION_DODO_PAID_PRODUCT_ID` (live products), `VITE_OPENKLACK_BREW_CASK`, `VITE_OPENREACTION_BREW_CASK` (`owner/tap/name`, e.g. `openappshq/tap/openklack`), optionally `VITE_OPENKLACK_MAC_DOWNLOAD_URL`, `VITE_OPENREACTION_MAC_DOWNLOAD_URL` (https, a direct download shown beside the brew command) |

Put the Cloudflare secrets only in `website-live`, never as repository-level secrets, so no PR job can read them.

Buying fails closed. An app's Buy button and its `brew install --cask …` command are live only when its paid product ID is set **and** its `VITE_<APP>_BREW_CASK` is a well-formed `owner/tap/name` cask. Otherwise Buy shows "Coming soon", and the download page says the Mac release is coming soon. There is no on/off list in code: to pull an app from sale, clear its cask variable and redeploy. `VITE_<APP>_MAC_DOWNLOAD_URL` only adds a direct download link beside the command and never enables Buy on its own.

## DNS cutover

Today `openapps.space` uses Vercel's nameservers (`ns1.vercel-dns.com`, `ns2.vercel-dns.com`), registered at Name.com. On 2026-09-15 a public lookup showed only `A` records for the apex and `www` (`www` answers `307` to the apex) and no `MX` or `TXT` records. The Vercel dashboard is the source of truth: check Domains → `openapps.space` → DNS records for anything else first (verification `TXT`, email, subdomains).

The order keeps the site up throughout: Cloudflare takes over DNS while still pointing at Vercel, and the Worker replaces the apex only once the zone is active.

1. **Add the zone.** In the production account: Add a domain → `openapps.space` → Free plan. Review the imported records. Keep the apex and `www` records pointing at Vercel, set them to **DNS only** (grey cloud) so Vercel keeps serving and renewing its certificate, and recreate anything the scan missed.
2. **Switch nameservers at Name.com.** If DNSSEC is on for the domain at Name.com, turn it off first. Then My Domains → `openapps.space` → Nameservers → replace the Vercel nameservers with the two Cloudflare assigned. Wait for Cloudflare to mark the zone **Active** (usually under an hour; up to 24 hours). `dig NS openapps.space +short` should show Cloudflare. The site is still served by Vercel.
3. **Set up Cloudflare and GitHub** as above. Merge to `main`, or run the workflow manually on `main`.
4. **First deploy.** The custom domain `openapps.space` can't attach while the apex still has its Vercel `A` records. Delete those records in Cloudflare DNS right before the first deploy. Running `wrangler deploy` from a checkout with the IDs set also offers to replace them. Visitors see errors only for the seconds in between. The Worker's custom domain then creates its own record and certificate.
5. **`www`.** Replace the `www` record with a proxied `AAAA www 100::` record, then Rules → Redirect Rules → template "Redirect from WWW to root" (301, preserve path and query).
6. **Verify:**
   ```sh
   curl -sI https://openapps.space/ | grep -i -E 'server|strict-transport'          # server: cloudflare
   curl -sI https://openapps.space/openklack                                        # 307 → /openklack/
   curl -sI https://openapps.space/nonexistent                                      # 404, page redirects to /
   curl -sI https://openapps.space/openreaction/thanks/ | grep -i -E 'robots|cache' # noindex, no-store
   curl -sI https://www.openapps.space/about                                         # 301 → https://openapps.space/about
   curl -s -X POST https://openapps.space/api/trial -d '{"app":"openklack","device":"'"$(printf x | shasum -a 256 | cut -d' ' -f1)"'","env":"test"}'
   ```
7. **Retire Vercel** after a quiet week: remove the domain from the Vercel project, then delete or archive the project. The repository has no Vercel configuration file; Vercel builds keep working until then, and the extra `_headers` file is harmless there.

**Rollback:** in Cloudflare DNS, remove the Worker's custom domain (Workers → `openapps-site` → Domains & Routes), then recreate DNS-only apex `A` records pointing at the Vercel IPs noted in step 1. Trials recorded meanwhile stay in D1.

## If the rate limiting binding isn't available

The Workers rate limiting binding is documented without a plan restriction, and `wrangler dev` supports it, but that hasn't been confirmed on the production account yet. If `wrangler deploy` rejects the `ratelimits` binding:

1. Remove the `ratelimits` block from `wrangler.jsonc` and the `TRIAL_RATE_LIMIT` check in `src/trial.ts`, along with its test.
2. Add the Free plan's one WAF rate limiting rule: Security → WAF → Rate limiting rules → URI Path equals `/api/trial`, counted by IP, 10 seconds, action Block for 10 seconds.

A WAF block answers `429` without `Retry-After`, which the apps treat as "retry with backoff". It counts before the Worker runs, so blocked requests don't cost Worker invocations.
