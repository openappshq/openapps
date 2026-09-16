import Foundation
@testable import MacPaperCore
import Testing

@Suite("Notch geometry")
struct NotchGeometryTests {
    /// A 14" MacBook Pro: 1512×982 points, a 37-point menu bar with the
    /// notch, auxiliary areas of 630 points each side of a 252-point notch.
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let left = CGRect(x: 0, y: 945, width: 630, height: 37)
    static let right = CGRect(x: 882, y: 945, width: 630, height: 37)

    @Test("The notch is between the auxiliary areas, as tall as the top inset")
    func notch() {
        let notch = NotchGeometry.notchRect(screenFrame: Self.screen, topInset: 37, auxiliaryTopLeft: Self.left, auxiliaryTopRight: Self.right)
        #expect(notch == CGRect(x: 630, y: 945, width: 252, height: 37))
        #expect(NotchGeometry.notchRect(screenFrame: Self.screen, topInset: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil) == nil)
        #expect(NotchGeometry.notchRect(screenFrame: Self.screen, topInset: 37, auxiliaryTopLeft: Self.left, auxiliaryTopRight: nil) == nil)
        #expect(NotchGeometry.notchRect(screenFrame: Self.screen, topInset: 37, auxiliaryTopLeft: Self.right, auxiliaryTopRight: Self.left) == nil, "areas the wrong way round")
    }

    @Test("The hover zone is the notch, or a thin hot edge without one")
    func hoverZone() {
        let notch = CGRect(x: 630, y: 945, width: 252, height: 37)
        #expect(NotchGeometry.hoverZone(screenFrame: Self.screen, notch: notch) == notch)
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        #expect(NotchGeometry.hoverZone(screenFrame: external, notch: nil) == CGRect(x: 1512 + 1280 - 100, y: 1438, width: 200, height: 2))
    }

    @Test("The panel hangs from the menu bar, centered on the notch, inside the screen")
    func panelFrame() {
        let notch = CGRect(x: 630, y: 945, width: 252, height: 37)
        let frame = NotchGeometry.panelFrame(screenFrame: Self.screen, menuBarHeight: 37, notch: notch, width: .regular, contentHeight: 500)
        #expect(frame == CGRect(x: 756 - 220, y: 945 - 500, width: 440, height: 500))
        // No notch: centered on the screen, under a 24-point menu bar.
        let plain = NotchGeometry.panelFrame(screenFrame: Self.screen, menuBarHeight: 24, notch: nil, width: .compact, contentHeight: 300)
        #expect(plain == CGRect(x: 756 - 180, y: 982 - 24 - 300, width: 360, height: 300))
        // A notch near the edge: the panel stays on screen.
        let edge = NotchGeometry.panelFrame(screenFrame: Self.screen, menuBarHeight: 37, notch: CGRect(x: 1400, y: 945, width: 100, height: 37), width: .wide, contentHeight: 100)
        #expect(edge.maxX == Self.screen.maxX && edge.width == 560)
        // Taller than the screen: clipped to it.
        let tall = NotchGeometry.panelFrame(screenFrame: Self.screen, menuBarHeight: 37, notch: notch, width: .regular, contentHeight: 5000)
        #expect(tall.minY == 0 && tall.height == 945)
    }

    @Test("Host display resolution")
    func hosts() {
        let notched = DisplayInfo(id: 1, name: "Built-in", pointSize: CGSize(width: 1512, height: 982), scale: 2, notchWidth: 252, isMain: false)
        let external = DisplayInfo(id: 2, name: "External", pointSize: CGSize(width: 2560, height: 1440), scale: 1, isMain: true)
        let second = DisplayInfo(id: 3, name: "Other", pointSize: CGSize(width: 1512, height: 982), scale: 2, notchWidth: 200)
        #expect(HostDisplay.notchDisplay.hosts(among: [external, notched, second]) == [notched])
        #expect(HostDisplay.notchDisplay.hosts(among: [external]).isEmpty)
        #expect(HostDisplay.mainDisplay.hosts(among: [notched, external]) == [external])
        #expect(HostDisplay.mainDisplay.hosts(among: [notched, second]) == [notched], "no main flagged: the first")
        #expect(HostDisplay.everyNotchedDisplay.hosts(among: [external, notched, second]) == [notched, second])
    }

