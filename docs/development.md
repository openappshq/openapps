# Development and release guide

OpenApps HQ is one workspace for independent desktop apps and their marketing pages.
OpenKlack and [OpenReaction](../apps/openreaction/README.md) have independent native apps.

## Run

Requires Vite+ (`vp`).

```sh
vp install
pnpm dev
```

```sh
pnpm test
pnpm build
```

React + TypeScript, HeroUI v3, Three.js / React Three Fiber, Motion, and the browser’s Web Audio API.
Vite+ handles development, bundling, formatting, linting, and Vitest.
Tailwind supplies HeroUI’s styles; both apps use the shared Figma tokens.

## Repository layout

```text
apps/
  website/                    One OpenApps website and static build
    src/catalog.ts            App cards, URLs, metadata, and asset sources
    src/apps/openklack/        OpenKlack marketing, download, and playground
      pages/                  Lazy-loaded page entries
    src/apps/openreaction/     OpenReaction marketing and emoji demo
  openklack-desktop/           OpenKlack's Tauri app and native input/audio
  openreaction/               OpenReaction's Swift app
packages/
  ui/                         @openapps/ui: shared theme and motion
  openklack-ui/                @openklack/ui: keyboard, sound browser, typing
  keyboard-layout/            @openklack/keyboard-layout: logical key data
  soundpacks/                 @openklack/soundpacks: recordings and credits
design/
  README.md                   Design entry point and source authority
  system.md                   Organization-wide visual and interaction rules
  components.md               Figma specimens mapped to current HeroUI code
  products/                   Current product contracts
  references/                 Figma foundations, component sheets, and snapshot
  archive/                    Superseded proposals and external research
  assets/                     Brand masters and current captures, grouped by app
  tokens.json                 Shared Figma design system
  tokens.css                  Generated tokens, exported by @openapps/ui
```

The workspace remains pnpm + Vite+, with no additional task runner.
`pnpm dev` serves OpenApps HQ at `/`, OpenKlack at `/OpenKlack/`, its download page at `/OpenKlack/download/`, and OpenReaction at `/openreaction/`.
`pnpm openklack:dev` runs the native utility.
`pnpm build` emits one static `dist/` with a real HTML entry for each catalog page and a `404.html` fallback.
The website loads each product's code and styles only when its route opens.
Models and sounds live under `/OpenKlack/`; logos remain in `/brand/<app-id>/`.
Catalog HTML and copied assets are generated during dev/build; authored social images remain tracked.
The desktop bundle identifier and saved-settings format are unchanged by the directory move.

### Add another app

