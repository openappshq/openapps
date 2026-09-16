# OpenNotes

Sticky notes kept as a deck docked to the edge of the screen: a thin pill at rest, a fan of tabs when the pointer reaches the edge, one note slid out to write in. Every note is a plain Markdown file in a folder the user can see; nothing else stores it.
Open source under MIT; the official build is paid on the same terms as every OpenApps HQ app ([LICENSING.md](../../LICENSING.md): 3-day in-app trial, no signup, one license for 3 Macs). Installed with one Terminal line or Homebrew; the official build checks a signed feed for updates once a day and installs one only when the user says so ([RELEASES.md](../../RELEASES.md)).

Primary task: press the hotkey anywhere, type, press Escape. The note is on the edge and in the folder.

## Identity

Signature color: coral (`coral/300` tile face, `coral/500` shade, `coral/700` / `coral/300` accent in light / dark) — a sticky that is not HQ's yellow. The ramp is derived for OpenNotes and recorded in [`apps/opennotes/design/tokens.json`](../../apps/opennotes/design/tokens.json) with its contrast checks; `coral/300` never carries text on a light ground.
The mark is a square sticky with its bottom-right corner folded up, in ink; the app icon is the same sticky on a coral tile.
Type follows the shared system: Bricolage Grotesque for window headings, Instrument Sans for interface text and the sans note face, IBM Plex Mono for labels, the "Saved" line and the mono note face.
The deck, the note card and the All Notes window are flat surfaces with one contact shadow on the open note; no glass (a translucent sticky reads as a sheet of paper, not a note).

## The deck

One deck per hosted display, docked to the **right** edge (Settings: left), vertically centred on the visible frame, above every window including full-screen apps and Stage Manager stages, on every Space. It never takes focus from the app in front until the user starts writing in a note.

| State | Looks like | Enters | Leaves |
| --- | --- | --- | --- |
| Pill | A 14 pt strip on the edge, one dash per active note in the note's color, rounded ends; 8 dashes at most, a dot for "more" | Launch; the fan collapsing; Escape or a click outside an open note | The pointer reaching the edge for 120 ms |
| Fan | Tabs shingled down the edge, 40 pt wide, one per active note (8 at most, then "+N"), the title reading down the tab in the note's color; a `+` tab at the end | The pill, after the pointer has rested on the edge; the hotkey while read-only; an open note closing | The pointer leaving the edge and the deck for 350 ms; a tab click; Escape |
| Open | One note slid out of the deck as a 320 × 360 pt card next to its tab; the other tabs stay as the fan | A tab click; the hotkey (a new note, focused); ⌘W from another open note (the next one); "Open" in All Notes | Escape (saves, slides back to the fan); a click outside; the hotkey again; ⌘W with no next note; Archive |
| Editing | The open note with the keyboard focus (the app is active, the caret in the text) | A click in the text; the hotkey's new note | Escape; a click outside |

Rules:

- Hover opens the fan, and only the fan: a note never opens on its own.
- The open note stays open while the pointer is elsewhere; only Escape, a click outside, the hotkey, Archive or ⌘W close it. Closing always saves.
- Every change of state is one movement (180 ms, ease-out); Reduce Motion makes them instant.
- The deck reads the notes folder (`~/Documents/OpenNotes`, iCloud Drive, or any folder; see "Storage") and shows what is there, so a note written by another app appears within a second.
- **Read-only** (after the trial, [LICENSING.md](../../LICENSING.md); see "Licensing"): the deck stays visible and every note opens and can be read, searched and exported; the text is not editable, the hotkey and `+` fan the deck instead of creating, archive and the swatches are off, and the open note's footer says why. Nothing the user wrote is ever hidden or changed.

## Capture

