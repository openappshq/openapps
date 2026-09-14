# Development and release guide

A free, open-source keyboard sound utility for Mac, with an interactive marketing website and 18 recorded switch packs.

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

React + TypeScript, HeroUI v3, Three.js / React Three Fiber, Drei, maath, and Howler. Vite+ handles development, bundling, formatting, linting, and Vitest. Tailwind supplies HeroUI's styles; the page theme is in `apps/website/src/styles.css`.

## Repository layout

```text
apps/
  website/          Marketing page and interactive browser playground
  desktop/          Mac utility, React settings, and native input/audio
packages/
  keyboard-layout/  Shared logical-key labels and keyboard geometry
  soundpacks/       Shared recorded catalog, audio, and credits
design/
  assets/           Exact Figma logo and interface exports
  tokens.json       Figma palette, semantic modes, metrics, and typography
  tokens.css        Generated CSS token bindings
```

The pnpm workspace and Vite+ scripts cover the two apps without another task runner.
Run `pnpm dev` for the website or `pnpm desktop` for the native utility.
The website builds to root `dist/` for the existing static hosting configuration; the desktop frontend builds to its own directory.
The website copies shared audio and brand assets into ignored public directories before dev and build, keeping one source of truth.
Run `pnpm theme` after updating the Figma token export; do not edit generated `design/tokens.css` directly.
The [design index](../design/README.md) links the Figma system, exported logos, and [complete desktop UI specification](../design/openklack-app-ui.md).

## Behavior

- Type or click/drag across the 3D keyboard. Each key has damped travel and a local RGB pulse.
- Enable sound or choose a pack. Sound requires a user gesture and works while the interactive keyboard is focused.
- Search and filter 18 packs: Cherry MX Black/Blue/Brown/Red in ABS and PBT, Alps, Holy Panda, Alpaca, Gateron, Box Navy, Cream, Topre, and Buckling Spring. Preview buttons do not change assignments.
- Select and preview a pack, then explicitly Apply it to the whole keyboard or an individual key, with master, per-key, and release volume. Sample variation uses each pack's supplied alternatives.
- Finish, playback settings, and assignments persist in localStorage. Older Deep/Crisp/Clicky preferences migrate to recorded packs. Sound starts off on every visit.
- Reduced motion removes RGB animation and makes key movement immediate. Browser shortcuts and form controls keep their normal behavior.
- The accessible key selector and preview button offer an alternative to selecting keys on the canvas.

## Sound library