    @Test("Fullscreen: the frontmost app owns a normal-layer window covering the screen")
    func fullscreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        typealias W = FullscreenHeuristic.Window
        let full = W(ownerPID: 10, layer: 0, bounds: screen)
        let sized = W(ownerPID: 10, layer: 0, bounds: CGRect(x: 0, y: 25, width: 1512, height: 957))
        let desktop = W(ownerPID: 3, layer: -2147483623, bounds: screen)
        #expect(FullscreenHeuristic.isFullscreen(windows: [full], frontmostPID: 10, screenBounds: screen))
        #expect(!FullscreenHeuristic.isFullscreen(windows: [full], frontmostPID: 11, screenBounds: screen), "another app is in front")
        #expect(!FullscreenHeuristic.isFullscreen(windows: [sized], frontmostPID: 10, screenBounds: screen), "a window under the menu bar")
        #expect(!FullscreenHeuristic.isFullscreen(windows: [desktop], frontmostPID: 3, screenBounds: screen), "the desktop layer")
        #expect(!FullscreenHeuristic.isFullscreen(windows: [full], frontmostPID: nil, screenBounds: screen))
        #expect(FullscreenHeuristic.isFullscreen(windows: [W(ownerPID: 10, layer: 0, bounds: screen.insetBy(dx: 0.5, dy: 0.5))], frontmostPID: 10, screenBounds: screen), "within tolerance")
    }
}

@Suite("Panel rules")
struct PanelStateMachineTests {
    typealias Event = PanelEvent
    typealias Effect = PanelEffect

    @Test("Hover opens after the delay while the pointer stays, and closes after it leaves both")
    func hover() {
        var panel = PanelStateMachine(settings: PanelSettings(trigger: .both, hoverOpenDelay: 0.18, hoverCloseDelay: 0.4))
        #expect(panel.handle(.pointerEnteredNotch) == [.startTimer(.hoverOpen, 0.18)])
        #expect(panel.pendingOpen)
        #expect(panel.handle(.timerFired(.hoverOpen)) == [.open])
        #expect(panel.isOpen && panel.openedBy == .hover)
        // Into the panel, out of the notch: stays.
        #expect(panel.handle(.pointerEnteredPanel).isEmpty)
        #expect(panel.handle(.pointerLeftNotch).isEmpty)
        // Out of the panel too: the close timer.
        #expect(panel.handle(.pointerLeftPanel) == [.startTimer(.hoverClose, 0.4)])
        // Back before it fires: cancelled.
        #expect(panel.handle(.pointerEnteredPanel) == [.cancelTimer(.hoverClose)])
        #expect(panel.handle(.pointerLeftPanel) == [.startTimer(.hoverClose, 0.4)])
        #expect(panel.handle(.timerFired(.hoverClose)) == [.close])
        #expect(!panel.isOpen)
    }

    @Test("Leaving the notch before the delay cancels the open; a stale timer opens nothing")
    func hoverCancelled() {
        var panel = PanelStateMachine()
        _ = panel.handle(.pointerEnteredNotch)
        #expect(panel.handle(.pointerLeftNotch) == [.cancelTimer(.hoverOpen)])
        #expect(panel.handle(.timerFired(.hoverOpen)).isEmpty)
        #expect(!panel.isOpen)
    }

