# Development and release guide

OpenApps HQ is one workspace for independent desktop apps and their marketing pages.
OpenKlack, [OpenReaction](../apps/openreaction/README.md), [Hertz](../apps/hertz/README.md) and [macPaper](../apps/macpaper/README.md) have independent native apps.

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

The production site and the trial registry run as one Cloudflare Worker. After `pnpm build`, `pnpm site:dev` serves `dist/` and `/api/trial` with a local D1 database at `http://127.0.0.1:8787`; `pnpm site:test` runs the Worker's tests in the Workers runtime. Deploys, setup and the DNS cutover are in [cloudflare.md](cloudflare.md).

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
    src/apps/hertz/            Hertz marketing and the drawn dashboard
  site-worker/                Cloudflare Worker: serves the site, runs /api/trial on D1
  openklack-desktop/           OpenKlack's Tauri app and native input/audio
  openreaction/               OpenReaction's Swift app
  hertz/                      Hertz's Swift app
  macpaper/                   macPaper's Swift app (in development; no website page yet)
packages/
  openapps-licensing/         Swift: licensing rules, trial, record store and clients (LICENSING.md)
  openapps-updater/           Swift: the in-app updater (RELEASES.md)
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
`pnpm dev` serves OpenApps HQ at `/`, OpenKlack at `/openklack/`, its download page at `/openklack/download/`, OpenReaction at `/openreaction/`, and Hertz at `/hertz/`.
`pnpm openklack:dev` runs the native utility.
`pnpm build` emits one static `dist/` with a real HTML entry for each catalog page and a `404.html` fallback.
The website loads each product's code and styles only when its route opens.
Models and sounds live under `/openklack/`; logos remain in `/brand/<app-id>/`.
Catalog HTML and copied assets are generated during dev/build; authored social images remain tracked.
The desktop bundle identifier and saved-settings format are unchanged by the directory move.

### Add another app

