import AppKit
import MacPaperCore
import SwiftUI

/// Set by the preview harness: views drawn by `ImageRenderer` cannot show
/// materials or AppKit-backed controls, so a few surfaces draw a flat
/// stand-in instead. Never set in the running app.
struct PreviewRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var previewRendering: Bool {
        get { self[PreviewRenderingKey.self] }
        set { self[PreviewRenderingKey.self] = newValue }
    }
}

/// A brand segmented control: one row of choices, the selected one on a
/// filled pill, keyboard-operable as buttons (design/components.md: tabs
/// with a 150 ms indicator; theme changes snap).
struct SegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(Value, String)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.0) { value, label in
                let selected = value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { selection = value }
                } label: {
                    Text(label)
                        .font(Brand.body(12, weight: selected ? 600 : 400))
                        .foregroundStyle(selected ? Brand.accentOn : Brand.textPrimary)
                        .padding(.horizontal, Brand.Space.s8)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Brand.Radius.control - 2, style: .continuous)
                                    .fill(Brand.accentSolid)
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
        .padding(2)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.borderSubtle.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A color swatch that opens the system color panel. The panel's changes
/// land in the binding as they happen; the swatch is a plain button, so
/// the preview harness can draw it and VoiceOver names it.
struct ColorWell: View {
    let title: String
    @Binding var color: RGBAColor
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        Button {
            ColorPanelBridge.shared.begin(with: color) { color = $0 }
        } label: {
            Circle()
                .fill(Color(nsColor: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Brand.borderControl.opacity(0.6), lineWidth: 1))
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
/// which the preview harness cannot draw): the same shape as the color
/// row's add and remove.
struct CountStepper: View {
    let title: (Int) -> String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: Brand.Space.s4) {
            Text(title(value))
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
            Button {
                value = max(range.lowerBound, value - 1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(CardActionStyle())
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("Fewer")
            Button {
                value = min(range.upperBound, value + 1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(CardActionStyle())
            .disabled(value >= range.upperBound)
            .accessibilityLabel("More")
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(title(value))
    }
}
