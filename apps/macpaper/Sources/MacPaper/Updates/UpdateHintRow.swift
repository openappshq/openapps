import SwiftUI

/// One line above the panel's footer while an update asks for something
/// (RELEASES.md, "In-app updater": "Update available — Install", "Update
/// ready — Restart"); nothing otherwise. Asked on every body, so the row
/// follows the updater's phase. Never shown by a build without the updater,
/// whose status hints nothing.
struct UpdateHintRow: View {
    let updates: UpdateStatus

    var body: some View {
        if let hint = updates.hint() {
            HStack(spacing: Brand.Space.s8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.accentText)
                    .accessibilityHidden(true)
                MonoLabel(UpdateCopy.line(for: hint))
                if let action = UpdateCopy.action(for: hint) {
                    Button(action) {
                        switch hint {
                        case .ready: updates.restart()
                        default: updates.install()
                        }
                    }
                    .buttonStyle(LinkButtonStyle())
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The words the update row uses for each hint.
nonisolated enum UpdateCopy {
    /// The line naming the update.
    static func line(for hint: UpdateHint) -> String {
        switch hint {
        case .available(let new): "macPaper \(new) available"
        case .downloading(let new): "Downloading \(new)…"
        case .ready: "Update ready"
        }
    }

    /// The one action beside it, or nil while nothing is asked.
    static func action(for hint: UpdateHint) -> String? {
        switch hint {
        case .available: "Install"
        case .ready: "Restart"
        case .downloading: nil
        }
    }
}
