import AppKit
import OpenNotesCore
import SwiftUI

/// Keys the open note answers beyond typing (design/products/opennotes.md,
/// "Keyboard"); the deck controller acts on them.
enum EditorCommand: Hashable {
    /// ⎋: save and slide back.
    case escape
    /// ⌘W: the next note.
    case next
    /// ⌘⇧A.
    case archive
    /// ⌘⇧P.
    case togglePin
    /// ⌘⇧M.
    case toggleFace
}

/// The note's text view: plain-text paste, no smart substitutions, live
/// Markdown-lite styling that only ever changes attributes, checkboxes
/// toggled by a click on the box, Escape and the note commands reported
/// to the owner. TextKit does the editing; nothing here replaces text
/// except the three characters of a checkbox, through the same
/// `shouldChangeText` / `didChangeText` path a keystroke takes.
final class NoteTextView: NSTextView {
    var styler = NoteStyler(face: .sans) {
        didSet { restyle() }
    }
    var onTextChange: (String) -> Void = { _ in }
    var onCommand: (EditorCommand) -> Void = { _ in }
    var onFocus: () -> Void = {}
    /// Set while the owner pushes text in, so the change is not reported back.
    private var isReplacingProgrammatically = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure() {
        isRichText = true
        importsGraphics = false
        allowsImageEditing = false
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = false
        insertionPointColor = styler.ink
        textContainerInset = NSSize(width: 12, height: 12)
        typingAttributes = styler.baseAttributes
        setAccessibilityLabel("Note text")
    }

    // MARK: - Text in and out

    /// Replaces the text without reporting it as an edit; the caret stays
    /// where the text allows.
    func setText(_ text: String) {
        guard string != text else { return }
        let selection = selectedRange()
        isReplacingProgrammatically = true
        string = text
        isReplacingProgrammatically = false
        restyle()
        let length = (text as NSString).length
        setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    func restyle() {
        guard let textStorage else { return }
        styler.apply(to: textStorage)
        typingAttributes = styler.baseAttributes
        insertionPointColor = styler.ink
    }

    override func didChangeText() {
        super.didChangeText()
        restyle()
        if !isReplacingProgrammatically { onTextChange(string) }
    }

    // MARK: - Plain text only

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let text = pboard.string(forType: .string) else { return false }
        insertText(text, replacementRange: selectedRange())
        return true
    }

    // MARK: - Checkboxes

    override func mouseDown(with event: NSEvent) {
        if isEditable, let toggle = checkboxToggle(at: event) {
            if shouldChangeText(in: toggle.range, replacementString: toggle.replacement) {
                textStorage?.replaceCharacters(in: toggle.range, with: toggle.replacement)
                didChangeText()
            }
            return
        }
        super.mouseDown(with: event)
    }

    /// The box under the pointer, if the click lands on its three characters.
    private func checkboxToggle(at event: NSEvent) -> (range: NSRange, replacement: String)? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard let box = MarkdownLite.checkboxes(in: string).first(where: { index >= $0.range.location && index <= NSMaxRange($0.range) }) else { return nil }
        // The insertion index sits between characters; a click past the
        // box's last character is on the space after it.
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: box.range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        guard rect.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return (box.range, box.checked ? "[ ]" : "[x]")
    }

    // MARK: - Keys

    override func cancelOperation(_ sender: Any?) {
        onCommand(.escape)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command], key == "w" {
            onCommand(.next)
            return true
        }
        if flags == [.command, .shift] {
            switch key {
            case "a": onCommand(.archive); return true
            case "p": onCommand(.togglePin); return true
            case "m": onCommand(.toggleFace); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus() }
        return became
    }

    // MARK: - Links

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
        } else if let string = link as? String, let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The editor in SwiftUI: a scroll view around `NoteTextView`, the text
/// pushed in when the note changes elsewhere, edits reported up.
struct NoteEditor: NSViewRepresentable {
    let text: String
    let face: NoteFace
    let isEditable: Bool
    /// Bumped to put the caret in the text.
    var focusRequest = 0
    var onTextChange: (String) -> Void
    var onCommand: (EditorCommand) -> Void
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NoteTextView.makeScrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        guard let textView = scrollView.documentView as? NoteTextView else { return scrollView }
        textView.styler = NoteStyler(face: face, appearance: textView.effectiveAppearance)
        textView.setText(text)
        textView.isEditable = isEditable
        textView.onTextChange = onTextChange
        textView.onCommand = onCommand
        textView.onFocus = onFocus
        context.coordinator.lastFocusRequest = focusRequest
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        textView.onTextChange = onTextChange
        textView.onCommand = onCommand
        textView.onFocus = onFocus
        if textView.styler.face != face || context.coordinator.appearance != textView.effectiveAppearance.name {
            textView.styler = NoteStyler(face: face, appearance: textView.effectiveAppearance)
            context.coordinator.appearance = textView.effectiveAppearance.name
        }
        textView.setText(text)
        textView.isEditable = isEditable
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFocusRequest = 0
        var appearance: NSAppearance.Name?
    }
}

extension NoteTextView {
    /// The `NSScrollView` + `NoteTextView` pair, the way `NSTextView`
    /// builds its own (TextKit 1 through the layout manager, which the
    /// checkbox hit test reads).
    static func makeScrollableTextView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        let contentSize = scrollView.contentSize
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = NoteTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        return scrollView
    }
}
