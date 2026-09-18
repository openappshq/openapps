import Foundation

/// What reaches the rules: the menu-bar item's click and the shortcut
/// (both toggle), a click outside, Escape, the space, the settings, and
/// the host display going away.
public enum PanelEvent: Hashable, Sendable {
    /// The menu-bar item's click, or the shortcut: opens the panel under
    /// the item, closes an open one.
    case toggle
    case clickedOutside
    case escape
    case fullscreenChanged(Bool)
    case settingsChanged(hideInFullscreen: Bool)
    /// The host display went away, or the panel is being torn down.
    case hostLost
}

/// What the controller does in response: showing and hiding the panel.
public enum PanelEffect: Hashable, Sendable {
    case open
    case close
}

/// The open/close rules of the panel (design/products/macpaper.md, "The
/// panel"): the menu-bar item and the shortcut toggle it; a click outside,
/// Escape, the host going away or — with Hide in fullscreen on — the app in
/// front going fullscreen closes it. Pure: the controller owns the window
/// and the monitors and feeds events back.
public struct PanelStateMachine: Hashable, Sendable {
    public private(set) var hidesInFullscreen: Bool
    public private(set) var isOpen = false
    public private(set) var isFullscreen = false

    public init(hideInFullscreen: Bool = true) {
        hidesInFullscreen = hideInFullscreen
    }

    /// Whether an open panel stays: not hidden by fullscreen. The item and
    /// the shortcut open the panel regardless (over a fullscreen app too);
    /// this only closes one when the space in front goes fullscreen.
    public var canShow: Bool {
        !(hidesInFullscreen && isFullscreen)
    }

    public mutating func handle(_ event: PanelEvent) -> PanelEffect? {
        switch event {
        case .toggle:
            isOpen.toggle()
            return isOpen ? .open : .close
        case .clickedOutside, .escape, .hostLost:
            return closeIfOpen()
        case .fullscreenChanged(let fullscreen):
            isFullscreen = fullscreen
            return canShow ? nil : closeIfOpen()
        case .settingsChanged(let hideInFullscreen):
            hidesInFullscreen = hideInFullscreen
            return canShow ? nil : closeIfOpen()
        }
    }

    private mutating func closeIfOpen() -> PanelEffect? {
        guard isOpen else { return nil }
        isOpen = false
        return .close
    }
}