    @Test("Click opens at once, cancels a pending hover, and only click-outside, Escape, the hotkey or fullscreen close it")
    func click() {
        var panel = PanelStateMachine()
        _ = panel.handle(.pointerEnteredNotch)
        #expect(panel.handle(.notchClicked) == [.cancelTimer(.hoverOpen), .open])
        #expect(panel.openedBy == .click)
        // Hover leaving does not close a click-opened panel.
        #expect(panel.handle(.pointerLeftNotch).isEmpty)
        #expect(panel.handle(.pointerEnteredPanel).isEmpty && panel.handle(.pointerLeftPanel).isEmpty)
        #expect(panel.isOpen)
        #expect(panel.handle(.clickedOutside) == [.close])
        _ = panel.handle(.notchClicked)
        #expect(panel.handle(.escape) == [.close])
        _ = panel.handle(.notchClicked)
        #expect(panel.handle(.hotkey) == [.close])
        _ = panel.handle(.notchClicked)
        #expect(panel.handle(.fullscreenChanged(true)) == [.close])
        // A click on the notch while open closes too.
        _ = panel.handle(.fullscreenChanged(false))
        _ = panel.handle(.notchClicked)
        #expect(panel.handle(.notchClicked) == [.close])
    }

    @Test("Triggers: hover-only ignores clicks, click-only ignores hover")
    func triggers() {
        var hoverOnly = PanelStateMachine(settings: PanelSettings(trigger: .hover))
        #expect(hoverOnly.handle(.notchClicked).isEmpty)
        #expect(hoverOnly.handle(.pointerEnteredNotch) == [.startTimer(.hoverOpen, 0.18)])
        var clickOnly = PanelStateMachine(settings: PanelSettings(trigger: .click))
        #expect(clickOnly.handle(.pointerEnteredNotch).isEmpty)
        #expect(clickOnly.handle(.notchClicked) == [.open])
        // Switching to click-only while a hover is pending cancels it.
        var both = PanelStateMachine()
        _ = both.handle(.pointerEnteredNotch)
        #expect(both.handle(.settingsChanged(PanelSettings(trigger: .click))) == [.cancelTimer(.hoverOpen)])
    }

    @Test("Fullscreen hides the panel and blocks hover; the hotkey opens the popover instead")
    func fullscreen() {
        var panel = PanelStateMachine()
        #expect(panel.handle(.fullscreenChanged(true)).isEmpty)
        #expect(panel.handle(.pointerEnteredNotch).isEmpty)
        #expect(panel.handle(.notchClicked).isEmpty)
        #expect(panel.handle(.hotkey) == [.openPopover])
        #expect(panel.handle(.fullscreenChanged(false)).isEmpty)
        #expect(panel.handle(.hotkey) == [.open])
        #expect(panel.openedBy == .hotkey)
        // With hiding off, fullscreen changes nothing.
        var shown = PanelStateMachine(settings: PanelSettings(hideInFullscreen: false))
        _ = shown.handle(.notchClicked)
        #expect(shown.handle(.fullscreenChanged(true)).isEmpty)
        #expect(shown.isOpen)
        #expect(shown.handle(.hotkey) == [.close])
        #expect(shown.handle(.hotkey) == [.open])
    }

    @Test("Turning the panel off closes it; the hotkey then opens the popover")
    func disabled() {
        var panel = PanelStateMachine()
        _ = panel.handle(.notchClicked)
        #expect(panel.handle(.settingsChanged(PanelSettings(isEnabled: false))) == [.close])
        #expect(panel.handle(.hotkey) == [.openPopover])
        #expect(panel.handle(.pointerEnteredNotch).isEmpty)
        #expect(panel.handle(.notchClicked).isEmpty)
    }

    @Test("Losing the host resets everything")
    func hostLost() {
        var panel = PanelStateMachine()
        _ = panel.handle(.pointerEnteredNotch)
        _ = panel.handle(.timerFired(.hoverOpen))
        _ = panel.handle(.pointerEnteredPanel)
        _ = panel.handle(.pointerLeftNotch)
        _ = panel.handle(.pointerLeftPanel)
        #expect(panel.pendingClose)
        #expect(panel.handle(.hostLost) == [.cancelTimer(.hoverClose), .close])
        #expect(!panel.isOpen && !panel.pointerInNotch && !panel.pointerInPanel && !panel.pendingOpen && !panel.pendingClose)
    }

