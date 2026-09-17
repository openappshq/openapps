---
name: new-app
description: Add a new OpenApps HQ Mac app to the monorepo, or bring an existing one up to parity — product contract, design system, website page, README, licensing and trial, first-run guide, updater, release pipeline, defaults. Use for "add an app", "import <app>", "new product", or when an app is missing something the others have.
---

# New OpenApps app

Every app ships the same surface. This skill is the order of work and the definition of done; each rule lives in exactly one authoritative file, linked below — read those, don't duplicate them.

## 0. Before writing code

- Say the plan first and wait for the go. Decisions with real trade-offs (price, permissions, storage, naming) go to the user as a table of options, not a conclusion.
- One app id, lowercase, used everywhere: directory `apps/<app-id>` (Swift) or `apps/<app-id>-desktop` (Tauri), package `@openapps/<app-id>…`, website route `/<app-id>`, tag prefix `<app-id>-v`, cask `openappshq/tap/<app-id>`, GitHub environment `<app-id>-release`, Dodo brand `<App>`.
- Commits are authored by `Kevin <194793062+kevintechpro@users.noreply.github.com>` only. Never commit private keys, `.p12`, `.env`, generated `LicensingConfig.swift`, or Dodo API keys.
- Never launch an app that installs an event tap or key listener on a shared machine; unit tests, builds and the debug-only preview harnesses are the way to see UI.

## 1. Product and design

