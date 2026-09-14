import AppKit
import OpenReactionCore
import SwiftUI

struct PickerView: View {
    let model: PickerModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Namespace private var selection

    private var style: PickerStyle {
        PickerStyle(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
    }

    var body: some View {
        content
            .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.96, anchor: model.isAboveCaret ? .bottom : .top)
            .opacity(model.isPresented ? 1 : 0)
            .padding(PickerMetrics.shadowInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.isAboveCaret ? .bottomLeading : .topLeading)
    }

    @ViewBuilder private var content: some View {
        let items = Array(model.suggestions.enumerated())
        let layout = model.layout
        let stack = Group {
            switch layout {
            case .list:
                VStack(spacing: 0) {
                    ForEach(items, id: \.element.id) { index, suggestion in
                        row(index: index, suggestion: suggestion, layout: layout)
                    }
                }
            case .strip:
                HStack(spacing: 0) {
                    ForEach(items, id: \.element.id) { index, suggestion in
                        row(index: index, suggestion: suggestion, layout: layout)
                    }
                }
            }
        }
        .padding(PickerMetrics.padding)
        .animation(reduceMotion ? nil : .spring(duration: Brand.Motion.standard, bounce: 0.2), value: model.selectedIndex)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Emoji suggestions")

        PanelBackground(style: style, layout: layout) { stack }
    }

    private func row(index: Int, suggestion: Suggestion, layout: PickerLayout) -> some View {
        PickerRow(
            suggestion: suggestion,
            isSelected: index == model.selectedIndex,
            layout: layout,
            style: style,
            selection: selection
        )
        .contentShape(Capsule())
        .onTapGesture { model.onChoose?(index) }
        .onHover { hovering in
            if hovering { model.selectedIndex = index }
        }
    }
}

/// Accessibility-driven rendering choices shared by the panel and its rows.
private struct PickerStyle {
    let reduceTransparency: Bool
    let increasedContrast: Bool

    /// Real Liquid Glass is used on macOS 26 unless the user asked for
    /// solid surfaces.
    var usesGlass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !reduceTransparency
    }
}

private struct PickerRow: View {
    let suggestion: Suggestion
    let isSelected: Bool
    let layout: PickerLayout
    let style: PickerStyle
    let selection: Namespace.ID

    var body: some View {
        Group {
            switch layout {
            case .list: listContent
            case .strip: stripContent
            }
        }
        .background {
            if isSelected {
                SelectionCapsule(style: style)
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var listContent: some View {
        HStack(spacing: Brand.Space.s8) {
            glyph(size: 20)
                .frame(width: 24)
            Text(":\(suggestion.title):")
                .font(Brand.mono(13, medium: isSelected))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Brand.Space.s4)
            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(labelColor.opacity(0.7))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Brand.Space.s12)
        .frame(height: PickerMetrics.rowHeight)
    }

    private var stripContent: some View {
        glyph(size: 24)
            .frame(width: PickerMetrics.stripCell, height: PickerMetrics.stripCell)
            .help(":\(suggestion.title):")
    }

    private var labelColor: Color {
        isSelected ? Brand.accentOn : Brand.textPrimary
    }

    @ViewBuilder private func glyph(size: CGFloat) -> some View {
        switch suggestion.preview {
        case .glyph(let glyph):
            Text(glyph).font(.system(size: size))
        }
    }

    private var accessibilityText: String {
        switch suggestion.preview {
        case .glyph(let glyph): "\(glyph) \(suggestion.title.replacingOccurrences(of: "_", with: " "))"
        }
    }
}

/// The sliding highlight: an orchid-tinted glass capsule on macOS 26, a solid
/// orchid capsule elsewhere and whenever contrast or transparency settings
/// ask for a clearer edge.
private struct SelectionCapsule: View {
    let style: PickerStyle

    var body: some View {
        if #available(macOS 26, *), style.usesGlass, !style.increasedContrast {
            Capsule()
                .fill(Brand.accentSolid.opacity(0.55))
                .glassEffect(.regular.tint(Brand.accentSolid).interactive(), in: Capsule())
        } else {
            Capsule()
                .fill(Brand.accentSolid)
                .overlay {
                    if style.increasedContrast {
                        Capsule().strokeBorder(Brand.textPrimary, lineWidth: 1)
                    }
                }
        }
    }
}

/// System Liquid Glass on macOS 26; a behind-window popover material with a
/// hairline rim and standard shadow on earlier systems; an opaque surface
/// when Reduce Transparency is on.
private struct PanelBackground<Content: View>: View {
    let style: PickerStyle
    let layout: PickerLayout
    @ViewBuilder let content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PickerMetrics.cornerRadius(for: layout), style: .continuous)
    }

    var body: some View {
        if #available(macOS 26, *), style.usesGlass {
            content
                .glassEffect(.regular, in: shape)
                .overlay {
                    if style.increasedContrast {
                        shape.strokeBorder(Brand.textPrimary.opacity(0.6), lineWidth: 1)
                    }
                }
        } else if style.reduceTransparency {
            content
                .background(Brand.canvas, in: shape)
                .overlay { shape.strokeBorder(rimColor, lineWidth: style.increasedContrast ? 1 : 0.5) }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        } else {
            content
                .background { VisualEffectBackground().clipShape(shape) }
                .overlay { shape.strokeBorder(rimColor, lineWidth: style.increasedContrast ? 1 : 0.5) }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        }
    }

    private var rimColor: Color {
        style.increasedContrast ? Brand.textPrimary.opacity(0.6) : Color.white.opacity(0.28)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        // The panel is never key, so follow-window-state would render inactive.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