    @Test("A hover re-entering the notch cancels a pending close")
    func reenter() {
        var panel = PanelStateMachine()
        _ = panel.handle(.pointerEnteredNotch)
        _ = panel.handle(.timerFired(.hoverOpen))
        #expect(panel.handle(.pointerLeftNotch) == [.startTimer(.hoverClose, 0.4)])
        #expect(panel.handle(.pointerEnteredNotch) == [.cancelTimer(.hoverClose)])
        #expect(panel.handle(.timerFired(.hoverClose)).isEmpty, "a timer that fires after being cancelled closes nothing")
        #expect(panel.isOpen)
    }
}

@Suite("Hotkey")
struct HotkeyTests {
    @Test("The default is ⌃⌥⌘W, shortcuts print in macOS order, and validity needs a real modifier")
    func hotkey() throws {
        #expect(Hotkey.default.displayString == "⌃⌥⌘W")
        #expect(Hotkey(keyCode: 49, modifiers: [.shift, .command]).displayString == "⇧⌘Space")
        #expect(Hotkey(keyCode: 0, modifiers: .shift).isValid == false)
        #expect(Hotkey(keyCode: 0, modifiers: .option).isValid)
        #expect(Hotkey(keyCode: 55, modifiers: .command).isValid == false, "a modifier key code")
        // Reserved: the app switcher, Spotlight, screenshots, Quit, Hide, Escape.
        for reserved in [Hotkey(keyCode: 48, modifiers: .command), Hotkey(keyCode: 49, modifiers: .command), Hotkey(keyCode: 49, modifiers: [.command, .option]),
                         Hotkey(keyCode: 20, modifiers: [.command, .shift]), Hotkey(keyCode: 12, modifiers: .command), Hotkey(keyCode: 4, modifiers: .command),
                         Hotkey(keyCode: 53, modifiers: [.command, .option]), Hotkey(keyCode: 12, modifiers: [.command, .control])] {
            #expect(reserved.isReserved && !reserved.isValid, Comment(rawValue: reserved.displayString))
            #expect(reserved.problem?.contains("belongs to macOS") == true)
        }
        #expect(!Hotkey(keyCode: 12, modifiers: [.command, .option]).isReserved, "⌥⌘Q is free")
        #expect(Hotkey.default.problem == nil)
        #expect(Hotkey(keyCode: 0, modifiers: .shift).problem == "Use at least one of ⌘, ⌥ or ⌃.")
        #expect(Hotkey.Modifiers([.command, .shift, .option, .control]).carbonFlags == (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12))
        let data = try JSONEncoder().encode(Hotkey.default)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == .default)
    }
}

@Suite("First run")
struct FirstRunTests {
    final class MemoryFlags: FlagStore {
        var bools: [String: Bool] = [:]
        var ints: [String: Int] = [:]
        var otherValues: Set<String> = []
        func bool(forKey key: String) -> Bool { bools[key] ?? false }
        func integer(forKey key: String) -> Int { ints[key] ?? 0 }
        func set(_ value: Bool, forKey key: String) { bools[key] = value }
        func set(_ value: Int, forKey key: String) { ints[key] = value }
        func removeObject(forKey key: String) { bools[key] = nil; ints[key] = nil; otherValues.remove(key) }
        func hasValue(forKey key: String) -> Bool { bools[key] != nil || ints[key] != nil || otherValues.contains(key) }
    }

    @Test("A fresh install turns the login item on once; anything earlier leaves it alone")
    func freshInstall() {
        let store = MemoryFlags()
        let fresh = FreshInstallDefault.loginItem(store: store)
        #expect(!fresh.hadPreferences && !fresh.isDecided)
        #expect(fresh.shouldTurnOn(isOn: false, storageIsFresh: nil) == false, "storage has not answered")
        #expect(!fresh.isDecided)
        #expect(fresh.shouldTurnOn(isOn: false, storageIsFresh: true))
        #expect(fresh.isDecided)
        #expect(fresh.shouldTurnOn(isOn: false, storageIsFresh: true) == false, "decided once")
        // Any preference, a stored false included, is an earlier launch.
        let upgraded = MemoryFlags()
        upgraded.bools[PreferenceKey.notchEnabled] = false
        #expect(FreshInstallDefault.loginItem(store: upgraded).hadPreferences)
        #expect(FreshInstallDefault.loginItem(store: upgraded).shouldTurnOn(isOn: false, storageIsFresh: true) == false)
        let stringy = MemoryFlags()
        stringy.otherValues.insert(PreferenceKey.hotkey)
        #expect(FreshInstallDefault.loginItem(store: stringy).hadPreferences)
        // Records present: not fresh.
        #expect(FreshInstallDefault.loginItem(store: MemoryFlags()).shouldTurnOn(isOn: false, storageIsFresh: false) == false)
        // Already on: nothing to do, still decided.
        let on = MemoryFlags()
        let onDefault = FreshInstallDefault.loginItem(store: on)
        #expect(onDefault.shouldTurnOn(isOn: true, storageIsFresh: true) == false && onDefault.isDecided)
    }

