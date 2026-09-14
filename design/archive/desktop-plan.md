# OpenKlack desktop plan

> Historical proposal: preset UI and the repository layout below are superseded.
> Use the [current product contract](../products/openklack.md) and [development guide](../../docs/development.md).

Interview completed September 13, 2026.
This document records the user's decisions and the recommended implementation.
The repository now contains the website/demo and the desktop application in development.
See [desktop verification](../desktop-verification.md) for implementation status and observed results.

## Product commitment

OpenKlack is a free, open-source Mac menu-bar utility that makes everyday typing sound satisfying. It should usually be forgotten after setup. Sound must respond promptly, including the first keystroke after idle, without an expensive background interface. The website remains the marketing site and interactive demo.

The user chose Mac quality over immediate platform coverage, React for the main interface with native modules welcome, and a single GitHub repository. Mobile is deferred. Its original goal - adding sound to the existing keyboard inside other apps - must not quietly become a replacement-keyboard product.

## Recommended stack

| Responsibility | Recommendation | Reason |
| --- | --- | --- |
| Desktop shell | Tauri 2 | React settings plus a native process that owns input, audio, app state, and the tray. |
| Settings interface | Existing React, TypeScript, Vite+, HeroUI, and Three.js stack | Reuse working components selectively; design the desktop flows for occasional adjustments. |
| Mac integration | Rust with maintained macOS bindings | Keep global input and system observation outside JavaScript. Add a small Swift/Objective-C bridge only where a specific native API requires it. |
| Audio | Start with Rodio, backed by CPAL | Use existing decoding/playback libraries; validate latency, overlap, routing, and power before committing to the implementation. |
| Repository | pnpm workspaces and existing Vite+ tasks | Vite+ already supports workspace orchestration and caching. Do not add a second task runner without a concrete need. |
| Local persistence | Versioned files in the app's support directory, written atomically | Settings, presets, installed-pack metadata, and separate audio files do not initially require a database or service. |
| Distribution | Signed, notarized website download; GitHub Actions release jobs | The Mac App Store is not a launch requirement. Signing credentials are a release prerequisite, not a prerequisite for the native experiment. |