Start with the [design checklist](../design/system.md#adding-a-product) so the new product has a documented purpose, identity, and interaction contract.

1. Add its desktop project in `apps/<app-id>-desktop/` with a unique workspace package name, such as `@openapps/<app-id>-desktop`.
2. Put its marketing entry in `apps/website/src/apps/<app-id>/pages/Home.tsx`, exporting a React component as default.
   Keep its components and styles beside that folder; use product-specific class names.
3. Add one product to `apps/website/src/catalog.ts` with its id, route (for example `/another_route`), description, platform, status, brand imagery, asset sources, and pages.
   Every product needs a home page with `path: ""`; optional subpages use `path: "download"` or another segment.
   A free app sets `free: true` and `price: "Free"`: it gets no download, thanks or checkout pages, is left out of licensing and of the trial registry, and installs with the same Homebrew command through its own install block. No app in the catalog is free today.
   `entry: "Home"` resolves to `pages/Home.tsx`; optional `template` preserves product-specific HTML metadata.
4. Set `brandSource` to its exported brand directory and reference `/brand/<app-id>/` URLs in the catalog.
   Add any product-specific public assets through that product's `assets` list; destinations are relative to its route.
5. Restart `pnpm dev`, or run `pnpm build`.
   The app card, page metadata, static routes, and asset copies come from the catalog automatically.

New desktop apps can have their own native stack and release workflow, but every app follows [RELEASES.md](../RELEASES.md); OpenReaction's workflow is [`openreaction.yml`](../.github/workflows/openreaction.yml), documented in [its release guide](../apps/openreaction/RELEASING.md), and Hertz's is [`hertz.yml`](../.github/workflows/hertz.yml), documented in [its release guide](../apps/hertz/RELEASING.md).
Do not copy OpenKlack's bundle identifier, preference storage, or keyboard dependencies into an unrelated app.
Use app-specific release tags, update keys and feeds so one app's release cannot become another app's update.

### Shared styling

Both frontends use Tailwind CSS v4, HeroUI v3, and custom CSS for layouts and the 3D experience.
Import `@openapps/ui/theme.css` for the Figma tokens and `@openapps/ui/motion` for reduced-motion-aware transitions.
Reusable brand foundations belong in `packages/ui`; product-specific components belong with their app or in a product package.
Run `pnpm theme` after changing the Figma token export; never edit generated `design/tokens.css` directly.
Start with the [design index](../design/README.md) for organization-wide rules, component mappings, product contracts, and local Figma references.
Run `pnpm design:check` to verify tokens against the saved Figma snapshot and validate export checksums.

## Behavior

The website’s install links open `/openklack/download/`, a separate static HTML entry. Apps install from one Terminal line, the [install script](../RELEASES.md#install-script) served at `/install/<app>` from `apps/website/public/install/<app>`, with the Homebrew cask as the alternative (see [RELEASES.md](../RELEASES.md)). The script and the cask are published together, so the cask is the gate: with `VITE_OPENKLACK_BREW_CASK` set to the cask (`owner/tap/name`, e.g. `openappshq/tap/openklack`), the page, the app page and the thanks page show `curl -fsSL https://openapps.space/install/openklack | sh` with a Copy button, one sentence on what it does with a link to the script's source, and "Prefer Homebrew? `brew install --cask <cask>`" under it. Without it, the page shows the unreleased state and offers nothing. `VITE_OPENKLACK_MAC_DOWNLOAD_URL` is optional: when it is an https URL and the cask is set, the page also attempts that download once and exposes the same URL as a manual retry link, and the install buttons read "Download for Mac" instead of "Install for Mac". Set the variables in `apps/website/.env.local` (see `.env.example`) and rebuild. Browsers do not report download completion to the page; it must not claim the file finished downloading. GitHub release discovery is deferred; there is no release API polling or fake installer. Social links open the repository or an editable X post, without automatically starring or posting.

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

`/<app>/thanks/` and the site-wide `/thanks/` are where Dodo Payments sends customers back, with `license_key`, `email`, `status` and `payment_id` in the query string. Each generated page starts its `<head>` with `<meta name="referrer" content="no-referrer">` and an inline script that moves those parameters into memory and replaces the URL before any stylesheet or script is requested, so the key never appears in a Referer header, in history, or in a bookmark. The page keeps the key only in memory and never stores or sends it.

What no page code can prevent: the host that serves the thanks page receives the initial request, query string included. The build emits `dist/_headers` from the catalog (`apps/website/headers.ts`): every `noindex` page is served with `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex` and `Cache-Control: no-store`. On Cloudflare those pages are plain static asset requests that never run Worker code, and the Worker keeps Workers Logs off; don't enable Logpush or Workers Logs for it.

Paid app pages offer the install (the one-line command with Homebrew under it, with its 3-day trial and no signup, plus a direct download when one is configured) and Buy for the app's price. Trials start in the app, so there is no trial checkout or trial thanks page. Buying fails closed: Buy shows “Coming soon”, and the download page says the Mac release is coming soon, unless the app's paid product ID is set and its `VITE_<APP>_BREW_CASK` is a well-formed cask. There is no on/off list in code; unsetting the cask variable pulls the app. After a purchase, the thanks page repeats the install command before the open-and-paste steps, for buyers who don't have the app yet. Hertz's page also keeps an install section with the command and the Homebrew line, on the same gate (`VITE_HERTZ_DODO_PAID_PRODUCT_ID` and `VITE_HERTZ_BREW_CASK`).

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

## Hertz

The menu-bar system monitor lives in `apps/hertz` and is plain SwiftPM: `swift build`, `swift test`, `swift run Hertz`, `scripts/bundle.sh`; see [its README](../apps/hertz/README.md). It asks macOS for no permissions. Official builds compile licensing in from `packages/openapps-licensing` (`OPENAPPS_LICENSING=1` with a generated `LicensingConfig.swift`, [LICENSING.md](../LICENSING.md)): the 3-day trial, Settings → License, and the readings off after the trial; a build from source has none of it. Official builds also compile in the shared updater, `packages/openapps-updater` (`OPENAPPS_OFFICIAL=1`): the signed feed at `https://openapps.space/updates/hertz/appcast.xml`, automatic checks on for a fresh install, installing opt-in, `brew upgrade --cask hertz` always works ([RELEASES.md](../RELEASES.md), [its release guide](../apps/hertz/RELEASING.md)). The [product contract](../design/products/hertz.md) records approved behavior.

## macPaper

The notch wallpaper maker lives in `apps/macpaper` and is plain SwiftPM: `swift build`, `swift test`, `scripts/bundle.sh`; see [its README](../apps/macpaper/README.md). It asks macOS for no permissions. It is in development: no catalog entry, website page, release workflow or cask yet, and licensing and the updater are compiled out of every build until the licensing ticket wires the shared packages in (the `#if OPENAPPS_LICENSING` seams are in place). The debug build's `--preview <directory>` renders the notch panel, the popover and Settings to PNGs without a status item, a window or a desktop change: on a shared Mac that is the way to look at the UI, never `open` or `swift run`. The [product contract](../design/products/macpaper.md) records approved behavior.

## Desktop application (in development)

The Mac utility lives in `apps/openklack-desktop` and uses Tauri 2, React, and a native Rust audio engine with a macOS input bridge.
Its marketing pages and browser demo live in `apps/website/src/apps/openklack/`.

```sh
pnpm openklack:dev
pnpm openklack:test
pnpm openklack:build
```

Global keyboard sound requires macOS Input Monitoring permission for OpenKlack.
Open System Settings (in the setup guide and on the home screen's permission notice) asks macOS with `CGRequestListenEventAccess`, opens the Input Monitoring pane, and shows a floating drag-to-grant helper: a small non-activating utility panel (`NSPanel`, floating level, on every Space) at the bottom-right of the screen with System Settings, holding the app icon as an `NSDraggingSource` that vends the bundle's file URL (`NSPasteboardTypeFileURL`, what Finder puts on the pasteboard), for when OpenKlack is missing from the list and has to be dropped into it.
"Not working? Reset" runs `/usr/bin/tccutil reset ListenEvent <bundle id>` directly (no shell, this app only) and asks again, so macOS re-prompts and a fresh entry matching this build appears; the panel closes itself once the permission is granted, from Close or its title bar, when the guide's Keyboard access step is left, and on quit. The guide's step offers "Show the helper again" while it is away.
The native bridge (`src-tauri/native/macos.m`, called from `engine.rs`) reports state to Rust as numbered message kinds, and Rust exposes the panel to the settings window as two commands:

| Message kind | Meaning                                                                                      |
| ------------ | -------------------------------------------------------------------------------------------- |
| 0, 1         | Key down, key up: key code and logical key name                                              |
| 2            | Forget held keys                                                                             |
| 100          | Input Monitoring permission: 1 granted                                                       |
| 101          | Microphone: 0 idle, 1 in use, 2 unknown, 3 detection unavailable                             |
| 102          | Mac resting (sleep, screens off, session inactive): 1 paused                                 |
| 103          | Default output device changed; reopen the audio output                                       |
| 104          | Frontmost app changed (bundle identifier in the text)                                        |
| 105          | Secure input: 1 active                                                                       |
| 106          | Default output route: 1 built-in speakers, 0 anything else                                   |
| 107          | Drag-to-grant helper panel: 1 shown, 0 hidden (closed by the user, or once the permission is granted) |

| Command                    | Effect                                                                                        |
| -------------------------- | --------------------------------------------------------------------------------------------- |
| `request_input_permission` | Asks macOS for Input Monitoring and opens the pane when it is still missing                   |
| `show_permission_helper`   | Shows the floating helper (`ok_show_permission_helper`); nothing once the permission is there, checked again natively right before showing |
| `hide_permission_helper`   | Hides it (`ok_hide_permission_helper`); also run when the permission arrives and on quit      |

The panel's state (`Runtime.permission_helper.visible`, `model.rs`) follows kind 107, is never visible while the permission is granted, and is published in the snapshot as `runtime.permissionHelper`. The settings window orders its shows against its hides (`permissionHelper.ts`): a hide asked while a show is still queued cancels that show and runs after it.
The home screen offers sound selection, starred favorites, one volume slider, and optional per-key customization. Settings contain muted apps, microphone pause, launch at login, appearance, file imports/exports, and local diagnostics. There is no desktop typing test or user-facing preset editor.
Official builds open a short setup guide once, on first launch (`onboardingCompleted` in `settings.json`; Settings → About & help → Show setup guide reopens it), and turn "Open at login" on once, on that first launch (`loginItemDefaulted`), after which the Settings toggle and System Settings → Login Items are the user's; source builds do neither.
App updates follow [RELEASES.md](../RELEASES.md): official builds check a signed feed, download in the background and install on the next quit or restart; "Check for updates automatically" is turned on once, on that same first launch of a fresh install (`autoCheckDefaulted` in `updates.json`), "Download and install automatically" stays off until the user turns it on, and `brew upgrade --cask openklack` always works (see [Releases and updates](#releases-and-updates)).
Builds from source say under Settings → About & help that they don't include app updates.
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

For a local release app without a DMG (the release ships a zip, not a disk image):

```sh
APPLE_SIGNING_IDENTITY='Your signing identity' pnpm --filter @openapps/openklack-desktop tauri build --bundles app
```

### Licensed builds

Licensing follows the shared [licensing contract](../LICENSING.md) and is compiled in only with the `licensing` cargo feature.
The default build from source has no License section, no trial, makes no license or registry network calls, and plays sounds without restriction; `cargo test` covers the shared test cases in `src-tauri/src/licensing/core.rs` and `runtime.rs` in both flavours, against a fake Dodo client, a fake trial registry, an in-memory Keychain and an injectable clock.
A licensed build reads its configuration from the environment at build time and fails with a list of what is missing:

| Variable                         | Value                                                                                                                                           |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `OPENKLACK_LICENSE_ENV`          | `test` for development builds against Dodo test mode, `live` for releases; also the trial registry's `env`                                      |
| `OPENKLACK_DODO_PAID_PRODUCT_ID` | The `OpenKlack` product ID for that environment                                                                                                 |
| `OPENKLACK_BUY_URL`              | The https checkout link opened by Buy for $5                                                                                                    |
| `OPENKLACK_TRIAL_REGISTRY_URL`   | Optional; the trial registry's origin, defaults to `https://openapps.space`. A `test` build may point at a local registry such as `http://127.0.0.1:8787` |
| `OPENKLACK_SUPPORT_URL`          | Optional; Contact support link, defaults to the OpenKlack page                                                                                  |

```sh
OPENKLACK_LICENSE_ENV=test OPENKLACK_DODO_PAID_PRODUCT_ID=pdt_… OPENKLACK_BUY_URL=https://… \
OPENKLACK_TRIAL_REGISTRY_URL=http://127.0.0.1:8787 OPENKLACK_DEBUG_TRIAL_MINUTES=10 \
pnpm --filter @openapps/openklack-desktop tauri dev --features licensing
```

The Dodo product is not created yet, so no real ID exists; the workflow's checks job uses placeholders to compile and test the licensed flavour, and the release job requires `OPENKLACK_DODO_PAID_PRODUCT_ID` and `OPENKLACK_BUY_URL` as variables in the `openklack-release` environment before it builds with `OPENKLACK_LICENSE_ENV=live` (a live build refuses a registry origin that isn't https).
The license and trial records live in the app's record store (`src-tauri/src/licensing/store.rs`): `~/Library/Application Support/OpenApps/openklack/records/license`, `trial` and `cleanups` (the deactivations still owed), directory `0700`, files `0600`, each written atomically (temporary file, `fsync`, rename). Every path under Application Support is walked through directory descriptors without following symlinks: a link, or anything but a regular file or directory, where a record or a store directory should be is unavailable, never absent, and nothing is written through it. A file is `openapps-records-v1`, a 12-byte nonce and AES-256-GCM over the record's JSON with `openklack:<file name>` as additional data, under a key derived by HKDF-SHA256 (info `openapps-records-v1:openklack`) from the Mac's hardware UUID (or `no-hardware-uuid`); nothing about the key is stored, so the files can't be read, edited or moved to another Mac casually. A missing file is positively absent, an unreadable directory or file is unavailable, and a file that fails the magic, the tag or JSON decoding is corrupt; the last two are storage errors that leave the file in place. A write can fail before the rename with the old record intact, or after it when only the directory sync fails: that second outcome is reported as indeterminate, and the service then keeps the new record as the one in effect, grants nothing on its strength, and writes the same record again every tick until a write is confirmed. A removal follows the same rule: the unlink is confirmed by the directory sync, and a retried removal syncs the directory even when the file is already gone, so `Ok` always means the absence is durable. Remove this Mac deletes `license`; nothing deletes `trial`. Nothing lives in the Keychain, and the Keychain items older releases wrote are never read, written or deleted, since a signing identity change would make macOS prompt for them.
Keyboard sounds stay off until the license record has been read; if the license record, the trial record or `pending_cleanups` can't be read, Settings shows a storage error with Try again and the read is retried with backoff — it is never treated as "no license" or "no trial yet", and entries that couldn't be read are never overwritten.

The trial starts on its own at first launch with no license record: a provisional trial record (`started_at`, `last_seen_at`, `registered: false`) is saved to the record store first, and only then do sounds turn on; if that save fails, no trial runs and the save is retried. The app then posts `{app: "openklack", device, env}` to `<registry>/api/trial`, where `device` is the SHA-256 of `openapps-trial-v1:openklack:<IOPlatformUUID>` (or of a random UUID saved in the trial record when the hardware UUID can't be read). It retries with backoff from a minute up to an hour, honouring `Retry-After`, and again on wake or when the registry becomes reachable; the answer's start, converted to local time, replaces the provisional one if it is earlier, and a registered trial never calls again. An unregistered trial stops after 24 hours of elapsed time until the registry answers. Elapsed time is `last_seen_at − started_at`, and the engine keeps one trial clock anchored at the last tick: each observation raises `last_seen_at` exactly once, to `max(anchor + monotonic time since, now)` (`mach_continuous_time`, which counts through sleep), and re-anchors. Access, the window and the deadline thread all use that projected time, so a frozen or rolled-back wall clock doesn't pause the trial. `last_seen_at` is saved at most hourly, when the trial ends and on quit (the quit save gets at most two seconds). If launch or wake finds the clock more than an hour behind `last_seen_at` with no license, sound stays off with "Your Mac's clock is behind" until it is corrected; meanwhile no time counts, nothing about the trial is saved, and a registry answer is held and applied once the clock is right. A license record left by the old trial keys (`kind: "trial"`) or for any product other than the paid one is not a license: the trial rules apply, starting from that record's activation. When the trial ends, the menu bar status says "Free trial ended"; nothing opens on its own. The settings window's header shows the same state as a pill beside the sound button ("Free trial · N days left", "Trial ended", or the menu bar's short reason; nothing while licensed) that opens Settings → License. Remove this Mac returns to the trial record's state and never touches the record.
Debug builds (`tauri dev`, `tauri build --debug`) read `OPENKLACK_DEBUG_TRIAL_MINUTES` to shorten the trial for manual end-to-end runs; release builds ignore it.
The service follows the contract's write order: losing access takes effect in memory first and is then saved (a failed save is retried every tick and shown as a storage error), while gaining or extending access is saved first and takes effect only once that save has landed — playback is on only when both the record in memory and the last saved record grant it. Record reads are single-flight, and a read that started before the record changed is discarded.
A revocation is also noted in a small non-secret journal outside the record store (`license-journal.json` in the app's data directory), keyed by a SHA-256 hash of the activation ID and holding only the record's event sequence after the change (never a clock), written before the record save; on load, an entry whose sequence is ahead of the saved record forces Revoked whatever the record says, while one the record has caught up with is stale and dropped. Journal notes carry that sequence, so a delayed clear can never erase a newer revocation and a queued retry is superseded by a newer note for the same activation. A journal that can't be read is a storage error that keeps sounds off while the saved record is held and checked with Dodo right away; the answer rebuilds the journal (the corrupt file is copied aside first, then replaced atomically) and, if it is `valid: true`, saves the grant and unlocks. Removing or replacing an activation writes the same note as a tombstone, and an entry is cleared only once the revoked, cleared or replaced record has been saved, or on `valid: true` for that activation; a journal write that fails keeps access off in memory, shows a storage error and is retried every tick. It never contains the license key.
Every gate decision carries a revision, and the audio engine ignores older ones, so a delayed unlock can never follow a block; a separate deadline thread that only reads the engine ends trials (at three days, or at the offline limit) and grace on time even while a record write or network call is stuck.
Only a Mac with a license record calls Dodo; daily checks are scheduled on the local clock, a day after the last answer from Dodo or sooner with backoff.
A paid license's time is anchored to Dodo's `Date` header at the last successful check; a clock set back more than an hour before the latest moment seen asks it to check again until Dodo answers.
`openklack://activate?key=…` (registered in `Info.plist`) opens Settings with the key pre-filled; the user confirms before anything is sent. Other parameters are ignored. Source builds only open Settings.

### Releases and updates

Releases follow the shared [release contract](../RELEASES.md): the install script (`curl -fsSL https://openapps.space/install/openklack | sh`) and a Homebrew cask (`brew install --cask openappshq/tap/openklack`), both into `/Applications`, a zip on the GitHub Release `openklack-vX.Y.Z`, a stable self-signed certificate instead of Developer ID and notarization, and a signed update feed at `https://openapps.space/updates/openklack/latest.json`.
The [desktop workflow](../.github/workflows/openklack.yml) runs the checks on every change and, on a pushed `openklack-vX.Y.Z` tag (or a manual run with a version and `publish`), the release: build → sign and verify → package → publish → feed → verify live → cask.
The scripts it runs are the ones you can run locally:

| Script | Does |
| --- | --- |
| `scripts/release/create-signing-certificate.sh <dir>` | One-time: creates the `OpenApps HQ Release` certificate shared by every app, as a `.p12` plus its password (never committed) |
| `scripts/release/designated-requirement.sh <bundle id> <cert.pem>` | Prints the designated requirement to pin (public; committed) |
| `scripts/release/with-signing-keychain.sh <command>` | Runs a command with the certificate in a temporary keychain and removes it afterwards, whatever happens (Bash; re-executes itself under Bash from any other shell; `scripts/release/tests/with-signing-keychain.test.sh` checks bash and zsh) |
| `scripts/release/verify-designated-requirement.sh <App.app> <pinned.txt>` | `codesign --verify --deep --strict`, hardened runtime, and the exact pinned requirement |
| `scripts/release/release-tag-ruleset.sh check\|apply <definition.json>` | Checks for, or creates, the ruleset that makes `openklack-v*` tags immutable |
| `scripts/release/write-install-script.sh <app-id> <App> <version> <sha256> <out-file>` | Writes the pinned install script served at `/install/<app-id>` (never a downgrade or a rewrite); `scripts/release/tests/install-script.test.sh` runs a generated script against a zip on `127.0.0.1` |
| `scripts/release/verify-live-install-script.sh <app-id> <version> <sha256>` | Fetches the live install script and checks its pin, content type, syntax and that it equals the committed file |
| `release/create-update-key.sh <dir>` | One-time: creates the Tauri updater key and pins its public half in `release/updater-public-key.txt` |
| `release/updater-config.mjs <out.json> <version>` | The build's config overlay: version, updater artifacts, the pinned update key and feed |
| `release/build-signed.sh <version>` | Builds the licensed, updater-enabled app signed with the release identity and verifies the pinned requirement (inside `with-signing-keychain.sh`) |
| `release/package.sh <bundle dir> <version> <dist>` | Zip (`ditto -c -k --keepParent`), update archive, update-key signatures, SHA-256 |
| `release/write-feed.sh <version> <dist> <feed dir>` | Writes and signs `latest.json` |
| `release/verify-update-signature.mjs <file> <file.sig>` | Verifies a Tauri updater signature without the app |
| `release/publish-release.sh [--dry-run]` | Publishes the GitHub Release only once the tag provably names the built commit |
| `release/verify-live.sh <version> <sha256>` | Fetches the public zip, feed and signature and checks digest, signature and version |
| `release/test-update-locally.sh` | The whole thing locally with throwaway keys and a feed on `127.0.0.1`, including install-on-quit |
| `packaging/homebrew/bump-cask.sh <cask.rb> <version> <sha256>` | Sets the cask to a published release (the template's `0.0.0` takes any first version; never a downgrade or a rewrite); `packaging/homebrew/Casks/openklack.rb` is the template for the tap |

**Signing.** macOS ties Input Monitoring to the app's designated requirement, so every release is signed with the same self-signed certificate; a different identity would make an update look like a new app and lose the permission. The license and trial records are files the app owns, so they survive an identity change.
The requirement is pinned in `release/designated-requirement.txt` as `identifier "com.openklack.desktop" and certificate leaf = H"<certificate SHA-1>"`, and a release whose signature does not produce exactly that fails before anything is published.
The app is not notarized: the cask and the install script clear the quarantine flag after install, and a zip downloaded by hand needs right-click → Open once.
Both pinned files start as a `NOT GENERATED` marker; until the release owner has generated the material on their own Mac and committed the public halves, the release job stops before building and official builds report that updates aren't configured.

**Setup, once, on the release owner's Mac** (the generators never touch the login keychain; back the output up offline, then delete it locally):

```sh
scripts/release/create-signing-certificate.sh ~/openapps-release            # shared by every app
scripts/release/designated-requirement.sh com.openklack.desktop ~/openapps-release/release-signing.cert.pem \
  > apps/openklack-desktop/release/designated-requirement.txt
apps/openklack-desktop/release/create-update-key.sh ~/openapps-release      # pins release/updater-public-key.txt
scripts/release/release-tag-ruleset.sh apply .github/rulesets/openklack-release-tags.json openappshq/openapps
```

Then create the GitHub environment `openklack-release` (deployment branches and tags restricted to `main` and `openklack-v*`) with:

| Secret | Value |
| --- | --- |
| `RELEASE_SIGNING_P12` | `release-signing.p12.base64` from the certificate folder |
| `RELEASE_SIGNING_P12_PASSWORD` | `release-signing.p12.password` |
| `TAURI_SIGNING_PRIVATE_KEY` | `openklack-update.key` (the Tauri updater private key) |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Its password, if one was set |
| `RULESET_READ_TOKEN` | Fine-grained token, this repository only, Administration: read; lets the publish job see the tag ruleset's bypass actors |
| `FEED_COMMIT_TOKEN` | A token that may push to `main` (a fine-grained token with Contents: write that bypasses `main`'s protection, or a GitHub App token); used only to commit `apps/website/public/updates/openklack/latest.json`, `.sig` and `apps/website/public/install/openklack`, which then deploys the website |
| `HOMEBREW_TAP_DEPLOY_KEY` | Fine-grained token scoped to `openappshq/homebrew-tap` with Contents: write; used only to push the cask bump |

and the licensing variables `OPENKLACK_DODO_PAID_PRODUCT_ID`, `OPENKLACK_BUY_URL` and optional `OPENKLACK_SUPPORT_URL` from [Licensed builds](#licensed-builds).
The old `APPLE_*`, `KEYCHAIN_PASSWORD` and `TAURI_UPDATER_PUBLIC_KEY` entries and the `openklack-latest` channel release are no longer used.
The tap repository `openappshq/homebrew-tap` must exist; the first release copies `packaging/homebrew/Casks/openklack.rb` into it.

**Cutting a release.** Merge to `main`, then `git tag -a openklack-v1.0.0 -m "OpenKlack 1.0.0" && git push origin openklack-v1.0.0`.
The version is stamped from the tag; `tauri.conf.json` and `Cargo.toml` keep the development version.
`release` (read-only token) builds the universal licensed app, signs it inside a temporary keychain that is deleted as soon as the build ends, verifies the pinned requirement, packages `OpenKlack-1.0.0.zip` and `OpenKlack-1.0.0.app.tar.gz` with their update-key signatures, writes the signed feed and uploads everything as a workflow artifact.
`publish` (the only job that can write releases) downloads that exact artifact by id, checks the zip against the digest the release job reported, requires the tag ruleset, requires the tag to name the built commit, creates a draft release, uploads the files, checks the tag again and publishes.
`feed` commits the feed and the regenerated install script to `main` (the website deploy serves both), polls the live feed and zip until they match, checks the live install script, then bumps the cask.
A bad release is pulled by committing the previous feed back, and fixed with a new patch version; tags are never moved or reused.

**Updates in the app.** Only builds with the `updater` cargo feature (official builds) contain the updater; `pnpm openklack:build` and `cargo test` without it never check, download or install anything, and the commands answer "Builds from source don't include app updates."
The feed and its `latest.json.sig` are fetched with plain GETs (no identifiers), the signature is verified in Rust against the pinned key before any field is trusted, the feed must name downloads under `openklack-v<version>/` on the official releases and a newer version, and the update archive is verified again by Tauri's updater and once more before installing.
With "Check for updates automatically" on, the app checks at launch, daily while running and, since the timer catches up after sleep, on wake when the last check is older than a day; a failed check backs off an hour, then a day.
With "Download and install automatically" on, a found update is downloaded, unpacked into a private (0700) hidden folder next to the app and verified there (`codesign --verify --deep --strict`; it must *satisfy* the installed app's designated requirement, evaluated with `codesign -R=`, never compared as text; the expected version; each check bounded to 60 s), the menu bar and Settings show "Update ready — Restart", and it is installed while the app quits or restarts: verified again, exchanged with the installed bundle in one atomic rename (`renamex_np` with `RENAME_SWAP`, so the folder is never without an app), verified once more at its final path, and only then is the old bundle deleted — if that last check fails the exchange is undone, and if even that fails the old bundle is kept in a hidden `.OpenKlack.app.backup` folder next to the app that no cleanup ever deletes, and Settings says where it is; sound playback is never interrupted.
An update that is no longer newer than what is on disk (something else updated the app meanwhile) is refused, and the whole quit-path install is bounded to 90 s before the exchange; the exchange itself is never interrupted.
Turning "Download and install automatically" off discards an update that was staged automatically (a download the user asked for with "Download update" stays); the permission is checked again before staging and before installing.
"Check for updates automatically" is on by default and "Download and install automatically" off, and the default applies to fresh installs only: once the licensing runtime has read the records, a launch with no saved preferences, no trial and no license record (the same test as "Open at login") and no `updates.json` from an earlier install turns automatic checks on and records the decision (`autoCheckDefaulted` in `updates.json` in the app's data folder), and any other launch only records it, so a toggle the user could have set — on an upgrade from a version that defaulted to off, or in Settings while the records were still being read — is never changed (a Settings change carries only the toggle that was flipped and is merged onto what is saved); until the default resolves the app never contacts the feed on its own. A file from before `autoCheckDefaulted` loads as undecided with its values intact, and an older build ignores the field. "Check now" always works.
Updates never depend on the license or trial state.
An app that runs from a read-only location or App Translocation shows "Move OpenKlack to Applications to enable updates" instead.
Debug builds accept `OPENKLACK_DEV_UPDATE_FEED`, `OPENKLACK_DEV_UPDATE_PUBLIC_KEY`, `OPENKLACK_DEV_UPDATE_DOWNLOADS`, `OPENKLACK_DEV_QUIT_WHEN_UPDATE_READY` and `--no-input-listener` for `release/test-update-locally.sh`; release builds don't contain them.

The [current product contract](../design/products/openklack.md) records approved behavior.
The [original desktop plan](../design/archive/desktop-plan.md) preserves the interview and initial architecture proposal.
The [verification record](../design/desktop-verification.md) distinguishes tested behavior from remaining work.

OpenKlack source is MIT licensed.
Third-party recordings retain the separate notices described above.
