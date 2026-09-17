import AppKit
import Foundation
@testable import MacPaper
import MacPaperCore
import SwiftUI
import Testing

/// The review's fix round: the menu-bar item's click is never a click
/// outside, the shortcut's default follows the install, and the first-run
/// glow lets go of the pointer the moment the notch is used. No window is
/// ever ordered in; the hint's panel is created and left off-screen.
@MainActor
struct PanelOpenersTests {
    @Test("A mouse-down in the item's window, the panel or the hover zone is not outside; any other window is")
    func statusItemClickIsNotOutside() {
        let panel = NSObject(), hover = NSObject(), item = NSObject(), settings = NSObject()
        let own: [AnyObject?] = [panel, hover, item]
        #expect(!NotchPanelController.clickIsOutside(window: item, own: own))
        #expect(!NotchPanelController.clickIsOutside(window: panel, own: own))
        #expect(!NotchPanelController.clickIsOutside(window: hover, own: own))
        #expect(NotchPanelController.clickIsOutside(window: settings, own: own))
        #expect(NotchPanelController.clickIsOutside(window: nil, own: own), "no window at all is outside")
        // Without a status item (no window to exclude) nothing changes for the others.
        #expect(!NotchPanelController.clickIsOutside(window: panel, own: [panel, hover, nil]))
        #expect(NotchPanelController.clickIsOutside(window: item, own: [panel, hover, nil]))
    }

    @Test("The item's click as the UI dispatches it — mouse-down, then the toggle on mouse-up — closes an open panel once")
    func itemClickToggles() {
        var machine = PanelStateMachine()
        #expect(machine.handle(.statusItemClicked) == [.open])
        // The mouse-down lands in the item's window: not outside, so the
        // controller sends nothing; the mouse-up toggles.
        #expect(machine.handle(.statusItemClicked) == [.close])
        #expect(!machine.isOpen)
        // The old sequence, for contrast: an outside close then the toggle reopened.
        var old = PanelStateMachine()
        _ = old.handle(.statusItemClicked)
        _ = old.handle(.clickedOutside)
        #expect(old.handle(.statusItemClicked) == [.open], "what the fix prevents from being sent")
    }

    @Test("A fresh install gets ⌥⌘P, an upgrade keeps ⌃⌥⌘W, a stored or cleared shortcut stays, and the default is written once, on request")
    func shortcutDefaultFollowsTheInstall() throws {
        // Fresh: no earlier preference at all.
        let fresh = try TemporaryDefaults()
        defer { fresh.remove() }
        let preferences = Preferences(defaults: fresh.defaults)
        #expect(preferences.hotkey == .default)
        #expect(preferences.hotkeyDefaultPending)
        #expect(!fresh.defaults.hasValue(forKey: PreferenceKey.hotkey), "nothing written before the launch asks: the key is earlier-launch evidence")
        preferences.commitHotkeyDefault()
        #expect(fresh.defaults.hasValue(forKey: PreferenceKey.hotkey))
        #expect(!preferences.hotkeyDefaultPending)
        // The second launch of that fresh install reads the written ⌥⌘P,
        // even though its own preferences now count as earlier evidence.
        fresh.defaults.set(true, forKey: OnboardingLaunch.Key.shown)
        #expect(Preferences(defaults: fresh.defaults).hotkey == .default)

        // An upgrade: earlier preferences, no stored shortcut (0.2 never wrote its default).
        let upgraded = try TemporaryDefaults()
        defer { upgraded.remove() }
        upgraded.defaults.set(true, forKey: OnboardingLaunch.Key.shown)
        upgraded.defaults.set("hover", forKey: PreferenceKey.trigger)
        let legacy = Preferences(defaults: upgraded.defaults)
        #expect(legacy.hotkey == .legacyDefault)
        #expect(legacy.hotkey?.displayString == "⌃⌥⌘W")
        legacy.commitHotkeyDefault()
        #expect(Preferences(defaults: upgraded.defaults).hotkey == .legacyDefault, "written once, read from then on")

        // A stored shortcut, and an explicitly cleared one, are never defaulted.
        let stored = try TemporaryDefaults()
        defer { stored.remove() }
        let chosen = Hotkey(keyCode: 49, modifiers: [.command, .shift])
        stored.defaults.set(try JSONEncoder().encode(chosen), forKey: PreferenceKey.hotkey)
        let kept = Preferences(defaults: stored.defaults)
        #expect(kept.hotkey == chosen && !kept.hotkeyDefaultPending)
        let cleared = try TemporaryDefaults()
        defer { cleared.remove() }
        cleared.defaults.set(Data(), forKey: PreferenceKey.hotkey)
        let none = Preferences(defaults: cleared.defaults)
        #expect(none.hotkey == nil && !none.hotkeyDefaultPending)
        none.commitHotkeyDefault()
        #expect(Preferences(defaults: cleared.defaults).hotkey == nil)

        // A choice made in Settings ends the pending default and is written.
        let chooser = try TemporaryDefaults()
        defer { chooser.remove() }
        let choosing = Preferences(defaults: chooser.defaults)
        choosing.hotkey = chosen
        #expect(!choosing.hotkeyDefaultPending)
        #expect(Preferences(defaults: chooser.defaults).hotkey == chosen)
    }

