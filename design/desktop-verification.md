# Desktop implementation and verification

Updated September 14, 2026.
The desktop goal remains incomplete pending physical-Mac validation and release setup.
Approved behavior is in [the current product contract](products/openklack.md).
The [original desktop plan](archive/desktop-plan.md) is historical.

## Current interface verification — September 14, 2026

This section supersedes the interface descriptions in the chronological records below. See the [separate desktop audit](archive/desktop-interface-review.md) and [current UI specification](products/openklack.md).

- One automatically saved setup, current sound, volume, and a fixed keyboard. No desktop typing test, preset workspace, sound inspector, or tuning panel.
- HeroUI buttons, sliders, switches, search, animated type tabs, Select popovers, and Accordion panels. Native macOS menu and file sheets remain native.
- Four starting sound choices; stars move sounds to the top and into the menu. The complete library is scroll bounded and combines search with All/Linear/Tactile/Clicky filters.
- Native QA: Tactile plus “brown” showed only the two Brown recordings; stars and the Red PBT selection survived relaunch. Appearance dropdown selection, Escape dismissal, file accordion expansion, and key selection with Down/Return passed. Key selection alone did not change its sound.
- The latest development-signed app is installed at `/Applications/OpenKlack.app`; strict signature verification passed. Existing sound, 77% displayed volume, assignments, stars, and Input Monitoring were preserved. Temporary appearance changes were restored to Light.
- Light/dark home captures now replace the old website proposals. The menu illustration is identified as an illustration.
- Website QA: 15-second completion, aligned WPM/accuracy, retry focus, combined sound filters, and responsive controls at 390 × 844 passed. Both measured viewport widths (814 and 390) had zero horizontal overflow. The temporary viewport override was reset.
- Latest checks: `pnpm lint`, `pnpm test` (8 tests), `pnpm build`, desktop frontend build, and Rust tests (14 passed; 1 hardware test ignored in this run). The development-signed `.app` bundle succeeded. An earlier optional DMG packaging attempt failed; a distributable installer and notarization are not verified.
- Native menu contents were inspected through accessibility, including stars, More sounds, and the volume slider. This does not establish physical slider interaction or a visual capture of the tray icon.
- Full VoiceOver, zoom, runtime reduced-motion settings, current hardware sleep/call recovery, battery use, and end-to-end acoustic latency were not retested in this interface pass.
- No commit, push, deployment, or publication was performed. Local application backups are under `/tmp/openklack-before-refactor`.
- Generated debug/release app bundles were unregistered and archived with non-app directory names. Spotlight returned only `/Applications/OpenKlack.app`; the installed bundle was registered again and its strict signature check passed.

## Historical implementation record

The sections below describe earlier stages; their preset/tuning interfaces and check counts are historical.

### Implemented

- Tauri 2, React/HeroUI settings, Rust/Rodio audio, and a small macOS Objective-C bridge.
- Global listen-only input, layout-derived logical keys, modifier handling, repeat suppression, secure-input status, sleep/session observation, microphone activity observation without capture, and output-route recovery.
- Predecoded press/release recordings, variation, overlapping sounds, a 128-voice ceiling that replaces old tails instead of delaying new presses, pack-level gain matching, and explicit preview/apply separation.
- A curated core and searchable 18-pack bundled catalog, presets/favorites, per-key assignments, master/release/per-key volume, app rules, manual mute, and temporary resume.
- Immutable content-addressed pack versions and explicit installation of new bundled versions without rewriting existing presets.
- Compatible Thock ZIP and individual WAV/MP3/OGG/FLAC import, plus self-contained `.openklack` preset export/import with required audio and credits.
- Archive path/symlink/duplicate checks, compressed/expanded size bounds, manifest bounds, decoded audio limits, and verification of installed content hashes.
- Invalid installed manifests no longer prevent library startup.
- A missing or damaged active pack preserves the preset and leaves settings available for repair instead of failing application startup.
- Reimporting an exact damaged version preserves the damaged directory in a recovery folder before replacement.
- Serialized settings updates with revision checks, atomic writes, and unique recovery copies for malformed settings.
- Manual mute can be saved even when the active recording is unavailable; changing mute alone preserves the existing playback state and its recovery warning.
- A version-one settings fixture is checked by Rust serialization/validation and TypeScript compilation, including Unicode logical keys and app-rule targets.
- Native app selection for rules, human-readable app names, and Undo after rule removal.
- Shared Three.js keyboard with raised keys, per-key selection, and radial lighting; shared layout/labels in `packages/keyboard-layout`.
- Choose by typing selects logical keys outside the pictured layout; capture cancels on blur, hidden view, or native input reset.
- Keyboard event forwarding stops when the keyboard view is hidden or unmounted; closing settings destroys the WebView.
- Native menu-bar controls, including an NSSlider for effective-preset volume and labels distinguishing the default preset from an app-rule override.
- Failed native menu-bar saves restore the saved control state and show an error dialog; the dialog interaction remains unverified because the automation surface does not expose the status menu.
- Opt-in launch at login with `--background`, reviewable local diagnostics, and export of the exact reviewed report.
- Manual app-update checks and a separate download/install action using Tauri's signed updater, HTTPS-only clients, bounded downloads, and native update status independent of the settings WebView.
- Builds without a release endpoint remain usable and explicitly disable checking for updates.
- A GitHub workflow for checks/development artifacts and a manual signed/notarized release-candidate job with signed update archives and a static manifest, without automatic publication.

