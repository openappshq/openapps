import Foundation

/// The one note the app writes on its own: `welcome.md`, once, on the
/// first launch into a folder with no notes, so the first thing in the
/// deck shows what a note can hold (design/products/opennotes.md,
/// "Notes"). Every line is styled exactly as the text says — the markers
/// are `MarkdownLite`'s, the `=` line `Arithmetic`'s, nothing invented —
/// and every gesture, font, colour, folder and link named is the app's. The user's from then on: edited, moved, archived or deleted, it
/// is never written again.
nonisolated public enum WelcomeNote {
    public enum Key {
        /// Decided on the launch that first read the folder: written or
        /// found unnecessary, and never revisited (a folder emptied later
        /// gets no second welcome).
        public static let decided = "notes.welcomeDecided"
    }

    public static let id = NoteID("welcome")
    /// Not the default coral, so it stands apart from the first note the
    /// user makes.
    public static let color = NoteColor.yellow

    public static let text = """
    Welcome to OpenNotes
    This note is yours: type in it, or archive it once you know the ropes.

    ## Writing
    A note is plain text with a little Markdown, styled as you type:
    - **bold** between two stars, _italic_ between underscores
    - `code` between backticks
    - a link, https://openapps.space/opennotes/ — ⌘-click opens it
    - a list line starts with a dash, a star or a number
    1. numbered lines look like this
    - [ ] a checkbox: click the box to tick it; the tab counts the boxes
    - [x] a ticked one
    - a line that ends in = shows its answer; press Tab on it to keep the answer:
    Hotel 3 * $95 =

    ### Headings
    One to three # and a space at the start of a line make a heading. The first line is the note's title and, once, names its file.

    ## The deck
    - Press the hotkey anywhere (⌥⌘N, or the one you chose in Settings) for a new note; Escape saves it and slides it back.
    - Rest the pointer on the screen edge to fan the deck out; click a tab to open a note. Drop text, a link or files on the deck to make a note of them.
    - Drag a tab up or down the deck to reorder your notes; ⌥⌘↑ and ⌥⌘↓ move the open note from the keyboard.
    - The footer: a colour for the note (thirteen papers, or one of your own), a font (Sans, Serif, Mono or any on your Mac; ⌘⇧M cycles the faces), pin to keep it first (⌘⇧P), archive with ten seconds to undo (⌘⇧A).
    - ⌥⌘L opens All Notes: search, Active and Archived, Export, Reveal in Finder.

    ## Your files
    Every note is a Markdown file in your notes folder, yours to open in any other app: on this Mac, in iCloud Drive so every Mac signed in sees the same notes, or any folder you pick (Settings → General). Other apps and Shortcuts can make notes too — the link opennotes://new?text=hello, and the actions Create Note, Append to Note, Get Note Text and Open Note.
    """

    /// The note as first written: order 0 and unpinned, so it sits on top
    /// until the user makes a note (which takes one below the lowest order).
    public static func note(created: Date) -> Note {
        Note(id: id, text: text, color: color, typeface: .face(.sans), pinned: false, order: 0, created: created)
    }

    /// Whether the folder just read is one to welcome into: empty of notes
    /// (a chosen folder that already has some is somebody's, and gets
    /// nothing), decided once. The launch that finds the folder missing
    /// decides nothing and asks again next time.
    public static func shouldCreate(flags: any FlagStore, folderIsMissing: Bool, hasNotes: Bool) -> Bool {
        guard !flags.bool(forKey: Key.decided), !folderIsMissing else { return false }
        flags.set(true, forKey: Key.decided)
        return !hasNotes
    }
}
