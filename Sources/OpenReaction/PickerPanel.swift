import AppKit
import OpenReactionCore
import SwiftUI

/// Every number that shapes the pill, in one place. The website demo mirrors
/// these values.
enum PickerMetrics {
    /// Cell 26 pt, padding 4 pt: a 34 pt capsule, close to a native text line.
    static let pill = PillLayout(cell: 26, padding: 4, labelTrailing: 8, maxWidth: 340, peek: 14)
    static let glyphSize: CGFloat = 18
    static let labelFontSize: CGFloat = 12
    /// Distance between the caret and the pill.
    static let caretGap: CGFloat = 6
    /// Transparent margin so the system glass shadow is not clipped by the window.
    static let shadowInset: CGFloat = 24
    static let maxItems = 8
    static let maxLabelWidth: CGFloat = 150
    /// Centers the first emoji under the caret.
    static let leadingOffset: CGFloat = pill.padding + pill.cell / 2

    static func labelWidth(for title: String) -> CGFloat {
        let font = NSFont(name: "IBMPlexMono-Medium", size: labelFontSize) ?? .monospacedSystemFont(ofSize: labelFontSize, weight: .medium)
        let width = (":\(title):" as NSString).size(withAttributes: [.font: font]).width
        return min(ceil(width), maxLabelWidth)
    }
}

/// Borderless panel that never takes focus.
///
/// The picker must not activate OpenReaction or become the key window: the
/// host app's text field has to keep keyboard focus and its caret, or typing
/// would stop reaching it. `.nonactivatingPanel` lets the panel receive clicks
/// without activating the app, and refusing key/main status keeps focus put.
final class PickerPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
@Observable
final class PickerModel {
    var suggestions: [Suggestion] = []
    var labelWidths: [CGFloat] = []
    var selectedIndex = 0
    var scrollOffset: CGFloat = 0
    var isAboveCaret = false
    var isPresented = false
    @ObservationIgnored var onChoose: ((Int) -> Void)?
    @ObservationIgnored var onHover: ((Int) -> Void)?

    var selectedLabelWidth: CGFloat {
        labelWidths.indices.contains(selectedIndex) ? labelWidths[selectedIndex] : 0
    }
}

@MainActor
final class PickerPanelController {
    let model = PickerModel()
    /// Reports the visible pill frame in Quartz coordinates, or nil when hidden.
    var onVisibilityChange: ((CGRect?) -> Void)?

    private let panel = PickerPanel()
    private var caret = CGRect.zero
    /// Pill frame in AppKit coordinates at its widest, as placed on screen.
    private var placedFrame = CGRect.zero

    init() {
        let hostingView = FirstMouseHostingView(rootView: PickerView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
    }

    var isVisible: Bool { panel.isVisible }

    var selectedSuggestion: Suggestion? {
        model.suggestions.indices.contains(model.selectedIndex) ? model.suggestions[model.selectedIndex] : nil
    }

    /// - Parameter caret: AppKit global coordinates.
    func present(_ suggestions: [Suggestion], caret: CGRect) {
        let items = Array(suggestions.prefix(PickerMetrics.maxItems))
        let selectionChanged = items.map(\.id) != model.suggestions.map(\.id)
        if selectionChanged {
            model.selectedIndex = 0
            model.scrollOffset = 0
        }
        model.suggestions = items
        model.labelWidths = items.map { PickerMetrics.labelWidth(for: $0.title) }
        self.caret = caret
        layout()

        guard !panel.isVisible else {
            if selectionChanged { announceSelection() }
            return
        }
        model.isPresented = false
        panel.orderFrontRegardless()
        // Render the hidden state first so the appearance animates from it.
        panel.displayIfNeeded()
        withAnimation(Self.appearAnimation) {
            model.isPresented = true
        }
        announceSelection()
    }

    func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.isPresented = false
        onVisibilityChange?(nil)
    }

    func moveSelection(by delta: Int) {
        let count = model.suggestions.count
        guard count > 0 else { return }
        select((model.selectedIndex + delta + count) % count)
    }

    /// Selects `index`, scrolling it into view and telling the tap the new
    /// hit region. Keyboard, hover and clicks all go through here so the
    /// pill, its scroll offset and the reported frame never disagree.
    func select(_ next: Int) {
        let count = model.suggestions.count
        guard model.suggestions.indices.contains(next) else { return }
        let offset = PickerMetrics.pill.scrollOffset(
            selected: next,
            count: count,
            labelWidth: model.labelWidths[next],
            current: model.scrollOffset
        )
        withAnimation(Self.reduceMotion ? nil : .spring(duration: Brand.Motion.standard, bounce: 0.2)) {
            model.selectedIndex = next
            model.scrollOffset = offset
        }
        reportFrame()
        announceSelection()
    }

    private func layout() {
        let pill = PickerMetrics.pill
        let size = CGSize(
            width: pill.stableWidth(count: model.suggestions.count, labelWidths: model.labelWidths),
            height: pill.height
        )
        let placement = PanelPlacement.place(
            size: size,
            caret: caret,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            gap: PickerMetrics.caretGap,
            leadingOffset: PickerMetrics.leadingOffset
        )
        model.isAboveCaret = placement.isAboveCaret
        model.scrollOffset = pill.scrollOffset(
            selected: model.selectedIndex,
            count: model.suggestions.count,
            labelWidth: model.selectedLabelWidth,
            current: model.scrollOffset
        )
        placedFrame = placement.frame
        let inset = PickerMetrics.shadowInset
        panel.setFrame(placement.frame.insetBy(dx: -inset, dy: -inset), display: panel.isVisible)
        reportFrame()
    }

    /// The pill is leading-aligned in the panel and narrower than its widest
    /// size for most selections; report the part that is actually drawn.
    private func reportFrame() {
        let visibleWidth = PickerMetrics.pill.visibleWidth(count: model.suggestions.count, labelWidth: model.selectedLabelWidth)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        onVisibilityChange?(CGRect(
            x: placedFrame.minX,
            y: primaryHeight - placedFrame.maxY,
            width: visibleWidth,
            height: placedFrame.height
        ))
    }

    private func announceSelection() {
        guard let suggestion = selectedSuggestion else { return }
        let text: String
        switch suggestion.preview {
        case .glyph(let glyph): text = "\(glyph) \(suggestion.subtitle.isEmpty ? suggestion.title : suggestion.subtitle)"
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static var appearAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: Brand.Motion.fast)
            : .spring(duration: Brand.Motion.expressive, bounce: 0.3)
    }
}
