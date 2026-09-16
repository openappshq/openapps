# OpenKlack for Mac

Mechanical keyboard sounds for the keyboard you already own. A Tauri 2 menu bar app: Rust audio engine and macOS input bridge in `src-tauri/`, React settings window in `src/`.

```sh
pnpm install
pnpm openklack:dev     # run from source
pnpm openklack:test    # Rust tests
pnpm openklack:build   # local app bundle
```

Build requirements, signing, releases and the licensed build flavour are in the [development guide](../../docs/development.md#desktop-application-in-development); the release process follows [RELEASES.md](../../RELEASES.md).

Install the official build with one line, no Homebrew needed: `curl -fsSL https://openapps.space/install/openklack | sh` (the [install script](../../RELEASES.md#install-script) downloads the signed release, checks its digest, puts the app in `/Applications` and opens it), or with Homebrew: `brew install --cask openappshq/tap/openklack`. It checks for updates once a day and tells you when one is available (on by default; installing is your call, or turn on "Download and install automatically" under Settings → About & help, off by default). `brew upgrade --cask openklack` always works too.

## Source builds are unrestricted

OpenKlack is [MIT licensed](../../LICENSE). A build from source has licensing compiled out: every feature works, there is no License section in Settings, and nothing contacts the license service.

The official download is the signed build with updates, sold for $5 through Dodo Payments. It works right after download for a free 3-day trial with no signup, then keyboard sounds stop until you buy. It is built with the `licensing` cargo feature, following the shared [licensing contract](../../LICENSING.md). Without a license or trial only keyboard sound playback stops; the menu bar, Settings, License and Quit always work.

## Privacy

> Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac's hardware ID (it can't be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac's name, what you type, and how you use the app are never sent. Builds from source never contact the license service.

The license and trial records are kept in encrypted files the app owns (`~/Library/Application Support/OpenApps/openklack/records/`, readable only by your user and only on this Mac), never in plain preferences and never in the Keychain. Typed text is never stored or sent anywhere, licensed or not.
