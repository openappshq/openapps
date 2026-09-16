# OpenNotes

Sticky notes kept as a deck docked to the edge of the screen: a thin pill at rest, a fan of tabs when the pointer reaches the edge, one note slid out to write in. Every note is a plain Markdown file in a folder the user can see; nothing else stores it.
Open source under MIT; the official build is paid on the same terms as every OpenApps HQ app ([LICENSING.md](../../LICENSING.md): 3-day in-app trial, no signup, one license for 3 Macs). Installed with one Terminal line or Homebrew; the official build checks a signed feed for updates once a day and installs one only when the user says so ([RELEASES.md](../../RELEASES.md)).

Primary task: press the hotkey anywhere, type, press Escape. The note is on the edge and in the folder.

## Identity

Signature color: coral (`coral/300` tile face, `coral/500` shade, `coral/700` / `coral/300` accent in light / dark) — a sticky that is not HQ's yellow. The ramp is derived for OpenNotes and recorded in [`apps/opennotes/design/tokens.json`](../../apps/opennotes/design/tokens.json) with its contrast checks; `coral/300` never carries text on a light ground.
The mark is a square sticky with its bottom-right corner folded up, in ink; the app icon is the same sticky on a coral tile.
Type follows the shared system: Bricolage Grotesque for window headings, Instrument Sans for interface text and the Sans note face, IBM Plex Mono for labels, the "Saved" line and the Mono note face; a note can also be set in any font installed on the Mac.
The deck, the note card and the All Notes window are flat surfaces with one contact shadow on the open note; no glass (a translucent sticky reads as a sheet of paper, not a note).

## The deck

One deck per hosted display, docked to the **right** edge (Settings: left), vertically centred on the visible frame, above every window including full-screen apps and Stage Manager stages, on every Space. It never takes focus from the app in front until the user starts writing in a note.

| State | Looks like | Enters | Leaves |
| --- | --- | --- | --- |
| Pill | A 14 pt strip on the edge, one dash per active note in the note's light paper, rounded ends; 8 dashes at most, a dot for "more" | Launch; the fan collapsing; Escape or a click outside an open note | The pointer reaching the edge for 120 ms |
| Fan | Tabs stacked down the edge as separate papers, 40 × 112 pt, 6 pt apart, one per active note, every one; each tab in the note's paper for the appearance, the title reading down it (up on the left edge) in the paper's ink and the note's font; what does not fit scrolls; a `+` tab fixed under the fan | The pill, after the pointer has rested on the edge; the hotkey while read-only; an open note closing | The pointer leaving the edge and the deck for 350 ms; a tab click; Escape |
| Open | One note slid out of the deck as a 320 × 360 pt card next to its tab; the other tabs stay as the fan | A tab click; the hotkey (a new note, focused); ⌘W from another open note (the next one); "Open" in All Notes | Escape (saves, slides back to the fan); a click outside; the hotkey again; ⌘W with no next note; Archive |
| Editing | The open note with the keyboard focus (the app is active, the caret in the text) | A click in the text; the hotkey's new note | Escape; a click outside |

Rules:

