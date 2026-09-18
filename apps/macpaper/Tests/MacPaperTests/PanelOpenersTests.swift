import AppKit
import Foundation
@testable import MacPaper
import MacPaperCore
import SwiftUI
import Testing

/// The panel's openers: the menu-bar item's click is never a click outside,
/// and the shortcut's default follows the install.
@MainActor
struct PanelOpenersTests {
    @Test("A mouse-down in the item's window or the panel's own is not outside; any other window is")
    func statusItemClickIsNotOutside() {
        let panel = NSObject(), item = NSObject(), settings = NSObject()
        let own: [AnyObject?] = [panel, item]
        #expect(!PanelController.clickIsOutside(window: item, own: own))
        #expect(!PanelController.clickIsOutside(window: panel, own: own))
        #expect(PanelController.clickIsOutside(window: settings, own: own))
        #expect(PanelController.clickIsOutside(window: nil, own: own), "no window at all is outside")
        // Without a status item (no window to exclude) nothing changes for the others.
        #expect(!PanelController.clickIsOutside(window: panel, own: [panel, nil]))
        #expect(PanelController.clickIsOutside(window: item, own: [panel, nil]))
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
        upgraded.defaults.set("hover", forKey: "notch.trigger")
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

    @Test("A list measured for the column's height stands in for its rows: count × row height plus the hairlines, nothing built")
    func listStandIn() {
        #expect(PanelList<EmptyView>.height(rows: 0) == 0)
        #expect(PanelList<EmptyView>.height(rows: 1) == PanelLayout.listRowHeight)
        #expect(PanelList<EmptyView>.height(rows: 34) == 34 * PanelLayout.listRowHeight + 33)
    }
}