## Verified

| Check | Observed result | Limit |
| --- | --- | --- |
| User physical typing check | User replied “sounds fine” after being asked to type in another app and assess first-key delay | User observation, not an acoustic or numerical latency measurement |
| Input permission | Packaged app reports Input Monitoring available | The agent did not grant the permission |
| Rust checks | Eleven tests pass; one explicit hardware-audio test is ignored in the normal suite; strict Clippy passes | Covers actual decoding of all 793 regions, tracking, pause precedence, import/repair/bundle flows, voice bounds, diagnostic aggregation, the version-one settings contract, updater configuration and size boundaries |
| JavaScript checks | Five tests pass across two files; desktop TypeScript/build and repository lint pass | Includes readable Unicode key labels from the shared native settings fixture; Three.js mutation and localStorage-error reporting have narrowly documented lint exceptions |
| Preview/apply | Earlier packaged-app check previewed Cream without changing Brown; Apply changed and persisted Cream | Explicit preview does not establish global input playback |
| Preset bundle round trip | Native export included two exact pack versions, recordings, and credits; import/rename/activate restored Space assignment and 66% gain | Actual native dialogs and persisted JSON were inspected |
| Compatible Thock import | Imported the reviewed Alps ZIP; installed versions increased from 18 to 19; active Brown preset stayed unchanged | Compatibility is for the reviewed Thock format, not every keyboard-sound format |
| Individual audio import | Imported a WAV through the native dialog; installed versions increased to 20; active preset stayed unchanged | Other supported codecs are handled by the same decoder path but were not each imported through UI |
| Malformed audio | Native WAV import displayed a decoder error, retained 20 installed versions, and preserved the active preset | Invalid archive and corrupted-bundle cases also run through storage integration tests |
| Pack recovery | In a separately identified packaged QA app, damaged active audio produced a recovery warning and preserved the preset; native bundle reimport restored the exact audio hash, retained damaged bytes in a recovery directory, and cleared the warning | Used isolated QA data with no Input Monitoring grant; does not validate global playback |
| Mute during recovery | Reproduced a failed mute while audio was damaged, fixed the shared save path, then verified mute persisted and remained enabled after successful repair | Other settings changes still require valid prepared playback |
| Malformed settings recovery | Isolated packaged app reopened with defaults and an explicit recovery notice; the malformed bytes were preserved exactly in a unique recovery file | This is a local corruption test, not an app-update rollback test |
| App picker and rules | Native picker returned an app identity; rule saved; removing and undoing restored the exact rule | Latest app-name picker and live rule activation still need interaction checks |
| Login setting | UI enables/disables a LaunchAgent; its arguments point to the bundled executable with `--background`; restored to off afterward | An actual logout/login was not performed |
| Diagnostics export | Prepared report in General, saved through a native sheet, read back matching JSON | Report excludes key identities, text, app identities, and paths; no transmission occurs |
| Settings appearance | Inspected packaged WKWebView at 1080 × 760 and approximately 767 × 607; fixed concatenated switch labels and file dialogs lacking a parent window | Full VoiceOver, zoom, and runtime reduced-motion checks remain |
| Keyboard navigation | Clicked A, pressed Right, and observed selected/focused S plus assignment selector S; final packaged selection-mode button enters/cancels with matching accessible state | Actual physical-key selection and blur cancellation remain unverified |
| Settings lifecycle | Command-W closed settings while native process stayed running; reopening reset transient selection to Space and restored the saved preset | A real login session has not been tested |
| Local packaging | Optimized release and debug app bundles build and are development-signed; strict bundle-signature verification passes for both | Development signing is not Developer ID notarization |
| Disk image and relocation | Earlier 10,524,175-byte DMG passed `hdiutil verify`; image and contained app signatures passed; copied app launched from a separate directory with the image ejected and accepted native preview | Uses existing local app data and development signing; not a clean-Mac Gatekeeper or notarization test |
| Final updater build | Updated 11,704,287-byte DMG passed `hdiutil verify`; strict app and image signatures passed; packaged app reopened with Brown PBT, Space override, and 52% volume intact | Development-signed only; the final binary includes the refined updater error handling |
| Website | Production build and existing tests passed after shared layout extraction | No website deployment was requested or performed |
| Release scripts | Parsed workflow YAML and executed its exact configuration/manifest scripts with isolated local files; valid output and missing-key, HTTP, oversized-archive rejection passed | No signing key, published endpoint, remote CI run, or update installation was involved |
| Update failure recovery | Isolated packaged QA build checked a deliberately unreachable HTTPS endpoint, displayed a recoverable error, and retained that result after closing and reopening settings | Checks the real native command and WebView lifecycle; no valid release, signature, download, or installation was exercised |
| Unconfigured updates | Final release's General panel shows its native 0.1.0 version, explains that no update service is included, and disables Check for updates | No official destination or signing key has been configured for this local build |

