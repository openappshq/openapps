# OpenKlack app UI

Choose a sound. Set the volume. Close the window.

OpenKlack has one current setup that saves automatically. “Preset” is an internal compatibility term, not a user-facing feature. The typing test belongs only to the marketing website.

## Home

The top bar holds the OpenKlack mark, sound on/off, and Settings. A pause reason appears only when relevant, with temporary resume for automatic pauses.

The current sound and one volume slider sit above the fixed 3D keyboard. Clicking a key plays it. The renderer sleeps between interactions and unmounts when hidden; native typing audio continues independently of the window.

Below the keyboard, four sound choices provide a starting point. Clicking a sound applies it immediately. The play button previews without changing the active sound. A star pins a sound above the other choices and adds it to the native menu bar. Browse all opens a bounded, searchable list with All, Linear, Tactile, and Clicky tabs. Their sliding indicator follows selection; filters never change the active sound.

Customize a key reveals just Key and Sound selectors, with a reset action. Clicking the 3D model selects a key in this mode. Choose by typing is explicit and cancellable. Done returns to sound choices.

## Settings

| Control | Behavior |
| --- | --- |
| Open at login | Optional native launch setting. |
| Pause when the microphone is in use | On by default; includes calls, dictation, and recording. |
| Muted apps | Pick an installed app to pause while it is in front. Removing an app offers Undo. |
| Appearance | System, Light, or Dark. |
| Sounds & settings files | Import audio, compatible sound packs, or a self-contained settings bundle. Export the current setup with audio and credits. |
| About & help | Keyboard permission, app version and updates, recording credits, and reviewable local diagnostics. |

Settings files apply on import. The previous stored setup is retained internally for compatibility; imports never discard recordings. Existing app-specific sound rules remain functional and are identified as legacy rules in the app list. New rules only mute an app.

No tone, pitch, stereo, release-volume, or variation controls are exposed. Existing desktop values remain compatible. The browser demo restores only sound, volume, and valid stars so old hidden overrides cannot unexpectedly change its sound.

## Menu bar

Mute and volume are always available. Automatic pauses show their cause and a temporary resume action. Starred sounds appear above More sounds; selecting either changes the current sound immediately while preserving volume and key assignments. Open OpenKlack opens the main sound screen.

## Visual system

[Figma: OpenApps HQ · Tactile Studio](https://www.figma.com/design/2fvzpabR06HanNwQIxxtm1/OpenApps-HQ-%C2%B7-Tactile-Studio?node-id=2-94) supplies the brand, palette, and type system. [tokens.json](tokens.json) generates [tokens.css](tokens.css). The older Figma page compositions predate this simplification; this document and current app captures describe the implementation.

React uses HeroUI controls, Motion page transitions, and the shared theme. Native macOS controls handle the menu bar and file dialogs. Respect reduced motion, retain accessible labels and keyboard focus, and keep validation/recovery messages close to their actions.

![Current desktop home](assets/openklack/ui/settings-light.png)

The local prototype keyboard uses adapted reference geometry with OpenKlack materials, legends, and baked lighting. See [provenance](../packages/ui/assets/keyboard/PROVENANCE.md) and [verification](desktop-verification.md).
