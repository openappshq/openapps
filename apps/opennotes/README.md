<div align="center">

<img src="design/assets/app-icon.svg" alt="OpenNotes app icon" width="128" />

# OpenNotes

**Sticky notes docked to the edge of your screen. Every note is a Markdown file.**

Open source · Mac native · No permissions · No telemetry · 3-day trial, no signup

[Install](#install) · [Build and run](#build-and-run) · [Product contract](../../design/products/opennotes.md) · [Report a bug](https://github.com/openappshq/openapps/issues)

</div>

## What it does

A thin pill sits on the right edge of the screen (or the left). Push the pointer against it and the deck fans out: one colored tab per note. Click a tab and the note slides out to write in; press Escape and it slides back; drag a tab up or down the deck to reorder your notes. The first launch into an empty folder leaves one welcome note, a tour of the formatting and the gestures, yours to edit or archive. The deck stays above every window, full-screen apps and Stage Manager stages included, on every Space.

- **Capture from anywhere** — ⌥⌘N (rebindable) makes a new note and puts the caret in it, whatever app is in front. Escape saves it. An empty note is not kept.
- **Files, not a database** — each note is one `.md` file in `~/Documents/OpenNotes` (Settings: any folder — iCloud Drive, an Obsidian vault). A short front matter block keeps the color, the face, pinned, archived and the order. Edit a file in another app and the deck picks it up within a second; a file that changed outside is never overwritten — it keeps that version, and your unsaved text continues in a conflict copy beside it. OpenNotes never deletes a file.
- **Plain text that stays plain** — paste strips rich text; smart quotes and dashes are off. Markdown-lite is styled live without changing a character: `#` headings, `**bold**`, `_italic_`, `` `code` ``, lists, `- [ ]` checklists you tick with a click, URLs. Two faces, Sans and Mono; six colors.
- **Archive, not delete** — ⌘⇧A moves a note out of the deck with a 10-second Undo; it stays in the folder, in search and in All Notes → Archived. Auto-archive can retire untouched notes after 7, 30 or 90 days.
- **All Notes** (⌥⌘L) — search titles and text, Active / Archived, drag to reorder, Open, Pin, Archive, Export as `.md` or `.txt`, Reveal in Finder.
- **Keyboard** — ⌘W saves and opens the next note, ⌘⇧P pins, ⌘⇧M switches the face, ⌥⌘↑ / ⌥⌘↓ move the open note along the deck, ⌘, opens Settings.

OpenNotes needs **no permissions**: the hotkey is a Carbon system hotkey, the deck is a window level, the notes are a folder you choose. Nothing leaves the Mac; a source build makes no network calls at all. The official build opens a short setup guide once (welcome, nothing to grant, your notes are files, starts with your Mac, tips; Settings → About → Show setup guide reopens it where you left off), turns "Open at login" and "Check for updates automatically" on once on a fresh install, and installs an update only when you say so ([RELEASES.md](../../RELEASES.md)).

## Install

```sh
curl -fsSL https://openapps.space/install/opennotes | sh
```

No Homebrew needed: the [install script](../../RELEASES.md#install-script) downloads the signed release, checks its SHA-256 against the digest pinned in the script, puts the app in `/Applications` and opens it. Prefer Homebrew? `brew install --cask openappshq/tap/opennotes` installs the same zip, and `brew upgrade --cask opennotes` updates it.

## Trial, license and privacy

The official build is paid, on the same terms as every OpenApps HQ app ([LICENSING.md](../../LICENSING.md)): a 3-day free trial that starts when you first open OpenNotes, then a one-time license for up to 3 Macs, bought on [openapps.space/opennotes](https://openapps.space/opennotes/). When the trial ends OpenNotes is **read-only**: the deck stays where it is and every note stays readable, searchable and exportable — they are your files, and not one is changed — but making, editing, renaming, archiving and reordering notes wait for a license. The pill on the open note, above All Notes and in the Settings title bar shows the trial's remaining days or why the notes are read-only; Settings → License is where to buy a license (the button opens the website, which is the only place a price is stated), paste a key or remove this Mac from a license. The app never shows a price. Builds from source have none of this.

> Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use OpenNotes are never sent. Builds from source never contact the license service.

## Requirements

macOS 14 Sonoma or later. The release is a universal binary.

## Build and run

Requires Xcode 26 (Swift 6.2 or later).

```sh
swift build            # debug build, licensing compiled out
swift test             # OpenNotesCoreTests (the file format, the store against temporary folders, the styler,
                       # search, export, archive and undo, the deck rules and layout, the first-run flags)
                       # and OpenNotesTests (the app model, preferences, the styler on a text storage, wiring)
swift run OpenNotes    # run from the terminal (no setup guide, no login item)
scripts/bundle.sh      # release build → build/OpenNotes.app, ad-hoc signed
```

A build from source has licensing compiled out: no License section, no trial, no license network calls, every note editable; Settings → Updates says the build has no updater. The official flavour compiles both in (`OPENAPPS_LICENSING=1 OPENAPPS_OFFICIAL=1`, with `scripts/generate-licensing-config.sh` writing the gitignored `Sources/OpenNotes/Licensing/LicensingConfig.swift` from `OPENAPPS_DODO_ENV` and `OPENAPPS_DODO_PAID_PRODUCT_ID`; a debug build shortens the trial with `OPENNOTES_DEBUG_TRIAL_DAY_SECONDS=60`). The debug binary renders every surface to PNGs without opening a window, touching your notes folder or registering anything:

```sh
.build/debug/OpenNotes --preview /tmp/opennotes-preview   # deck states (read-only too), All Notes (empty, one, ten notes, no match, read-only), the license card, the setup guide, Settings; light and dark
```

Regenerate the app icon and menu-bar image from the SVG masters in `design/assets` with `scripts/make-icons.sh`.

## Architecture

| Layer | Where | Notes |
| --- | --- | --- |
| Note model and file format | `OpenNotesCore/Note.swift` | `Note`, `NoteColor`, `NoteFace`, the front matter parser and serializer, file names (slug of the title, decided when a new note first closes, never changed) |
| Markdown-lite | `OpenNotesCore/MarkdownLite.swift` | Styled runs over UTF-16 ranges that always tile the text; checkbox toggles as three-character replacements; plain-text export |
| Store and watcher | `OpenNotesCore/NoteStore.swift`, `FolderWatcher.swift` | Reads the folder, writes after a 250 ms debounce, reconciles outside edits by size, date and hash, conflict copies, read-only; FSEvents on the folder |
| Rules | `OpenNotesCore/DeckStateMachine.swift`, `Export.swift` | The deck's states and effects (pure), the deck geometry for both edges, search, export, auto-archive, the 10-second undo |
| Deck | `OpenNotes/Deck/` | One non-activating `NSPanel` per hosted display; the state machine drives it; `DeckView` draws the pill, the fan, the note and the toast from `DeckLayout` |
| Editor | `OpenNotes/Editor/` | `NoteTextView` (plain paste, no substitutions, checkbox clicks) and `NoteStyler` (attributes only, never characters) |
| All Notes, Settings | `OpenNotes/AllNotes/`, `OpenNotes/Settings/` | The window, the form; the hotkey recorder; the login item; the license card and the pill; Settings → License and Updates |
| Licensing | `OpenNotes/Licensing/` | `LicenseStatus` (what every view and the store read: the projected entitlement, asked afresh on every read, never stored), the controller over `packages/openapps-licensing` in official builds, the pill, Settings → License, the `opennotes://activate` link |
| Updater, guide | `OpenNotes/Updates/`, `OpenNotes/Onboarding/` | The shared updater (`packages/openapps-updater`) in official builds and its Settings section; the setup guide |
| Harness | `OpenNotes/PreviewHarness.swift` | `--preview`: `ImageRenderer` over a temporary folder, a throwaway defaults suite and a license bound to an ended trial for the read-only stages |

The [product contract](../../design/products/opennotes.md) records approved behavior; the signed release is built by CI from an `opennotes-v*` tag ([RELEASING.md](RELEASING.md)).

## Credits

Fonts: Bricolage Grotesque, Instrument Sans and IBM Plex Mono (SIL OFL). See [NOTICE](NOTICE).

---

<div align="center">

<img src="../../design/assets/openapps-hq/app-icon.svg" alt="OpenApps HQ" width="56" />

**[MIT](LICENSE) · An [OpenApps HQ](https://github.com/openappshq) original.**

</div>
