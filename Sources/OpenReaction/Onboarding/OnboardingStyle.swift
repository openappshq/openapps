import AppKit
import OpenReactionCore
import SwiftUI

/// Accessibility-driven surface choices shared by onboarding, the guide panel
/// and settings.
struct SurfaceStyle {
    let reduceTransparency: Bool
    let increasedContrast: Bool

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

/// Short uppercase category label in IBM Plex Mono.
struct MonoLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(12, medium: true))
            .tracking(0.6)
            .foregroundStyle(Brand.textSecondary)
    }
}

/// Permission status as icon plus text. Only "allowed" uses color (success
/// tokens); every other state is neutral, with shape and wording carrying the
/// meaning.
struct PermissionStatusBadge: View {
    let status: PermissionStatus
    var celebrate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            icon
            Text(title)
                .font(Brand.mono(13, medium: status == .granted))
        }
        .foregroundStyle(status == .granted ? Brand.successSolid : Brand.textSecondary)
        .padding(.horizontal, Brand.Space.s8)
        .frame(minHeight: 24)
        .background {
            if status == .granted {
                RoundedRectangle(cornerRadius: Brand.Radius.small, style: .continuous).fill(Brand.successSubtle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .symbolEffect(.bounce, value: reduceMotion ? false : celebrate)
        case .requested:
            ProgressView().controlSize(.mini)
        case .missing:
            Image(systemName: "circle.dashed")
        case .needsRelaunch:
            Image(systemName: "arrow.clockwise.circle")
        case .stale:
            Image(systemName: "exclamationmark.circle")
        }
    }

    private var title: String {
        switch status {
        case .granted: "Allowed"
        case .requested: "Waiting for you in System Settings"
        case .missing: "Not allowed yet"
        case .needsRelaunch: "Allowed — needs a relaunch"
        case .stale: "Old permission entry"
        }
    }
}

enum Motion {
    static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: Brand.Motion.fast) : .easeOut(duration: Brand.Motion.standard)
    }

    static func expressive(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: Brand.Motion.fast) : .spring(duration: Brand.Motion.expressive, bounce: 0.15)
    }

    @MainActor static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Polite VoiceOver announcement for an important status change.
@MainActor
func announce(_ message: String) {
    NSAccessibility.post(
        element: NSApp.keyWindow ?? NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
    )
}

/// Re-arming `withObservationTracking`: calls `onChange` on the main actor
/// after anything read in `read` changes, for as long as the owner lives.
@MainActor
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

/// Hosting view that accepts the first click in a non-activating panel.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
