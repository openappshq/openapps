import Foundation

/// What a drop onto the deck becomes (design/products/opennotes.md, "Drop
/// to create"): the note's text, from the items the pasteboard carried.
/// Pure — the app reads the pasteboard and sorts each item into one of
/// the three kinds; nothing here reads a file or the network.
nonisolated public enum DropPayload {
    public enum Item: Hashable, Sendable {
        /// Plain text: the body as dropped.
        case text(String)
        /// A web link: one line, the address itself (no title is fetched).
        case url(URL)
        /// A file: one line, `[name](file:///…)`; the file stays where it is.
        case file(URL)
    }

    /// The text of the note a drop of these items makes, in the order
    /// they came; items on their own lines. Nil when there is nothing to
    /// write — no items, or only blank text.
    public static func noteText(for items: [Item]) -> String? {
        let lines = items.compactMap(line)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// One item's contribution: text as it is (trailing blank lines
    /// dropped, a blank item skipped), a link as its address, a file as a
    /// Markdown link to it by name.
    static func line(for item: Item) -> String? {
        switch item {
        case .text(let text):
            let trimmed = trimmingTrailingNewlines(text)
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trimmed
        case .url(let url):
            return url.absoluteString
        case .file(let url):
            let name = url.lastPathComponent
            return "[\(name.isEmpty ? url.absoluteString : name)](\(url.absoluteString))"
        }
    }

    private static func trimmingTrailingNewlines(_ text: String) -> String {
        var scalars = Substring(text)
        while let last = scalars.last, last.isNewline { scalars.removeLast() }
        return String(scalars)
    }
}
