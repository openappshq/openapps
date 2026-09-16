import MacPaperCore
import SwiftUI

/// Palette: the current colors as swatches (with add and remove where the
/// generator takes a variable count, From photo… and From accent color),
/// then the preset palettes by group, seven a row, the matching one
/// ringed. A preset lifts the menu bar by itself where the strip would
/// not read (`AppModel.applyPreset`).
struct PaletteSection: View {
    @Bindable var model: AppModel
    let width: CGFloat
    private let columns = 7
    private let gap: CGFloat = Brand.Space.s8

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s16) {
            ParameterRow(title: model.currentPreset?.name ?? "Custom", value: nil, pin: .palette, model: model) {
                CurrentColors(model: model)
            }
            HStack(spacing: Brand.Space.s8) {
                Button("From photo…") { Task { await model.usePhotoPalette() } }
                    .buttonStyle(PanelSecondaryButtonStyle())
                    .help("The dominant colors of an image")
                Button("From accent color") { model.useAccentPalette() }
                    .buttonStyle(PanelSecondaryButtonStyle())
                    .help("The Mac's accent color, expanded into a palette")
            }
            PanelMonoLabel("Presets")
            grid
        }
    }

    /// Seven per row, by group; drawn as plain rows so the harness sees
    /// every cell.
    private var grid: some View {
        let cell = ((width - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        return VStack(alignment: .leading, spacing: Brand.Space.s12) {
            ForEach(PaletteGroup.presetGroups, id: \.self) { group in
                let presets = Palettes.presets(in: group)
                let rows = stride(from: 0, to: presets.count, by: columns).map { Array(presets[$0..<min($0 + columns, presets.count)]) }
                VStack(alignment: .leading, spacing: gap) {
                    Text(group.title)
                        .font(Brand.body(11, weight: 600))
                        .foregroundStyle(Brand.Panel.textSecondary)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: gap) {
                            ForEach(row) { preset in
                                PresetCell(preset: preset, size: cell, selected: model.currentPreset?.name == preset.name) {
                                    model.applyPreset(preset)
                                }
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(group.title) palettes")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preset palettes")
    }
}

/// The edited generator's colors as swatches, with add and remove where
/// it takes a variable count.
private struct CurrentColors: View {
    @Bindable var model: AppModel

    private var range: ClosedRange<Int> {
        switch model.generatorKind {
        case .gradient: GradientParameters.stopRange
        case .mesh: MeshParameters.colorRange
        case .field: FieldParameters.toneRange
        default: model.editedGenerator.colors.count...model.editedGenerator.colors.count
        }
    }

    var body: some View {
        let colors = model.paletteColors
        HStack(spacing: Brand.Space.s8) {
            ForEach(colors.wrappedValue.indices, id: \.self) { index in
                ColorWell(title: "Color \(index + 1)", color: Binding(
                    get: { colors.wrappedValue.indices.contains(index) ? colors.wrappedValue[index] : .black },
                    set: { value in
                        var next = colors.wrappedValue
                        if next.indices.contains(index) { next[index] = value; colors.wrappedValue = next }
                    }
                ))
            }
            Spacer(minLength: 0)
            if range.lowerBound != range.upperBound {
                Button {
                    var next = colors.wrappedValue
                    next.removeLast()
                    colors.wrappedValue = next
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(PanelIconButtonStyle())
                .disabled(colors.wrappedValue.count <= range.lowerBound)
                .accessibilityLabel("Remove a color")
                Button {
                    var next = colors.wrappedValue
                    next.append(next.last.map { $0.mixed(with: .white, amount: 0.3) } ?? .white)
                    colors.wrappedValue = next
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(PanelIconButtonStyle())
                .disabled(colors.wrappedValue.count >= range.upperBound)
                .accessibilityLabel("Add a color")
            }
        }
    }
}

/// One preset: its colors as a diagonal sweep, ringed while in use.
private struct PresetCell: View {
    let preset: Palette
    let size: CGFloat
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LinearGradient(colors: preset.tones.map { Color($0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                        .strokeBorder(selected ? Brand.Panel.accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(preset.name)
    }
}
