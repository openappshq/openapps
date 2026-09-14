import AppKit
import OpenReactionCore
import SwiftUI

/// `list` shows glyph and shortcode per row; `strip` is a compact horizontal
/// capsule of glyphs only.
enum PickerLayout: Sendable {
    case list
    case strip
}

enum PickerMetrics {
    static let contentWidth: CGFloat = 280
    static let rowHeight: CGFloat = 32
    static let stripCell: CGFloat = 40
    static let padding: CGFloat = Brand.Space.s8
    /// Transparent margin so the system glass shadow is not clipped by the window.
    static let shadowInset: CGFloat = 24
    static let maxRows = 7

    /// Concentric with the capsule rows inside.
    static func cornerRadius(for layout: PickerLayout) -> CGFloat {
        switch layout {
        case .list: padding + rowHeight / 2
        case .strip: padding + stripCell / 2
        }
    }

    /// Moves the panel left so the glyph column lines up under the caret.
    static func leadingOffset(for layout: PickerLayout) -> CGFloat {
        switch layout {
        case .list: padding + Brand.Space.s12
        case .strip: padding
        }
    }

    static func contentSize(rows: Int, layout: PickerLayout) -> CGSize {
        switch layout {
        case .list:
            CGSize(width: contentWidth, height: CGFloat(rows) * rowHeight + padding * 2)
        case .strip:
            CGSize(width: CGFloat(rows) * stripCell + padding * 2, height: stripCell + padding * 2)
        }
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
    var selectedIndex = 0
    var isAboveCaret = false
    var isPresented = false
    var layout = PickerLayout.list
    @ObservationIgnored var onChoose: ((Int) -> Void)?
}

@MainActor
final class PickerPanelController {
    let model = PickerModel()
    /// Reports the visible content frame in Quartz coordinates, or nil when hidden.
    var onVisibilityChange: ((CGRect?) -> Void)?

    private let panel = PickerPanel()
    private var caret = CGRect.zero

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
        let rows = Array(suggestions.prefix(PickerMetrics.maxRows))
        if rows.map(\.id) != model.suggestions.map(\.id) {
            model.selectedIndex = 0
        }
        model.suggestions = rows
        self.caret = caret
        layout()

        guard !panel.isVisible else { return }
        model.isPresented = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Render the hidden state first so the appearance animates from it.
        panel.displayIfNeeded()
        withAnimation(Self.appearAnimation) {
            model.isPresented = true
        }
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
        let next = (model.selectedIndex + delta + count) % count
        withAnimation(Self.reduceMotion ? nil : .spring(duration: Brand.Motion.standard, bounce: 0.15)) {
            model.selectedIndex = next
        }
    }

    private func layout() {
        let size = PickerMetrics.contentSize(rows: model.suggestions.count, layout: model.layout)
        let placement = PanelPlacement.place(
            size: size,
            caret: caret,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            gap: Brand.Space.s4,
            leadingOffset: PickerMetrics.leadingOffset(for: model.layout)
        )
        model.isAboveCaret = placement.isAboveCaret
        let inset = PickerMetrics.shadowInset
        panel.setFrame(placement.frame.insetBy(dx: -inset, dy: -inset), display: panel.isVisible)

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartz = CGRect(
            x: placement.frame.minX,
            y: primaryHeight - placement.frame.maxY,
            width: placement.frame.width,
            height: placement.frame.height
        )
        onVisibilityChange?(quartz)
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
