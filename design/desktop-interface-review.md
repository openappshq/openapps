# Desktop interface review

Reviewed September 14, 2026, after the simplicity and HeroUI pass.

## Scope and coverage

Scope: the installed macOS home, sound browser, key customization, Settings, and menu contents. React 19, HeroUI 3, Motion, Tauri/WKWebView, and the shared Tactile Studio tokens in `design/tokens.json`. Conventions: the supplied AGENTS.md guidance, `design/desktop-plan.md`, and the later user instructions to remove preset/tuning complexity. This is a desktop review; the website typing test is deliberately excluded.

| Domain | Evidence inspected | Result |
| --- | --- | --- |
| Accessibility | Native accessibility tree; labeled buttons, search, tabs, dropdowns and switches; focus CSS; Down/Return selection and Escape dismissal | Corrected duplicate search focus ring; full VoiceOver unverified |
| Layout | Installed 1080 × 760 home, browse, customization and Settings; bounded lists and source breakpoint rules | Removed sidebar/inspector; four initial choices fit; full library scrolls |
| Writing | Visible actions, saved-setup terminology, pause reasons, import/export and optional diagnostics | Removed preset terminology, redundant explanations and tuning labels |
| Typography | Bricolage headings, Instrument Sans controls and IBM Plex Mono values in light/dark screenshots | Clear within inspected size; zoom unverified |
| Colors | Shared light/dark tokens, selected rows, focus and volume thumb | Inspected text pairs pass 4.5:1; dark thumb remains visible |
| UI | HeroUI Select, Accordion, Tabs, Slider and button states; native menu AX | Dropdown/accordion interactions passed; native menu contents verified, physical tray interaction unverified |

## Findings resolved

| Severity | Domain | Location | Before | After | Why |
| --- | --- | --- | --- | --- | --- |
| HIGH | Layout | `apps/desktop/src/App.tsx:79`; `apps/desktop/src/SoundLibrary.tsx:12` | Sidebar destinations, inspector and preset workflow surrounded the primary task | One home with current sound, volume, keyboard and immediate sound selection | The everyday task must not require navigating or applying a candidate |
| MEDIUM | UI | `apps/desktop/src/controls.tsx:75`; `apps/desktop/src/General.tsx:70` | Plain selects and disclosures felt unrelated to the component system | HeroUI Select and Accordion, with native focus and expansion semantics | Consistent behavior and recognizable feedback |
| MEDIUM | Layout | `apps/desktop/src/SoundLibrary.tsx:24`; `packages/ui/SoundBrowser.tsx:25` | Entire catalog dominated the window with no quick type narrowing | Four initial choices and a bounded browser with combined search/type tabs | Progressive disclosure keeps the main action compact |
| MEDIUM | UI | `apps/desktop/src/SoundLibrary.tsx:73`; `apps/desktop/src-tauri/src/lib.rs:428` | Favorites did not form one predictable route between home and menu | Shared persisted stars sort first and appear above More sounds | Frequently used sounds should take one selection |
| MEDIUM | Accessibility | `packages/ui/browser.css:12` | Search input and its group both drew focus outlines; native cancel duplicated the clear action | The group owns the focus ring; HeroUI owns clearing | One visible focus target with one clear control |
| LOW | Writing | `apps/desktop/src/useDesktop.ts:60`; `apps/desktop/src/SoundLibrary.tsx:62` | Imported Alps recording appeared indistinguishable from the bundled entry | Imported source is identified in name and subtitle | Similar names should explain their actual difference |
| LOW | Colors | `apps/desktop/src/styles.css:635` | The slider thumb could inherit a dark inner surface | Explicit white inner thumb in both appearances | Volume position remains visible on the track |

No unresolved HIGH findings were identified within this scope. Legacy non-mute app rules retain their compatibility label; this review does not re-specify that legacy workflow.

## Verification

Passed:

- `pnpm lint`; `pnpm test` (8); `pnpm build`; desktop `web:build`; `cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml` (14 passed, 1 ignored hardware check).
- Development-signed `tauri build --debug --bundles app`; installed bundle passed `codesign --verify --deep --strict`.
- Installed home preserved Red PBT, displayed 77% volume, existing assignment and stars after relaunch. No desktop typing test or preset navigation was present.
- Browse all → Tactile → search “brown”: only Brown ABS and Brown PBT remained. The selected sound stayed Red PBT.
- Settings → Appearance: inspected HeroUI popover, changed Dark/Light and restored Light; Escape dismissed the popover and restored trigger focus.
- Sounds & settings files expanded with import/export actions; nested About/help uses the same Accordion implementation.
- Customize a key → Key dropdown → Down → Return selected Enter; Sound showed the unchanged default and Reset was disabled.
- Native menu AX exposed the volume slider, starred Blue/Brown PBT, More sounds, Open and Quit actions.
- Measured token pairs: primary/light 18.42:1; secondary/light surface 5.50:1; accent/light selected surface 7.07:1; secondary/dark surface 8.40:1; accent/dark selected surface 8.42:1.

Not verified:

- Full VoiceOver, 200% zoom, RTL, and runtime reduced-motion behavior.
- Final native layout at the minimum window size; source breakpoints were inspected, while packaged visual checks used 1080 × 760.
- Actual tray slider interaction/icon appearance, new file imports, or app-rule undo in this pass; earlier checks remain in the historical verification record.
- Genuine hardware latency, sleep/reconnect/call recovery, and battery use after this UI pass.
- Notarization and DMG packaging. The local `.app` succeeded; an earlier DMG attempt failed.

## Verdict

Approve for the inspected desktop interface paths. This does not establish public-release readiness or the unverified accessibility and hardware modes.
