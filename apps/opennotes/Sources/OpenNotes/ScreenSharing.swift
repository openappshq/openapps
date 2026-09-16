import AppKit

/// "Hide notes from screen sharing" (design/products/opennotes.md,
/// "Settings"): the windows that show a note's text — every deck (the
/// pill, the fan, the open note) and All Notes — take `sharingType =
/// .none`, so Zoom, Meet and a screen recording never see them while they
/// stay on the user's own screen. Settings and the setup guide show no
/// note and are shared like any window. One rule, applied wherever a
/// window is made or the setting changes.
///
/// macOS never raises a window's `sharingType` again once it is `.none`
/// (the setter is a one-way ratchet, verified on macOS 26): a window
/// hidden once stays hidden for its life. So turning the setting off
/// cannot be done in place — `apply` says so, and the owner makes the
/// window anew (the deck's host rebuilds its decks, All Notes reopens).
enum ScreenSharing {
    /// The window classes the app has, by what they show.
    enum Surface: CaseIterable {
        /// A display's deck: the pill, the fan of tabs, the open note, the toast.
        case deck
        case allNotes
        case settings
        case onboarding

        /// Whether the setting hides this window: only the ones with notes on them.
        var hidesNotes: Bool {
            switch self {
            case .deck, .allNotes: true
            case .settings, .onboarding: false
            }
        }
    }

    /// The sharing type a window of this class takes with the setting as
    /// given: `.none` hides it from capture, `.readOnly` is a window's
    /// ordinary state (shared, never driven remotely).
    static func sharingType(for surface: Surface, hidden: Bool) -> NSWindow.SharingType {
        surface.hidesNotes && hidden ? .none : .readOnly
    }

    /// Gives the window the type its class and the setting call for.
    /// True when the window now has it; false when it cannot — a window
    /// once hidden is never shown again (see above) — and the owner must
    /// replace the window to show it.
    @discardableResult
    static func apply(to window: NSWindow, surface: Surface, hidden: Bool) -> Bool {
        let wanted = sharingType(for: surface, hidden: hidden)
        if window.sharingType != wanted { window.sharingType = wanted }
        return window.sharingType == wanted
    }
}
