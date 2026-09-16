import MacPaperCore
import SwiftUI

/// The edited side's generator parameters. Each editor binds into the
/// draft (the light side, or the dark side materialised on its first edit)
/// through `AppModel.editedGenerator`, whose setter goes through the one
/// gated `edit`: the license is asked at the moment of the change, and an
/// allowed change re-renders the preview.
struct ParametersView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            switch model.editedGenerator {
            case .gradient(let p):
                GradientEditor(parameters: binding(p) { .gradient($0) }, model: model)
            case .mesh(let p):
                MeshEditor(parameters: binding(p) { .mesh($0) }, model: model)
            case .pattern(let p):
                PatternEditor(parameters: binding(p) { .pattern($0) }, model: model)
            case .solid(let p):
                SolidEditor(parameters: binding(p) { .solid($0) }, model: model)
            case .pixelize(let p):
                PixelizeEditor(parameters: binding(p) { .pixelize($0) }, model: model)
            case .dither(let p):
                DitherEditor(parameters: binding(p) { .dither($0) }, model: model)
            case .field(let p):
                FieldEditor(parameters: p, model: model)
            }
            if model.editedGenerator.kind.takesBase {
                BaseRow(model: model)
            }
        }
    }

    /// A binding to the parameters inside the enum: reads the current
    /// value, writes it back wrapped.
    private func binding<P>(_ value: P, wrap: @escaping (P) -> Generator) -> Binding<P> {
        Binding(get: { value }, set: { model.editedGenerator = wrap($0) })
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

/// A row of color wells with add and remove, for gradient stops, mesh
/// palettes and the gradient map, plus the palette sources (a photo, the
/// accent color) when a model is given.
struct ColorRow: View {
    let title: String
    @Binding var colors: [RGBAColor]
    let range: ClosedRange<Int>
    var labelWidth: CGFloat = 64
    var model: AppModel? = nil

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            if labelWidth > 0 {
                Text(title)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: labelWidth, alignment: .leading)
            }
            ForEach(colors.indices, id: \.self) { index in
                ColorWell(title: "\(title) \(index + 1)", color: Binding(
                    get: { colors.indices.contains(index) ? colors[index] : .black },
                    set: { if colors.indices.contains(index) { colors[index] = $0 } }
                ))
            }
            Spacer(minLength: 0)
            if let model { PaletteMenu(model: model) }
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

/// From photo…, From accent color, and the preset palettes by group.
struct PaletteMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("From photo…") { Task { await model.usePhotoPalette() } }
            Button("From accent color") { model.useAccentPalette() }
            ForEach(PaletteGroup.presetGroups, id: \.self) { group in
                Menu(group.title) {
                    ForEach(Palettes.presets(in: group)) { palette in
                        Button(palette.name) { model.applyPalette(palette) }
                    }
                }
            }
        } label: {
            Image(systemName: "paintpalette")
        }
        .menuStyle(.button)
        .buttonStyle(CardActionStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel("Palette: from a photo, the accent color, or built-in")
        .help("Palette from a photo, the accent color, or built-in")
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

/// Fill / fit / stretch and the background color, shared by the framed generators.
private struct FramingRow: View {
    @Binding var fit: ImageFit
    @Binding var background: RGBAColor
    let hasSource: Bool

    var body: some View {
        HStack(spacing: Brand.Space.s16) {
            ChoiceRow(title: "Framing", selection: $fit, choices: ImageFit.allCases.map { ($0, $0.title) })
            if fit == .fit || !hasSource {
                ColorWell(title: "Background", color: $background)
            }
        }
        if fit == .fill, hasSource {
            Text("Drag the ring on the preview to choose what the crop keeps.")
                .font(Brand.body(11))
                .foregroundStyle(Brand.textSecondary)
        }
    }
}

/// Import… and the source's state.
private struct SourceRow: View {
    let source: ImageReference?
    let model: AppModel

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Button("Import Image…") { Task { await model.importImage() } }
                .secondaryAction()
            Text(note)
                .font(Brand.mono(11))
                .foregroundStyle(model.isSourceMissing ? Brand.dangerSolid : Brand.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var note: String {
        guard let source else { return "No image yet: the background color shows." }
        if model.isSourceMissing { return "Image missing — import it again." }
        return "\(source.contentHash.prefix(8))…"
    }
}

// MARK: - Editors

private struct GradientEditor: View {
    @Binding var parameters: GradientParameters
    let model: AppModel

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
        ), range: GradientParameters.stopRange, model: model)
        HStack(spacing: Brand.Space.s8) {
            Text("Blend").font(Brand.body(12)).foregroundStyle(Brand.textSecondary).frame(width: 64, alignment: .leading)
            SegmentedControl(title: "Blend", selection: $parameters.interpolation, choices: ColorInterpolation.allCases.map { ($0, $0.title) })
                .frame(width: 160)
            Text(parameters.interpolation == .oklch ? "no grey between saturated colors" : "plain sRGB mix")
                .font(Brand.body(11))
                .foregroundStyle(Brand.textSecondary)
        }
    }
}

