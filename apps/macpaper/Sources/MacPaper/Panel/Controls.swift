import AppKit
import MacPaperCore
import SwiftUI

/// Set by the preview harness: views drawn by `ImageRenderer` cannot show
/// materials, scroll views or AppKit-backed controls, so a few surfaces
/// draw a flat stand-in instead. In the running app only the column's
/// off-screen measurement sets it (`PanelMetrics.naturalHeight`), where
/// the stand-ins take the same room as the controls.
struct PreviewRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var previewRendering: Bool {
        get { self[PreviewRenderingKey.self] }
        set { self[PreviewRenderingKey.self] = newValue }
    }
}

// MARK: - Lists

/// A list of rows in the column: lazy, so a long library or history builds
/// only the rows in the scroll viewport; a plain stack for the harness,
/// whose renderer has no viewport.
struct PanelList<Content: View>: View {
    let rendering: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if rendering {
            VStack(spacing: 0) { content() }
        } else {
            LazyVStack(spacing: 0) { content() }
        }
    }
}

// MARK: - Segments

/// A segmented control that never wraps: every segment is as wide as the
/// widest label measured in the segment font (`LabelMeasure`), so the
/// control's width follows its labels, not the other way round. The
/// selected segment sits on an accent pill; segments are buttons, so the
/// keyboard reaches them and VoiceOver names them (design/components.md:
/// tabs with a 150 ms indicator; theme changes snap).
struct SegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(Value, String)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    private var segmentWidth: CGFloat {
        (LabelMeasure.segmentWidths(choices.map(\.1)).max() ?? 0) + 2 * PanelLayout.segmentPadding
    }

    var body: some View {
        let width = segmentWidth
        HStack(spacing: PanelLayout.segmentSpacing) {
            ForEach(choices, id: \.0) { value, label in
                let selected = value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { selection = value }
                } label: {
                    Text(label)
                        .font(Brand.body(SegmentMetrics.fontSize, weight: selected ? 600 : 400))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? Brand.Panel.accentOn : Brand.Panel.textPrimary)
                        .frame(width: width, height: SegmentMetrics.height - 2 * PanelLayout.segmentInset)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Brand.Radius.control - 2, style: .continuous)
                                    .fill(Brand.Panel.accent)
                                    .matchedGeometryEffect(id: "indicator", in: indicator)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityLabel(label)
            }
        }
        .padding(PanelLayout.segmentInset)
        .background(Brand.Panel.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.Panel.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Rows

/// One parameter: its label, its pin, its readout, and the control under
/// them, on the column's row rhythm (`PanelLayout.rowHeight`).
struct ParameterRow<Control: View>: View {
    let title: String
    var value: String? = nil
    var pin: ParameterKey? = nil
    var model: AppModel? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Brand.Space.s8) {
                Text(title)
                    .font(Brand.body(13, weight: 600))
                    .foregroundStyle(Brand.Panel.textPrimary)
                    .lineLimit(1)
                if let pin, let model { PinButton(pin: pin, model: model) }
                Spacer(minLength: Brand.Space.s8)
                if let value {
                    Text(value)
                        .font(Brand.mono(12))
                        .foregroundStyle(Brand.Panel.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(height: 20)
            control()
        }
        .padding(.vertical, 7)
        .frame(minHeight: PanelLayout.rowHeight, alignment: .top)
    }
}

/// The pin beside a parameter's label: filled while Shuffle keeps it.
struct PinButton: View {
    let pin: ParameterKey
    let model: AppModel

    var body: some View {
        let pinned = model.isPinned(pin)
        Button {
            model.togglePin(pin)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(pinned ? Brand.Panel.accent : Brand.Panel.textSecondary)
                .rotationEffect(.degrees(pinned ? 0 : 45))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pinned ? "Unpin \(pin.title)" : "Pin \(pin.title)")
        .accessibilityHint("A pinned parameter keeps its value through Shuffle")
        .help(pinned ? "Pinned: Shuffle keeps \(pin.title.lowercased())" : "Pin: Shuffle keeps \(pin.title.lowercased())")
    }
}

/// A thin track with a round knob: the column's slider. Drawn by SwiftUI,
/// so the preview harness shows it and the theme is the column's; a
/// focusable element that the arrow keys move and VoiceOver adjusts.
struct ThinSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let knob: CGFloat = 16
    private let track: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - knob, 1)
            let fraction = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, .ulpOfOne)
            let x = CGFloat(min(max(fraction, 0), 1)) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.Panel.track).frame(height: track)
                Capsule().fill(Brand.Panel.accent).frame(width: x + knob / 2, height: track)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(Brand.Panel.accent, lineWidth: focused ? 2 : 0))
                    .offset(x: x)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let t = min(max((drag.location.x - knob / 2) / width, 0), 1)
                value = range.lowerBound + Double(t) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: knob)
        .focusable()
        .focused($focused)
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(1); return .handled }
        .onKeyPress(.downArrow) { step(-1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 1 : -1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Brand.Motion.fast), value: focused)
    }

    /// One percent of the range per key press.
    private func step(_ direction: Double) {
        let span = range.upperBound - range.lowerBound
        value = min(max(value + direction * span / 100, range.lowerBound), range.upperBound)
    }
}

