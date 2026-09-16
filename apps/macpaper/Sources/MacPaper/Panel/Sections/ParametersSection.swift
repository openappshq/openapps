import MacPaperCore
import SwiftUI

/// Parameters: the edited side's generator parameters as a vertical list
/// of rows, each with a pin that locks it against Shuffle. Each editor
/// binds into the draft (the light side, or the dark side materialised on
/// its first edit) through `AppModel.editedGenerator`, whose setter goes
/// through the one gated `edit`: the license is asked at the moment of
/// the change, and an allowed change re-renders the preview and reaches
/// the desktop.
struct ParametersSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.editedGenerator {
            case .field(let p):
                FieldEditor(parameters: p, model: model)
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
            }
            BaseRow(model: model)
        }
    }

    /// A binding to the parameters inside the enum: reads the current
    /// value, writes it back wrapped.
    private func binding<P>(_ value: P, wrap: @escaping (P) -> Generator) -> Binding<P> {
        Binding(get: { value }, set: { model.editedGenerator = wrap($0) })
    }
}

// MARK: - Shared rows

/// A choice on one line: the label, the pin, the segments under them.
struct ChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(Value, String)]
    var pin: ParameterKey? = nil
    var model: AppModel? = nil
    var note: String? = nil

    var body: some View {
        ParameterRow(title: title, value: note, pin: pin, model: model) {
            SegmentedControl(title: title, selection: $selection, choices: choices)
        }
    }
}

/// Fill / fit / stretch and the background color, shared by the framed generators.
private struct FramingRow: View {
    @Binding var fit: ImageFit
    @Binding var background: RGBAColor
    let hasSource: Bool
    let model: AppModel

