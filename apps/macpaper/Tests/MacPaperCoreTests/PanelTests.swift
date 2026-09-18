import Foundation
@testable import MacPaperCore
import Testing

@Suite("Screen notch")
struct ScreenNotchTests {
    /// A 14" MacBook Pro: 1512×982 points, a 37-point menu bar with the
    /// notch, auxiliary areas of 630 points each side of a 252-point notch.
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let left = CGRect(x: 0, y: 945, width: 630, height: 37)
    static let right = CGRect(x: 882, y: 945, width: 630, height: 37)

    @Test("The notch is between the auxiliary areas, as tall as the top inset")
    func rect() {
        let notch = ScreenNotch.rect(screenFrame: Self.screen, topInset: 37, auxiliaryTopLeft: Self.left, auxiliaryTopRight: Self.right)
        #expect(notch == CGRect(x: 630, y: 945, width: 252, height: 37))
        #expect(ScreenNotch.rect(screenFrame: Self.screen, topInset: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil) == nil)
        #expect(ScreenNotch.rect(screenFrame: Self.screen, topInset: 37, auxiliaryTopLeft: Self.left, auxiliaryTopRight: nil) == nil)
        #expect(ScreenNotch.rect(screenFrame: Self.screen, topInset: 37, auxiliaryTopLeft: Self.right, auxiliaryTopRight: Self.left) == nil, "areas the wrong way round")
    }
}

@Suite("Fullscreen")
struct FullscreenHeuristicTests {
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

    @Test("Toggle opens when closed, closes when open")
    func toggle() {
        var panel = PanelStateMachine()
        #expect(panel.handle(.toggle) == .open)
        #expect(panel.isOpen)
        #expect(panel.handle(.toggle) == .close)
        #expect(!panel.isOpen)
    }

    @Test("Click outside, Escape and losing the host close only an open panel")
    func closeOnlyWhenOpen() {
        for event: Event in [.clickedOutside, .escape, .hostLost] {
            var panel = PanelStateMachine()
            #expect(panel.handle(event) == nil, "\(event) on a closed panel")
            _ = panel.handle(.toggle)
            #expect(panel.handle(event) == .close, "\(event) on an open panel")
            #expect(!panel.isOpen)
        }
    }

    @Test("Fullscreen with hide on closes an open panel; with hide off it stays")
    func fullscreenHideOn() {
        var panel = PanelStateMachine(hideInFullscreen: true)
        _ = panel.handle(.toggle)
        #expect(panel.handle(.fullscreenChanged(true)) == .close)
        #expect(!panel.isOpen && !panel.canShow)
        #expect(panel.handle(.fullscreenChanged(false)) == nil)
        #expect(panel.canShow)

        var shown = PanelStateMachine(hideInFullscreen: false)
        _ = shown.handle(.toggle)
        #expect(shown.handle(.fullscreenChanged(true)) == nil)
        #expect(shown.isOpen && shown.canShow)
    }

    @Test("Toggle still opens the panel over a fullscreen app")
    func toggleWhileFullscreen() {
        var panel = PanelStateMachine()
        _ = panel.handle(.fullscreenChanged(true))
        #expect(!panel.canShow)
        #expect(panel.handle(.toggle) == .open)
        #expect(panel.isOpen)
    }

    @Test("Settings turning hide-in-fullscreen on closes an open panel while fullscreen")
    func settingsChangedWhileFullscreen() {
        var panel = PanelStateMachine(hideInFullscreen: false)
        _ = panel.handle(.toggle)
        _ = panel.handle(.fullscreenChanged(true))
        #expect(panel.isOpen)
        #expect(panel.handle(.settingsChanged(hideInFullscreen: true)) == .close)
        #expect(!panel.isOpen)
        // Off again while still fullscreen: nothing to close.
        #expect(panel.handle(.settingsChanged(hideInFullscreen: false)) == nil)
    }
}

@Suite("Hotkey")
struct HotkeyTests {
    @Test("The default is ⌥⌘P, shortcuts print in macOS order, and validity needs a real modifier")
    func hotkey() throws {
        #expect(Hotkey.default.keyCode == 35 && Hotkey.default.modifiers == [.option, .command])
        #expect(Hotkey.default.displayString == "⌥⌘P")
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
        // Any preference, a stored false included, is an earlier launch — a
        // legacy key from an upgrade counts too.
        let upgraded = MemoryFlags()
        upgraded.bools["notch.enabled"] = false
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

    @Test("Every preference key, current and legacy, counts as evidence")
    func evidence() {
        for key in PreferenceKey.all + PreferenceKey.legacy {
            #expect(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(key), Comment(rawValue: key))
        }
        #expect(FreshInstallDefault.Key.earlierPreferenceEvidence.contains(OnboardingLaunch.Key.shown))
        #expect(FreshInstallDefault.Key.earlierPreferenceEvidence.contains("OpenAppsUpdater.checkAutomatically"))
        let store = MemoryFlags()
        #expect(OnboardingLaunch.shouldShow(store: store))
        OnboardingLaunch.markShown(store: store)
        #expect(!OnboardingLaunch.shouldShow(store: store))
    }

    @Test("An upgrade with only legacy notch-trigger keys still counts as an earlier install")
    func legacyKeysAloneAreEarlierInstall() {
        let store = MemoryFlags()
        store.bools[PreferenceKey.legacy[0]] = true
        #expect(FreshInstallDefault.loginItem(store: store).hadPreferences)
    }
}

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test("The text names the version, the displays, the panel and the applied documents")
    func text() {
        let snapshot = DiagnosticsSnapshot(
            appVersion: "0.1.0 (1000)", loginStatus: "on", licensing: "compiled out (source build)",
            displays: [DisplayInfo(id: 1, name: "Built-in Retina Display", pointSize: CGSize(width: 1512, height: 982), scale: 2, notchWidth: 252, isMain: true)],
            width: .regular, hideInFullscreen: true, hotkey: .default, hotkeyProblem: nil,
            shuffle: .hour1, favoritesOnly: false, sameOnAllDisplays: true, favoritesCount: 2,
            applied: ["1": .starter], lastApplied: Date(timeIntervalSince1970: 0)
        )
        let text = snapshot.text(generatedAt: Date(timeIntervalSince1970: 0))
        #expect(text.hasPrefix("macPaper 0.1.0 (1000)\nGenerated: "))
        #expect(text.contains("Open at login: on\nLicensing: compiled out (source build)\n\nDisplays:\n- Built-in Retina Display (1) · 1512×982 pt @2x · 3024×1964 px · notch 252 pt · main\n"))
        #expect(text.contains("Panel: regular · hide in fullscreen on\nHotkey: ⌥⌘P\nShuffle: hour1 · favorites only off · same on all displays on\nFavorites: 2\n"))
        #expect(text.contains("Applied:\n- 1: {\"") && text.contains("\"composition\":\"none\""))
        let empty = DiagnosticsSnapshot(appVersion: "dev", loginStatus: "off", licensing: "x", displays: [], width: .compact, hideInFullscreen: false, hotkey: nil, hotkeyProblem: "taken", shuffle: .off, favoritesOnly: true, sameOnAllDisplays: false, favoritesCount: 0, applied: [:], lastApplied: nil).text()
        #expect(empty.contains("Displays:\n- none") && empty.contains("Panel: compact · hide in fullscreen off") && empty.contains("Hotkey: none (taken)") && empty.contains("Last applied: never") && empty.contains("Applied:\n- nothing yet"))
    }
}
