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
/// toggled by a click on the box, `=` lines answered after the line (drawn,
/// never typed in unless Tab asks), links opened with ⌘-click or ⌥⏎ and
/// named by a hover chip, Escape and the note commands reported to the
/// owner. TextKit does the editing; nothing here replaces text except the
/// three characters of a checkbox and the answer Tab commits, through the
/// same `shouldChangeText` / `didChangeText` path a keystroke takes.
final class NoteTextView: NSTextView {
    var styler = NoteStyler(face: .sans) {
        didSet { restyle() }
    }
    /// The `=` lines and the links of the current text, read once per
    /// change for drawing, Tab, the pointer and the keys.
    private(set) var answers: [Arithmetic.Answer] = []
    private(set) var links: [MarkdownLite.Link] = []
    private var chip: LinkChipHost?
    private var hoverArea: NSTrackingArea?
    var onTextChange: (String) -> Void = { _ in }
    var onCommand: (EditorCommand) -> Void = { _ in }
    var onFocus: () -> Void = {}
    /// Asked before every change TextKit is about to make (a keystroke, a
    /// paste, a checkbox click, a drop): the license now, not the
    /// `isEditable` the last render set. Refused, the text stays as it is
    /// (LICENSING.md, read-only).
    var mayEdit: () -> Bool = { true }
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
        // What AppKit lays over `.link` ranges: the styler's link color, no
        // pointing hand (a plain click places the caret).
        linkTextAttributes = [.foregroundColor: styler.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
        answers = Arithmetic.answers(in: string, format: styler.arithmeticFormat)
        links = MarkdownLite.links(in: string)
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        restyle()
        if !isReplacingProgrammatically { onTextChange(string) }
    }

    /// Every user edit passes here first; a programmatic `setText` does not.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard isReplacingProgrammatically || mayEdit() else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
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
        if commandClick(at: event) { return }
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

    // MARK: - Answers

