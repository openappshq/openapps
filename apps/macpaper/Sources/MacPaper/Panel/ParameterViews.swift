import MacPaperCore
import SwiftUI

/// The current generator's parameters. Each editor binds straight into the
/// draft, so every change re-renders the preview.
struct ParametersView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            switch model.draft.generator {
            case .gradient(let p):
                GradientEditor(parameters: binding(p) { .gradient($0) })
            case .mesh(let p):
                MeshEditor(parameters: binding(p) { .mesh($0) })
            case .pattern(let p):
                PatternEditor(parameters: binding(p) { .pattern($0) })
            case .solid(let p):
                SolidEditor(parameters: binding(p) { .solid($0) })
            case .pixelize(let p):
                PixelizeEditor(parameters: binding(p) { .pixelize($0) }, model: model)
            }
        }
    }

    /// A binding to the parameters inside the enum: reads the current
    /// value, writes it back wrapped.
    private func binding<P>(_ value: P, wrap: @escaping (P) -> Generator) -> Binding<P> {
        Binding(get: { value }, set: { model.draft.generator = wrap($0) })
    }
}

// MARK: - Shared controls

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Text(title)
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range) { Text(title) }
                .labelsHidden()
                .tint(Brand.accentSolid)
            Text(format(value))
                .font(Brand.mono(11))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
    }
}

/// A row of color wells with add and remove, for gradient stops and mesh palettes.
struct ColorRow: View {
    let title: String
    @Binding var colors: [RGBAColor]
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Text(title)
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 64, alignment: .leading)
            ForEach(colors.indices, id: \.self) { index in
                ColorWell(title: "\(title) \(index + 1)", color: Binding(
                    get: { colors.indices.contains(index) ? colors[index] : .black },
                    set: { if colors.indices.contains(index) { colors[index] = $0 } }
                ))
            }
            Spacer(minLength: 0)
            Button {
                colors.removeLast()
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(CardActionStyle())
            .disabled(colors.count <= range.lowerBound)
            .accessibilityLabel("Remove a color")
            Button {
                colors.append(colors.last.map { $0.mixed(with: .white, amount: 0.3) } ?? .white)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(CardActionStyle())
            .disabled(colors.count >= range.upperBound)
            .accessibilityLabel("Add a color")
        }
    }
}

private struct ChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(Value, String)]

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Text(title)
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 64, alignment: .leading)
            SegmentedControl(title: title, selection: $selection, choices: choices)
        }
    }
}

// MARK: - Editors

private struct GradientEditor: View {
    @Binding var parameters: GradientParameters

    var body: some View {
        ChoiceRow(title: "Shape", selection: $parameters.kind, choices: GradientKind.allCases.map { ($0, $0.title) })
        if parameters.kind != .radial {
            LabeledSlider(title: "Angle", value: $parameters.angle, range: 0...360, format: { "\(Int($0))°" })
        }
        if parameters.kind != .linear {
            LabeledSlider(title: "Center X", value: $parameters.center.x, range: 0...1, format: { "\(Int($0 * 100))%" })
            LabeledSlider(title: "Center Y", value: $parameters.center.y, range: 0...1, format: { "\(Int($0 * 100))%" })
        }
        ColorRow(title: "Colors", colors: Binding(
            get: { parameters.stops.map(\.color) },
            set: { colors in
                let count = max(colors.count, 1)
                parameters.stops = colors.enumerated().map { i, color in
                    ColorStop(position: count == 1 ? 0 : Double(i) / Double(count - 1), color: color)
                }
            }
        ), range: GradientParameters.stopRange)
    }
}

private struct MeshEditor: View {
    @Binding var parameters: MeshParameters

    var body: some View {
        HStack(spacing: Brand.Space.s16) {
            Text("Grid").font(Brand.body(12)).foregroundStyle(Brand.textSecondary).frame(width: 64, alignment: .leading)
            CountStepper(title: { "\($0) columns" }, value: $parameters.columns, range: MeshParameters.gridRange)
            CountStepper(title: { "\($0) rows" }, value: $parameters.rows, range: MeshParameters.gridRange)
        }
        LabeledSlider(title: "Jitter", value: $parameters.jitter, range: 0...1, format: { "\(Int($0 * 100))%" })
        LabeledSlider(title: "Softness", value: $parameters.softness, range: 0...1, format: { "\(Int($0 * 100))%" })
        ColorRow(title: "Palette", colors: $parameters.colors, range: MeshParameters.colorRange)
    }
}

private struct PatternEditor: View {
    @Binding var parameters: PatternParameters

    var body: some View {
        ChoiceRow(title: "Pattern", selection: $parameters.kind, choices: PatternKind.allCases.map { ($0, $0.title) })
        LabeledSlider(title: "Scale", value: $parameters.scale, range: PatternParameters.scaleRange, format: { "\(Int($0)) px" })
        if parameters.kind == .lines || parameters.kind == .checks {
            LabeledSlider(title: "Angle", value: $parameters.angle, range: 0...180, format: { "\(Int($0))°" })
        }
        HStack(spacing: Brand.Space.s16) {
            HStack(spacing: Brand.Space.s8) {
                Text("Ink").font(Brand.body(12)).foregroundStyle(Brand.textSecondary).frame(width: 64, alignment: .leading)
                ColorWell(title: "Ink", color: $parameters.foreground)
            }
            HStack(spacing: Brand.Space.s8) {
                Text("Paper").font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
                ColorWell(title: "Paper", color: $parameters.background)
            }
        }
    }
}

private struct SolidEditor: View {
    @Binding var parameters: SolidParameters

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Text("Color").font(Brand.body(12)).foregroundStyle(Brand.textSecondary).frame(width: 64, alignment: .leading)
            ColorWell(title: "Color", color: $parameters.color)
            Text(parameters.color.hexString).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
        }
    }
}

private struct PixelizeEditor: View {
    @Binding var parameters: PixelizeParameters
    let model: AppModel

    private var sourceNote: String {
        guard let source = parameters.source else { return "No image yet: the background color shows." }
        if model.isSourceMissing { return "Image missing — import it again." }
        return "\(source.contentHash.prefix(8))…"
    }

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Button("Import Image…") { Task { await model.importImage() } }
                .secondaryAction()
            Text(sourceNote)
                .font(Brand.mono(11))
                .foregroundStyle(model.isSourceMissing ? Brand.dangerSolid : Brand.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        LabeledSlider(title: "Block", value: Binding(get: { Double(parameters.blockSize) }, set: { parameters.blockSize = Int($0.rounded()) }), range: Double(PixelizeParameters.blockRange.lowerBound)...Double(PixelizeParameters.blockRange.upperBound), format: { "\(Int($0)) px" })
        HStack(spacing: Brand.Space.s8) {
            Toggle(isOn: Binding(get: { parameters.paletteSize != nil }, set: { parameters.paletteSize = $0 ? 8 : nil })) {
                Text("Reduce colors").font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
            }
            .toggleStyle(.checkbox)
            if let count = parameters.paletteSize {
                CountStepper(title: { "\($0) colors" }, value: Binding(get: { count }, set: { parameters.paletteSize = $0 }), range: PixelizeParameters.paletteRange)
            }
        }
        HStack(spacing: Brand.Space.s16) {
            ChoiceRow(title: "Placement", selection: $parameters.fit, choices: ImageFit.allCases.map { ($0, $0.title) })
            if parameters.fit == .fit || parameters.source == nil {
                ColorWell(title: "Background", color: $parameters.background)
            }
        }
    }
}
