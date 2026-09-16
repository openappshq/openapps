<div align="center">

<img src="design/assets/app-icon.svg" alt="OpenReaction app icon" width="128" />

# OpenReaction

**Type `:tada:` in any text field on your Mac. Get 🎉.**

Free & open source · Mac native · No account · No telemetry

[Build and run](#build-and-run) · [Architecture](docs/architecture.md) · [Report a bug](https://github.com/openappshq/openapps/issues)

</div>

## What it does

- Slack/Discord-style `:shortcode:` emoji autocomplete in any app
- A glass pill of emoji at your caret: arrow keys to choose, Return or Tab to insert, Esc to dismiss
- A full `:tada:` with the closing colon turns straight into 🎉
- Emoji, names and languages come from macOS itself; familiar shortcodes like `:+1:` still work
- Stays out of password fields, secure input, terminals and apps that already expand shortcodes — the app list in Settings shows the defaults and lets you switch them on or add your own
- Liquid Glass on macOS 26 Tahoe, native materials on Sonoma and Sequoia
- GIFs and stickers are planned

## License

OpenReaction is MIT licensed and **a build from source is unrestricted**: licensing is compiled out, every feature works, and nothing contacts the license service. The license pays for the official build — the signed download with in-app updates: $5 one-time per app, lifetime updates, 3 Macs. The official build works for 3 days right after download, no signup. Details in [LICENSING.md](../../LICENSING.md).

> Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use OpenReaction are never sent. Builds from source never contact the license service.

## Requirements

macOS 14 Sonoma or later.

OpenReaction needs **Accessibility** and **Input Monitoring** permission to notice shortcodes as you type and insert the result into the app you are using.

**Privacy.** Keystrokes are inspected in memory as they pass, only to spot a shortcode after a colon, and are never stored, logged or sent anywhere. Outside a shortcode nothing is kept beyond whether the last character was part of a word; a shortcode is kept only while you type it. When macOS Secure Input is on (most password fields, Terminal's Secure Keyboard Entry) OpenReaction reads nothing. Other password fields are detected through Accessibility on a best-effort basis: macOS reports focus changes asynchronously, so a field that becomes a password field programmatically can be seen a moment late. To rank suggestions, OpenReaction remembers which emoji you pick (on this Mac only, with the day of last use); Settings has a "Clear Usage History" button.

## Build and run

Requires Xcode 26 (Swift 6.2 or later).

```sh
swift build          # debug build
swift test           # unit tests for the core library
scripts/bundle.sh    # release build → build/OpenReaction.app (licensing off)
```

Official builds opt into licensing; the script generates the compiled-in configuration and refuses to build without the Dodo paid product ID:

```sh
OPENAPPS_LICENSING=1 OPENAPPS_DODO_ENV=test OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… scripts/bundle.sh
```

The trial registers with `https://openapps.space/api/trial` (`env` follows `OPENAPPS_DODO_ENV`). A test build can use a local `wrangler dev` instead with `OPENAPPS_TRIAL_REGISTRY_BASE_URL=http://127.0.0.1:8787`. To run the whole trial in minutes, start a debug build with `OPENREACTION_DEBUG_TRIAL_DAY_SECONDS=60` (a trial "day" becomes a minute); release builds ignore it.

Licensing comes from the shared package `packages/openapps-licensing` (every build links its rules and badge; only a licensed build links its Dodo and trial registry clients, see [LICENSING.md](../../LICENSING.md)). Official builds also compile in the shared updater (`OPENAPPS_OFFICIAL=1`; `packages/openapps-updater`: a fresh install checks for updates automatically and only tells you; installing stays your move unless you turn "Download and install automatically" on, see [RELEASES.md](../../RELEASES.md)). The official download is built by CI from an `openreaction-v*` tag, published as a GitHub Release and installed with `curl -fsSL https://openapps.space/install/openreaction | sh` (the [install script](../../RELEASES.md#install-script)) or `brew install --cask openappshq/tap/openreaction`; see [RELEASING.md](RELEASING.md).

`scripts/bundle.sh` signs ad-hoc unless it runs inside `scripts/release/with-signing-keychain.sh` with the release certificate:

```sh
scripts/bundle.sh
open build/OpenReaction.app
```

macOS ties Accessibility and Input Monitoring grants to the code signature. Ad-hoc signatures change with every build, so expect to grant the permissions again after each rebuild; releases are signed with one stable certificate so users never do.

To check the picker's look without permissions or the event tap:

```sh
swift run OpenReaction --preview-picker   # ← → move the selection
```

The setup guide, the settings window and every license pill, the same way (debug builds only; no tap, a throwaway preferences suite, permission and relaunch actions that touch nothing, in-memory license storage and services that never answer; ⌘] and ⌘[ move the guide between steps, ⌘D shows the drag-to-grant helper on a permission step — it stays without System Settings and prints a drag from its icon). With a directory it renders each window, the helper included, in light and dark appearance as PNGs and quits:

```sh
swift run OpenReaction --preview-setup            # interactive
swift run OpenReaction --preview-setup /tmp/shots  # PNGs, then quits
```

Regenerate the app icon and menu-bar image from the SVG masters in `design/assets` with `scripts/make-icons.sh`.

## Architecture

| Layer | Where | Notes |
| --- | --- | --- |
| Keystroke capture | `KeyboardTap` | Active session `CGEventTap` on its own thread, so picker keys can be swallowed; re-enables itself if macOS times it out |
| Trigger | `TriggerMachine` (core) | Pure state machine over a short typed tail: word-boundary colons, backspace, dismiss, closing colon |
| Emoji data | `AppleEmojiData`, `EmojiCatalog` (core) | macOS CoreEmoji names, gemoji shortcodes, CoreText render check |
| Search | `EmojiSearch` (core) | Tiered ranking: shortcode, words, keywords, stems, fuzzy, typos; frecency within tiers |
| Caret | `CaretLocator` | Accessibility text bounds off the main thread, with fallbacks |
| Picker | `PickerPanel`, `PickerView` | Non-activating panel that never takes focus; `PanelPlacement` (core) positions it |
| Insertion | `TextInserter` | Synthetic backspaces plus Unicode key events, leaving the clipboard alone |

The reasoning behind each choice is in [docs/architecture.md](docs/architecture.md).

## Credits

Emoji shortcodes and tags from [gemoji](https://github.com/github/gemoji) (MIT). Fonts: Bricolage Grotesque, Instrument Sans and IBM Plex Mono (SIL OFL). See [NOTICE](NOTICE).

---

<div align="center">

<img src="design/assets/openapps-hq/app-icon.svg" alt="OpenApps HQ" width="56" />

**[MIT](LICENSE) · An [OpenApps HQ](https://github.com/openappshq) original.**

</div>
