import Foundation
import HertzCore
import Observation

/// The few settings Hertz has, saved as they change. Everything else the app
/// shows is read live from the system. The first-run flags (the setup
/// guide, the login-item default) live in `HertzCore`'s `OnboardingLaunch`
/// and `FreshInstallDefault`, on the same defaults domain; every key written
/// here is listed in `FreshInstallDefault.Key.earlierPreferenceEvidence`.
@Observable
final class Preferences {
    private enum Key {
        static let readout = "menuBarReadout"
        static let diagnosis = "showsDiagnosis"
        static let sleepBlockers = "showsSleepBlockers"
        static let processes = "showsProcesses"
        static let cleanup = "showsCleanupScout"
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarReadout = defaults.string(forKey: Key.readout).flatMap(MenuBarReadout.init(rawValue:)) ?? .cpu
        showsDiagnosis = defaults.object(forKey: Key.diagnosis) as? Bool ?? true
        showsSleepBlockers = defaults.object(forKey: Key.sleepBlockers) as? Bool ?? true
        showsProcesses = defaults.object(forKey: Key.processes) as? Bool ?? true
        showsCleanupScout = defaults.object(forKey: Key.cleanup) as? Bool ?? true
    }
}
