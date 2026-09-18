import Foundation
@testable import MacPaper
import MacPaperCore
import Testing

@MainActor
struct PreferencesTests {
    @Test("Defaults are the contract's: regular, hide in fullscreen, ⌥⌘P (a fresh install), shuffle off, same on all displays, kept, clock off")
    func defaults() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let preferences = Preferences(defaults: temporary.defaults)
        #expect(preferences.width == .regular)
        #expect(preferences.hideInFullscreen)
        #expect(preferences.hotkey == .default)
        #expect(preferences.hotkeyDefaultPending)
        #expect(preferences.shuffleInterval == .off)
        #expect(!preferences.favoritesOnly)
        #expect(preferences.sameOnAllDisplays)
        #expect(preferences.exportFolder.lastPathComponent == "macPaper")
        #expect(preferences.keepApplied && preferences.clockStyle == .off && preferences.clockPosition == .bottomRight && preferences.clockSize == .medium)
    }

    // The hotkey default's fresh/upgrade/stored/cleared/commit-once matrix
    // is PanelOpenersTests.shortcutDefaultFollowsTheInstall.

    @Test("Every setting round-trips through its key, and a cleared hotkey stays cleared")
    func roundTrip() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let defaults = temporary.defaults
        let preferences = Preferences(defaults: defaults)
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
        preferences.pins = [.seed, .palette]
        let reloaded = Preferences(defaults: defaults)
        #expect(!reloaded.keepApplied && reloaded.clockStyle == .analog && reloaded.clockPosition == .topLeft && reloaded.clockSize == .large)
        #expect(reloaded.width == .wide && !reloaded.hideInFullscreen)
        #expect(reloaded.hotkey == Hotkey(keyCode: 49, modifiers: [.command, .shift]))
        #expect(!reloaded.hotkeyDefaultPending, "a stored hotkey is never a pending default")
        #expect(reloaded.shuffleInterval == .hours3 && reloaded.favoritesOnly && !reloaded.sameOnAllDisplays)
        #expect(reloaded.exportFolder.path == "/tmp/exports")
        #expect(reloaded.pins == [.seed, .palette])
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
        defaults.set("sideways", forKey: PreferenceKey.width)
        defaults.set(Data("junk".utf8), forKey: PreferenceKey.hotkey)
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.width == .regular)
        #expect(preferences.hotkey == nil)
    }

    @Test("A pins file from an earlier panel build, stored under its old names, decodes to the new parameter keys")
    func legacyPinNames() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let defaults = temporary.defaults
        let stored = ["gradientShape", "gradientAngle", "gradientCenter", "gradientBlend", "meshGrid", "meshJitter", "meshSoftness", "patternScale", "patternAngle", "pixelizeBlock", "pixelizePalette", "ditherCell", "ditherPalette", "seed"]
        defaults.set(try JSONEncoder().encode(stored), forKey: PreferenceKey.pins)
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.pins == [.gradientKind, .angle, .center, .interpolation, .columns, .jitter, .softness, .scale, .angle, .blockSize, .paletteSize, .cell, .paletteSize, .seed])
        for (legacy, key) in Preferences.legacyPinNames {
            #expect(ParameterKey(rawValue: legacy) == nil, "\(legacy) collides with a current key")
            #expect(Preferences.legacyPinNames[legacy] == key)
        }
    }
}

struct LicensingSeamTests {
    @Test("The seam's facts follow the build's flavour")
    func facts() {
        #expect(Licensing.appID == "macpaper")
        #expect(Licensing.appName == "macPaper")
        #expect(Licensing.journalSuite == "space.openapps.macpaper.license")
        #expect(Licensing.flavourDescription == (Licensing.isCompiledIn ? "official build" : "compiled out (source build)"))
        #expect(LicensingCopy.network.contains("makes no network calls at all") == (!Licensing.isCompiledIn && !Updating.isCompiledIn))
        #expect(!UpdateTesting.isCompiledIn || Updating.isCompiledIn)
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
