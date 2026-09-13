# Desktop interface review

Reviewed September 13, 2026.

## Scope and coverage

Scope: the packaged macOS settings interface, including Keyboard, Presets, App rules, General, native file sheets, close/reopen behavior, isolated startup recovery, and app-update error feedback.
The implementation uses React 19.2, HeroUI 3, Geist, custom CSS, and Tauri's WKWebView.
Project conventions come from `/Users/anurag/AGENTS.md` and the accepted `design/desktop-plan.md`.
This review covers the inspected desktop interface, not website design or public-release readiness.

| Domain | Evidence inspected | Result |
| --- | --- | --- |
| Accessibility | Native accessibility tree, labeled controls, error/status roles, keyboard key selector, focus CSS, switch structure | Corrected switch labeling; arrow navigation passed; full VoiceOver not verified |
| Layout | Packaged settings at 1080 × 760 and approximately 767 × 607; Keyboard and App rules at the smaller size | Corrected description alignment and offscreen error feedback; no horizontal overflow observed |
| Writing | Preview/apply controls, pause reasons, import errors, General diagnostics explanation, app-rule labels | Clear within inspected states; diagnostics explicitly distinguish callback timing from speaker latency |
| Typography | Geist text hierarchy, key legends, labels and descriptions in packaged screenshots | Clear within inspected sizes; zoom not verified |
| Colors | Declared foreground/background pairs, focus styles, selected states, switch outlines | Inspected text pairs exceed 4.5:1; final packaged General screen shows distinct off-state track and thumb |
| UI | Keyboard depth/selection, panels, dialogs, preset/rule actions, close/reopen | Native file sheets, rule Undo, and saved preset restoration passed; native tray slider not verified |

## Findings

No remaining HIGH findings were identified in the inspected interface paths.
These root causes were corrected during implementation:

| Severity | Domain | Location | Before | After | Why |
| --- | --- | --- | --- | --- | --- |
| HIGH | UI | `apps/desktop/src-tauri/src/lib.rs:19` | File actions could fail to present a usable sheet | All file dialogs share a helper that attaches the settings window | Import/export must produce a visible, operable dialog |
| MEDIUM | UI | `apps/desktop/src-tauri/src/engine.rs:418` | A damaged recording prevented manual mute from saving | A mute-only change preserves playback and its warning while persisting mute | The primary silence control must remain usable during recovery |
| MEDIUM | Accessibility | `apps/desktop/src/controls.tsx:60` | Switch label and description appeared concatenated | Label/control share Switch.Content; Description remains a distinct sibling | Separates the control's name from explanatory text |
| MEDIUM | Layout | `apps/desktop/src/App.tsx:171` | Import failures could appear above the current scroll position | Error feedback scrolls into view and uses an alert role | Users can locate the failure and act on it |
| LOW | Layout | `apps/desktop/src/styles.css:629` | Switch descriptions were indented independently of their labels | Description padding aligns with its label | Preserves visual grouping |

The off-state switch outline was strengthened at `apps/desktop/src/styles.css:635` and inspected in the final packaged General screen.
The final packaged key-selection button enters selection mode, displays the physical-key instruction, and cancels through the same button.
Automation could not establish a reliable window-focus transition for testing automatic cancellation, so that behavior remains unverified.

## Verification

Passed:

- `pnpm exec vp lint`, `pnpm test`, and `pnpm --filter @openklack/desktop web:build` passed after the latest source changes.
- Clicking A and pressing Right selected S, moved focus to S, and updated the assignment selector to S.
- Closing settings with Command-W kept the native process running; reopening reset the transient selection to Space and restored the user's saved Brown PBT preset and 52% volume.
- Removing the test app rule exposed Undo; Undo restored the exact rule.
- Native sheets imported a compatible Thock archive and individual WAV, reported a malformed WAV, and saved the reviewed diagnostics report.
- Keyboard and App rules were inspected at approximately 767 × 607 without observed horizontal clipping.
- General's switch label and description were visibly distinct and aligned.
- The updated release's Choose by typing control enters and cancels selection mode with matching accessible pressed state.
- An isolated packaged QA app displayed a damaged-pack warning, accepted manual mute, and cleared the warning after native import repaired the recording; mute remained enabled.
- Malformed QA settings produced a visible recovery-copy notice and a usable default preset after relaunch.
- A deliberately unreachable update endpoint produced a readable connection/retry message in the packaged QA app, retained the native failure state after closing/reopening settings, and left Check for updates available.
- The final local release shows its version, a clear unconfigured-update explanation, and a disabled Check for updates button; the General layout was visually inspected at 1080 × 760.
- Declared contrast checks include body text 12.51:1, secondary text at least 4.78:1 on inspected surfaces, accent text 9.10:1, error text 7.13:1, and key labels 6.56:1.

Not verified:

- Full VoiceOver navigation, 200% zoom, and runtime reduced-motion behavior.
- Native menu-bar slider interaction; the automation surface did not expose the status menu.
- The new native save-error dialog and restoration of failed menu-bar controls; the shared Rust paths compile and pass strict Clippy, but the status-menu error route was not exercised interactively.
- Physical-key selection and blur cancellation, live RGB timing, and international-layout behavior through genuine hardware input.
- Browser-width reflow below the native settings minimum of 760 × 600.
- Available-update notes, download progress, signature rejection, installation, and restart against an actual signed release.

## Verdict

Approve for the inspected interface paths only.
This verdict does not cover the unverified accessibility modes, native tray controls, hardware behavior, or public release.