The exported diagnostic snapshot in this pass contains zero native input events, including after automation-generated key presses.
It therefore cannot substantiate an event-to-audio latency distribution.
The user's positive physical-typing report is recorded separately rather than converted into invented measurements.

Earlier hardware audio tests at 48 kHz observed first nonzero output callbacks at 6.851/5.006 ms initially and 4.670/0.214 ms after 30 seconds idle.
Those tests submit a predecoded sample directly to the actual device callback.
They do not measure acoustic output or the live global keyboard hook.

Earlier closed-window development-process observation showed about 110 MB RSS and 0.0% CPU in one snapshot.
A later open-window native-process snapshot showed about 90 MB RSS and 0.0% CPU.
Neither is an energy benchmark or an accounting of all WebView processes.

An optimized release with settings closed was then sampled four times over approximately 31 seconds using `top`.
The native process used approximately 51 MB memory; after the initial 0.0% reading, three CPU samples each reported 0.2%.
This is a short local baseline amid other machine activity, not a controlled battery test or a count of all WebView processes.
After updater integration, the final optimized build was sampled again with settings closed over 30 seconds.
The native process reported 42–50 MB memory and three successive 0.2% CPU samples after the initial reading.
The same measurement limits apply; settings were reopened afterward with the saved preset intact.
The scoped interface review is in [desktop-interface-review.md](archive/desktop-interface-review.md).

## Still required before public release

- Capture and validate live native input diagnostics, including first keystrokes after long idle, chords/modifiers, held repeats, and ANSI/ISO/non-US layouts.
- Verify sleep/wake, lock/unlock, permission revocation/regrant, microphone transitions, and output changes including AirPods on supported hardware.
- Measure an optimized release with settings open/closed and establish CPU, wakeup, memory, and acoustic-latency budgets.
- Verify native tray slider and live app-rule interactions, complete keyboard-only operation, VoiceOver, and reduced motion.
- Complete the native visual pass of the original shared 3D keyboard after unlocking the Mac.
- Configure the official update destination for openappshq/openapps with its updater signing key, then verify explicit update installation and rollback behavior.
- Run the GitHub workflow in the actual repository; it has been authored locally but not executed remotely.
- Supply Developer ID signing/notarization credentials and verify download, installation, launch, and updates on the supported Macs.

The user selected https://github.com/openappshq/openapps on September 14; it is configured as the origin remote.
Only an Apple Development signing identity was available locally; no signing identity or credential is hardcoded into repository configuration.
Developer ID Application signing and notarization setup are still required for public Mac distribution.

## Completion audit

