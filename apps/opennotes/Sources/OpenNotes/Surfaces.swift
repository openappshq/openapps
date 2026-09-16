import AppKit
import SwiftUI

/// Set by the debug preview harness: AppKit-backed views (the editor, the
/// hotkey recorder, grouped forms) draw flat stand-ins under `ImageRenderer`.
struct PreviewRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var previewRendering: Bool {
        get { self[PreviewRenderingKey.self] }
        set { self[PreviewRenderingKey.self] = newValue }
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

/// Small icon-only action in a note's footer or a list row: quiet until
/// hovered, with a help tag carrying the name.
struct FooterActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.small + 2, style: .continuous)
                    .fill(configuration.isPressed ? Color.black.opacity(0.12) : Color.clear)
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

/// Relative age for a list row: "now", "5 min", "3 h", "2 d", "Mar 4".
enum Age {
    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    static func text(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400)) d" }
        return dayFormatter.string(from: date)
    }
}