Tauri separates the native core from system-WebView UI processes. This makes the proposed separation possible; it does not guarantee low power or low latency. Its global-shortcut facility is not an every-keystroke listener. Global input needs dedicated native integration. [Tauri process model](https://v2.tauri.app/concept/process-model/), [tray support](https://v2.tauri.app/learn/system-tray/), [macOS signing](https://v2.tauri.app/distribute/sign/macos/).

Rodio uses CPAL for audio output and supports existing decoder backends. Predecoded short samples and overlapping playback are the starting design, not a performance claim. If measurements identify a library limitation, evaluate direct CPAL or a focused Mac audio implementation before replacing more of the stack. [Rodio](https://github.com/RustAudio/rodio).

Vite+ can run tasks across pnpm workspaces and cache task results. Cargo remains responsible for Rust builds; signing and publishing are explicit release operations. Turborepo is a valid alternative if a demonstrated workflow needs it, not an additional layer required to have a monorepo. [Vite+ monorepos](https://viteplus.dev/guide/monorepo), [task runner](https://viteplus.dev/guide/run).

## Native sound path

```text
macOS input event
  → normalize key identity and suppress held-key repeats
  → resolve mute/pause, preset, and key assignment
  → play an already decoded sample through native audio

React settings ↔ configuration and status messages ↔ native core
Visible keyboard ← transient key animation events ← native core
```

The per-keystroke sound path must not depend on React, a WebView round trip, filesystem reads, downloads, or decoding. The event callback must return promptly; audio rendering must not wait for UI work. Configuration changes prepare a replacement playback state before activating it. If loading fails, preserve the working preset and explain the failure.

Load the samples needed by active assignments. App rules that promise an immediate preset change must prepare their target audio before activation. Bound memory use and cache eviction deliberately instead of decoding the entire downloadable catalog. Closing settings should release its 3D resources; the native utility remains available. Do not forward a continuous stream of key events to a hidden interface or keep an event history.

The user wants physical press/release behavior: modifiers sound, held-key repeats do not. Use actual release recordings when supplied; an explicitly empty release mapping means silence. Clear held-key state after interruptions and do not replay stale input after recovery.

Keeping the output ready can compete with idle power savings. Measure that tradeoff on hardware. Do not stop the stream on an arbitrary timer if it loses or delays the next stroke. Output changes and sleep/wake must rebuild invalid audio state without requiring the user to reopen settings.

## Settings and sound library

These are confirmed product choices:

- A curated set of clearly different sounds, backed by a larger searchable enthusiast catalog. Breadth should come from recordings with different character, not only more effect sliders.
- A preset restores the pack, per-key assignments, and volume settings. App rules live separately.
- Preview plays a short comparison sequence without changing the active preset. Applying a selection is a distinct action. Use the same native playback engine for desktop previews and typing.
- Match perceived loudness across packs while preserving their character. Store playback gain metadata rather than destructively rewriting recordings; short transients need listening checks as well as measurements.
- Import compatible sound packs and individual audio files. Defer recording and a waveform editor. Start compatibility with the reviewed Thock format and OpenKlack bundles; do not advertise universal pack compatibility.
- Export self-contained preset bundles containing their required audio and credits. Official catalog entries must have reviewed redistribution terms; imported items retain their supplied provenance and any export restrictions must be surfaced.
- Pin installed pack versions. Discovering an upstream update must not silently change an existing preset.
- One setup across keyboards; assignments follow logical keys rather than being stored per device.
- No account, cloud sync, paid build, or automatic telemetry. Donations are optional. Diagnostics are local and reviewable before the user attaches them to an issue.

Reuse the reviewed recordings and import knowledge in [the existing sound research](thock-sound-architecture.md). The website's compressed audio sprites are a delivery format, not a requirement for the native engine. Retain source/version information, full required notices, real down/up mappings, and explicit silence.

The existing browser mappings use `KeyboardEvent.code`, which represents physical positions. They must not be treated as a finished cross-layout logical-key contract. Define semantic special keys and layout-aware character-key identities, and test ANSI/ISO and non-US layouts. Translate key identity transiently; never record typed strings. Secure input and permission restrictions must be respected.

An exported bundle should record its schema version, exact pack versions, required assets, mappings, gains, and credits. Validate schemas, file references, archive paths, decoded size/duration, and supported audio formats before installation. Reject malformed imports without overwriting working data. A shared schema and cross-language fixtures should keep TypeScript and Rust aligned without a generic plugin framework.

## Everyday interface and defaults

The menu-bar entry exposes mute, volume, current preset, a few favorites, and the reason for an automatic pause. Use a small native surface where possible. A stock tray menu is not automatically a rich popover with a volume slider; prove that interaction before choosing the final presentation.

Settings contain the original OpenKlack 3D keyboard, sound browsing, per-key assignments, presets, and automation. Render the keyboard only while visible and preserve a non-canvas way to configure keys. The existing Raycast model and atlases are reference assets with no supplied redistribution permission; create original assets or obtain permission before product distribution. [Current provenance](../../packages/openklack-ui/assets/keyboard/PROVENANCE.md).

| Situation | Recommended default |
| --- | --- |
| User manually mutes | Remain muted until the user resumes; automation never turns sound back on. |
| Mac locks or sleeps | Pause; restore the user's prior intent once the session and input/audio are ready. |
| Microphone is in use | Pause by default only after a reliable public activity signal is demonstrated. Show “Microphone in use,” not an inferred call label. |
| Activity signal is temporarily uncertain | Prefer silence, show the reason, and offer temporary resume. Do not mistake a permanently unsupported detector for an active microphone. |
| Headphones disconnect | Follow the Mac's active output and continue playing, as explicitly requested. |
| Foreground app changes | Keep the global preset unless the user configured a rule for that app. |
| Screen sharing or a game is suspected | No broad heuristic by default; app identity alone does not establish either activity. |

Automation may inspect only app identity and basic system state. Never inspect window titles, URLs, screen contents, or document text. Routine pauses should not produce repeated notifications. A temporary resume bypasses the current optional automatic pause, not a manual mute, a locked session, or unavailable input/audio. Clearly show when it is active and end it when that pause condition clears.

Use app activation notifications for app rules. A Core Audio device activity property exists, but that alone does not establish reliable microphone-use detection across devices and target OS versions. Validate it without opening or recording a microphone; if unavailable, expose the limitation and retain manual/app-based controls. [App activation](https://developer.apple.com/documentation/AppKit/NSWorkspace/didActivateApplicationNotification), [Core Audio activity property](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertydeviceisrunningsomewhere).

Additional recommended defaults, delegated by the user: explain input permission during onboarding, let users explicitly enable launch at login, keep the installed core library usable offline, and require an explicit action to install app updates. Permission revocation must leave a recoverable status rather than a silently broken utility. Diagnostics exclude typed text, key-event histories, and window contents.

## Repository shape

```text
apps/
  web/                    # Existing marketing site and browser demo
  desktop/                # React settings and src-tauri native application
packages/
  soundpacks/             # Reviewed assets, catalog, and import tooling
  contracts/              # Versioned pack/preset schemas and compatibility fixtures
  keyboard-view/          # Original keyboard view, once both apps consume it
```

This is a destination, not a request to scaffold everything at once. Move existing code as it becomes shared. Keep platform behavior in the native app; do not create an abstract platform framework before a second implementation exists. Share data contracts, recordings, and useful React DOM components. Browser Howler playback and native desktop playback have different lifecycles.

Future Windows/Linux support requires separate input, permission, tray, and lifecycle validation. An app shell compiling on an OS is not evidence that global typing sound works there. Future mobile can reuse recordings and portable settings; it will require a separate feasibility decision and native integration. Expo supports native extensions to React Native apps, but does not remove OS restrictions. Apple's supported custom-keyboard route replaces the keyboard, which is why mobile is deferred. [Expo native customization](https://docs.expo.dev/workflow/customizing/), [Apple custom keyboards](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard).

## Build order and release gate

Recommended launch support is macOS 14+ on Apple Silicon. Add Intel only with real hardware validation. This is a support policy recommendation, not a claim about the minimum OS accepted by the chosen libraries. A maintainer must own native lifecycle/permission behavior and release signing; React reuse does not eliminate that work.

1. **Prove the native utility with one reviewed pack.** Global down/up/modifier events, repeat suppression, overlapping audio, mute, permission status, and a minimal tray control. No polished settings work yet.
2. **Measure the failure cases that would invalidate the product.** First stroke after long idle; fast typing and chords; sleep/wake; output changes including AirPods; permission loss and input restrictions; microphone activity without capture. Compare settings closed/open and app running/quit for CPU, memory, wakeups, and energy impact.
3. **Finish the sound model and everyday controls.** Versioned packs/presets, per-key assignments, native comparison preview, normalization, imports/export, and the verified automation defaults.
4. **Build the finished React settings and original keyboard.** Keep the web marketing experience separate, reuse proven components, and verify keyboard access, reduced motion, and resource release on close.
5. **Validate the installed release.** Signing, notarization, permissions, launch behavior, updates, offline use, and recovery on supported hardware. Development-server behavior is insufficient evidence for these paths.

Measure event-to-audio scheduling and actual acoustic output separately; Bluetooth output latency must not be confused with time spent in OpenKlack. Establish concrete release budgets from the native baseline before polishing the UI. Do not promise an invented millisecond or RAM figure. Any stream-idle optimization must preserve the first key, and a visually successful demo does not pass the release gate if native reliability or background power is poor.

Open technical questions belong in the experiment: microphone signal reliability, output-stream power versus readiness, correct cross-layout key mapping, and the smallest satisfactory menu-bar volume control. These need evidence, not another preference interview.
