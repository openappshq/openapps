import Foundation
import MacPaperCore
import Observation

/// The settings, saved as they change, under the keys `PreferenceKey`
/// lists (every one of them counts as earlier-launch evidence for the
/// fresh-install default). The first-run flags live beside them in the
/// same defaults domain. Documents, favorites and imports are files under
/// Application Support, not preferences.
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var notchEnabled: Bool {
        didSet { defaults.set(notchEnabled, forKey: PreferenceKey.notchEnabled) }
    }
    var hostDisplay: HostDisplay {
        didSet { defaults.set(hostDisplay.rawValue, forKey: PreferenceKey.hostDisplay) }
    }
    var trigger: PanelTrigger {
        didSet { defaults.set(trigger.rawValue, forKey: PreferenceKey.trigger) }
    }
    var direction: PanelDirection {
        didSet { defaults.set(direction.rawValue, forKey: PreferenceKey.direction) }
    }
    var width: PanelWidth {
        didSet { defaults.set(width.rawValue, forKey: PreferenceKey.width) }
    }
    var hideInFullscreen: Bool {
        didSet { defaults.set(hideInFullscreen, forKey: PreferenceKey.hideInFullscreen) }
    }
    /// How long the pointer rests on the notch before a hover opens, in
    /// seconds; kept within `Preferences.hoverDelayRange`.
    var hoverDelay: TimeInterval {
        didSet { defaults.set(hoverDelay, forKey: PreferenceKey.hoverDelay) }
    }
    /// Nil is "no hotkey". Without a stored value the default depends on
    /// the install: ⌥⌘P on a fresh one, ⌃⌥⌘W where an earlier launch left
    /// preferences (the shortcut those installs had); `commitHotkeyDefault`
    /// writes the choice once, so later launches read it like any other.
    var hotkey: Hotkey? {
        didSet {
            hotkeyDefaultPending = false
            writeHotkey()
        }
    }
    /// The hotkey was defaulted, not read: to be written once the launch
    /// has read its fresh-install evidence.
    @ObservationIgnored private(set) var hotkeyDefaultPending = false
    var shuffleInterval: ShuffleInterval {
        didSet { defaults.set(shuffleInterval.rawValue, forKey: PreferenceKey.shuffleInterval) }
    }
    var favoritesOnly: Bool {
        didSet { defaults.set(favoritesOnly, forKey: PreferenceKey.favoritesOnly) }
    }
    var sameOnAllDisplays: Bool {
        didSet { defaults.set(sameOnAllDisplays, forKey: PreferenceKey.sameOnAllDisplays) }
    }
    /// The export folder's path; the default is `~/Pictures/macPaper`.
    var exportFolder: URL {
        didSet { defaults.set(exportFolder.path, forKey: PreferenceKey.exportFolder) }
    }
    /// Pin so it stays: re-apply macPaper's file when macOS shows something else.
    var keepApplied: Bool {
        didSet { defaults.set(keepApplied, forKey: PreferenceKey.keepApplied) }
    }
    var clockStyle: ClockStyle {
        didSet { defaults.set(clockStyle.rawValue, forKey: PreferenceKey.clockStyle) }
    }
    var clockPosition: ClockPosition {
        didSet { defaults.set(clockPosition.rawValue, forKey: PreferenceKey.clockPosition) }
    }
    var clockSize: ClockSize {
        didSet { defaults.set(clockSize.rawValue, forKey: PreferenceKey.clockSize) }
    }
    /// The parameters pinned in the panel: Shuffle keeps them. The
    /// user's, not a document's — they survive loading a recipe — and
    /// mirrored into the draft (`Wallpaper.pinned`) so a share or a
    /// recipe file carries them.
    var pins: Set<ParameterKey> {
        didSet {
            guard pins != oldValue else { return }
            defaults.set((try? JSONEncoder().encode(pins.map(\.rawValue).sorted())) ?? Data(), forKey: PreferenceKey.pins)
        }
    }

    /// The names an earlier panel build stored, mapped to the keys.
    static let legacyPinNames: [String: ParameterKey] = [
        "gradientShape": .gradientKind, "gradientAngle": .angle, "gradientCenter": .center, "gradientBlend": .interpolation,
        "meshGrid": .columns, "meshJitter": .jitter, "meshSoftness": .softness,
        "patternScale": .scale, "patternAngle": .angle,
        "pixelizeBlock": .blockSize, "pixelizePalette": .paletteSize,
        "ditherCell": .cell, "ditherPalette": .paletteSize,
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notchEnabled = defaults.object(forKey: PreferenceKey.notchEnabled) as? Bool ?? true
        hostDisplay = defaults.string(forKey: PreferenceKey.hostDisplay).flatMap(HostDisplay.init(rawValue:)) ?? .notchDisplay
        trigger = defaults.string(forKey: PreferenceKey.trigger).flatMap(PanelTrigger.init(rawValue:)) ?? .both
        direction = defaults.string(forKey: PreferenceKey.direction).flatMap(PanelDirection.init(rawValue:)) ?? .down
        width = defaults.string(forKey: PreferenceKey.width).flatMap(PanelWidth.init(rawValue:)) ?? .regular
        hideInFullscreen = defaults.object(forKey: PreferenceKey.hideInFullscreen) as? Bool ?? true
        let storedDelay = defaults.object(forKey: PreferenceKey.hoverDelay) as? Double ?? PanelSettings.defaultHoverOpenDelay
        hoverDelay = Self.hoverDelayRange.contains(storedDelay) ? storedDelay : PanelSettings.defaultHoverOpenDelay
        if let data = defaults.data(forKey: PreferenceKey.hotkey) {
            hotkey = data.isEmpty ? nil : try? JSONDecoder().decode(Hotkey.self, from: data)
        } else {
            // Read before anything is written: an upgrade keeps the shortcut
            // it had, a fresh install gets the new one.
            let hadEarlierPreferences = FreshInstallDefault.Key.earlierPreferenceEvidence.contains { defaults.object(forKey: $0) != nil }
            hotkey = hadEarlierPreferences ? .legacyDefault : .default
            hotkeyDefaultPending = true
        }
        shuffleInterval = defaults.string(forKey: PreferenceKey.shuffleInterval).flatMap(ShuffleInterval.init(rawValue:)) ?? .off
        favoritesOnly = defaults.object(forKey: PreferenceKey.favoritesOnly) as? Bool ?? false
        sameOnAllDisplays = defaults.object(forKey: PreferenceKey.sameOnAllDisplays) as? Bool ?? true
        exportFolder = defaults.string(forKey: PreferenceKey.exportFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppPaths.defaultExportFolder
        keepApplied = defaults.object(forKey: PreferenceKey.keepApplied) as? Bool ?? true
        clockStyle = defaults.string(forKey: PreferenceKey.clockStyle).flatMap(ClockStyle.init(rawValue:)) ?? .off
        clockPosition = defaults.string(forKey: PreferenceKey.clockPosition).flatMap(ClockPosition.init(rawValue:)) ?? .bottomRight
        clockSize = defaults.string(forKey: PreferenceKey.clockSize).flatMap(ClockSize.init(rawValue:)) ?? .medium
        let pinNames = defaults.data(forKey: PreferenceKey.pins).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        pins = Set(pinNames.compactMap { ParameterKey(rawValue: $0) ?? Self.legacyPinNames[$0] })
    }

    /// Writes a defaulted hotkey so the next launch reads it. Called once
    /// the launch has read its fresh-install evidence (the login item's and
    /// the updater's), since the key is itself evidence of an earlier launch.
    func commitHotkeyDefault() {
        guard hotkeyDefaultPending else { return }
        hotkeyDefaultPending = false
        writeHotkey()
    }

    private func writeHotkey() {
        if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: PreferenceKey.hotkey)
        } else {
            // Stored as empty data, not removed: "no hotkey" is a choice,
            // and a choice is earlier-launch evidence.
            defaults.set(Data(), forKey: PreferenceKey.hotkey)
        }
    }

    /// What the hover delay may be set to, in seconds.
    static let hoverDelayRange: ClosedRange<TimeInterval> = 0.05...1.0

    /// The panel rules' view of the settings.
    var panelSettings: PanelSettings {
        PanelSettings(isEnabled: notchEnabled, trigger: trigger, hideInFullscreen: hideInFullscreen, hoverOpenDelay: hoverDelay)
    }
}
