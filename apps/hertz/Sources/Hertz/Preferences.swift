import Foundation
import HertzCore
import Observation

/// The few settings Hertz has, saved as they change. Everything else the app
/// shows is read live from the system.
@Observable
final class Preferences {
    private enum Key {
        static let readout = "menuBarReadout"
        static let diagnosis = "showsDiagnosis"
        static let sleepBlockers = "showsSleepBlockers"
        static let processes = "showsProcesses"
        static let cleanup = "showsCleanupScout"
        static let welcomed = "didShowWelcome"
        static let loginDefaulted = "didDefaultOpenAtLogin"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var menuBarReadout: MenuBarReadout {
        didSet { defaults.set(menuBarReadout.rawValue, forKey: Key.readout) }
    }
    var showsDiagnosis: Bool {
        didSet { defaults.set(showsDiagnosis, forKey: Key.diagnosis) }
    }
    var showsSleepBlockers: Bool {
        didSet { defaults.set(showsSleepBlockers, forKey: Key.sleepBlockers) }
    }
    var showsProcesses: Bool {
        didSet { defaults.set(showsProcesses, forKey: Key.processes) }
    }
    var showsCleanupScout: Bool {
        didSet { defaults.set(showsCleanupScout, forKey: Key.cleanup) }
    }
    /// The welcome window is shown once, on the first launch of a packaged app.
    var didShowWelcome: Bool {
        didSet { defaults.set(didShowWelcome, forKey: Key.welcomed) }
    }
    /// "Open at login" is turned on once, on the first launch of a packaged
    /// app; after that the user's own choice in Settings (or in System
    /// Settings → Login Items) is never overridden.
    var didDefaultOpenAtLogin: Bool {
        didSet { defaults.set(didDefaultOpenAtLogin, forKey: Key.loginDefaulted) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarReadout = defaults.string(forKey: Key.readout).flatMap(MenuBarReadout.init(rawValue:)) ?? .cpu
        showsDiagnosis = defaults.object(forKey: Key.diagnosis) as? Bool ?? true
        showsSleepBlockers = defaults.object(forKey: Key.sleepBlockers) as? Bool ?? true
        showsProcesses = defaults.object(forKey: Key.processes) as? Bool ?? true
        showsCleanupScout = defaults.object(forKey: Key.cleanup) as? Bool ?? true
        didShowWelcome = defaults.bool(forKey: Key.welcomed)
        didDefaultOpenAtLogin = defaults.bool(forKey: Key.loginDefaulted)
    }
}