private struct MeshEditor: View {
    @Binding var parameters: MeshParameters
    let model: AppModel

    var body: some View {
        HStack(spacing: Brand.Space.s16) {
            Text("Grid").font(Brand.body(12)).foregroundStyle(Brand.textSecondary).frame(width: 64, alignment: .leading)
            CountStepper(title: { "\($0) columns" }, value: $parameters.columns, range: MeshParameters.gridRange)
            CountStepper(title: { "\($0) rows" }, value: $parameters.rows, range: MeshParameters.gridRange)
        }
        LabeledSlider(title: "Jitter", value: $parameters.jitter, range: 0...1, format: { "\(Int($0 * 100))%" })
        LabeledSlider(title: "Softness", value: $parameters.softness, range: 0...1, format: { "\(Int($0 * 100))%" })
        ColorRow(title: "Palette", colors: $parameters.colors, range: MeshParameters.colorRange, model: model)
    }
}

private struct PatternEditor: View {
    @Binding var parameters: PatternParameters
    let model: AppModel

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
            Spacer()
            PaletteMenu(model: model)
        }
    }
}

private struct SolidEditor: View {
    @Binding var parameters: SolidParameters
    let model: AppModel

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Text("Color").font(Brand.body(12)).foregroundStyle(Brand.textSecondary).frame(width: 64, alignment: .leading)
            ColorWell(title: "Color", color: $parameters.color)
            Text(parameters.color.hexString).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            Spacer()
            if model.draft.isTrueBlack {
                Text("true black: exact #000000")
                    .font(Brand.mono(10))
                    .foregroundStyle(Brand.textSecondary)
            } else {
                Button("True black") { model.useTrueBlack() }
                    .buttonStyle(LinkButtonStyle())
                    .help("#000000 with every finish off: exact zeros, the best ground for Liquid Glass")
            }
            PaletteMenu(model: model)
        }
    }
}

private struct PixelizeEditor: View {
    @Binding var parameters: PixelizeParameters
    let model: AppModel

    var body: some View {
        SourceRow(source: parameters.source, model: model)
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
        FramingRow(fit: $parameters.fit, background: $parameters.background, hasSource: parameters.source != nil)
    }
}

private struct DitherEditor: View {
    @Binding var parameters: DitherParameters
    let model: AppModel

