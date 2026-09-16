import MacPaperCore
import SwiftUI

/// The icon rail on the column's left: the mark at the top, one button
/// per section (the active one on a lit tile), and at the bottom Shuffle
/// and Collapse. Buttons, so the keyboard reaches them and VoiceOver
/// names them; a help tag carries the name for the pointer.
struct PanelRail: View {
    @Bindable var model: AppModel
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Brand.Space.s4) {
            Image(nsImage: AppResources.menuBarImage())
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .foregroundStyle(Brand.Panel.accent)
                .frame(width: 44, height: 44)
                .accessibilityLabel("macPaper")
                .padding(.top, Brand.Space.s8)
            ForEach(PanelSection.allCases) { section in
                RailButton(symbol: section.symbolName, title: section.title, active: model.panelSection == section) {
                    withAnimation(Motion.standard(reduceMotion: reduceMotion)) { model.panelSection = section }
                }
                .accessibilityAddTraits(model.panelSection == section ? [.isSelected] : [])
            }
            Spacer(minLength: Brand.Space.s8)
            RailButton(symbol: "shuffle", title: "Shuffle", active: false) { model.shuffle() }
                .disabled(!model.canAct)
                .accessibilityHint("A new wallpaper, applied now; pinned parameters are kept")
            RailButton(symbol: "chevron.up", title: "Collapse", active: false, action: dismiss)
                .padding(.bottom, Brand.Space.s8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Brand.Panel.ground)
    }
}

private struct RailButton: View {
    let symbol: String
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .symbolVariant(active ? .fill : .none)
                .foregroundStyle(active ? Brand.Panel.accent : Brand.Panel.textSecondary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? Brand.Panel.surface : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(RailButtonStyle())
        .accessibilityLabel(title)
        .help(title)
    }
}

/// Press feedback on the rail: the tile scales, and a hover lights it.
private struct RailButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Brand.Panel.hover.opacity(0.6) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: Brand.Motion.fast), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
