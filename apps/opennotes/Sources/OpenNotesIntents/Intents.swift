#if canImport(AppIntents)
import AppIntents
import Foundation
import OpenNotesCore

/// The Shortcuts actions (design/products/opennotes.md, "Automation"):
/// Create Note, Append to Note, Get Note Text, Open Note. In-process
/// `AppIntent`s — no extension — so Shortcuts, Spotlight and Siri run
/// them in the app, where they go through the same door as the links
/// (the app's `Automation`, bound to `IntentHost.perform` at launch) and
/// ask the license first. Their own module, without the app's main-actor
/// default: `@Parameter` storage is nonisolated by design, and the
/// intent hops to the main actor to perform. A toolchain without
/// AppIntents compiles the module empty.
///
/// Parameters (the contract's table):
///
/// | Action | Parameters | Returns |
/// | --- | --- | --- |
/// | Create Note | Text (required), Title, Color | The note's file (URL) |
/// | Append to Note | Title (required), Text (required) | — |
/// | Get Note Text | Title (required) | The text |
/// | Open Note | Title (required) | — |
public enum IntentHost {
    /// Performs a request in the running app; set at launch. Until then
    /// every action fails with "OpenNotes is not running".
    @MainActor public static var perform: (AutomationRequest) throws -> AutomationOutcome = { _ in throw IntentFailure.notRunning }

    static func run(_ request: AutomationRequest) async throws -> AutomationOutcome {
        try await MainActor.run { try perform(request) }
    }
}

public enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case emptyText
    case emptyTitle

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "OpenNotes is not running."
        case .emptyText: "The note needs some text."
        case .emptyTitle: "The note needs a title."
        }
    }
}

/// The six sticky colors as Shortcuts offers them.
public enum NoteColorChoice: String, AppEnum {
    case coral, yellow, mint, sky, lilac, paper

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note Color")
    public static let caseDisplayRepresentations: [NoteColorChoice: DisplayRepresentation] = [
        .coral: "Coral", .yellow: "Yellow", .mint: "Mint", .sky: "Sky", .lilac: "Lilac", .paper: "Paper",
    ]

    public var noteColor: NoteColor { NoteColor(rawValue: rawValue) ?? .coral }
}

/// Create Note: text (its first line is the title unless one is given),
/// an optional title and color; the note slides out of the deck and the
/// action returns its file. Refused while read-only, with the notice.
public struct CreateNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Create Note"
    public static let description = IntentDescription("Creates a note in the OpenNotes deck, slides it out, and returns the note’s file.")
    public static let openAppWhenRun = true

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    public var text: String

    @Parameter(title: "Title")
    public var title: String?

    @Parameter(title: "Color")
    public var color: NoteColorChoice?

    public static var parameterSummary: some ParameterSummary {
        Summary("Create a note with \(\.$text)") {
            \.$title
            \.$color
        }
    }

    public init() {}

    public init(text: String, title: String? = nil, color: NoteColorChoice? = nil) {
        self.text = text
        self.title = title
        self.color = color
    }

    /// What the parameters ask for: a blank title is none, the text as
    /// typed. Nil when there is nothing to write.
    public var request: AutomationRequest? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard !AutomationLink.compose(title: trimmedTitle, text: text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .new(text: text, title: trimmedTitle, color: color?.noteColor)
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        guard let request else { throw IntentFailure.emptyText }
        guard case .created(_, let url) = try await IntentHost.run(request) else { throw IntentFailure.emptyText }
        return .result(value: url)
    }
}

/// Append to Note: a line added to the note the title names; a new note
/// with that title when none does.
public struct AppendToNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Append to Note"
    public static let description = IntentDescription("Adds a line to the note with this title, or creates the note when there is none.")

    @Parameter(title: "Title")
    public var title: String

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    public var text: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Append \(\.$text) to \(\.$title)")
    }

    public init() {}

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    /// Nil without a title or without text.
    public var request: AutomationRequest? {
        guard let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              !text.trimmingCharacters(in: .newlines).isEmpty else { return nil }
        return .append(title: trimmedTitle, text: text)
    }

    public func perform() async throws -> some IntentResult {
        guard let request else { throw title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? IntentFailure.emptyTitle : IntentFailure.emptyText }
        _ = try await IntentHost.run(request)
        return .result()
    }
}

/// Get Note Text: the text of the note the title names (active first).
public struct GetNoteTextIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Note Text"
    public static let description = IntentDescription("The text of the note with this title.")

    @Parameter(title: "Title")
    public var title: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Get the text of \(\.$title)")
    }

    public init() {}

    public init(title: String) {
        self.title = title
    }

    public var request: AutomationRequest? {
        title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { .text(title: $0) }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let request else { throw IntentFailure.emptyTitle }
        guard case .text(let text) = try await IntentHost.run(request) else { return .result(value: "") }
        return .result(value: text)
    }
}

/// Open Note: the note the title names slides out of the deck.
public struct OpenNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Note"
    public static let description = IntentDescription("Slides the note with this title out of the deck.")
    public static let openAppWhenRun = true

    @Parameter(title: "Title")
    public var title: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$title)")
    }

    public init() {}

    public init(title: String) {
        self.title = title
    }

    public var request: AutomationRequest? {
        title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { .open(title: $0) }
    }

    public func perform() async throws -> some IntentResult {
        guard let request else { throw IntentFailure.emptyTitle }
        _ = try await IntentHost.run(request)
        return .result()
    }
}

/// What Spotlight and Siri offer without a shortcut being built first.
public struct OpenNotesShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: ["Create a note in \(.applicationName)", "New \(.applicationName) note"],
            shortTitle: "Create Note",
            systemImageName: "note.text.badge.plus"
        )
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: ["Open a note in \(.applicationName)"],
            shortTitle: "Open Note",
            systemImageName: "note.text"
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
