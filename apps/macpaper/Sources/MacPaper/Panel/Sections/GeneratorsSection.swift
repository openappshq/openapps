import MacPaperCore
import SwiftUI

/// Generators: one row per choice in the panel's order — the six pixel
/// fields first, then dither, mesh and pixelize — the current one
/// marked. Switching carries the colors (and the photo between the two
/// image generators). A flat color or a gradient on its own is the base
/// layer, under Effects, so it is not listed here; a document that is
/// one shows as such under the list.
struct GeneratorsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(GeneratorChoice.panelOrder) { choice in
                GeneratorRow(choice: choice, selected: model.generatorChoice == choice) {
                    model.generatorChoice = choice
                }
                if choice != GeneratorChoice.panelOrder.last {
                    Rectangle().fill(Brand.Panel.hairline).frame(height: 1)
                }
            }
            if model.generatorKind.isBaseLayer {
                Text("The base layer is on: \(model.generatorKind == .solid ? "a flat color" : "a gradient") on its own. Pick a generator above, or change the base layer under Effects.")
                    .font(Brand.body(11))
                    .foregroundStyle(Brand.Panel.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Brand.Space.s12)
            }
        }
    }
}

private struct GeneratorRow: View {
    let choice: GeneratorChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Brand.Space.s12) {
                Image(systemName: choice.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Brand.Panel.accentOn : Brand.Panel.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(selected ? Brand.Panel.accent : Brand.Panel.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.title)
                        .font(Brand.body(13, weight: 600))
                        .foregroundStyle(Brand.Panel.textPrimary)
                    Text(choice.summary)
                        .font(Brand.body(11))
                        .foregroundStyle(Brand.Panel.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Brand.Panel.accent)
                }
            }
            .frame(minHeight: PanelLayout.listRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityValue(choice.summary)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