    @Test("The user's own switch supersedes a pending default")
    func superseded() {
        let store = MemoryFlags()
        let fresh = FreshInstallDefault.loginItem(store: store)
        fresh.markSuperseded()
        #expect(fresh.isDecided)
        #expect(fresh.shouldTurnOn(isOn: false, storageIsFresh: true) == false)
        #expect(FreshInstallDefault.updateChecks(store: store).key == FreshInstallDefault.Key.updateChecksApplied)
    }

    @Test("Every preference key counts as evidence")
    func evidence() {
        for key in PreferenceKey.all {
            #expect(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(key), Comment(rawValue: key))
        }
        #expect(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(OnboardingLaunch.Key.shown))
        #expect(FreshInstallDefault.Key.earlierPreferenceEvidence.contains("OpenAppsUpdater.checkAutomatically"))
        let store = MemoryFlags()
        #expect(OnboardingLaunch.shouldShow(store: store))
        OnboardingLaunch.markShown(store: store)
        #expect(!OnboardingLaunch.shouldShow(store: store))
    }
}

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test("The text names the version, the displays, the panel and the applied documents")
    func text() {
        let snapshot = DiagnosticsSnapshot(
            appVersion: "0.1.0 (1000)", loginStatus: "on", licensing: "compiled out (source build)",
            displays: [DisplayInfo(id: 1, name: "Built-in Retina Display", pointSize: CGSize(width: 1512, height: 982), scale: 2, notchWidth: 252, isMain: true)],
            panelSettings: PanelSettings(), hostDisplay: .notchDisplay, direction: .down, width: .regular, hotkey: .default, hotkeyProblem: nil,
            shuffle: .hour1, favoritesOnly: false, sameOnAllDisplays: true, favoritesCount: 2,
            applied: ["1": .starter], lastApplied: Date(timeIntervalSince1970: 0)
        )
        let text = snapshot.text(generatedAt: Date(timeIntervalSince1970: 0))
        #expect(text.hasPrefix("macPaper 0.1.0 (1000)\nGenerated: "))
        #expect(text.contains("Open at login: on\nLicensing: compiled out (source build)\n\nDisplays:\n- Built-in Retina Display (1) · 1512×982 pt @2x · 3024×1964 px · notch 252 pt · main\n"))
        #expect(text.contains("Notch panel: on · host notchDisplay · opens on both · down · regular · hide in fullscreen on\nHotkey: ⌃⌥⌘W\nShuffle: hour1 · favorites only off · same on all displays on\nFavorites: 2\n"))
        #expect(text.contains("Applied:\n- 1: {\"") && text.contains("\"composition\":\"none\""))
        let empty = DiagnosticsSnapshot(appVersion: "dev", loginStatus: "off", licensing: "x", displays: [], panelSettings: PanelSettings(), hostDisplay: .mainDisplay, direction: .down, width: .compact, hotkey: nil, hotkeyProblem: "taken", shuffle: .off, favoritesOnly: true, sameOnAllDisplays: false, favoritesCount: 0, applied: [:], lastApplied: nil).text()
        #expect(empty.contains("Displays:\n- none") && empty.contains("Hotkey: none (taken)") && empty.contains("Last applied: never") && empty.contains("Applied:\n- nothing yet"))
    }
}