- Hover opens the fan, and only the fan: a note never opens on its own.
- **Tabs are papers, not a slab:** each tab is the note's paper for the appearance with a hairline edge and a soft shadow, a 3 pt bar of the note's colour (its mid tone, `noteBars` in the tokens; derived for a custom colour) along its outer edge, the pin glyph when pinned, and the title along the tab at a readable size, cut with an ellipsis. Each fanned tab leans at its own small, stable angle (1.5–3°, either way, and up to 3 pt in from the edge — seeded from the note's file name, never from a launch, so it leans the same way every time and never jitters), so neighbours read as papers stuck on one by one; the open note's tab and a lifted tab are straight. Hover lifts a tab a little out from the edge; a drag lifts it more.
- **Overflow scrolls:** every active note has a tab; when the stack is taller than the screen leaves between the margins and the `+` tab, the fan scrolls — trackpad or wheel over the tabs, a drag along the deck axis off the tabs, ↑ / ↓ while the deck has the keyboard, and a lifted tab held at either end scrolls the fan under it. A fade over 28 pt at the top or the bottom shows only while more tabs lie beyond that end. The open note's tab, or the last one used, is brought into view when the fan opens or the note opens, and the scroll is otherwise the user's. No "+N more" tab; the `+` tab stays put under the fan. The pill is unchanged (8 dashes at most, a dot for more).
- The open note stays open while the pointer is elsewhere; only Escape, a click outside, the hotkey, Archive or ⌘W close it. Closing always saves.
- **Drag to reorder:** a tab pressed and moved 6 pt along the deck lifts (a little larger, a deeper shadow) and follows the pointer up and down the deck only, the other tabs sliding out of its way with a spring; letting go drops it in the gap, and the drop writes `order` through the very same path the All Notes list uses (one write, only the notes whose position changed). A shorter press is a click and opens the note. Pinned notes stay first: a lift never crosses the group boundary — the tab gives a little past it and snaps back to the group's edge, and no drag pins or unpins (that is the pin's job). Escape puts a lifted tab back; the fan stays out while a tab is held, whatever the pointer does. While read-only nothing lifts; the license card and the footer say why. The keyboard does the same: ⌥⌘↑ / ⌥⌘↓ move the open note one slot, VoiceOver has Move up / Move down on every tab, and each move is announced ("Groceries moved to position 2 of 5").
- Every change of state is one movement (180 ms, ease-out); the reorder is a spring (300 ms); Reduce Motion makes them instant.
- The deck reads `~/Documents/OpenNotes` (Settings: any folder) and shows what is there, so a note written by another app appears within a second.
- **Read-only** (after the trial, [LICENSING.md](../../LICENSING.md); see "Licensing"): the deck stays visible and every note opens and can be read, searched and exported; the text is not editable, the hotkey and `+` fan the deck instead of creating, archive and the swatches are off, and the open note's footer says why. Nothing the user wrote is ever hidden or changed.

## Capture

