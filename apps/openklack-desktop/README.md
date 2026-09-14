# OpenKlack for Mac

Mechanical keyboard sounds for the keyboard you already own. A Tauri 2 menu bar app: Rust audio engine and macOS input bridge in `src-tauri/`, React settings window in `src/`.

```sh
pnpm install
pnpm openklack:dev     # run from source
pnpm openklack:test    # Rust tests
pnpm openklack:build   # local app bundle
```

Build requirements, signing, releases and the licensed build flavour are in the [development guide](../../docs/development.md#desktop-application-in-development).

## Source builds are unrestricted

OpenKlack is [MIT licensed](../../LICENSE). A build from source has licensing compiled out: every feature works, there is no License section in Settings, and nothing contacts the license service.

The official download is the signed, notarized build with updates, sold for $5 through Dodo Payments with a free 3-day trial. It is built with the `licensing` cargo feature, following the shared [licensing contract](../../LICENSING.md). Without a valid license only keyboard sound playback stops; the menu bar, Settings, License and Quit always work.

## Privacy

> Official builds check your license with Dodo Payments, our payment provider. The license key and an activation ID are sent when you activate and once a day after that. Your Mac's name, what you type, and how you use the app are never sent. Builds from source never contact the license service.

The license record is kept in the macOS Keychain (`space.openapps.openklack.license`), never in plain preferences. Typed text is never stored or sent anywhere, licensed or not.
