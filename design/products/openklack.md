# OpenKlack

One autosaved setup: choose a sound, set volume, close the window.
Figma's preset navigation, inspector, Apply action, and 2D keyboard are superseded.
“Preset” remains an internal compatibility term only.

## Sound selection: desktop and website

Keep the sound list beside the keyboard on wide layouts and stack it on narrow screens.
Start with four choices; Browse all opens bounded search with All/Linear/Tactile/Clicky tabs and a sliding indicator.
A row applies immediately; Play previews without applying; Star pins above other sounds and also populates the desktop menu.
Filters preserve the active sound; switching sounds preserves volume and assignments.
Expose no tone, pitch, stereo, release-volume, or variation knobs.

## Desktop

Home: mark, sound toggle, Settings; a compact sound list beside current sound, volume, and the fixed 3D keyboard.
Keys preview on click, with subtle travel and local glow; no pointer tilt or bounce.
Native typing audio runs independently of the window.
Customize a key reveals Key/Sound selectors and Reset; the model selects keys in this mode.
Physical-key selection is explicit and cancellable; Done restores sound choices.

Menu: mute, volume, starred sounds, More sounds, Open OpenKlack.
Automatic pauses show their cause and temporary Resume on home and menu.

| Settings                | Behavior                                                                                                                             |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Open at login           | Opt-in                                                                                                                               |
| Microphone pause        | Default on; includes calls, dictation, recording                                                                                     |
| Muted apps              | Pause for a chosen foreground app; removal offers Undo                                                                               |
| Appearance              | System / Light / Dark                                                                                                                |
| Sounds & settings files | Import compatible packs, audio, or settings; export current setup with audio and credits                                             |
| License                 | Official builds only, per [LICENSING.md](../../LICENSING.md): state, trial days, key field, Remove this Mac; hidden in source builds |
| About & help            | Permissions, version/updates, credits, reviewable local diagnostics                                                                  |

Imported settings become active without discarding recordings or the prior stored setup.
Retain legacy tuning and app-specific sound rules for compatibility; label legacy rules, while new rules only mute.

## Marketing only

At `/openklack/`, prioritize Download for Mac → `/openklack/download/`.
An unconfigured installer URL shows unreleased status; a configured URL attempts download and offers manual retry, without claiming completion.
GitHub and editable social-post links are secondary actions; never auto-star or auto-post.

The playground combines the keyboard, sound controls, and a basic typing test: free typing or 15/30/60 seconds, starting on the first keystroke.
Keep one caret and legible correct/error states; sound changes preserve the test.
Completion replaces the passage with aligned WPM, accuracy, and retry, keeping the keyboard position stable.
Typing tests never belong in the desktop app.
Browser sound starts on; the first typing or keyboard click unlocks audio, and mute stays available.
Shortcuts and form controls retain normal behavior.
Persist only sound, volume, and valid stars; typed text/results stay in memory.
Keep the old “Keyboard buttons” disclosure and sound-credits link out of the playground; retain required recording notices elsewhere.

## Defaults and recovery

| Situation                       | Behavior                                                                                                                           |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Typing                          | Physical presses, including modifiers; suppress held-key repeats                                                                   |
| Output changes                  | Follow the Mac's active output; continue when ready                                                                                |
| Manual mute                     | Persists until user resumes; automation cannot override                                                                            |
| Microphone signal               | Name observed activity, not an inferred call; temporarily uncertain → silence with reason/Resume; unsupported → explain limitation |
| Input permission / Secure Input | Explain unavailability/recovery; respect OS restrictions                                                                           |
| Failed import or sound change   | Preserve working data and offer recovery                                                                                           |
| Pack update                     | Keep installed version until explicit update                                                                                       |

Inspect only app identity and basic system state.
No accounts, automatic telemetry, typed-text logs, or key-event histories; diagnostics stay local until reviewed and shared.
Mac first; other platforms remain unadvertised future work.
Measure latency, first-key reliability, and background energy on hardware before release.

## References

[Installed app capture](../assets/openklack/ui/settings-light.png) · [Verification](../desktop-verification.md) · [Keyboard workflow](../keyboard/README.md).
The prototype uses Raycast geometry with OpenKlack materials; [provenance](../../packages/openklack-ui/assets/keyboard/PROVENANCE.md) requires permission or replacement before redistribution.