| Requirement | Current evidence | Status |
| --- | --- | --- |
| Mac-first React settings with native input/audio in one repository | Workspace configuration, native bridge, native audio engine, successful packaged builds | Implemented |
| Global physical key movement, logical assignments, responsive first stroke | User reports acceptable sound; tracker tests pass; direct device-callback test passes; live native counters remain zero in inspected reports | Physical-input and cross-layout validation required |
| Distinct sound library, configuration, pinned versions, portable imports/exports | 18 bundled packs, 793 decoded regions, packaged import/export/repair checks, shared version-one settings fixture | Core flows verified; perceived-loudness listening comparison remains a release check |
| Low background overhead | Final closed-window release baseline of 42–50 MB and three 0.2% CPU samples over 30 seconds | Controlled power and acoustic latency budgets remain unverified |
| Automatic pause and output recovery | Native observation code and pause-precedence tests; visible status and temporary resume controls | Real microphone, sleep, lock, permission, and AirPods transitions required |
| Everyday native menu and accessible settings | Settings navigation, arrows, small window, and error/recovery flows inspected; native slider and save-error dialog implemented | Native menu, full VoiceOver, and reduced-motion interaction checks required |
| Preserve settings and recover from damaged data | Isolated packaged corruption/repair exercises, exact hashes/recovery copies, manual mute preservation, login-item configuration | Verified paths above; actual login session remains untested |
| Private, offline, free/open-source utility | Local diagnostics export, bundled resources, MIT source license and separate recording credits; no accounts or automatic telemetry implemented | Implemented; no automatic data transmission introduced |
| Installable Mac artifact | Development-signed app and DMG, image checksum/signatures, detached-image relocation launch, preview and saved settings restored | Local package verified; public signing/notarization required |
| Official updates and public release pipeline | Native signed-updater integration and CI artifact/manifest steps implemented; configuration/size checks pass; GitHub repository selected; Developer ID release setup pending | Live update installation and release verification need repository/signing setup |

The remaining evidence cannot be replaced by more simulated key presses, repeated builds, or local signature checks.
The pending physical-key question asks whether Choose by typing selects A and whether General's report counts the press.
The repository choice is resolved; Developer ID availability remains a release setup question.

## Isolated recovery exercise

The recovery build used a temporary Tauri merge configuration with `productName: "OpenKlack QA"` and `identifier: "com.openklack.desktop.qa"`.
Its app data was separate from `com.openklack.desktop`; the user's settings were not restored from a backup or used as corruption-test data.
The native UI exported a known-good preset bundle before the QA audio was intentionally damaged on disk.
Reopening, muting, and importing that original bundle exercised the packaged startup, error display, settings persistence, archive validation, repair, and engine reload paths together.
The QA app was quit after testing and no Input Monitoring permission or login item was enabled for it.
The source fixture lives at `apps/openklack-desktop/fixtures/preferences-v1.json` and is consumed by both the Rust and TypeScript checks.

## Reproduction

```sh
vp install
pnpm openklack:dev
pnpm --filter @openapps/openklack-desktop web:build
pnpm test
pnpm openklack:test
cargo clippy --manifest-path apps/openklack-desktop/src-tauri/Cargo.toml --all-targets -- -D warnings
APPLE_SIGNING_IDENTITY='Your signing identity' pnpm --filter @openapps/openklack-desktop tauri build --debug --bundles app
```

The opt-in hardware audio test plays a quiet sample and waits 30 seconds:

```sh
cargo test --manifest-path apps/openklack-desktop/src-tauri/Cargo.toml native_output_starts_after_idle -- --ignored --nocapture
```

Bundles are under `apps/openklack-desktop/src-tauri/target/{debug,release}/bundle/macos/OpenKlack.app`.
Build output is ignored by Git.
App data is under `~/Library/Application Support/com.openklack.desktop/`.
The test imports are local artifacts; the user's subsequently chosen Brown PBT preset and 52% volume were preserved.

## Brand and workspace pass, September 14

The marketing site now lives in `apps/website`, alongside `apps/openklack-desktop`.
Both consume `packages/soundpacks`; their logical-key data remains in `packages/keyboard-layout`.
The exact Figma logo exports, light/dark tokens, UI previews, and branded README cover are preserved in `design/assets` and `design/tokens.json`.
The initial branding pass documented the target desktop UI in a document now maintained as [the product contract](products/openklack.md).
The later desktop settings redesign below records its implementation.

