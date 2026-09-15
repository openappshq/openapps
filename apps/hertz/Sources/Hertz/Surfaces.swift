import AppKit
import SwiftUI

/// Accessibility-driven surface choices shared by the dashboard, the welcome
/// window and settings.
struct SurfaceStyle {
    let reduceTransparency: Bool
    let increasedContrast: Bool

    /// Real Liquid Glass on macOS 26 unless the user asked for solid surfaces.
    var usesGlass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !reduceTransparency
    }
}

/// Card surface: Liquid Glass on macOS 26, a system material before that, and
/// an opaque grouped surface when Reduce Transparency is on. Increase Contrast
/// adds a visible rim in every case.
private struct CardSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let style = SurfaceStyle(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        Group {
            if #available(macOS 26, *), style.usesGlass {
                content.glassEffect(.regular, in: shape)
            } else if style.reduceTransparency {
                content.background(Brand.surface, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .overlay {
            shape.strokeBorder(style.increasedContrast ? Brand.textPrimary.opacity(0.6) : Brand.borderSubtle.opacity(0.6), lineWidth: 1)
        }
    }
}

/// Secondary actions: the system glass button on macOS 26, the brand outlined
/// button otherwise or when contrast and transparency settings ask for a clear edge.
private struct SecondaryAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let style = SurfaceStyle(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        if #available(macOS 26, *), style.usesGlass, !style.increasedContrast {
            content
                .buttonStyle(.glass)
                .font(Brand.body(14, weight: 600))
                .controlSize(.large)
        } else {
            content.buttonStyle(SecondaryButtonStyle())
        }
    }
}

extension View {
    func cardSurface(radius: CGFloat = Brand.Radius.panel) -> some View {
        modifier(CardSurface(radius: radius))
    }

    func secondaryAction() -> some View {
        modifier(SecondaryAction())
    }
}

/// Text-only action in the accent color, for low-emphasis links.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.body(14, weight: 600))
            .foregroundStyle(Brand.accentText)
            .underline(configuration.isPressed)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Small icon-only action in a dashboard card's header: quiet until hovered,
/// with a help tag carrying the name.
struct CardActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Brand.textSecondary)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.small + 2, style: .continuous)
                    .fill(configuration.isPressed ? Brand.hover : Color.clear)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Short uppercase category label in IBM Plex Mono.
struct MonoLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(11, medium: true))
            .tracking(0.6)
            .foregroundStyle(Brand.textSecondary)
    }
}

enum Motion {
    static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: Brand.Motion.fast) : .easeOut(duration: Brand.Motion.standard)
    }

    static func expressive(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: Brand.Motion.fast) : .spring(duration: Brand.Motion.expressive, bounce: 0.15)
    }
}

/// Re-arming `withObservationTracking`: calls `onChange` on the main actor
/// after anything read in `read` changes, for as long as the owner lives.
func observeChanges(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
    withObservationTracking(read) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                onChange()
                observeChanges(read, onChange: onChange)
            }
        }
    }
}