The MIT-declared recordings come from [Thock soundpacks](https://github.com/kamillobinski/thock-soundpacks), originally Mechvibes and kbsim. Full notices ship in `packages/soundpacks/sounds/NOTICE.txt`; source revisions, original IDs, and licenses are retained in `packages/soundpacks/catalog.json`. The [research](../design/thock-sound-architecture.md) records the source format and provenance.

Each pack has OGG and MP3 audio sprites. Howler loads packs on demand and overlaps voices; mappings preserve per-key samples, alternate samples, and genuine press/release pairs. Packs without release recordings remain silent on key-up. The 793 source clips occupy about 7 MB across both formats. OpenKlack applies no pitch/EQ presets; some source alternatives were pitch-adjusted by kbsim.

To regenerate from the reviewed checkout (requires Python 3 and ffmpeg):

```sh
git clone https://github.com/kamillobinski/thock-soundpacks.git /tmp/thock-soundpacks
git -C /tmp/thock-soundpacks checkout 213e1443c5005a99d5e51b46e31e17f30e4d752a
python3 scripts/import-soundpacks.py /tmp/thock-soundpacks
```

## Keyboard reference assets

The supplied HAR's Raycast model and texture atlases are included with [provenance](../apps/website/public/keyboard/PROVENANCE.md). They retain the reference's key legends. Chalk and Sage recolor the base atlas. The earlier Raycast audio has been replaced by the recorded switch library above.

The original reference analysis is in [design/raycast-implementation.md](../design/raycast-implementation.md). Scene calibration is centralized in `apps/website/src/KeyboardScene.tsx`.

The browser demo neither records typed text nor intercepts typing outside its page.
System-wide sound is implemented in the development desktop application below; public release verification is still pending.

## Desktop application (in development)

The Mac utility lives in `apps/desktop` and uses Tauri 2, React, and a native Rust audio engine with a macOS input bridge.
The website above remains its browser demo.

```sh
pnpm desktop
pnpm desktop:test
pnpm desktop:build
```

Global keyboard sound requires macOS Input Monitoring permission for OpenKlack.
Settings include a curated/searchable library, per-key sounds, presets, favorites, app rules, microphone pause, optional launch at login, and reviewable local diagnostics.
App updates are checked manually and require a separate download-and-install action.
Builds without a configured release service explain that in General settings.
The native engine plays predecoded audio independently of the settings window.
Closing settings destroys its WebView; typing sound continues in the menu bar.

Import reviewed Thock-format ZIPs, individual WAV/MP3/OGG/FLAC recordings, or self-contained `.openklack` presets.
Individual recordings are limited to five seconds; archives are limited to 128 MB expanded, 4,096 entries, and 1 MB manifests.
Installed versions are content-addressed and presets stay pinned until the user applies another version.
Preset export includes the required recordings and credits.
Corrupt pack files are preserved during repair, and malformed settings receive a recovery copy.

The desktop keyboard uses original CSS perspective and raised keycaps with transient RGB feedback.
It does not include the Raycast reference model used by the browser demo.
The shared keyboard layout and labels live in `packages/keyboard-layout`.

For a locally signed development bundle, use an identity already installed in your keychain:

```sh
APPLE_SIGNING_IDENTITY='Your signing identity' pnpm --filter @openklack/desktop tauri build --debug --bundles app
codesign --verify --deep --strict apps/desktop/src-tauri/target/debug/bundle/macos/OpenKlack.app
```

Regenerate the packaged macOS icon from the exact Figma export after changing the brand asset:

```sh
pnpm desktop:icons
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
CI=true APPLE_SIGNING_IDENTITY='Your signing identity' pnpm --filter @openklack/desktop tauri build --bundles app,dmg
```

Tauri's `CI=true` bundling mode skips Finder decoration while retaining the app and Applications link in the disk image.
The `--ci` CLI flag alone does not select that behavior; the bundler checks the environment variable.
See the [Tauri DMG bundler](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-bundler/src/bundle/macos/dmg/mod.rs).

Public distribution requires Developer ID signing and notarization.
The [desktop workflow](../.github/workflows/desktop.yml) runs checks on an Apple Silicon Mac runner and can produce a signed release candidate through manual dispatch.
It does not publish a GitHub release or deploy the website.
Configure the `desktop-release` environment with `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD` (an app-specific password), and `APPLE_TEAM_ID` before running the notarization job.
Use [Tauri's signing instructions](https://v2.tauri.app/distribute/sign/macos/) for the certificate and notarization setup.
The workflow uses GitHub's documented [macOS ARM64 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

The same environment needs the `TAURI_UPDATER_PUBLIC_KEY` variable and `TAURI_SIGNING_PRIVATE_KEY` secret, plus `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` if the key is encrypted.
Use a matching key pair generated with the [Tauri updater signing instructions](https://v2.tauri.app/plugin/updater/#signing-updates); these keys are separate from the Apple signing certificate.
Keep the private key outside the repository and retain it for future releases.
The workflow embeds its own GitHub repository's HTTPS release endpoint and produces the DMG, signed `.app.tar.gz`, `.sig`, and `latest.json` as candidate artifacts.
After verification, publish those exact files together on a stable GitHub release tagged `v<app-version>`; the manifest points to that tag and its archive filename.
Publishing is a separate action and has not been performed from this checkout.
The app verifies update signatures before installation, permits HTTPS only, and limits archives to 128 MiB.
Test an actual upgrade on a separate Mac before offering the release to installed users.

The [desktop plan](../design/desktop-plan.md) records the agreed product scope.
The [verification record](../design/desktop-verification.md) distinguishes tested behavior from remaining work.

OpenKlack source is MIT licensed.
Third-party recordings and reference assets retain the separate notices described above.