1. Contract: `design/products/<app-id>.md` — purpose, primary task, defaults, exceptional states, system exceptions ([design checklist](../../../design/system.md#adding-a-product)). Link it from `design/README.md`.
2. Identity: glyph, signature colour, app icon exported with provenance to `design/assets/<app-id>/` ([asset usage](../../../design/assets/README.md)). Restyle imported apps to the OpenApps look: tokens from `@openapps/ui/theme.css`, [shared rules](../../../design/system.md), [components](../../../design/components.md). No hand-edited `tokens.css`.
3. Verify UI across light/dark, keyboard focus, reduced motion and narrow layouts ([verification](../../../design/desktop-verification.md)).

## 2. Repository and website

Follow [Add another app](../../../docs/development.md#add-another-app) exactly: app directory, `apps/website/src/catalog.ts` entry (id, route, price, `permissions`, `brandSource`, pages), `apps/website/src/apps/<app-id>/pages/Home.tsx` on the design system, `docs/development.md` section for the app's build/run, and the app's own `README.md` + `RELEASING.md`. The install line, its Copy button and the "How do I install this?" step-by-step guide come with `InstallCommand` for free: the guide reads the app's name, commands and `permissions` from the catalog, so there is nothing to write per app.

**README every time.** `README.md` at the root lists every app in the "Our apps" table with one line, a screenshot or icon, links to the website page and source, and the install command; keep the intro sentence true (what is free, what is paid). A new app or a change of price/status updates it in the same branch.

## 3. Licensing and trial (paid apps)

Contract: [LICENSING.md](../../../LICENSING.md) — states, rules, record store, trial registry, shared test cases, and the [Adding licensing to a new app](../../../LICENSING.md#adding-licensing-to-a-new-app) checklist.

- Dodo: brand + `$5` product with purchasing power parity, license keys, 3 activations, no expiry, in **test and live**; record IDs in the Dodo products artifact and the website env (`VITE_<APP>_DODO_PAID_PRODUCT_ID`, test ID in `apps/website/.env.local`, live ID as a Cloudflare variable only once the licensed build ships).
- Swift apps depend on `packages/openapps-licensing` (OpenReaction is the reference integration); Tauri apps follow OpenKlack's `src-tauri/src/licensing/`.
- Records live in the encrypted file record store, never the Keychain. The trial starts in-app, no signup; the registry at `openapps.space/api/trial` accepts paid apps from the catalog automatically.
- The app never shows a price: the button says **Buy a license** and opens the website.
- Run the shared test cases and the end-to-end checks in Dodo test mode before the first licensed release.

## 4. First-run guide, pill, defaults

Parity with OpenReaction and OpenKlack:

- First-run guide (official builds, once, skippable, resumes after a permission relaunch): welcome with the trial line derived from real license state; one step per system permission the app needs, or a "no permissions needed" step; tips; "starts with your Mac" note from the real login-item setting.
- Trial pill / license badge in the app's header or menu-bar popover, driven by the same projected clock as access.
- License settings section: state, Buy a license, paste a key, Remove this Mac.
- Defaults on a **fresh install only**, recorded as decided, never changed by an upgrade: open at login **on**, automatic update checks **on**, automatic install **off** ([RELEASES.md](../../../RELEASES.md#in-app-updater)). An explicit user choice made while the default resolves wins.

## 5. Releases and updates

Contract: [RELEASES.md](../../../RELEASES.md). In short: `.github/workflows/<app-id>.yml` modelled on `opennotes.yml` (four flavours, the update e2e) or `hertz.yml` (two) — the [pipeline](../../../RELEASES.md#pipeline) shape: a `preflight` job that classifies the change and, on a manual run, finds an already passed run; a `checks` matrix over the app's flavours with the build cache; `packages` and `lint`; `release` needing all of them with the pass-or-skipped rule; `apps/<app-id>/scripts/flavour-tests.txt` naming the app target's suites; heavy tests marked `.heavy`; the app's rows in `nightly.yml`; the shared `scripts/release/` helpers; sign with the stable `OpenApps HQ Release` certificate and pin the designated requirement in `apps/<app-id>/release/designated-requirement.txt`; zip + sha256 on the GitHub release `<app-id>-vX.Y.Z`; signed feed committed to `apps/website/public/updates/<app-id>/`; the [install script](../../../RELEASES.md#install-script) `apps/website/public/install/<app-id>` regenerated by the `feed` job with `scripts/release/write-install-script.sh` (add the app's bundle identifier to the generator) and checked live with `verify-live-install-script.sh`; cask template in `packaging/homebrew/Casks/<app-id>.rb` pushed to the tap with the deploy key; tag ruleset via `scripts/release/release-tag-ruleset.sh`; GitHub environment `<app-id>-release` (deployment branches `main` and tags `<app-id>-v*`) holding the app's update key (`SPARKLE_ED_PRIVATE_KEY`, or `TAURI_SIGNING_PRIVATE_KEY` + `_PASSWORD` for a Tauri app), the two publishing credentials `FEED_COMMIT_TOKEN` and `HOMEBREW_TAP_DEPLOY_KEY` (the same values every app uses, restored from the offline backup — they stay per environment so only `main` and release tags can publish) and the licensing variables; the certificate and `RULESET_READ_TOKEN` are repository secrets every app's workflow already reads and are never copied ([Signing material](../../../RELEASES.md#signing-material)). In-app updater on `packages/openapps-updater` (Swift) or the OpenKlack `updater` feature (Rust); the cask's `postflight` and the install script clear quarantine.

Verify locally before the first publish: signing dry run with a throwaway certificate, `verify-release.sh`, `actionlint`, `shellcheck`, `scripts/release/tests/changes.test.sh` (add the app's rows). Then push, wait for the checks to go green, and dispatch with `publish=true` — never a `publish=false` dry run (the dispatch relies on the passed run and runs no checks of its own).

## 6. Definition of done

- [ ] `design/products/<app-id>.md`, assets, design index link
- [ ] Catalog entry, website page, `docs/development.md`, app README + RELEASING.md
- [ ] Root `README.md` table and intro updated
- [ ] Dodo brand/product (test + live), IDs recorded, website env
- [ ] Licensing, record store, trial, License settings, "Buy a license"
- [ ] First-run guide, trial pill, fresh-install defaults
- [ ] Workflow, cert pin, feed, install script, cask, ruleset, environment with the update key, the two publishing credentials and the variables (certificate and ruleset token never copied)
- [ ] Updater with automatic checks on
- [ ] Shared test cases pass; `pnpm lint`, `pnpm test`, `pnpm build`, app tests in every flavour
- [ ] Reviews: up to 3 rounds; only P0s block; push to `main` when green
- [ ] Traycer artifact updated with what shipped and what could not be run