    /// A pointer monitor the test drives by hand.
    final class FakePointerMonitor: PointerMonitor {
        private(set) var handler: (@MainActor (CGPoint) -> Void)?
        private(set) var installs = 0, removals = 0
        var isInstalled: Bool { handler != nil }
        func install(_ handler: @escaping @MainActor (CGPoint) -> Void) {
            self.handler = handler
            installs += 1
        }
        func remove() {
            if handler != nil { removals += 1 }
            handler = nil
        }
    }

    @Test("The glow watches the pointer only while armed: using the notch removes the monitor at once, tearing down too")
    func glowLetsGoOfThePointer() throws {
        // The pointer never comes near here: a near pointer orders the glow's
        // window in, and no test of this package shows a window. The zone
        // itself is `NotchGeometry.hintZone`, tested in the core.
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first, "a display to lay the glow on")
        let notch = CGRect(x: screen.frame.midX - 126, y: screen.frame.maxY - 37, width: 252, height: 37)
        let flags = MemoryFlags()
        let monitor = FakePointerMonitor()
        let hint = NotchHintController(screen: screen, notch: notch, flags: flags, monitor: monitor)
        #expect(monitor.isInstalled && hint.isWatching && monitor.installs == 1)
        #expect(!hint.isShowing)
        // Far from the notch: nothing shows.
        monitor.handler?(CGPoint(x: screen.frame.minX + 10, y: screen.frame.minY + 10))
        #expect(!hint.isShowing)
        hint.panelOpened()
        #expect(!hint.isShowing)
        // The notch opened the panel: done for good, and the pointer is no longer read.
        hint.markUsed()
        #expect(!monitor.isInstalled && !hint.isWatching)
        #expect(monitor.removals == 1)
        #expect(!hint.isShowing)
        #expect(flags.bool(forKey: NotchHint.Key.used))
        #expect(!NotchHint.isArmed(store: flags))
        hint.tearDown()
        #expect(monitor.removals == 1, "nothing left to remove")

        // Tearing down an armed hint removes the monitor as well.
        let other = FakePointerMonitor()
        let torn = NotchHintController(screen: screen, notch: notch, flags: MemoryFlags(), monitor: other)
        #expect(other.isInstalled)
        torn.tearDown()
        #expect(!other.isInstalled)
    }

    @Test("A list measured for the column's height stands in for its rows: count × row height plus the hairlines, nothing built")
    func listStandIn() {
        #expect(PanelList<EmptyView>.height(rows: 0) == 0)
        #expect(PanelList<EmptyView>.height(rows: 1) == PanelLayout.listRowHeight)
        #expect(PanelList<EmptyView>.height(rows: 34) == 34 * PanelLayout.listRowHeight + 33)
    }
}
