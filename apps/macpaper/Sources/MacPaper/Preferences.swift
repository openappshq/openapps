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
    /// Nil is "no hotkey".
    var hotkey: Hotkey? {
        didSet {
            if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
                defaults.set(data, forKey: PreferenceKey.hotkey)
            } else {
                // Stored as empty data, not removed: "no hotkey" is a choice,
                // and a choice is earlier-launch evidence.
                defaults.set(Data(), forKey: PreferenceKey.hotkey)
            }
        }
    }
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
    /// The parameters pinned in the panel: Shuffle keeps them.
    var pins: PinnedParameters {
        didSet {
            guard pins != oldValue else { return }
            defaults.set((try? JSONEncoder().encode(pins.pins.map(\.rawValue).sorted())) ?? Data(), forKey: PreferenceKey.pins)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notchEnabled = defaults.object(forKey: PreferenceKey.notchEnabled) as? Bool ?? true
        hostDisplay = defaults.string(forKey: PreferenceKey.hostDisplay).flatMap(HostDisplay.init(rawValue:)) ?? .notchDisplay
        trigger = defaults.string(forKey: PreferenceKey.trigger).flatMap(PanelTrigger.init(rawValue:)) ?? .both
        direction = defaults.string(forKey: PreferenceKey.direction).flatMap(PanelDirection.init(rawValue:)) ?? .down
        width = defaults.string(forKey: PreferenceKey.width).flatMap(PanelWidth.init(rawValue:)) ?? .regular
        hideInFullscreen = defaults.object(forKey: PreferenceKey.hideInFullscreen) as? Bool ?? true
        if let data = defaults.data(forKey: PreferenceKey.hotkey) {
            hotkey = data.isEmpty ? nil : try? JSONDecoder().decode(Hotkey.self, from: data)
        } else {
            hotkey = .default
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
        pins = PinnedParameters(Set(pinNames.compactMap(ParameterPin.init(rawValue:))))
    }

    /// The panel rules' view of the settings.
    var panelSettings: PanelSettings {
        PanelSettings(isEnabled: notchEnabled, trigger: trigger, hideInFullscreen: hideInFullscreen)
    }
}