    var body: some View {
        SourceRow(source: parameters.source, model: model)
        HStack(spacing: Brand.Space.s8) {
            Text("Mode").font(Brand.body(12)).foregroundStyle(Brand.textSecondary).frame(width: 64, alignment: .leading)
            Picker("Mode", selection: Binding(get: { parameters.mode }, set: { mode in
                parameters.mode = mode
                parameters.cell = min(max(parameters.cell, mode.cellRange.lowerBound), mode.cellRange.upperBound)
            })) {
                ForEach(DitherMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            .accessibilityLabel("Dither mode")
            Spacer()
        }
        LabeledSlider(title: parameters.mode.isGlyphMode ? "Glyph" : "Cell", value: Binding(get: { Double(parameters.cell) }, set: { parameters.cell = Int($0.rounded()) }), range: Double(parameters.mode.cellRange.lowerBound)...Double(parameters.mode.cellRange.upperBound), format: { "\(Int($0)) px" })
        HStack(spacing: Brand.Space.s8) {
            Toggle(isOn: Binding(get: { parameters.paletteSize != nil }, set: { parameters.paletteSize = $0 ? 6 : nil })) {
                Text("Palette from image").font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
            }
            .toggleStyle(.checkbox)
            .disabled(parameters.mode.isGlyphMode)
            if let count = parameters.paletteSize, !parameters.mode.isGlyphMode {
                CountStepper(title: { "\($0) colors" }, value: Binding(get: { count }, set: { parameters.paletteSize = $0 }), range: DitherParameters.paletteRange)
            } else {
                Text("Ink").font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
                ColorWell(title: "Ink", color: $parameters.ink)
                Text("Paper").font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
                ColorWell(title: "Paper", color: $parameters.paper)
            }
            Spacer()
            PaletteMenu(model: model)
        }
        FramingRow(fit: $parameters.fit, background: $parameters.background, hasSource: parameters.source != nil)
    }
}

/// The pixel-field generator: the family, its tones, and every knob the
/// family declares (a slider, a toggle or a choice), each with a pin that
/// tells Shuffle to keep it.
private struct FieldEditor: View {
    let parameters: FieldParameters
    let model: AppModel

    var body: some View {
        ChoiceRow(title: "Family", selection: Binding(get: { parameters.family }, set: { model.fieldFamily = $0 }), choices: FieldFamily.allCases.map { ($0, $0.title) })
        ColorRow(title: "Tones", colors: Binding(
            get: { parameters.tones },
            set: { tones in
                var p = parameters
                p.tones = tones
                model.editedGenerator = .field(p)
            }
        ), range: FieldParameters.toneRange, model: model)
        ForEach(parameters.family.knobs, id: \.key) { knob in
            KnobRow(knob: knob, value: Binding(get: { parameters[knob.key] }, set: { model.setKnob(knob.key, $0) }), model: model)
        }
    }
}

/// One knob with its pin.
struct KnobRow: View {
    let knob: KnobSpec
    @Binding var value: Double
    let model: AppModel

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            switch knob.style {
            case .slider:
                LabeledSlider(title: knob.title, value: $value, range: knob.range, format: { knob.isWhole ? "\(Int($0.rounded()))" : String(format: "%.2f", $0) })
            case .toggle:
                Toggle(isOn: Binding(get: { value >= 0.5 }, set: { value = $0 ? 1 : 0 })) {
                    Text(knob.title).font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
                }
                .toggleStyle(.checkbox)
                Spacer()
            case .choice(let titles):
                ChoiceRow(title: knob.title, selection: Binding(get: { Int(value.rounded()) }, set: { value = Double($0) }), choices: Array(titles.enumerated()).map { ($0.offset, $0.element) })
            }
            PinButton(key: knob.key, model: model)
        }
    }
}

/// The pin beside a parameter: filled while Shuffle keeps it.
struct PinButton: View {
    let key: ParameterKey
    let model: AppModel

    var body: some View {
        Button {
            model.togglePin(key)
        } label: {
            Image(systemName: model.isPinned(key) ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.isPinned(key) ? Brand.accentText : Brand.textSecondary.opacity(0.7))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isPinned(key) ? "Unpin \(key.title)" : "Pin \(key.title)")
        .help(model.isPinned(key) ? "Shuffle keeps \(key.title.lowercased())" : "Keep \(key.title.lowercased()) when shuffling")
    }
}

/// What lies under the texture: none, a flat color, a gradient or a mesh
/// from the palette's ground.
private struct BaseRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            ChoiceRow(title: "Base", selection: $model.baseKind, choices: BaseKind.allCases.map { ($0, $0.title) })
            if case .solid(let color) = model.draft.base {
                ColorWell(title: "Base color", color: Binding(get: { color }, set: { model.setBase(.solid($0)) }))
            }
            PinButton(key: .base, model: model)
        }
        .help("What lies under the texture: a flat color, a gradient or a soft mesh")
    }
}