The global hotkey (default ⌥⌘N; Settings: rebindable through Carbon's `RegisterEventHotKey`, so no permission; never `⌘Q`, `⌘Tab`, `⌘Space`, a bare `⇧`, or an `Fn`/Globe combination) creates a note in the deck and opens it for writing from any app, full-screen ones included. Escape saves and slides it back. An empty new note is not kept: Escape on a note with no text removes it.

## Notes

- A note is one `.md` file: YAML front matter (`color`, `face` or `font`, `size`, `pinned`, `archived`, `order`, `created`, `modified`), then the text. `color` is a preset's name or a picked colour as `"#RRGGBB"`; `face` is one of `sans`, `serif`, `mono` (as 0.1.0 wrote it), `font` a family name in quotes (`font: "Georgia"`), `size` a point size 10–24; a note without `face`, `font` or `size` takes the defaults in Settings → Notes, and a file carrying both `face` and `font` keeps the font. A value that isn't ours (a colour name or hex the app doesn't know) leaves the note on the default paper and the file untouched. The first line is the title (a leading `# ` is not shown as such). While a new note is being written its file has a provisional name (`note-20260916-1030.md`); when the note first closes the file takes the title's name (`groceries.md`, `groceries-2.md`; the provisional one stays when there is no title) and is never renamed afterwards, so iCloud Drive, Obsidian and git see one stable file.
- Saved 250 ms after typing stops, on every close, before sleep, when the app resigns active and at quit. Outside edits are picked up by a folder watcher (FSEvents) and by a rescan when the app becomes active. Every write is a transaction: the existing file is opened (never through a link), hashed in full through that descriptor and compared with what was last read or written; the replacement is created exclusively when the file is absent, or swapped in atomically with the displaced file checked to be the very one verified — an outside edit that lands at any point, before the check or between the check and the swap, is never overwritten: the file keeps it, and the user's text becomes its own note beside it, `<name> (conflict <date-time>).md` (unique; never over an existing file), which the open note switches to so typing continues. A save that fails (the folder gone, the disk full) keeps the text in the app, says so in the footer and retries every few seconds; a folder switch or a quit with unsaved text that cannot be written is held until it can (Try Again / Keep Editing). The app never deletes a file, except a brand-new empty note's own file: opened under its name, verified to be the same inode with the same content the app wrote, then unlinked by name (never recursively — a folder or a different file that took the name is left alone).
- Budgets: a file over 1 MB is shown from its beginning (64 KB), read-only, and never written; note bodies are kept in memory up to 8 MB in total — beyond that the least recently used ones keep their first kilobyte (title and preview) and are read back when opened, searched or exported, never while open or unsaved; styling covers the first 64 000 characters of a note, the rest is plain.
- Paste is plain text. Smart quotes, smart dashes and text replacement are off in every note.
- Markdown-lite, styled live without changing a character: `#`, `##`, `###` headings, `**bold**`, `_italic_` / `*italic*`, `` `code` ``, `- ` / `* ` / `1. ` lists, `- [ ]` / `- [x]` checklists (a click on the box toggles it, `[ ]` ↔ `[x]` in the file), links underlined (below). Markers stay visible, dimmed. Nothing else is interpreted.
- Links: `http(s)://`, `www.`, `mailto:`, `file:///` and `~/…` paths underline live (a styled run, not stored; never inside a code span; the sentence's trailing punctuation and an unmatched closing bracket stay text, so `[text](https://…)` keeps working). ⌘-click, or ⌥⏎ with the caret on the link, opens it through the system (`NSWorkspace`); a plain click places the caret. While the pointer rests on a link a small chip names its host, mailbox or file name and says ⌘click — nothing is fetched, no network.
- Inline arithmetic: a line ending in `=` (or `= ` and an earlier answer) evaluates the expression before the `=` — after a label of words if there is one (`Hotel 3 * $95 =`; a malformed expression such as `2 + (3 * 4 =` shows nothing, never its valid tail) — and shows the answer after the `=` in the ink's secondary colour, live as you type: `+ - * / ^ ( )`, `×` `÷`, a postfix `%` (`12% of 80`, `80 + 10%`; `10 % 3` is the remainder), thousands separators, `k` / `M` after a number, `$` / `€` / `£` carried into the answer (two decimals for money), `sum` for the amounts on the lines above up to a blank line (each line's trailing expression, or its last number), and the decimal separator of the user's locale in and out. Division by zero shows `÷0`, an answer past 10¹⁵ shows `overflow`, a line that isn't arithmetic shows nothing. **The answer is never written to the file** unless Tab is pressed on that line, which types it after the `=`; an earlier answer that no longer matches is dimmed and struck through, and Tab replaces it. Pure Swift over bounded input (200 characters, 32 levels), never `NSExpression`.
- Fonts: three faces — Sans (Instrument Sans), Serif (the system serif), Mono (IBM Plex Mono) — and every family installed on the Mac (`NSFontManager`'s families, the system-private ones hidden), listed under their localised names, each row set in its own face, searchable. Settings → Notes holds the default font and size for new notes and for any note without its own; the open note's footer menu picks a face, Choose font… (the same list), the size, or Use default, and ⌘⇧M cycles the faces. The fanned tab's title and the All Notes list's title and preview line are set in the note's font at their own sizes. A family named in a file that isn't installed here renders in the default with a "isn't installed on this Mac" line in the footer; the file keeps the name, so the note comes back in it on a Mac that has the font (the iCloud Drive case). Bold and italic come from the family's own members through the font manager; a face without an italic is slanted. Code spans and checkboxes sit on the note's own grid when its font is monospaced.
- Colours: 13 preset papers — coral, yellow, butter, mint, sage, sky, lagoon, lilac, rose, sand, slate, graphite, paper (every 0.1.0 name kept) — and Custom…, the system colour panel with its eyedropper. Each paper is tuned for both appearances: a light face with ink text, and in Dark Mode a deep face of the same hue, still saturated, so the tab, the open note and the All Notes bar read as one colour there too; the ink is neutral/950 or neutral/0, whichever reads at 4.5:1 or better (Graphite and a deep custom colour take the paper ink in both; a midtone neither reaches takes pure black or white); markers and metadata take the ink's softer shade at 3:1 or better (the body ink faded towards the paper when the shade falls short), links and ticked boxes the coral shade of the ink's polarity that reads at 4.5:1, else 3:1, else the ink. A custom colour is the Light Mode paper; its Dark Mode paper is derived (same hue, saturation 45–70 %, lightness stepped down until the ink reads at 5:1) and its inks chosen the same way. New notes: Settings → Notes → New notes is **Random** (fresh installs, and anyone who never chose one) — a preset that differs from the last note created and from the notes the new one lands between in the deck, chosen by the deck's state so the same deck gives the same paper — or one fixed colour. The pill's dash and the menu's swatches keep the light face in both appearances.
- Pinned notes come first in the deck and are never auto-archived.
- **The welcome note:** the first launch into a folder with no notes writes one note of the app's own, `welcome.md` ("Welcome to OpenNotes", yellow, unpinned, order 0): a short tour of exactly the Markdown above — a `##` and a `###` heading, `**bold**`, `_italic_`, `` `code` ``, a URL, `- ` and `1. ` lines, a `- [ ]` and a `- [x]` box — and of the hotkey, the edge, the footer, archive with undo, drag to reorder and All Notes, every line true for the build that wrote it. Exactly once: decided on the launch that first reads the folder and never revisited, so a welcome the user archived or deleted is not written again, a folder chosen later with notes in it gets none, and neither does an upgrade (the decision is fresh-install evidence like every other first-run flag). It is the one file the app writes without asking the license: a first launch is a fresh install, and a fresh install is in its trial. From then on it is the user's note like any other.
- Archive, not delete: ⌘⇧A or the footer moves a note out of the deck (`archived: true` in the file); a toast in the deck offers Undo for 10 s. Archived notes stay in the folder, in search, and in All Notes → Archived, where Restore brings one back. Auto-archive (Settings → Notes: off, 7, 30 or 90 days) archives unpinned notes untouched for that long, at launch and then whenever the next note falls due (nothing runs while it is off). Deleting a file is the Finder's job.

## All Notes

⌥⌘L, the menu-bar item or the deck's fan footer opens one window on the app's canvas, split by a hairline. The sidebar: a search field (titles and text, case- and diacritic-insensitive, live) with the count of the notes shown inside it; Active / Archived as two chips, the chosen one in the accent's tint; the list, one row per note with the note's color as a dash like the pill's, the title (a pin glyph after a pinned one), the age in proportional type, and the text after the title as one line in the note's own face with the markers gone; drag to reorder the active list, which writes `order` to the files — the same write a drag on the deck's tabs makes. The chosen row is a tint of the accent, a hovered one the surface; never the system highlight. The preview pane: a small uppercase caption for the state (Active · in the deck / Pinned · in the deck / Archived) with the trial pill at its far end while the license has something to say; the actions as chips — Open (Restore for an archived note) filled with the accent, then Pin / Unpin, Archive, Export… (`.md` as saved without the front matter, or `.txt` with the markers stripped) and Reveal in Finder as quiet surface chips with a glyph, which keep only the glyph when the pane is narrow; and the note as its own paper — the same face color, ink, 12 pt corner and contact shadow as the docked card, at most 600 pt wide, with a footer band inside it (created, edited, the file name, and whether the file is shown in part; the face at its end). Nothing is full-bleed and no system blue appears. With nothing to show, the pane says why (No notes yet / Nothing archived / No matches) in two quiet lines. Export and Reveal work in read-only too; Pin, Archive, Restore and reordering wait for a license, and the license card in the sidebar, above the list it gates, says so.

## Keyboard

| Keys | Does |
| --- | --- |
| ⌥⌘N (rebindable) | New note, from any app |
| ⎋ | Save and slide the note back; collapse the fan |
| ⌘W | Save and open the next note in the deck; the last one slides back |
| ⌘⇧A | Archive the open note (Undo for 10 s) |
| ⌘⇧P | Pin / unpin the open note |
| ⌘⇧M | The open note's next face: Sans → Serif → Mono → Sans (a note in a chosen family goes to Sans) |
| ⌥⌘↑ / ⌥⌘↓ | Move the open note one slot up / down the deck (inside its pinned or unpinned group) |
| ⌥⌘L | All Notes |
| ⌘, | Settings |
| ⇥ on an `=` line | Types the answer into the note |
| ⌘-click, ⌥⏎ on a link | Opens the link |

## Automation

Every entry point is an action (LICENSING.md): a write asks the projected license at that moment and, refused, writes nothing. A refused link shows a note-shaped card beside the deck — "Waits for a license", the read-only line, Settings → License from it — for ten seconds or until clicked; a refused Shortcuts action fails with the same read-only line. Reading never waits.

URL scheme, registered in `Info.plist` (`CFBundleURLTypes`) in every build but the update-test variant; parameters are percent-decoded, `+` is a `+`; a text over 100 000 characters or a title over 1 000 is refused at the door (a link is dropped, an action fails saying so):

| Link | Does |
| --- | --- |
| `opennotes://new?text=…&title=…&color=…` | Creates a note with the text (the title, when given, becomes its first line; `color` a preset's name or `#RRGGBB`, else the default — Settings' fixed colour or the random pick), written and named as a note closing would (front matter as the app writes it), and slides it out of the deck. Without text: the hotkey's empty note, focused |
| `opennotes://open?title=…` | Slides out the note the title names: the first whose title is the query (case- and diacritic-insensitive), else starts with it, else contains it — active notes in deck order first, then archived (an archived match opens All Notes) |
| `opennotes://append?title=…&text=…` | Appends the text as a line to that note (saved at once); creates a note with that title and text when none matches |
| `opennotes://activate?key=…` | Pre-fills a license key (see "Licensing") |

Shortcuts, Spotlight and Siri: App Intents in the app itself (no extension), the module `OpenNotesIntents`, guarded by `#if canImport(AppIntents)` so a source build on an older toolchain still builds; `scripts/bundle.sh` extracts their metadata for Shortcuts. A read-only refusal, a missing note or an empty text is the action's error.

| Action | Parameters | Returns |
| --- | --- | --- |
| Create Note | Text (required, multiline), Title (optional), Color (optional: one of the 13 preset papers) | The note's file (URL) |
| Append to Note | Title (required), Text (required, multiline) | — |
| Get Note Text | Title (required) | The note's whole text — an error, never a part, when the body can't be read or the file is over 1 MB |
| Open Note | Title (required) | — |

"Create a note in OpenNotes" and "Open a note in OpenNotes" are offered as App Shortcuts. Titles match as for `open`.

## Menu bar

A template sticky symbol; the menu: New Note, Show Deck / Hide Deck, All Notes…, Settings…, Quit. No Dock icon. Opening the app again from Finder or Spotlight opens All Notes.

## Settings

| Section | Behavior |
| --- | --- |
| General | Open at login (on once on a fresh install, `SMAppService`, approval state shown; the user can turn it off); Deck side (right / left); Display (the main display; the display with the pointer — the deck moves when the pointer reaches another display's edge, never while a note is open; every display); Hotkey (the recorder; a taken or refused key says so); Notes folder (the path and Choose…; unsaved text is written to the old folder first, and the switch waits if it can't be; files are never moved) |
| Notes | Default font (Sans / Serif / Mono, or any installed family from the searchable list) and Size (10–24 pt), for new notes and any note without its own; New notes (Random, or a fixed preset or custom colour, the same swatch grid and Custom… as the note's menu); Auto-archive untouched notes (off / 7 / 30 / 90 days) |
| License (official builds) | The shared section ([LICENSING.md](../../LICENSING.md)): state, Buy a license (opens the website; never a price), paste a key, Remove this Mac (confirmed); storage and journal problems named; a key from the `opennotes://activate` link waits for Activate; the trial pill in the title bar |
| Updates | The shared section ([RELEASES.md](../../RELEASES.md)): Check for updates automatically (on once for a fresh install), Download and install automatically (off until turned on), the status with Check Now / Install and Restart / Restart to Update / Try Again, "Move OpenNotes to Applications to enable updates"; a source build says it has no updater |
| About | What OpenNotes reads (the notes folder) and where it goes (nowhere; the only network calls are the license check, the trial registry and the update check, named per flavour, none in a source build); MIT; Show setup guide; Copy Diagnostics (version, login state, side, display, hotkey and its problem, folder path, note counts, watcher state, the build's licensing flavour and where the license stands, never the key) |

## Defaults and recovery

| Situation | Behavior |
| --- | --- |
| Fresh install (no earlier preferences, both records positively absent) | Open at login and Check for updates automatically are turned on once, after storage answers, each under its own flag; never revisited. With no earlier preferences and an empty notes folder, the welcome note is written once, under its own flag (see "Notes") |
| The notes folder is missing | Created on launch (the default under Documents); a chosen folder that has gone (an unmounted volume) shows one note-shaped message in the deck, "Can't find the notes folder", with Choose… in Settings; nothing is created elsewhere |
| A file can't be parsed | Front matter that isn't ours is left alone; the whole file is the text and the note takes the defaults. It is saved back only if the user edits it, and then with front matter |
| A file names a font that isn't installed | Shown in the default font, the footer says which font is missing; the file keeps the name |
| A save fails | The note stays open with its text, the footer says "Couldn't save" and why, the next keystroke retries |
| An outside edit lands while the note is open and unedited | The text updates in place, the caret kept where the text allows |
| An outside edit lands while the note has unsaved edits | The file keeps theirs; ours continues as `<name> (conflict <time>).md`, the open note switches to it, the footer says so once |
| A save fails (folder gone, disk full, the path is now a folder) | The text stays in the app, dirty; the footer says why; retried every 5 s and on the next keystroke; a folder switch or quit waits (Try Again / Keep Editing) |
| A file over 1 MB | Shown truncated and read-only; never written |
| The system refuses a rename in the middle of a write (a full disk, a provider hiccup) | Nothing is deleted: every version stays on disk under some name (the outside version as `<name> (conflict …).md`, or in a hidden temporary that the next folder read gives a `<name> (recovered …).md` name), the footer says so, and the note is read again before it is written again |
| Hotkey taken by another app | Settings → General shows "⌥⌘N is taken by another app" under the recorder; the menu-bar item still creates notes |
| The display hosting the deck goes away | The deck moves to the next host by the Display setting; an open note is saved first |
| Read-only (trial ended, license needed) | See "Licensing": visible, readable, searchable, exportable; nothing changed, nothing new |

No permissions, no accounts, no telemetry. Diagnostics are copied only on request and only to the pasteboard. The privacy copy every licensed app ships (LICENSING.md, "Privacy copy") is OpenNotes' too.

## Licensing

Official builds follow [LICENSING.md](../../LICENSING.md): a 3-day trial from the first launch, no signup, one license for 3 Macs, bought on the website (the app never states a price). OpenNotes' core feature is writing notes, and the restriction is **read-only**, decided with the user: while the trial has ended, a license is revoked, a check is required, the trial can't reach the registry, the clock is behind, or a record can't be read, the deck stays visible and every note stays readable, searchable and exportable — the files are the user's and not one is changed. What waits for a license: creating a note (the hotkey and `+` fan the deck instead), editing text (typing, paste, a checkbox click), renaming (a new note's file keeps its provisional name until it next closes allowed), pin, colour (the swatches, Custom… and every pick the colour panel sends), font and size, archiving and unarchiving (the undo toast included), reordering, auto-archive, and changing the notes folder. The folder watcher keeps reflecting outside edits.

The entitlement is never a stored flag: every action asks the license's projection at that moment, and every continuation asks again — a note closing, the folder panel returning, the auto-archive sweep — and the store asks once more at the file, so no new change is written after a deadline that passed between two renders. Text the user typed while it was allowed is never lost: the store stamps that buffer at the last accepted keystroke, and its flush — the 250 ms save debounce, a close, sleep, quit — is written whatever the license says then (an outside edit meanwhile gets the usual conflict copy). The restriction applies to new edits only; any other change held in memory (a pin on a note that never reached disk) waits for the license, and quit is never held by it (licensing never blocks quitting).

What says so: the pill (the trial's remaining days, or the short reason) at the top of the open note, above All Notes, in the Settings title bar and on the guide's welcome step; the license card above All Notes' list (title, what it means, Buy a license / Enter a key / Try again per state); the open note's footer line with a lock ("Read-only: …; Settings → License"), the lock on the `+` tab, the dimmed swatches, and the status menu's first line — each opens Settings → License. Nothing opens on its own when the trial ends.

## Setup guide

Once, on the first launch of the packaged app (never from `swift run`, never in the update-test variant), and again from Settings → About → Show setup guide, resuming at the furthest step reached: Welcome (what the deck is, the hotkey; the trial line and the pill from the real license state), Nothing to grant (what OpenNotes touches: the notes folder, the pasteboard when pasting; the network calls of this flavour), Your notes are files (the folder in use, iCloud Drive or an Obsidian vault as the folder, Open Settings), Starts with your Mac (the login item from its real state, the switch), Tips (the hotkey, the edge, All Notes, and in official builds where the license lives). Skip for now at any step keeps the progress.

## Out of scope

Rich text, images, fonts that aren't installed on the Mac (nothing is bundled beyond the three faces), a database, our own sync, a notch surface, encryption of the files (FileVault does that), per-app notes, AutoPaste, unit conversion and date arithmetic (the `=` line does numbers only), JavaScript or extensions, OCR, timers, widgets, iPhone. Some are later tickets; none changes the file format.

## Marketing only

At `/opennotes/`: the coral key in the headline, a drawn deck beside the three states, the install block with the one-line command and Copy, Buy, questions, the closing field.

## References

[App README](../../apps/opennotes/README.md) · [Releasing](../../apps/opennotes/RELEASING.md) · [Tokens](../../apps/opennotes/design/tokens.json) · [Licensing](../../LICENSING.md) · [Hertz contract](hertz.md) (the shared surface this one mirrors).
