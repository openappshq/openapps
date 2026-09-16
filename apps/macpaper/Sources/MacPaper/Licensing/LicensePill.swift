import AppKit
import OpenAppsLicensing
import SwiftUI

/// The license status as a small capsule: the trial's remaining time, or
/// the short reason the generator is off. Clicking it opens Settings →
/// License. Shown in the panel's header, the settings window's title
/// bar and on the guide's welcome step. Hidden while simply licensed.
struct LicensePill: View {
    let label: LicenseBadge.Label
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if label.tone == .attention {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    Circle()
                        .fill(Brand.accentSolid)
                        .frame(width: 6, height: 6)
                }
                Text(label.text)
                    .font(Brand.mono(11, medium: true))
                    .lineLimit(1)
            }
            .foregroundStyle(label.tone == .trial ? Brand.accentText : Brand.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .modifier(PillSurface(tone: label.tone))
            .contentShape(Capsule())
        }
        .buttonStyle(PillButtonStyle())
        .help("Opens License settings")
        .accessibilityLabel("License: \(label.text)")
        .accessibilityHint("Opens License settings")
        .animation(Motion.standard(reduceMotion: reduceMotion), value: label)
    }
}

/// Capsule behind the pill: Liquid Glass tinted with the tone's color on
/// macOS 26, a flat brand fill before that, with Reduce Transparency, or
/// in the preview harness (`ImageRenderer` draws no glass). Increase
/// Contrast adds a visible rim in every case.
private struct PillSurface: ViewModifier {
    let tone: LicenseBadge.Tone
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.previewRendering) private var previewRendering

    func body(content: Content) -> some View {
        let style = SurfaceStyle(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        Group {
            if #available(macOS 26, *), style.usesGlass, !previewRendering {
                content.glassEffect(.regular.tint(glassTint).interactive(), in: Capsule())
            } else {
                content.background(flatFill, in: Capsule())
            }
        }
        .overlay {
            Capsule().strokeBorder(rim(style), lineWidth: 1)
        }
    }

    /// Glass blends its tint with what is behind it, so the trial's tint is
    /// the solid accent at low opacity rather than the already pale subtle
    /// token: it reads at a glance on a white title bar and stays in the
    /// same family in dark.
    private var glassTint: Color {
        tone == .trial ? Brand.accentSolid.opacity(0.2) : Brand.surface
    }

    private var flatFill: Color {
        tone == .trial ? Brand.accentSubtle : Brand.surface
    }

    private func rim(_ style: SurfaceStyle) -> Color {
        if style.increasedContrast { return Brand.textPrimary.opacity(0.6) }
        return tone == .trial ? Brand.accentSolid.opacity(0.35) : Brand.borderSubtle
    }
}

/// Press feedback for the pill; the cursor says it is clickable.
private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: Brand.Motion.fast), value: configuration.isPressed)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Hosts the pill at the trailing end of the settings window's title bar.
/// `badge` is read under observation tracking, so an `@Observable` source
/// (the license controller) re-lays the pill out as its text changes.
/// Hidden while there is nothing to say (licensed).
@MainActor
final class LicensePillAccessory: NSTitlebarAccessoryViewController {
    private let badge: () -> LicenseBadge.Label?
    private let action: () -> Void
    private let hosting: NSHostingView<AnyView>

    init(badge: @escaping () -> LicenseBadge.Label?, action: @escaping () -> Void) {
        self.badge = badge
        self.action = action
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
        view = hosting
        observeChanges { [badge] in
            _ = badge()
        } onChange: { [weak self] in
            self?.update()
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        update()
    }

    /// The pill, centered in a view as tall as the title bar: AppKit places
    /// a trailing accessory by its frame, so the height must match.
    private func update() {
        guard let label = badge() else {
            isHidden = true
            return
        }
        let action = self.action
        let height = titleBarHeight
        hosting.rootView = AnyView(
            LicensePill(label: label, action: action)
                .padding(.trailing, Brand.Space.s8)
                .padding(.leading, Brand.Space.s4)
                .frame(height: height)
        )
        view.frame = NSRect(x: 0, y: 0, width: hosting.fittingSize.width, height: height)
        isHidden = false
    }

    private var titleBarHeight: CGFloat {
        guard let window = view.window else { return 28 }
        return max(22, window.frame.height - window.contentLayoutRect.height)
    }
}
