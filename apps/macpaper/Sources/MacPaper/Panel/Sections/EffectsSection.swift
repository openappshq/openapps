import MacPaperCore
import SwiftUI

/// Effects: which side is edited and the pair, the finish stack (grain,
/// top shade, tint, duotone, gradient map) as pinnable rows, the notch
/// composition, and the base layer (a flat color or a gradient on its
/// own, in place of a generator).
struct EffectsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sideAndPair
            finishes
            ChoiceRow(title: "Notch", selection: model.binding(\.composition), choices: Composition.allCases.map { ($0, $0.title) }, pin: .composition, model: model, note: model.currentDisplay?.hasNotch == false ? "this display has no notch" : nil)
                .help("How the wallpaper composes around the notch of the display it is applied to")
            baseLayer
        }
    }

    // MARK: Side and pair

    @ViewBuilder
    private var sideAndPair: some View {
        ParameterRow(title: "Editing", value: sideNote) {
            HStack(spacing: Brand.Space.s12) {
                SegmentedControl(title: "Side", selection: Binding(get: { model.shownSide }, set: { model.editingSide = $0 }), choices: Side.allCases.map { ($0, $0.title) })
                if model.shownSide == .dark, model.draft.hasCustomDark {
                    Button("Derive again") { model.resetDarkSide() }
                        .buttonStyle(PanelLinkButtonStyle())
                        .help("Make the dark side from the light one again")
                }
            }
        }
        ParameterRow(title: "Pair", value: pairNote, pin: .pair, model: model) {
            // The frame count goes under the segments, never beside them:
            // the row's width is the measured control's.
            VStack(alignment: .leading, spacing: Brand.Space.s8) {
                SegmentedControl(title: "Pair", selection: Binding(get: { PairChoice(model.draft.pair) }, set: { model.setPair($0.pair(frames: currentFrames)) }), choices: PairChoice.allCases.map { ($0, $0.title) })
                if case .timeOfDay(let frames) = model.draft.pair {
                    CountStepperOver(values: PairMode.frameCounts, value: frames, title: { "\($0) frames" }) { model.setPair(.timeOfDay(frames: $0)) }
                }
            }
        }
    }

    private var currentFrames: Int {
        if case .timeOfDay(let frames) = model.draft.pair { return frames }
        return 8
    }

    private var sideNote: String {
        model.shownSide == .dark ? (model.draft.hasCustomDark ? "edited by hand" : "derived from light") : "the light side"
    }

    private var pairNote: String {
        switch model.draft.pair {
        case .still: "one still"
        case .lightDark: "macOS switches by itself"
        case .timeOfDay: "the day curve, by clock time"
        }
    }

    // MARK: Finishes

    @ViewBuilder
    private var finishes: some View {
        SliderRow(title: "Grain", value: model.binding(\.grain), range: 0...1, format: { "\(Int($0 * 100))%" }, pin: .grain, model: model)
        SliderRow(title: "Top shade", value: model.binding(\.finish.topShade), range: 0...1, format: { "\(Int($0 * 100))%" }, pin: .topShade, model: model)
        if let readability = model.readability, model.previewWallpaper == model.draft, !readability.reads, model.draft.finish.topShade == 0 {
            HStack(spacing: Brand.Space.s8) {
                Text("The menu bar reads badly over this top strip.")
                    .font(Brand.body(11))
                    .foregroundStyle(Brand.Panel.textSecondary)
                Button("Shade the top") { model.shadeTheTop() }
                    .buttonStyle(PanelLinkButtonStyle())
                    .help("Shade the menu-bar strip so its text reads")
            }
            .padding(.bottom, Brand.Space.s8)
        }
        OptionalFinishRow(title: "Tint", pin: .tint, model: model, isOn: Binding(get: { model.draft.finish.tint != nil }, set: { on in model.setFinish { $0.tint = on ? Tint(color: model.draft.generator.colors.first ?? .black, amount: 0.4) : nil } })) {
            if let tint = model.draft.finish.tint {
                ColorWell(title: "Tint color", color: Binding(get: { tint.color }, set: { color in model.setFinish { $0.tint = Tint(color: color, amount: tint.amount) } }))
                ThinSlider(title: "Tint amount", value: Binding(get: { tint.amount }, set: { amount in model.setFinish { $0.tint = Tint(color: tint.color, amount: amount) } }), range: 0...1, format: { "\(Int($0 * 100))%" })
                Text("\(Int(tint.amount * 100))%").font(Brand.mono(12)).foregroundStyle(Brand.Panel.textSecondary).frame(width: 40, alignment: .trailing)
            }
        }
        OptionalFinishRow(title: "Duotone", pin: .duotone, model: model, isOn: Binding(get: { model.draft.finish.duotone != nil }, set: { on in model.setFinish { $0.duotone = on ? Duotone(shadow: RGBAColor(hex: 0x242B55), highlight: RGBAColor(hex: 0xFFD528)) : nil } })) {
            if let duotone = model.draft.finish.duotone {
                ColorWell(title: "Shadow", color: Binding(get: { duotone.shadow }, set: { color in model.setFinish { $0.duotone = Duotone(shadow: color, highlight: duotone.highlight) } }))
                Text("Shadow").font(Brand.body(12)).foregroundStyle(Brand.Panel.textSecondary)
                ColorWell(title: "Highlight", color: Binding(get: { duotone.highlight }, set: { color in model.setFinish { $0.duotone = Duotone(shadow: duotone.shadow, highlight: color) } }))
                Text("Highlight").font(Brand.body(12)).foregroundStyle(Brand.Panel.textSecondary)
            }
        }
        OptionalFinishRow(title: "Gradient map", pin: .gradientMap, model: model, isOn: Binding(get: { model.draft.finish.gradientMap != nil }, set: { on in model.setFinish { $0.gradientMap = on ? [ColorStop(position: 0, color: RGBAColor(hex: 0x163A29)), ColorStop(position: 1, color: RGBAColor(hex: 0xFFF1EA))] : nil } })) {
            if let map = model.draft.finish.gradientMap {
                let colors = Binding<[RGBAColor]>(
                    get: { map.map(\.color) },
                    set: { colors in
                        let count = max(colors.count, 1)
                        model.setFinish { $0.gradientMap = colors.enumerated().map { i, color in ColorStop(position: count == 1 ? 0 : Double(i) / Double(count - 1), color: color) } }
                    }
                )
                ForEach(map.indices, id: \.self) { index in
                    ColorWell(title: "Map stop \(index + 1)", color: Binding(
                        get: { map.indices.contains(index) ? map[index].color : .black },
                        set: { value in var next = colors.wrappedValue; if next.indices.contains(index) { next[index] = value; colors.wrappedValue = next } }
                    ), size: 24)
                }
                Button { var next = colors.wrappedValue; next.removeLast(); colors.wrappedValue = next } label: { Image(systemName: "minus") }
                    .buttonStyle(PanelIconButtonStyle())
                    .disabled(map.count <= GradientParameters.stopRange.lowerBound)
                    .accessibilityLabel("Remove a stop")
                Button { var next = colors.wrappedValue; next.append(next.last.map { $0.mixed(with: .white, amount: 0.3) } ?? .white); colors.wrappedValue = next } label: { Image(systemName: "plus") }
                    .buttonStyle(PanelIconButtonStyle())
                    .disabled(map.count >= GradientParameters.stopRange.upperBound)
                    .accessibilityLabel("Add a stop")
            }
        }
    }

    // MARK: Base layer

    private var baseLayer: some View {
        ChoiceRow(
            title: "Base layer",
            selection: Binding<BaseLayer>(get: { BaseLayer(model.draft) }, set: { model.setBaseLayer($0) }),
            choices: BaseLayer.allCases.map { ($0, $0.title) },
            note: model.generatorKind.isBaseLayer ? "on its own" : "instead of \(model.generatorKind.title.lowercased())"
        )
        .help("A flat color or a gradient on its own; True black is #000000 with every finish off")
    }
}

