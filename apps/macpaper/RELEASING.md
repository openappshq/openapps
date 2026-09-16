# Releasing macPaper

macPaper follows [RELEASES.md](../../RELEASES.md) like every OpenApps HQ
app: a universal `macPaper.app` with licensing and the in-app updater
compiled in, signed with the stable OpenApps HQ Release certificate, zipped,
published as the GitHub release `macpaper-vX.Y.Z`, with a signed update
feed at `apps/website/public/updates/macpaper/` and a Homebrew cask,
`openappshq/tap/macpaper`. The release pipeline (`.github/workflows/macpaper.yml`,
the update key, the cask, the tag ruleset, the `macpaper-release` environment)
is a later ticket; this file grows with it. Hertz's [RELEASING.md](../hertz/RELEASING.md)
is the template.

What exists today:

| Piece | State |
| --- | --- |
| `scripts/bundle.sh` | Builds and signs `build/macPaper.app` (ad-hoc by default; the release certificate inside `scripts/release/with-signing-keychain.sh`). The licensing and updater flavours are wired in the script but have nothing to link yet |
| `scripts/make-zip.sh` | `dist/macPaper-<version>.zip` and its `.sha256` |
| `scripts/verify-release.sh [--release] <zip>` | The checks a user's Mac and the updater run; `--release` requires the pinned requirement and the release certificate |
| `scripts/make-icons.sh` | Renders `design/assets/*.svg` into the committed `AppIcon.icns` and menu-bar images |
| `release/designated-requirement.txt` | `identifier "com.openappshq.macpaper" and certificate leaf = H"<sha1>"`, the same certificate as every OpenApps HQ app |
| `release/sparkle-public-key.txt` | Not yet: created with the release ticket's `scripts/create-update-key.sh` |

Local rehearsal, no secrets:

```sh
UNIVERSAL=1 VERSION=0.1.0 scripts/bundle.sh
scripts/make-zip.sh
scripts/verify-release.sh dist/macPaper-0.1.0.zip
```