    var body: some View {
        ParameterRow(title: "Framing", pin: .framing, model: model) {
            HStack(spacing: Brand.Space.s12) {
                SegmentedControl(title: "Framing", selection: $fit, choices: ImageFit.allCases.map { ($0, $0.title) })
                if fit == .fit || !hasSource {
                    ColorWell(title: "Background", color: $background)
                }
            }
        }
        if fit == .fill, hasSource {
            Text("Drag the ring on the preview to choose what the crop keeps.")
                .font(Brand.body(11))
                .foregroundStyle(Brand.Panel.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Import… and the source's state.
private struct SourceRow: View {
    let source: ImageReference?
    let model: AppModel

    var body: some View {
        ParameterRow(title: "Image") {
            HStack(spacing: Brand.Space.s8) {
                Button("Import Image…") { Task { await model.importImage() } }
                    .buttonStyle(PanelPrimaryButtonStyle())
                Text(note)
                    .font(Brand.mono(11))
                    .foregroundStyle(model.isSourceMissing ? Brand.Panel.danger : Brand.Panel.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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
        ChoiceRow(title: "Shape", selection: $parameters.kind, choices: GradientKind.allCases.map { ($0, $0.title) }, pin: .gradientKind, model: model)
        if parameters.kind != .radial {
            SliderRow(title: "Angle", value: $parameters.angle, range: 0...360, format: { "\(Int($0))°" }, pin: .angle, model: model)
        }
        if parameters.kind != .linear {
            SliderRow(title: "Center X", value: $parameters.center.x, range: 0...1, format: { "\(Int($0 * 100))%" }, pin: .center, model: model)
            SliderRow(title: "Center Y", value: $parameters.center.y, range: 0...1, format: { "\(Int($0 * 100))%" }, pin: .center, model: model)
        }
        ChoiceRow(
            title: "Blend", selection: $parameters.interpolation, choices: ColorInterpolation.allCases.map { ($0, $0.title) },
            pin: .interpolation, model: model, note: parameters.interpolation == .oklch ? "no grey between saturated colors" : "plain sRGB mix"
        )
    }
}

private struct MeshEditor: View {
    @Binding var parameters: MeshParameters
    let model: AppModel

    var body: some View {
        ParameterRow(title: "Grid", value: "\(parameters.columns) × \(parameters.rows)", pin: .columns, model: model) {
            HStack(spacing: Brand.Space.s16) {
                CountStepper(title: { "\($0) columns" }, value: $parameters.columns, range: MeshParameters.gridRange)
                CountStepper(title: { "\($0) rows" }, value: $parameters.rows, range: MeshParameters.gridRange)
            }
        }
        SliderRow(title: "Jitter", value: $parameters.jitter, range: 0...1, format: { "\(Int($0 * 100))%" }, pin: .jitter, model: model)
        SliderRow(title: "Softness", value: $parameters.softness, range: 0...1, format: { "\(Int($0 * 100))%" }, pin: .softness, model: model)
    }
}

private struct PatternEditor: View {
    @Binding var parameters: PatternParameters
    let model: AppModel

    var body: some View {
        ChoiceRow(title: "Pattern", selection: $parameters.kind, choices: PatternKind.allCases.map { ($0, $0.title) }, pin: .patternKind, model: model)
        SliderRow(title: "Scale", value: $parameters.scale, range: PatternParameters.scaleRange, format: { "\(Int($0)) px" }, pin: .scale, model: model)
        if parameters.kind == .lines || parameters.kind == .checks {
            SliderRow(title: "Angle", value: $parameters.angle, range: 0...180, format: { "\(Int($0))°" }, pin: .angle, model: model)
        }
        ParameterRow(title: "Ink and paper") {
            HStack(spacing: Brand.Space.s16) {
                HStack(spacing: Brand.Space.s8) {
                    ColorWell(title: "Ink", color: $parameters.foreground)
                    Text("Ink").font(Brand.body(12)).foregroundStyle(Brand.Panel.textSecondary)
                }
                HStack(spacing: Brand.Space.s8) {
                    ColorWell(title: "Paper", color: $parameters.background)
                    Text("Paper").font(Brand.body(12)).foregroundStyle(Brand.Panel.textSecondary)
                }
            }
        }
    }
}

private struct SolidEditor: View {
    @Binding var parameters: SolidParameters
    let model: AppModel

    var body: some View {
        ParameterRow(title: "Color", value: parameters.color.hexString) {
            HStack(spacing: Brand.Space.s12) {
                ColorWell(title: "Color", color: $parameters.color)
                if model.draft.isTrueBlack {
                    Text("true black: exact #000000")
                        .font(Brand.mono(11))
                        .foregroundStyle(Brand.Panel.textSecondary)
                } else {
                    Button("True black") { model.useTrueBlack() }
                        .buttonStyle(PanelLinkButtonStyle())
                        .help("#000000 with every finish off: exact zeros, the best ground for Liquid Glass")
                }
            }
        }
    }
}

private struct PixelizeEditor: View {
    @Binding var parameters: PixelizeParameters
    let model: AppModel

    var body: some View {
        SourceRow(source: parameters.source, model: model)
        SliderRow(
            title: "Block", value: Binding(get: { Double(parameters.blockSize) }, set: { parameters.blockSize = Int($0.rounded()) }),
            range: Double(PixelizeParameters.blockRange.lowerBound)...Double(PixelizeParameters.blockRange.upperBound), format: { "\(Int($0)) px" },
            pin: .blockSize, model: model
        )
        ParameterRow(title: "Colors", value: parameters.paletteSize.map { "\($0)" } ?? "all", pin: .paletteSize, model: model) {
            HStack(spacing: Brand.Space.s12) {
                PanelToggle(title: "Reduce colors", isOn: Binding(get: { parameters.paletteSize != nil }, set: { parameters.paletteSize = $0 ? 8 : nil }))
                if let count = parameters.paletteSize {
                    CountStepper(title: { "\($0) colors" }, value: Binding(get: { count }, set: { parameters.paletteSize = $0 }), range: PixelizeParameters.paletteRange)
                }
            }
        }
        FramingRow(fit: $parameters.fit, background: $parameters.background, hasSource: parameters.source != nil, model: model)
    }
}

private struct DitherEditor: View {
    @Binding var parameters: DitherParameters
    let model: AppModel

    var body: some View {
        SourceRow(source: parameters.source, model: model)
        ParameterRow(title: "Mode", value: parameters.mode.title, pin: .ditherMode, model: model) {
            PanelMenu(title: parameters.mode.title, accessibilityLabel: "Dither mode: \(parameters.mode.title)") {
                ForEach(DitherMode.allCases, id: \.self) { mode in
                    Button(mode.title) {
                        parameters.mode = mode
                        parameters.cell = min(max(parameters.cell, mode.cellRange.lowerBound), mode.cellRange.upperBound)
                    }
                }
            }
        }
        SliderRow(
            title: parameters.mode.isGlyphMode ? "Glyph" : "Cell", value: Binding(get: { Double(parameters.cell) }, set: { parameters.cell = Int($0.rounded()) }),
            range: Double(parameters.mode.cellRange.lowerBound)...Double(parameters.mode.cellRange.upperBound), format: { "\(Int($0)) px" },
            pin: .cell, model: model
        )
        ParameterRow(title: "Colors", value: parameters.paletteSize.map { "\($0) from the image" } ?? "ink and paper", pin: .paletteSize, model: model) {
            HStack(spacing: Brand.Space.s12) {
                PanelToggle(title: "Palette from image", isOn: Binding(get: { parameters.paletteSize != nil }, set: { parameters.paletteSize = $0 ? 6 : nil }))
                    .disabled(parameters.mode.isGlyphMode)
                if let count = parameters.paletteSize, !parameters.mode.isGlyphMode {
                    CountStepper(title: { "\($0) colors" }, value: Binding(get: { count }, set: { parameters.paletteSize = $0 }), range: DitherParameters.paletteRange)
                } else {
                    ColorWell(title: "Ink", color: $parameters.ink)
                    Text("Ink").font(Brand.body(12)).foregroundStyle(Brand.Panel.textSecondary)
                    ColorWell(title: "Paper", color: $parameters.paper)
                    Text("Paper").font(Brand.body(12)).foregroundStyle(Brand.Panel.textSecondary)
                }
            }
        }
        FramingRow(fit: $parameters.fit, background: $parameters.background, hasSource: parameters.source != nil, model: model)
    }
}

// MARK: - Pixel fields

/// The pixel-field generator: the family (a segmented control, the same
/// choice as the Generators list), then every knob the family declares —
/// a slider, a toggle or a choice — each with its pin. The tones are the
/// Palette section's.
private struct FieldEditor: View {
    let parameters: FieldParameters
    let model: AppModel

    var body: some View {
        ChoiceRow(title: "Family", selection: Binding(get: { parameters.family }, set: { model.fieldFamily = $0 }), choices: FieldFamily.allCases.map { ($0, $0.title) }, pin: .family, model: model)
        ForEach(parameters.family.knobs, id: \.key) { knob in
            KnobRow(knob: knob, value: Binding(get: { parameters[knob.key] }, set: { model.setKnob(knob.key, $0) }), model: model)
        }
    }
}

/// One knob of a field family, on the column's row rhythm.
private struct KnobRow: View {
    let knob: KnobSpec
    @Binding var value: Double
    let model: AppModel

    var body: some View {
        switch knob.style {
        case .slider:
            SliderRow(title: knob.key.title, value: $value, range: knob.range, format: { knob.step == 1 ? "\(Int($0.rounded()))" : String(format: "%.2f", $0) }, pin: knob.key, model: model)
        case .toggle:
            ParameterRow(title: knob.key.title, value: value >= 0.5 ? "on" : "off", pin: knob.key, model: model) {
                PanelToggle(title: value >= 0.5 ? "On" : "Off", isOn: Binding(get: { value >= 0.5 }, set: { value = $0 ? 1 : 0 }))
            }
        case .choice(let titles):
            ChoiceRow(title: knob.key.title, selection: Binding(get: { Int(value.rounded()) }, set: { value = Double($0) }), choices: Array(titles.enumerated()).map { ($0.offset, $0.element) }, pin: knob.key, model: model)
        }
    }
}

/// What lies under the texture: none, a flat color, a gradient or a soft
/// mesh from the palette's ground; the same control as Effects shows.
struct BaseRow: View {
    @Bindable var model: AppModel

    var body: some View {
        ParameterRow(title: "Base", value: model.baseNote, pin: .base, model: model) {
            HStack(spacing: Brand.Space.s12) {
                SegmentedControl(title: "Base", selection: $model.baseKind, choices: BaseKind.allCases.map { ($0, $0.title) })
                if case .solid(let color) = model.draft.base {
                    ColorWell(title: "Base color", color: Binding(get: { color }, set: { model.setBase(.solid($0)) }))
                }
            }
        }
        .help("What lies under the texture: a flat color, a gradient or a soft mesh from the palette's ground")
    }
}

extension AppModel {
    /// What the base is to the edited generator, for the base rows.
    var baseNote: String {
        switch generatorKind {
        case .field: "under the cells"
        case .dither: editedGenerator.source == nil ? "what gets dithered" : "behind the photo"
        case .pixelize: editedGenerator.source == nil ? "in blocks" : "behind the photo"
        case .pattern: "the paper"
        case .mesh: "under the mesh"
        case .gradient, .solid: "on its own"
        }
    }
}