/// A finish with an on/off checkbox and its controls beside it while on.
private struct OptionalFinishRow<Controls: View>: View {
    let title: String
    let pin: ParameterPin
    let model: AppModel
    @Binding var isOn: Bool
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        ParameterRow(title: title, value: isOn ? "on" : "off", pin: pin, model: model) {
            HStack(spacing: Brand.Space.s8) {
                PanelToggle(title: isOn ? "On" : "Off", isOn: $isOn)
                    .frame(width: 56, alignment: .leading)
                if isOn { controls() }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Still · Light / Dark · Time of day, as the segmented control shows them.
enum PairChoice: String, CaseIterable, Hashable {
    case still, lightDark, timeOfDay

    init(_ pair: PairMode) {
        switch pair {
        case .still: self = .still
        case .lightDark: self = .lightDark
        case .timeOfDay: self = .timeOfDay
        }
    }

    var title: String {
        switch self {
        case .still: "Still"
        case .lightDark: "Light / Dark"
        case .timeOfDay: "Time of day"
        }
    }

    func pair(frames: Int) -> PairMode {
        switch self {
        case .still: .still
        case .lightDark: .lightDark
        case .timeOfDay: .timeOfDay(frames: frames)
        }
    }
}

/// A flat color, a gradient, or true black in place of a generator; the
/// fourth state, "a generator", is what any other document is.
enum BaseLayer: String, CaseIterable, Hashable {
    case generator, flat, gradient, trueBlack

    init(_ wallpaper: Wallpaper) {
        if wallpaper.isTrueBlack { self = .trueBlack } else if wallpaper.generator.kind == .solid { self = .flat } else if wallpaper.generator.kind == .gradient { self = .gradient } else { self = .generator }
    }

    var title: String {
        switch self {
        case .generator: "Generator"
        case .flat: "Flat"
        case .gradient: "Gradient"
        case .trueBlack: "True black"
        }
    }
}

extension AppModel {
    /// The base layer control: a flat color or a gradient takes the
    /// generator's place (its colors carried); true black is the exact
    /// zeros; "Generator" goes back to the first listed generator.
    func setBaseLayer(_ layer: BaseLayer) {
        switch layer {
        case .generator: if generatorKind.isBaseLayer { generatorKind = GeneratorKind.panelOrder[1] }
        case .flat: generatorKind = .solid
        case .gradient: generatorKind = .gradient
        case .trueBlack: useTrueBlack()
        }
    }
}

/// A stepper over a fixed list of values (the time-of-day frame counts).
private struct CountStepperOver: View {
    let values: [Int]
    let value: Int
    let title: (Int) -> String
    let set: (Int) -> Void

    var body: some View {
        let index = values.firstIndex(of: value) ?? 0
        HStack(spacing: Brand.Space.s4) {
            Text(title(value)).font(Brand.mono(12)).foregroundStyle(Brand.Panel.textSecondary)
            Button { set(values[max(0, index - 1)]) } label: { Image(systemName: "minus") }
                .buttonStyle(PanelIconButtonStyle())
                .disabled(index == 0)
                .accessibilityLabel("Fewer frames")
            Button { set(values[min(values.count - 1, index + 1)]) } label: { Image(systemName: "plus") }
                .buttonStyle(PanelIconButtonStyle())
                .disabled(index == values.count - 1)
                .accessibilityLabel("More frames")
        }
    }
}
