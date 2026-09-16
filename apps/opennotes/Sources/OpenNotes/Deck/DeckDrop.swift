import AppKit
import OpenNotesCore

/// The pasteboard side of "drop to create" (design/products/opennotes.md,
/// "The deck"): what the deck accepts and how each pasteboard item is
/// sorted into `DropPayload`'s kinds. Files are named, never read or
/// copied; links are taken as written, never fetched.
enum DeckDrop {
    /// Files first, then links, then text: an item carrying more than one
    /// (a link dragged from a browser's address bar comes with its text)
    /// is taken as the most specific.
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    static func items(from pasteboard: NSPasteboard) -> [DropPayload.Item] {
        (pasteboard.pasteboardItems ?? []).compactMap(item)
    }

    static func item(from item: NSPasteboardItem) -> DropPayload.Item? {
        if let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL {
            // A file reference URL (`file:///.file/id=…`) becomes its path.
            return .file((url as NSURL).filePathURL ?? url)
        }
        if let string = item.string(forType: .URL), let url = URL(string: string) {
            return url.isFileURL ? .file((url as NSURL).filePathURL ?? url) : .url(url)
        }
        if let string = item.string(forType: .string) {
            return .text(string)
        }
        return nil
    }

    /// What the cursor badge says: files are linked, not copied; anything
    /// else is copied into the note. Nothing for items that make no note.
    static func operation(for items: [DropPayload.Item]) -> NSDragOperation {
        guard DropPayload.noteText(for: items) != nil else { return [] }
        let allFiles = items.allSatisfy { if case .file = $0 { return true } else { return false } }
        return allFiles ? .link : .copy
    }
}