Start with the [design checklist](../design/system.md#adding-a-product) so the new product has a documented purpose, identity, and interaction contract.

1. Add its desktop project in `apps/<app-id>-desktop/` with a unique workspace package name, such as `@openapps/<app-id>-desktop`.
2. Put its marketing entry in `apps/website/src/apps/<app-id>/pages/Home.tsx`, exporting a React component as default.
   Keep its components and styles beside that folder; use product-specific class names.
3. Add one product to `apps/website/src/catalog.ts` with its id, route (for example `/another_route`), description, platform, status, brand imagery, asset sources, and pages.
   Every product needs a home page with `path: ""`; optional subpages use `path: "download"` or another segment.
   `entry: "Home"` resolves to `pages/Home.tsx`; optional `template` preserves product-specific HTML metadata.
4. Set `brandSource` to its exported brand directory and reference `/brand/<app-id>/` URLs in the catalog.
   Add any product-specific public assets through that product's `assets` list; destinations are relative to its route.
5. Restart `pnpm dev`, or run `pnpm build`.
   The app card, page metadata, static routes, and asset copies come from the catalog automatically.

New desktop apps can have their own native stack and release workflow.
Do not copy OpenKlack's signing identifier, preference storage, or keyboard dependencies into an unrelated app.
Use app-specific release tags and updater channels so one app's release cannot become another app's update.

### Shared styling

Both frontends use Tailwind CSS v4, HeroUI v3, and custom CSS for layouts and the 3D experience.
Import `@openapps/ui/theme.css` for the Figma tokens and `@openapps/ui/motion` for reduced-motion-aware transitions.
Reusable brand foundations belong in `packages/ui`; product-specific components belong with their app or in a product package.
Run `pnpm theme` after changing the Figma token export; never edit generated `design/tokens.css` directly.
Start with the [design index](../design/README.md) for organization-wide rules, component mappings, product contracts, and local Figma references.
Run `pnpm design:check` to verify tokens against the saved Figma snapshot and validate export checksums.

## Behavior

The website’s primary Download for Mac links open `/OpenKlack/download/`, a separate static HTML entry. Without `VITE_OPENKLACK_MAC_DOWNLOAD_URL`, this page shows the unreleased state and never attempts a download. Once a signed public installer is available, set that variable in `apps/website/.env.local` (see `.env.example`) and rebuild. The page then attempts the download once and exposes the same URL as a manual retry link. Browsers do not report download completion to the page; it must not claim the file finished downloading. GitHub release discovery is deferred; there is no release API polling or fake installer. Social links open the repository or an editable X post, without automatically starring or posting.

- Type in the playground or click the interactive 3D keyboard.
  Each key has damped travel and a radial lighting pulse.
  The renderer sleeps between interactions and pauses offscreen without rebuilding the canvas.
- Sound starts on; typing or clicking a keyboard key unlocks audio while the playground or interactive keyboard is focused.
- Browse and search 18 sounds. Click a sound to apply it; Preview plays a short sample without changing the active sound.
- Star sounds to pin them to the top. The desktop also shows those favorites in its native menu bar.
- The website has free typing and 15/30/60-second tests. Switching sounds preserves the passage; text and results remain in memory only.
- Browser sound choice, volume, and stars persist in localStorage. Legacy sound choices migrate, with old tuning and key overrides left out of the simple demo.
- Reduced motion removes lighting animation and key travel. Browser shortcuts and form controls keep their normal behavior.
- Desktop per-key customization has an accessible key selector and explicit physical-key selection mode.

## Checkout return pages

`/<app>/thanks/`, `/<app>/thanks/trial/` and the site-wide `/thanks/` are where Dodo Payments sends customers back, with `license_key`, `email`, `status` and `payment_id` in the query string. Each generated page starts its `<head>` with `<meta name="referrer" content="no-referrer">` and an inline script that moves those parameters into memory and replaces the URL before any stylesheet or script is requested, so the key never appears in a Referer header, in history, or in a bookmark. The page keeps the key only in memory and never stores or sends it.

What no page code can prevent: the host that serves the thanks page receives the initial request, query string included, and may write it to its access logs. Configure the host to redact or drop query strings for `*/thanks/*` in its logs, and add a `Referrer-Policy: no-referrer` response header for those paths if the host supports per-path headers. The repository has no hosting configuration file today, so this is a hosting-side setting.

Buy and trial buttons stay disabled (“Coming soon”) until `officialBuilds` in `apps/website/src/shared/licensing.ts` marks the app as having an official build to license.

## Sound library

The MIT-declared recordings come from [Thock soundpacks](https://github.com/kamillobinski/thock-soundpacks), originally Mechvibes and kbsim. Full notices ship in `packages/soundpacks/sounds/NOTICE.txt`; source revisions, original IDs, and licenses are retained in `packages/soundpacks/catalog.json`. The [research](../design/archive/thock-sound-architecture.md) records the source format and provenance.

Each pack has OGG and MP3 audio sprites, decoded on demand with Web Audio.
Mappings preserve per-key samples, alternate samples, and genuine press/release pairs.
Packs without release recordings remain silent on key-up.
The 793 source clips occupy about 7 MB across both formats.
Browser and native playback match median clip RMS with a peak ceiling, then apply the user’s tuning.
Tone is a 1.5 kHz high shelf with up to ±6 dB gain and headroom compensation.
Pitch ranges from -6 to +6 semitones; stereo placement follows the shared ANSI layout.
Neutral settings preserve the original recording’s stereo image.
Some source alternatives were already pitch-adjusted by kbsim.

To regenerate from the reviewed checkout (requires Python 3 and ffmpeg):

```sh
git clone https://github.com/kamillobinski/thock-soundpacks.git /tmp/thock-soundpacks
git -C /tmp/thock-soundpacks checkout 213e1443c5005a99d5e51b46e31e17f30e4d752a
python3 scripts/import-soundpacks.py /tmp/thock-soundpacks
```

## Keyboard assets

Both apps use `packages/openklack-ui/Keyboard3D.tsx` and the same local model and textures.
The current prototype uses the supplied Raycast reference, with fixed framing and an ivory/graphite/cobalt material and lighting bake.
Untouched originals and their source hashes live in `design/keyboard/source`.
Run `pnpm keyboard:assets` with Blender available after editing `scripts/bake-keyboard.py`.
The build preserves the reference geometry and UV bytes and regenerates both lighting atlases.
See the [asset workflow](../design/keyboard/README.md) and [provenance](../packages/openklack-ui/assets/keyboard/PROVENANCE.md).
These reference assets need permission or replacement before public redistribution.

The browser demo neither records typed text nor intercepts typing outside its page.
System-wide sound is implemented in the development desktop application below; public release verification is still pending.

## Desktop application (in development)

The Mac utility lives in `apps/openklack-desktop` and uses Tauri 2, React, and a native Rust audio engine with a macOS input bridge.
Its marketing pages and browser demo live in `apps/website/src/apps/openklack/`.

```sh
pnpm openklack:dev
pnpm openklack:test
pnpm openklack:build
```

Global keyboard sound requires macOS Input Monitoring permission for OpenKlack.
The home screen offers sound selection, starred favorites, one volume slider, and optional per-key customization. Settings contain muted apps, microphone pause, launch at login, appearance, file imports/exports, and local diagnostics. There is no desktop typing test or user-facing preset editor.
App updates are checked manually and require a separate download-and-install action.
Builds without a configured release service explain that under Settings → About & help.
The native engine plays predecoded audio independently of the settings window.
Closing settings destroys its WebView; typing sound continues in the menu bar.

Import reviewed Thock-format ZIPs, individual WAV/MP3/OGG/FLAC recordings, or self-contained `.openklack` settings bundles.
Individual recordings are limited to five seconds; archives are limited to 128 MB expanded, 4,096 entries, and 1 MB manifests.
Installed versions are content-addressed and presets stay pinned until the user applies another version.
Export settings includes the required recordings and credits; importing a settings bundle makes it active.
Corrupt pack files are preserved during repair, and malformed settings receive a recovery copy.

The desktop and website share the 3D renderer, keyboard layout, audio catalog, theme, and motion helpers. The typing playground is website-only. The compatible internal preset/tuning model remains for existing desktop settings; the UI exposes one autosaved setup.
The native listener and audio callback never depend on React or WebView animation frames.
Old presets load with neutral tuning; neutral fields are omitted on export for compatibility.
Non-neutral tuning needs this version or newer to import.

For a locally signed development bundle, use an identity already installed in your keychain:

```sh
APPLE_SIGNING_IDENTITY='Your signing identity' pnpm --filter @openapps/openklack-desktop tauri build --debug --bundles app
codesign --verify --deep --strict apps/openklack-desktop/src-tauri/target/debug/bundle/macos/OpenKlack.app
```

Regenerate the packaged macOS icon from the exact Figma export after changing the brand asset:

```sh
pnpm openklack:icons
```

The monochrome menu-bar template and the app icon are separate assets.
Changing only the template does not change the icon in Finder or Apps.

After building, quit OpenKlack and move the generated `OpenKlack.app` into `/Applications` using Finder.
If replacing an existing installation, keep that copy until the new bundle has passed its signature check.
Launch `/Applications/OpenKlack.app` for everyday use.
Running debug, QA, and release bundles directly from the project lets macOS index each as a separate app.
Archive unused bundles as ZIP files and unregister those bundle paths with `lsregister -u` to remove duplicate launcher entries.
App bundles do not contain your saved sound preferences; those remain in Application Support.

For a local release app and DMG without requiring Finder automation:

```sh
CI=true APPLE_SIGNING_IDENTITY='Your signing identity' pnpm --filter @openapps/openklack-desktop tauri build --bundles app,dmg
```

Tauri's `CI=true` bundling mode skips Finder decoration while retaining the app and Applications link in the disk image.
The `--ci` CLI flag alone does not select that behavior; the bundler checks the environment variable.
See the [Tauri DMG bundler](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-bundler/src/bundle/macos/dmg/mod.rs).

### Licensed builds

Licensing follows the shared [licensing contract](../LICENSING.md) and is compiled in only with the `licensing` cargo feature.
The default build from source has no License section, makes no license network calls, and plays sounds without restriction; `cargo test` covers the shared test cases in `src-tauri/src/licensing/core.rs` in both flavours.
A licensed build reads its configuration from the environment at build time and fails with a list of what is missing:

| Variable                                   | Value                                                                     |
| ------------------------------------------ | ------------------------------------------------------------------------- |
| `OPENKLACK_LICENSE_ENV`                    | `test` for development builds against Dodo test mode, `live` for releases |
| `OPENKLACK_DODO_PAID_PRODUCT_ID`           | The `OpenKlack` product ID for that environment                           |
| `OPENKLACK_DODO_TRIAL_PRODUCT_ID`          | The `OpenKlack Trial` product ID for that environment                     |
| `OPENKLACK_BUY_URL`, `OPENKLACK_TRIAL_URL` | The https checkout links opened by Buy for $5 and Start 3-day trial       |
| `OPENKLACK_SUPPORT_URL`                    | Optional; Contact support link, defaults to the OpenKlack page            |

```sh
OPENKLACK_LICENSE_ENV=test OPENKLACK_DODO_PAID_PRODUCT_ID=pdt_… OPENKLACK_DODO_TRIAL_PRODUCT_ID=pdt_… \
OPENKLACK_BUY_URL=https://… OPENKLACK_TRIAL_URL=https://… \
pnpm --filter @openapps/openklack-desktop tauri dev --features licensing
```

The Dodo products are not created yet, so no real IDs exist; the workflow's checks job uses placeholders to compile and test the licensed flavour, and the release job requires `OPENKLACK_DODO_PAID_PRODUCT_ID`, `OPENKLACK_DODO_TRIAL_PRODUCT_ID`, `OPENKLACK_BUY_URL` and `OPENKLACK_TRIAL_URL` as variables in the `openklack-release` environment before it builds with `OPENKLACK_LICENSE_ENV=live`.
The license record lives in the Keychain item `space.openapps.openklack.license`; a development build signed with a different identity than an installed copy asks for Keychain access on first launch.
Keyboard sounds stay off until that record has been read; if the Keychain record or `pending_cleanups` can't be read, Settings shows a storage error with Try again and the read is retried with backoff — it is never treated as "no license", and entries that couldn't be read are never overwritten.
The service follows the contract's write order: losing access takes effect in memory first and is then saved (a failed save is retried every tick and shown as a storage error), while gaining or extending access is saved first and takes effect only once that save has landed — playback is on only when both the record in memory and the last saved record grant it. Keychain reads are single-flight, and a read that started before the record changed is discarded.
A revocation is also noted in a small non-secret journal outside the Keychain (`license-journal.json` in the app's data directory), keyed by a SHA-256 hash of the activation ID and holding only the record's event sequence after the change (never a clock), written before the Keychain save; on load, an entry whose sequence is ahead of the saved record forces Revoked whatever the record says, while one the record has caught up with is stale and dropped. A journal that can't be read is a storage error that keeps sounds off; the file is never overwritten, only moved aside once an authoritative answer has to be recorded. Removing or replacing an activation writes the same note as a tombstone, and an entry is cleared only once the revoked, cleared or replaced record has been saved, or on `valid: true` for that activation; a journal write that fails keeps access off in memory, shows a storage error and is retried every tick. It never contains the license key.
Every gate decision carries a revision, and the audio engine ignores older ones, so a delayed unlock can never follow a block; a separate deadline thread that only reads the engine ends trials and grace on time even while a Keychain write or network call is stuck.
Daily checks are scheduled on the local clock, a day after the last answer from Dodo or sooner with backoff.
Time is anchored to Dodo's `Date` header at the last successful check; a clock set back more than an hour before the latest moment seen ends a trial and asks a paid license to check again until Dodo answers.
`openklack://activate?key=…` (registered in `Info.plist`) opens Settings with the key pre-filled; the user confirms before anything is sent. The trial thanks page adds `&kind=trial`, which lets the app refuse a second trial without calling Dodo; other parameters are ignored. Source builds only open Settings.

Public distribution requires Developer ID signing and notarization.
The [desktop workflow](../.github/workflows/openklack.yml) runs checks on an Apple Silicon Mac runner and can produce a signed release candidate through manual dispatch.
It does not publish a GitHub release or deploy the website.
Configure the `openklack-release` environment with `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD` (an app-specific password), and `APPLE_TEAM_ID` before running the notarization job.
Use [Tauri's signing instructions](https://v2.tauri.app/distribute/sign/macos/) for the certificate and notarization setup.
The workflow uses GitHub's documented [macOS ARM64 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

The same environment needs the `TAURI_UPDATER_PUBLIC_KEY` variable and `TAURI_SIGNING_PRIVATE_KEY` secret, plus `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` if the key is encrypted.
Use a matching key pair generated with the [Tauri updater signing instructions](https://v2.tauri.app/plugin/updater/#signing-updates); these keys are separate from the Apple signing certificate.
Keep the private key outside the repository and retain it for future releases.
The workflow embeds the app-specific `/releases/download/openklack-latest/latest.json` HTTPS endpoint and produces the DMG, signed `.app.tar.gz`, `.sig`, and `latest.json` as candidate artifacts.
After verification, publish those exact files together on a stable GitHub release tagged `openklack-v<app-version>`; the manifest points to that tag and its archive filename.
After approving a release, also attach its `latest.json` to the `openklack-latest` channel release.
Other apps must use their own channel tags.
Publishing is a separate action and has not been performed from this checkout.
The app verifies update signatures before installation, permits HTTPS only, and limits archives to 128 MiB.
Test an actual upgrade on a separate Mac before offering the release to installed users.

The [current product contract](../design/products/openklack.md) records approved behavior.
The [original desktop plan](../design/archive/desktop-plan.md) preserves the interview and initial architecture proposal.
The [verification record](../design/desktop-verification.md) distinguishes tested behavior from remaining work.

OpenKlack source is MIT licensed.
Third-party recordings retain the separate notices described above.