Motion now supplies website disclosures, theme-preview fades, button feedback, and entry transitions, plus desktop navigation, card, favorite, and inline-form transitions.
Both apps use the shared `packages/ui` reduced-motion policy and Figma timing scale.
The macOS tray uses a 36-pixel native Figma PNG export as an 18-point monochrome template, replacing the keyboard text glyph.
The local optimized app was rebuilt with the existing Apple Development identity and its bundle signature verified.
The running native app reopened with its saved preset, volume, and Space assignment intact; settings-page navigation was exercised without applying another preset.
The automation surface did not expose the status item's pixels, so light/dark menu-bar appearance is not recorded as visually verified.

The website was inspected at desktop and 390-pixel phone widths.
Preview/apply separation, per-key application, real browser key events, search recovery, playback settings, theme preview, and animated FAQ controls were exercised.
No horizontal overflow or missing images were found in the phone check.
Repository lint and both frontend builds pass; five JavaScript tests and eleven native tests pass, with the opt-in hardware audio test still excluded.
Sound copies, logo bytes, PNG checksums, and local documentation links were checked.
The Three.js bundle still produces the existing large-chunk warning and dependency deprecation warnings; these are not presented as performance measurements.

## Desktop settings redesign

The desktop settings UI has been rebuilt from the Tactile Studio reference after the first branding pass only added motion.
The new implementation uses the exported K mark, shared semantic colors, Bricolage Grotesque, Instrument Sans, and IBM Plex Mono.
Navigation separates Sound library, My presets, Key assignments, Rules, and Settings.
Sound selection, preview, and applying remain independent; the library now has a dedicated inspector and persistent local favorites.
System, Light, and Dark appearance are stored locally without modifying sound presets.
The native audio engine, app rules, pack versions, and saved key assignments use their existing storage and APIs.

The rebuilt native window was inspected in light and dark modes across Library, Presets, Key assignments, Rules, and Settings.
Previewing NovelKeys Cream left the active Brown PBT preset and Space override intact.
The saved Portable QA preset retained its exact stored volume; the interface rounds only the displayed percentage.
Search-field and macOS select styling were corrected after native visual inspection.
The standard test suite and type-aware lint passed; the development-signed release bundle built successfully.

## Installed application and icon

The application is installed at `/Applications/OpenKlack.app`, with the new blue app icon generated from the Figma export.
Its signature and icon bytes were verified after installation, and the running process uses the installed path.
The debug, QA, and temporary installation-check bundles were archived under the ignored `target/app-backups/2026-09-14` directory.
Obsolete build, installer-volume, and temporary app registrations were removed.
Spotlight now returns only `/Applications/OpenKlack.app` for OpenKlack application bundles.
The installed application retains the saved presets, per-key assignments, and Input Monitoring permission.

## Local refactor review, September 14

The website retains its original contrasting Tactile Studio marketing design, with the new typing playground below the hero.
Sound selection and per-key editing are separate interactions.
Both frontends use the same reference geometry and fixed camera framing. The new OpenKlack material/lighting scene bakes ivory keycaps, gray modifiers, cobalt accents, and a graphite case into base/RGB textures.
Shared tuning controls expose tone, pitch, stereo placement, release level, and recorded variations.
The browser now decodes and mixes through Web Audio; native shaping uses Rodio and biquad.
The native listener, repeat suppression, pause precedence, output recovery, and pack storage stay independent of React.

The JavaScript suite has nine passing checks, including score calculation, recording-level matching, input/render notifications, and tuning persistence.
The native suite has thirteen passing checks, with the hardware test separately passing.
The direct device test at 48 kHz observed 5.242 ms to the first nonzero callback initially and 0.307 ms after 30 seconds idle.
These measurements exclude the global input hook, acoustic output, and Bluetooth latency.
They are not a battery or end-to-end latency benchmark.

Chrome was visually checked at its desktop viewport and at 390 × 844.
Typing, 15-second completion, pack preview, tuning, persistent text, and stable Space selection were exercised.
The mobile page measured 390 px wide with no horizontal overflow.
Three.js reports an upstream Clock deprecation through React Three Fiber; no application errors were captured in that browser pass.

A development-signed local build was installed at `/Applications/OpenKlack.app` with the existing identity and preserved settings.
The prior app and settings were backed up under `/tmp/openklack-before-refactor`.
The installed native window was subsequently raised and visually inspected; the reference model and RGB pulses loaded successfully with the packaged CSP. The final light-colorway installation check is recorded below when complete.
No commit, push, deployment, or publication was performed for this refactor.
