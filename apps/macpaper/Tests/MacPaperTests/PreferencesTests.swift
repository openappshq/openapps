import Foundation
@testable import MacPaper
import MacPaperCore
import Testing

@MainActor
struct PreferencesTests {
    @Test("Defaults are the contract's: on, the notch display, hover or click, down, regular, hide in fullscreen, ⌃⌥⌘W, shuffle off, same on all displays, kept, clock off")
    func defaults() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let preferences = Preferences(defaults: temporary.defaults)
        #expect(preferences.notchEnabled)
        #expect(preferences.hostDisplay == .notchDisplay)
        #expect(preferences.trigger == .both)
        #expect(preferences.direction == .down)
        #expect(preferences.width == .regular)
        #expect(preferences.hideInFullscreen)
        #expect(preferences.hotkey == .default)
        #expect(preferences.shuffleInterval == .off)
        #expect(!preferences.favoritesOnly)
        #expect(preferences.sameOnAllDisplays)
        #expect(preferences.exportFolder.lastPathComponent == "macPaper")
        #expect(preferences.panelSettings == PanelSettings())
        #expect(preferences.keepApplied && preferences.clockStyle == .off && preferences.clockPosition == .bottomRight && preferences.clockSize == .medium)
    }

    @Test("Every setting round-trips through its key, and a cleared hotkey stays cleared")
    func roundTrip() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let defaults = temporary.defaults
        let preferences = Preferences(defaults: defaults)
        preferences.notchEnabled = false
        preferences.hostDisplay = .everyNotchedDisplay
        preferences.trigger = .hover
        preferences.direction = .left
        preferences.width = .wide
        preferences.hideInFullscreen = false
        preferences.hotkey = Hotkey(keyCode: 49, modifiers: [.command, .shift])
        preferences.shuffleInterval = .hours3
        preferences.favoritesOnly = true
        preferences.sameOnAllDisplays = false
        preferences.exportFolder = URL(fileURLWithPath: "/tmp/exports", isDirectory: true)
        preferences.keepApplied = false
        preferences.clockStyle = .analog
        preferences.clockPosition = .topLeft
        preferences.clockSize = .large
        let reloaded = Preferences(defaults: defaults)
        #expect(!reloaded.keepApplied && reloaded.clockStyle == .analog && reloaded.clockPosition == .topLeft && reloaded.clockSize == .large)
        #expect(!reloaded.notchEnabled && reloaded.hostDisplay == .everyNotchedDisplay && reloaded.trigger == .hover)
        #expect(reloaded.direction == .left && reloaded.width == .wide && !reloaded.hideInFullscreen)
        #expect(reloaded.hotkey == Hotkey(keyCode: 49, modifiers: [.command, .shift]))
        #expect(reloaded.shuffleInterval == .hours3 && reloaded.favoritesOnly && !reloaded.sameOnAllDisplays)
        #expect(reloaded.exportFolder.path == "/tmp/exports")
        #expect(reloaded.panelSettings == PanelSettings(isEnabled: false, trigger: .hover, hideInFullscreen: false))
        reloaded.hotkey = nil
        #expect(Preferences(defaults: defaults).hotkey == nil, "not the default again")
        #expect(defaults.hasValue(forKey: PreferenceKey.hotkey), "a cleared hotkey is a choice, and evidence")
        for key in PreferenceKey.all {
            #expect(defaults.hasValue(forKey: key), Comment(rawValue: key))
        }
    }

    @Test("A stored value that is not a case falls back to the default")
    func badValues() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let defaults = temporary.defaults
        defaults.set("sideways", forKey: PreferenceKey.direction)
        defaults.set(Data("junk".utf8), forKey: PreferenceKey.hotkey)
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.direction == .down)
        #expect(preferences.hotkey == nil)
    }
}

struct LicensingSeamTests {
    @Test("The seam's facts for a source build")
    func facts() {
        #expect(!Licensing.isCompiledIn)
        #expect(Licensing.appID == "macpaper")
        #expect(Licensing.appName == "macPaper")
        #expect(Licensing.journalSuite == "space.openapps.macpaper.license")
        #expect(Licensing.flavourDescription == "compiled out (source build)")
        #expect(LicensingCopy.network.contains("makes no network calls at all"))
        #expect(!UpdateTesting.isCompiledIn)
    }

    @Test("The status asks its source each time and publishes changes")
    @MainActor
    func status() {
        let status = LicenseStatus()
        #expect(status.hasAccess() && status.restriction() == nil)
        var allowed = true
        status.bind(access: { allowed }, restriction: { allowed ? nil : .trialEndedSample }, canBuy: true)
        #expect(status.hasAccess() && status.canBuy)
        allowed = false
        #expect(!status.hasAccess(), "asked, not remembered")
        #expect(status.restriction()?.actions == [.buy, .enterKey])
        var bought = false
        status.buy = { bought = true }
        status.perform(.buy)
        #expect(bought)
        status.setBusy(true)
        #expect(status.isBusy)
    }
}