/// A slider row: the label, the pin, the value, the thin slider.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var pin: ParameterKey? = nil
    var model: AppModel? = nil

    var body: some View {
        ParameterRow(title: title, value: format(value), pin: pin, model: model) {
            ThinSlider(title: title, value: $value, range: range, format: format)
        }
    }
}

// MARK: - Color

/// A color swatch that opens the system color panel. The panel's changes
/// land in the binding as they happen; the swatch is a plain button, so
/// the preview harness can draw it and VoiceOver names it.
struct ColorWell: View {
    let title: String
    @Binding var color: RGBAColor
    var size: CGFloat = 28
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        Button {
            ColorPanelBridge.shared.begin(with: color) { color = $0 }
        } label: {
            Circle()
                .fill(Color(nsColor: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(color.hexString)
        .accessibilityHint("Opens the color panel")
        .help(color.hexString)
    }
}

/// One target for `NSColorPanel`: whichever swatch was clicked last gets
/// the panel's changes.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((RGBAColor) -> Void)?

    func begin(with color: RGBAColor, onChange: @escaping (RGBAColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changeColor(_:)))
        panel.color = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        panel.orderFront(nil)
    }

    @objc private func changeColor(_ sender: Any?) {
        guard let rgb = NSColorPanel.shared.color.usingColorSpace(.sRGB) else { return }
        onChange?(RGBAColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent)))
    }
}

/// A count with minus and plus, in place of `Stepper` (AppKit-backed,
/// which the preview harness cannot draw).
struct CountStepper: View {
    let title: (Int) -> String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: Brand.Space.s4) {
            Text(title(value))
                .font(Brand.mono(12))
                .foregroundStyle(Brand.Panel.textSecondary)
                .frame(minWidth: 72, alignment: .leading)
            Button {
                value = max(range.lowerBound, value - 1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(PanelIconButtonStyle())
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("Fewer")
            Button {
                value = min(range.upperBound, value + 1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(PanelIconButtonStyle())
            .disabled(value >= range.upperBound)
            .accessibilityLabel("More")
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(title(value))
    }
}

// MARK: - Buttons on the column

/// The one filled action of a section (Save, Import Image…).
struct PanelPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.body(13, weight: 600))
            .foregroundStyle(Brand.Panel.accentOn)
            .padding(.horizontal, Brand.Space.s16)
            .frame(height: 32)
            .background(Brand.Panel.accent, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: Brand.Motion.fast), value: configuration.isPressed)
    }
}

/// Quiet outlined action on the column.
struct PanelSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.body(13, weight: 600))
            .foregroundStyle(Brand.Panel.textPrimary)
            .padding(.horizontal, Brand.Space.s12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                    .fill(configuration.isPressed ? Brand.Panel.hover : Brand.Panel.surface)
            )
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.Panel.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: Brand.Motion.fast), value: configuration.isPressed)
    }
}

/// Text-only action in the accent color.
struct PanelLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.body(13, weight: 600))
            .foregroundStyle(Brand.Panel.accentText)
            .underline(configuration.isPressed)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// Small icon-only action: quiet until pressed.
struct PanelIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Brand.Panel.textSecondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.small + 2, style: .continuous)
                    .fill(configuration.isPressed ? Brand.Panel.hover : Brand.Panel.surface)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A text field on the column: the seed, a recipe's name.
struct PanelFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Brand.body(13))
            .foregroundStyle(Brand.Panel.textPrimary)
            .padding(.horizontal, Brand.Space.s12)
            .frame(height: 32)
            .background(Brand.Panel.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.Panel.hairline, lineWidth: 1))
    }
}

extension View {
    func panelField() -> some View { modifier(PanelFieldStyle()) }
}

/// A pull-down on the column: the current choice and a chevron on a
/// surface, the items in a system menu.
struct PanelMenu<Items: View>: View {
    let title: String
    var accessibilityLabel: String? = nil
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                Text(title).font(Brand.body(13)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Brand.Panel.textPrimary)
            .padding(.horizontal, Brand.Space.s12)
            .frame(height: 28)
            .background(Brand.Panel.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.Panel.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

/// Short uppercase category label in IBM Plex Mono, on the column.
struct PanelMonoLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(11, medium: true))
            .tracking(0.6)
            .foregroundStyle(Brand.Panel.textSecondary)
    }
}

/// A checkbox row on the column.
struct PanelToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(Brand.body(13)).foregroundStyle(Brand.Panel.textPrimary)
        }
        .toggleStyle(.checkbox)
        .tint(Brand.Panel.accent)
    }
}

/// A small render of a document, for lists and grids.
struct DocumentThumbnail: View {
    let model: AppModel
    let wallpaper: Wallpaper
    var width: CGFloat = PanelLayout.thumbnail
    var height: CGFloat = PanelLayout.thumbnail * 0.625
    var selected = false

    var body: some View {
        Group {
            if let image = model.thumbnail(for: wallpaper) {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            } else {
                Brand.Panel.surface
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.small + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.small + 2, style: .continuous).strokeBorder(selected ? Brand.Panel.accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
    }
}
