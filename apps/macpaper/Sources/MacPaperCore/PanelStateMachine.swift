import Foundation

/// The notch panel's settings as the rules read them.
public struct PanelSettings: Hashable, Sendable {
    public var isEnabled: Bool
    public var trigger: PanelTrigger
    public var hideInFullscreen: Bool
    /// How long the pointer rests on the notch before a hover opens.
    public var hoverOpenDelay: TimeInterval
    /// How long after the pointer leaves the notch and the panel a hover-opened panel closes.
    public var hoverCloseDelay: TimeInterval

    /// 180 ms: long enough that a pointer crossing the notch on its way
    /// to a menu opens nothing.
    public static let defaultHoverOpenDelay: TimeInterval = 0.18

    public init(isEnabled: Bool = true, trigger: PanelTrigger = .both, hideInFullscreen: Bool = true, hoverOpenDelay: TimeInterval = defaultHoverOpenDelay, hoverCloseDelay: TimeInterval = 0.4) {
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.hideInFullscreen = hideInFullscreen
        self.hoverOpenDelay = hoverOpenDelay
        self.hoverCloseDelay = hoverCloseDelay
    }
}

public enum PanelTimer: Hashable, Sendable {
    case hoverOpen, hoverClose
}

/// What reaches the rules: pointer movement over the notch and the panel,
/// clicks on the notch and on the menu-bar item, the hotkey, the space,
/// the settings, and the timers firing.
public enum PanelEvent: Hashable, Sendable {
    case pointerEnteredNotch, pointerLeftNotch
    case pointerEnteredPanel, pointerLeftPanel
    case notchClicked
    /// The menu-bar item: the panel opens under it whatever the notch
    /// settings say, and a second click closes it.
    case statusItemClicked
    case hotkey
    case clickedOutside
    case escape
    case fullscreenChanged(Bool)
    case settingsChanged(PanelSettings)
    /// The host display went away, or the panel is being torn down.
    case hostLost
    case timerFired(PanelTimer)
}

/// What the controller does in response: timers, and showing and hiding
/// the panel. Where the panel opens (the notch, under the menu-bar item,
/// the top center) follows from `openedBy` (`PanelAnchor.resolve`).
public enum PanelEffect: Hashable, Sendable {
    case startTimer(PanelTimer, TimeInterval)
    case cancelTimer(PanelTimer)
    case open
    case close
}

public enum PanelOpener: Hashable, Sendable {
    case hover, click, hotkey
    /// The menu-bar item.
    case statusItem
}

/// The open/close rules of the panel (design/products/macpaper.md, "The
/// panel"): hover opens after a delay and closes after the pointer has
/// left both the notch and the panel; a click opens at once and only a
/// click outside, Escape, the hotkey or fullscreen closes it; the hotkey
/// toggles, from the notch where the notch panel may show and from under
/// the menu-bar item otherwise; the menu-bar item toggles the panel under
/// itself whatever the notch settings say. Pure: the controller owns the
/// timers and the windows and feeds events back.
public struct PanelStateMachine: Hashable, Sendable {
    public private(set) var settings: PanelSettings
    public private(set) var isOpen = false
    public private(set) var openedBy: PanelOpener?
    public private(set) var isFullscreen = false
    public private(set) var pointerInNotch = false
    public private(set) var pointerInPanel = false
    public private(set) var pendingOpen = false
    public private(set) var pendingClose = false

    public init(settings: PanelSettings = PanelSettings()) {
        self.settings = settings
    }

    /// Whether the panel may show now: on, and not hidden by fullscreen.
    public var canShow: Bool {
        settings.isEnabled && !(settings.hideInFullscreen && isFullscreen)
    }

    public mutating func handle(_ event: PanelEvent) -> [PanelEffect] {
        var effects: [PanelEffect] = []
        switch event {
        case .pointerEnteredNotch:
            pointerInNotch = true
            cancelClose(&effects)
            if !isOpen, !pendingOpen, canShow, settings.trigger.opensOnHover {
                pendingOpen = true
                effects.append(.startTimer(.hoverOpen, settings.hoverOpenDelay))
            }
        case .pointerLeftNotch:
            pointerInNotch = false
            cancelPendingOpen(&effects)
            scheduleCloseIfHovering(&effects)
        case .pointerEnteredPanel:
            pointerInPanel = true
            cancelClose(&effects)
        case .pointerLeftPanel:
            pointerInPanel = false
            scheduleCloseIfHovering(&effects)
        case .notchClicked:
            if isOpen {
                close(&effects)
            } else if canShow, settings.trigger.opensOnClick {
                cancelPendingOpen(&effects)
                open(by: .click, &effects)
            }
        case .statusItemClicked:
            if isOpen {
                close(&effects)
            } else {
                cancelPendingOpen(&effects)
                open(by: .statusItem, &effects)
            }
        case .hotkey:
            // Opens whether or not the notch panel may show: under the
            // menu-bar item then (the anchor follows from `openedBy`).
            if isOpen {
                close(&effects)
            } else {
                cancelPendingOpen(&effects)
                open(by: .hotkey, &effects)
            }
        case .clickedOutside, .escape:
            if isOpen { close(&effects) }
        case .fullscreenChanged(let fullscreen):
            isFullscreen = fullscreen
            if !canShow {
                cancelPendingOpen(&effects)
                if isOpen { close(&effects) }
            }
        case .settingsChanged(let next):
            settings = next
            if !canShow {
                cancelPendingOpen(&effects)
                if isOpen { close(&effects) }
            } else if !settings.trigger.opensOnHover {
                cancelPendingOpen(&effects)
            }
        case .hostLost:
            cancelPendingOpen(&effects)
            cancelClose(&effects)
            pointerInNotch = false
            pointerInPanel = false
            if isOpen { close(&effects) }
        case .timerFired(.hoverOpen):
            pendingOpen = false
            if !isOpen, pointerInNotch, canShow, settings.trigger.opensOnHover {
                open(by: .hover, &effects)
            }
        case .timerFired(.hoverClose):
            pendingClose = false
            if isOpen, openedBy == .hover, !pointerInNotch, !pointerInPanel {
                close(&effects)
            }
        }
        return effects
    }

    private mutating func open(by opener: PanelOpener, _ effects: inout [PanelEffect]) {
        isOpen = true
        openedBy = opener
        effects.append(.open)
    }

    private mutating func close(_ effects: inout [PanelEffect]) {
        isOpen = false
        openedBy = nil
        cancelClose(&effects)
        effects.append(.close)
    }

    private mutating func cancelPendingOpen(_ effects: inout [PanelEffect]) {
        guard pendingOpen else { return }
        pendingOpen = false
        effects.append(.cancelTimer(.hoverOpen))
    }

    private mutating func cancelClose(_ effects: inout [PanelEffect]) {
        guard pendingClose else { return }
        pendingClose = false
        effects.append(.cancelTimer(.hoverClose))
    }

    /// A hover-opened panel closes once the pointer has left both the notch
    /// and the panel, after the close delay.
    private mutating func scheduleCloseIfHovering(_ effects: inout [PanelEffect]) {
        guard isOpen, openedBy == .hover, !pointerInNotch, !pointerInPanel, !pendingClose else { return }
        pendingClose = true
        effects.append(.startTimer(.hoverClose, settings.hoverCloseDelay))
    }
}