The global hotkey (default ⌥⌘N; Settings: rebindable through Carbon's `RegisterEventHotKey`, so no permission; never `⌘Q`, `⌘Tab`, `⌘Space`, a bare `⇧`, or an `Fn`/Globe combination) creates a note in the deck and opens it for writing from any app, full-screen ones included. Escape saves and slides it back. An empty new note is not kept: Escape on a note with no text removes it.

## Notes

- A note is one `.md` file: YAML front matter (`color`, `face`, `pinned`, `archived`, `order`, `created`, `modified`), then the text. The first line is the title (a leading `# ` is not shown as such). While a new note is being written its file has a provisional name (`note-20260916-1030.md`); when the note first closes the file takes the title's name (`groceries.md`, `groceries-2.md`; the provisional one stays when there is no title) and is never renamed afterwards, so iCloud Drive, Obsidian and git see one stable file.
- Saved 250 ms after typing stops, on every close, before sleep, when the app resigns active and at quit. Outside edits are picked up by a folder watcher (FSEvents) and by a rescan when the app becomes active. Every write is a transaction: the existing file is opened (never through a link), hashed in full through that descriptor and compared with what was last read or written; the replacement is created exclusively when the file is absent, or swapped in atomically with the displaced file checked to be the very one verified — an outside edit that lands at any point, before the check or between the check and the swap, is never overwritten: the file keeps it, and the user's text becomes its own note beside it, `<name> (conflict <date-time>).md` (unique; never over an existing file), which the open note switches to so typing continues. A save that fails (the folder gone, the disk full) keeps the text in the app, says so in the footer and retries every few seconds; a folder switch or a quit with unsaved text that cannot be written is held until it can (Try Again / Keep Editing). The app never deletes a file, except a brand-new empty note's own file: opened under its name, verified to be the same inode with the same content the app wrote, then unlinked by name (never recursively — a folder or a different file that took the name is left alone).
- Budgets: a file over 1 MB is shown from its beginning (64 KB), read-only, and never written; note bodies are kept in memory up to 8 MB in total — beyond that the least recently used ones keep their first kilobyte (title and preview) and are read back when opened, searched or exported, never while open or unsaved; styling covers the first 64 000 characters of a note, the rest is plain.
- Paste is plain text. Smart quotes, smart dashes and text replacement are off in every note.
- Markdown-lite, styled live without changing a character: `#`, `##`, `###` headings, `**bold**`, `_italic_` / `*italic*`, `` `code` ``, `- ` / `* ` / `1. ` lists, `- [ ]` / `- [x]` checklists (a click on the box toggles it, `[ ]` ↔ `[x]` in the file), URLs underlined. Markers stay visible, dimmed. Nothing else is interpreted.
- Two faces: Sans (Instrument Sans) and Mono (IBM Plex Mono); a default in Settings, and the open note's footer switches its own note.
- Six colors: coral, yellow, mint, sky, lilac, paper. The default is coral (Settings). Colors follow the appearance: a light face with ink text, a deep face with paper text in Dark Mode; the tab and the pill dash keep the light face in both.
- Pinned notes come first in the deck and are never auto-archived.
- Archive, not delete: ⌘⇧A or the footer moves a note out of the deck (`archived: true` in the file); a toast in the deck offers Undo for 10 s. Archived notes stay in the folder, in search, and in All Notes → Archived, where Restore brings one back. Auto-archive (Settings → Notes: off, 7, 30 or 90 days) archives unpinned notes untouched for that long, at launch and then whenever the next note falls due (nothing runs while it is off). Deleting a file is the Finder's job.

## Storage

Every note is a plain `.md` file in one folder; the folder is the only store, and where it is is a choice — Settings → General → Notes folder, and the setup guide's files step, offer the same three:

| Choice | Folder | Notes |
| --- | --- | --- |
| On this Mac (default) | `~/Documents/OpenNotes` | Created when missing |
| iCloud Drive | `~/Library/Mobile Documents/com~apple~CloudDocs/OpenNotes`, shown in Finder as iCloud Drive › OpenNotes | Created when missing; offered only while iCloud Drive's root exists on the Mac, else the row says "Sign in to iCloud Drive in System Settings". Any Mac signed in to the same iCloud, and any iOS Markdown app that opens iCloud Drive, sees the same files |
| Other folder… | Any folder the user picks (an Obsidian vault) | Never created by the app |

Nothing beyond the folder path is stored: the choice is read off the path (a chosen folder that happens to be one of the two built-in paths reads as that choice; any other reads as "Other folder"). Switching **copies** every note file to the new folder and then reads the new folder; nothing is ever moved or deleted from the old one. A file already in the new folder with the same content is left alone; one with different content keeps its content and ours goes beside it as `<name> (conflict <time>).md`; a placeholder in the new folder is a file whose content is not here to compare, and ours goes beside it the same way (a placeholder is never written over, not even by the copy); a note iCloud has not downloaded in the old folder has nothing to copy yet and is said so. Unsaved text is written to the old folder first, and the switch waits if it can't be (as any folder change); while read-only the switch waits for a license. What the switch did is one line under the choice until the next switch.

iCloud Drive is used as a folder, through the file system alone — no CloudKit, no ubiquity container, no entitlement (the app ships self-signed), no sync of our own. What iCloud shows on disk and what the app does with it:

| iCloud does | OpenNotes does |
| --- | --- |
| Leaves a placeholder (`.<name>.md.icloud`) for a file it has not downloaded | The note is in the deck and All Notes under its file name, greyed as not downloaded; opening it asks iCloud for the file (`startDownloadingUbiquitousItem`) and shows "Downloading…" until it arrives. A placeholder is never written over and never counts as a deleted note |
| Evicts a file the app holds (the file becomes a placeholder while the note is open or has unsaved text) | The text in memory is the note; a save finds the placeholder, asks for the download, keeps the text dirty and retries as any failed save ("waiting for iCloud" in the footer). When the file is back unchanged the save goes through; changed, it gets the usual conflict copy |
| Replaces a file by rename when a change arrives (a new inode, every time) | A file's identity is its **content**: the write transaction hashes the bytes behind the descriptor and compares them with what was last read or written, whatever inode holds them; the inode it verified is what the swap is checked against. So a file iCloud re-delivered unchanged is the same file, and one it changed gets the conflict copy |
| Keeps versions it could not merge (two Macs wrote the file) as `NSFileVersion` conflict versions | Each unresolved version is kept as `<name> (conflict from <device> <time>).md` beside the file — the same shape as our own conflict copies, never over an existing file or placeholder — and only then marked resolved. A version whose bytes are the file's at the moment of the comparison (the version is read first, the file hashed after it) is only resolved; a write landing between that comparison and the resolution is the one window left, and what it wrote is the file. Keeping a version is a write: the license is asked before the version is read, again after it (the read takes time) and once more at the file; while read-only nothing is written and nothing resolved, the versions are counted in the status line ("n conflict versions wait for a license") and written out once writing is allowed. A version that cannot be read or kept stays with iCloud, is named in the status line, and is tried again on the next rescan |
| Shows a file missing for an instant during a swap | A file a rescan does not find is removed from the deck only once a later rescan, half a second or more later, still does not find it (the app rescans again within a second to confirm); an unsaved or new note is never dropped for its file |
| Brings files in without a file event, sometimes | Besides the FSEvents watcher and the rescan on activation, the folder is read again every 30 s while it is iCloud's (`isUbiquitousItem`: the iCloud Drive folder, or Desktop & Documents kept in iCloud) |

Status: while the folder is iCloud's, All Notes' footer and the open note's "Saved" line say "In iCloud Drive · all notes on this Mac / n not downloaded / downloading n of m / waiting for iCloud / n conflict versions wait for a license", or the problem iCloud reported (a refused download, a version that could not be kept); Diagnostics includes the storage choice and that state. Only what the file system shows is claimed: whether iCloud has finished uploading a file is not observed, so nothing is said about the other Macs. A refused download is asked for again on the next open and on every rescan; a write the store could not settle cleanly (every version on disk under some name) is said in the note's footer, All Notes and Settings until the next write goes through.

## All Notes

⌥⌘L, the menu-bar item or the deck's fan footer opens one window: a search field (titles and text, case- and diacritic-insensitive, live), Active / Archived, a list (color bar, title, first line, age; drag to reorder the active list, which writes `order` to the files) and a preview pane with Open, Pin / Unpin, Archive / Restore, Export… (`.md` as saved without the front matter, or `.txt` with the markers stripped), Reveal in Finder. Export and Reveal work in read-only too; Pin, Archive, Restore and reordering wait for a license, and the license card above the list says so.

## Keyboard

| Keys | Does |
| --- | --- |
| ⌥⌘N (rebindable) | New note, from any app |
| ⎋ | Save and slide the note back; collapse the fan |
| ⌘W | Save and open the next note in the deck; the last one slides back |
| ⌘⇧A | Archive the open note (Undo for 10 s) |
| ⌘⇧P | Pin / unpin the open note |
| ⌘⇧M | Switch the open note between Sans and Mono |
| ⌥⌘L | All Notes |
| ⌘, | Settings |

## Menu bar

A template sticky symbol; the menu: New Note, Show Deck / Hide Deck, All Notes…, Settings…, Quit. No Dock icon. Opening the app again from Finder or Spotlight opens All Notes.

## Settings

| Section | Behavior |
| --- | --- |
| General | Open at login (on once on a fresh install, `SMAppService`, approval state shown; the user can turn it off); Deck side (right / left); Display (**every display** on a fresh install, decided once from the preferences alone and never revisited — an install with earlier preferences keeps the main display it had; the main display; the display with the pointer — the deck moves when the pointer reaches another display's edge, never while a note is open); Hotkey (the recorder; a taken or refused key says so); Notes folder (On this Mac / iCloud Drive / Other folder…, see "Storage": switching copies the notes and never moves a file; unsaved text is written to the old folder first, and the switch waits if it can't be; Change… for another folder) |
| Notes | Face (Sans / Mono) for new notes; Color for new notes; Auto-archive untouched notes (off / 7 / 30 / 90 days) |
| License (official builds) | The shared section ([LICENSING.md](../../LICENSING.md)): state, Buy a license (opens the website; never a price), paste a key, Remove this Mac (confirmed); storage and journal problems named; a key from the `opennotes://activate` link waits for Activate; the trial pill in the title bar |
| Updates | The shared section ([RELEASES.md](../../RELEASES.md)): Check for updates automatically (on once for a fresh install), Download and install automatically (off until turned on), the status with Check Now / Install and Restart / Restart to Update / Try Again, "Move OpenNotes to Applications to enable updates"; a source build says it has no updater |
| About | What OpenNotes reads (the notes folder) and where it goes (nowhere; the only network calls are the license check, the trial registry and the update check, named per flavour, none in a source build); MIT; Show setup guide; Copy Diagnostics (version, login state, side, display, hotkey and its problem, folder path, the storage choice and iCloud's state, note counts, watcher state, the build's licensing flavour and where the license stands, never the key) |

## Defaults and recovery

| Situation | Behavior |
| --- | --- |
| Fresh install (no earlier preferences, both records positively absent) | Open at login and Check for updates automatically are turned on once, after storage answers, each under its own flag; never revisited. Display is set to every display once, from the preferences alone (no storage answer needed), under its own flag |
| The notes folder is missing | Created on launch (the default under Documents, and the iCloud Drive folder); a chosen folder that has gone (an unmounted volume) shows one note-shaped message in the deck, "Can't find the notes folder", with the choice in Settings; nothing is created elsewhere |
| A note's file is an iCloud placeholder | Shown greyed under its file name; opening asks iCloud for it ("Downloading…"); never written over, never treated as deleted (see "Storage") |
| A file is evicted by iCloud while the note has unsaved text | The text stays in the app; the save asks for the download, says "waiting for iCloud" and retries; back unchanged, saved; back changed, the conflict copy |
| iCloud left conflict versions of a file | Each becomes `<name> (conflict from <device> <time>).md` beside the file and is marked resolved |
| A file is missing for an instant (a sync tool's rename) | Not a delete: the note goes only once a later rescan, after the grace, still finds no file |
| A file can't be parsed | Front matter that isn't ours is left alone; the whole file is the text and the note takes the defaults. It is saved back only if the user edits it, and then with front matter |
| A save fails | The note stays open with its text, the footer says "Couldn't save" and why, the next keystroke retries |
| An outside edit lands while the note is open and unedited | The text updates in place, the caret kept where the text allows |
| An outside edit lands while the note has unsaved edits | The file keeps theirs; ours continues as `<name> (conflict <time>).md`, the open note switches to it, the footer says so once |
| A save fails (folder gone, disk full, the path is now a folder) | The text stays in the app, dirty; the footer says why; retried every 5 s and on the next keystroke; a folder switch or quit waits (Try Again / Keep Editing) |
| A file over 1 MB | Shown truncated and read-only; never written |
| The system refuses a rename in the middle of a write (a full disk, a provider hiccup) | Nothing is deleted: every version stays on disk under some name (the outside version as `<name> (conflict …).md`, or in a hidden temporary that the next folder read gives a `<name> (recovered …).md` name), the footer, All Notes and Settings say so until the next write goes through, and the note is read again before it is written again. Giving a hidden temporary its visible name is a write: while read-only it stays in place, counted in the status line ("n recovered versions wait for a license"), and it never takes a name a file or an iCloud placeholder holds |
| The notes folder's path is swapped for a link to another directory after it was loaded | Nothing is written, renamed or unlinked there, not even bytes that match: the folder's real path is recorded when it is loaded or switched to, every write checks it still leads there ("The notes folder … now leads somewhere else"), and choosing the folder again takes the new path. A folder that is a link from the start is followed, as the user named it |
| A brand-new empty note is discarded while another writer replaces its provisional file | Known limit: the file is verified (same inode, same bytes) through its descriptor and then unlinked by name; a replacement that lands between the check and the unlink is removed. The window is between two system calls on one file the app itself created a moment ago; no other file is ever unlinked |
| Hotkey taken by another app | Settings → General shows "⌥⌘N is taken by another app" under the recorder; the menu-bar item still creates notes |
| The display hosting the deck goes away | The deck moves to the next host by the Display setting; an open note is saved first |
| Read-only (trial ended, license needed) | See "Licensing": visible, readable, searchable, exportable; nothing changed, nothing new; the storage choice waits for a license |

No permissions, no accounts, no telemetry. Diagnostics are copied only on request and only to the pasteboard. The privacy copy every licensed app ships (LICENSING.md, "Privacy copy") is OpenNotes' too.

## Licensing

Official builds follow [LICENSING.md](../../LICENSING.md): a 3-day trial from the first launch, no signup, one license for 3 Macs, bought on the website (the app never states a price). OpenNotes' core feature is writing notes, and the restriction is **read-only**, decided with the user: while the trial has ended, a license is revoked, a check is required, the trial can't reach the registry, the clock is behind, or a record can't be read, the deck stays visible and every note stays readable, searchable and exportable — the files are the user's and not one is changed. What waits for a license: creating a note (the hotkey and `+` fan the deck instead), editing text (typing, paste, a checkbox click), renaming (a new note's file keeps its provisional name until it next closes allowed), pin, color and face, archiving and unarchiving (the undo toast included), reordering, auto-archive, and changing the notes folder. The folder watcher keeps reflecting outside edits.

The entitlement is never a stored flag: every action asks the license's projection at that moment, and every continuation asks again — a note closing, the folder panel returning, the auto-archive sweep — and the store asks once more at the file, so no new change is written after a deadline that passed between two renders. Text the user typed while it was allowed is never lost: the store stamps that buffer at the last accepted keystroke, and its flush — the 250 ms save debounce, a close, sleep, quit — is written whatever the license says then (an outside edit meanwhile gets the usual conflict copy). The restriction applies to new edits only; any other change held in memory (a pin on a note that never reached disk) waits for the license, and quit is never held by it (licensing never blocks quitting).

What says so: the pill (the trial's remaining days, or the short reason) at the top of the open note, above All Notes, in the Settings title bar and on the guide's welcome step; the license card above All Notes' list (title, what it means, Buy a license / Enter a key / Try again per state); the open note's footer line with a lock ("Read-only: …; Settings → License"), the lock on the `+` tab, the dimmed swatches, and the status menu's first line — each opens Settings → License. Nothing opens on its own when the trial ends.

## Setup guide

Once, on the first launch of the packaged app (never from `swift run`, never in the update-test variant), and again from Settings → About → Show setup guide, resuming at the furthest step reached: Welcome (what the deck is, the hotkey; the trial line and the pill from the real license state), Nothing to grant (what OpenNotes touches: the notes folder, the pasteboard when pasting; the network calls of this flavour), Your notes are files (the storage choice — On this Mac / iCloud Drive / Other folder… — as in Settings, with what switching does), Starts with your Mac (the login item from its real state, the switch), Tips (the hotkey, the edge, All Notes, and in official builds where the license lives). Skip for now at any step keeps the progress.

## Out of scope

Rich text, images, fonts beyond the two faces, a database, our own sync (iCloud Drive is used as a folder; no CloudKit), a notch surface, encryption of the files (FileVault does that), per-app notes, AutoPaste, inline math, OCR, timers, widgets, an iPhone app (any iOS Markdown app can open the iCloud Drive folder). Some are later tickets; none changes the file format.

## Marketing only

At `/opennotes/`: the coral key in the headline, a drawn deck beside the three states, the install block with the one-line command and Copy, Buy, questions, the closing field.

## References

[App README](../../apps/opennotes/README.md) · [Releasing](../../apps/opennotes/RELEASING.md) · [Tokens](../../apps/opennotes/design/tokens.json) · [Licensing](../../LICENSING.md) · [Hertz contract](hertz.md) (the shared surface this one mirrors).
