import AppKit
import OpenReactionCore
import SwiftUI

/// Horizontal glass pill of emoji. The selected emoji sits in an orchid-tinted
/// capsule that widens to show its `:shortcode:` and slides between items.
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
        pill
            .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.96, anchor: model.isAboveCaret ? .bottomLeading : .topLeading)
            .opacity(model.isPresented ? 1 : 0)
            .padding(PickerMetrics.shadowInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.isAboveCaret ? .bottomLeading : .topLeading)
    }

    private var pill: some View {
        let layout = PickerMetrics.pill
        let count = model.suggestions.count
        let labelWidth = model.selectedLabelWidth
        let content = layout.contentWidth(count: count, labelWidth: labelWidth)
        let visible = layout.visibleWidth(count: count, labelWidth: labelWidth)

        return HStack(spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                let isSelected = index == model.selectedIndex
                PillCell(
                    suggestion: suggestion,
                    isSelected: isSelected,
                    labelWidth: isSelected ? labelWidth : 0,
                    style: style,
                    selection: selection
                )
                .frame(width: layout.cellWidth(index, selected: model.selectedIndex, labelWidth: labelWidth), height: layout.cell)
                .contentShape(Capsule())
                .onTapGesture { model.onChoose?(index) }
                .onHover { hovering in
                    if hovering, model.selectedIndex != index { model.selectedIndex = index }
                }
            }
        }
        .padding(.horizontal, layout.padding)
        .fixedSize()
        .offset(x: -model.scrollOffset)
        .frame(width: visible, height: layout.height, alignment: .leading)
        .mask(EdgeFade(
            leading: model.scrollOffset > 0,
            trailing: model.scrollOffset + visible < content - 0.5
        ))
        .clipShape(Capsule())
        .modifier(PillChrome(style: style))
        .animation(reduceMotion ? nil : .spring(duration: Brand.Motion.standard, bounce: 0.2), value: model.selectedIndex)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Emoji suggestions")
    }
}

/// Accessibility-driven rendering choices shared by the pill and its cells.
private struct PickerStyle {
    let reduceTransparency: Bool
    let increasedContrast: Bool

    /// Real Liquid Glass on macOS 26 unless the user asked for solid surfaces.
    var usesGlass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !reduceTransparency
    }
}

private struct PillCell: View {
    let suggestion: Suggestion
    let isSelected: Bool
    let labelWidth: CGFloat
    let style: PickerStyle
    let selection: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            glyph
                .frame(width: PickerMetrics.pill.cell, height: PickerMetrics.pill.cell)
            if isSelected {
                Text(":\(suggestion.title):")
                    .font(Brand.mono(13, medium: true))
                    .foregroundStyle(Brand.accentOn)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: labelWidth, alignment: .leading)
                    .transition(.opacity)
                Spacer(minLength: 0)
            }
        }
        .background {
            if isSelected {
                SelectionCapsule(style: style)
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
        .help(suggestion.subtitle.isEmpty ? ":\(suggestion.title):" : "\(suggestion.subtitle) :\(suggestion.title):")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private var glyph: some View {
        switch suggestion.preview {
        case .glyph(let glyph):
            Text(glyph).font(.system(size: 24))
        }
    }

    private var accessibilityText: String {
        switch suggestion.preview {
        case .glyph(let glyph):
            "\(glyph) \(suggestion.subtitle.isEmpty ? suggestion.title.replacingOccurrences(of: "_", with: " ") : suggestion.subtitle)"
        }
    }
}

/// The sliding highlight: orchid-tinted glass on macOS 26, a solid orchid
/// capsule elsewhere and whenever contrast or transparency settings ask for
/// clearer edges.
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
/// hairline rim and standard shadow earlier; opaque with Reduce Transparency.
private struct PillChrome: ViewModifier {
    let style: PickerStyle

    func body(content: Content) -> some View {
        if #available(macOS 26, *), style.usesGlass {
            content
                .glassEffect(.regular, in: Capsule())
                .overlay {
                    if style.increasedContrast {
                        Capsule().strokeBorder(Brand.textPrimary.opacity(0.6), lineWidth: 1)
                    }
                }
        } else if style.reduceTransparency {
            content
                .background(Brand.canvas, in: Capsule())
                .overlay { Capsule().strokeBorder(rimColor, lineWidth: style.increasedContrast ? 1 : 0.5) }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        } else {
            content
                .background { VisualEffectBackground().clipShape(Capsule()) }
                .overlay { Capsule().strokeBorder(rimColor, lineWidth: style.increasedContrast ? 1 : 0.5) }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        }
    }

    private var rimColor: Color {
        style.increasedContrast ? Brand.textPrimary.opacity(0.6) : Color.white.opacity(0.28)
    }
}

/// Fades a clipped edge so the next emoji visibly continues past it.
private struct EdgeFade: View {
    let leading: Bool
    let trailing: Bool

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 20)
            Color.black
            LinearGradient(colors: [.black, trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 20)
        }
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