    /// The fresh answers, drawn after their lines in the secondary color:
    /// on every `=` line without an old answer, and after a stale one. The
    /// text itself is untouched.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        for answer in answers where answer.needsDrawing {
            guard answer.lineRange.length > 0 else { continue }
            let last = NSRange(location: NSMaxRange(answer.lineRange) - 1, length: 1)
            let glyphs = layoutManager.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += textContainerInset.width
            rect.origin.y += textContainerInset.height
            let point = NSPoint(x: rect.maxX + Self.answerGap, y: rect.minY)
            guard dirtyRect.intersects(NSRect(x: point.x, y: point.y, width: bounds.width - point.x, height: rect.height)) else { continue }
            NSAttributedString(string: answer.text, attributes: styler.answerAttributes).draw(at: point)
        }
    }

    /// Between the line's end and its answer.
    static let answerGap: CGFloat = 8

    /// Tab on an `=` line writes the answer into the text (the only way it
    /// reaches the file); anywhere else Tab is a Tab.
    override func insertTab(_ sender: Any?) {
        if let answer = Arithmetic.answer(in: string, at: selectedRange().location, format: styler.arithmeticFormat), answer.needsDrawing {
            let edit = answer.commit
            if shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
                didChangeText()
                setSelectedRange(NSRange(location: edit.range.location + (edit.replacement as NSString).length, length: 0))
            }
            return
        }
        super.insertTab(sender)
    }

    // MARK: - Keys

    override func cancelOperation(_ sender: Any?) {
        onCommand(.escape)
    }

    /// ⌥⏎ with the caret on a link opens it; every other key is TextKit's.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.option], event.keyCode == 36 || event.keyCode == 76,
           let link = MarkdownLite.link(in: string, at: selectedRange().location) {
            open(link)
            return
        }
        super.keyDown(with: event)
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

    /// A plain click on a link places the caret, as on any other text;
    /// only ⌘-click (`mouseDown`) and ⌥⏎ open it.
    override func clicked(onLink link: Any, at charIndex: Int) {
        setSelectedRange(NSRange(location: charIndex, length: 0))
    }

    /// ⌘-click on a link opens it via `NSWorkspace`; nothing is fetched.
    private func commandClick(at event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let link = link(at: convert(event.locationInWindow, from: nil)) else { return false }
        open(link)
        return true
    }

    func open(_ link: MarkdownLite.Link) {
        guard let url = LinkTarget.url(for: link.target) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The link under a point in the view, if the point is on its glyphs.
    func link(at point: NSPoint) -> MarkdownLite.Link? {
        guard let layoutManager, let textContainer, !links.isEmpty else { return nil }
        let inset = NSPoint(x: point.x - textContainerInset.width, y: point.y - textContainerInset.height)
        let index = layoutManager.characterIndex(for: inset, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard let link = links.first(where: { index >= $0.range.location && index < NSMaxRange($0.range) }) else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: link.range, actualCharacterRange: nil)
        var hit = false
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, stop in
            if rect.insetBy(dx: -1, dy: -1).contains(inset) { hit = true; stop.pointee = true }
        }
        return hit ? link : nil
    }

    // MARK: - Hover chip

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let link = link(at: point) { showChip(for: link) } else { hideChip() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideChip()
    }

    /// The chip above the link's first line: the host or the file name,
    /// and how to open it. Nothing is fetched.
    private func showChip(for link: MarkdownLite.Link) {
        guard let layoutManager, let textContainer else { return }
        let host: LinkChipHost
        if let chip { host = chip } else {
            host = LinkChipHost(rootView: LinkChip(label: link.display))
            addSubview(host)
            chip = host
        }
        host.rootView = LinkChip(label: link.display)
        let glyphs = layoutManager.glyphRange(forCharacterRange: link.range, actualCharacterRange: nil)
        var anchor = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 1), in: textContainer)
        anchor.origin.x += textContainerInset.width
        anchor.origin.y += textContainerInset.height
        let size = host.fittingSize
        var x = anchor.minX
        if x + size.width > bounds.width - 4 { x = max(4, bounds.width - 4 - size.width) }
        var y = anchor.minY - size.height - 4
        if y < 0 { y = anchor.maxY + 4 }
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        host.isHidden = false
    }

    private func hideChip() {
        chip?.isHidden = true
    }
}

/// The hover chip's host: takes no clicks, so the link under it stays
/// clickable.
final class LinkChipHost: NSHostingView<LinkChip> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What a link opens: a `~/` path under the home folder, otherwise the
/// address, with characters a URL cannot hold percent-encoded.
enum LinkTarget {
    static func url(for target: String) -> URL? {
        if target.hasPrefix("~/") {
            return URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
        }
        return URL(string: target) ?? URL(string: target, encodingInvalidCharacters: true)
    }
}

/// The editor in SwiftUI: a scroll view around `NoteTextView`, the text
/// pushed in when the note changes elsewhere, edits reported up.
struct NoteEditor: NSViewRepresentable {
    let text: String
    let face: NoteFace
    let isEditable: Bool
    /// A token for "put the caret in the text": a new value focuses, nil
    /// leaves the focus where it is. Set per open, so a note opened with
    /// a click never takes the focus and one opened by the hotkey takes
    /// it on its very first update.
    var focusToken: Int?
    var onTextChange: (String) -> Void
    var onCommand: (EditorCommand) -> Void
    var onFocus: () -> Void = {}
    /// The license at the moment of an edit (`NoteTextView.mayEdit`).
    var mayEdit: () -> Bool = { true }

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
        textView.mayEdit = mayEdit
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        textView.onTextChange = onTextChange
        textView.onCommand = onCommand
        textView.onFocus = onFocus
        textView.mayEdit = mayEdit
        if textView.styler.face != face || context.coordinator.appearance != textView.effectiveAppearance.name {
            textView.styler = NoteStyler(face: face, appearance: textView.effectiveAppearance)
            context.coordinator.appearance = textView.effectiveAppearance.name
        }
        textView.setText(text)
        textView.isEditable = isEditable
        if let focusToken, context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFocusToken: Int?
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
