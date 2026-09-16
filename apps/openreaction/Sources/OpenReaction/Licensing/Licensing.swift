import Foundation
import OpenAppsLicensing

/// Compile-time facts about licensing in this build. Present in every build
/// so the rest of the app can ask without `#if`.
enum Licensing {
    #if OPENAPPS_LICENSING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif

    /// The app id the record store, the trial registry and the device hash use.
    static let appID = "openreaction"
    /// The app as the License screen and the badge name it.
    static let appName = "OpenReaction"
    /// The preferences suite the invalidation journal lives in.
    static let journalSuite = "space.openapps.openreaction.license"

    /// The trial's length. A debug build can shorten it to run the whole
    /// flow (start, "less than a day left", the offline limit, the end) in
    /// minutes: `OPENREACTION_DEBUG_TRIAL_DAY_SECONDS=60` makes a trial
    /// "day" one minute, so the trial lasts three. Release builds always use
    /// the real length; the override is not compiled into them.
    static var trialTiming: TrialTiming {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["OPENREACTION_DEBUG_TRIAL_DAY_SECONDS"]
            ?? UserDefaults.standard.string(forKey: "OpenReactionDebugTrialDaySeconds"),
            let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 1 {
            return TrialTiming(day: seconds)
        }
        #endif
        return .standard
    }
}

/// Text shared by the License screen, About and README (LICENSING.md,
/// "Privacy copy").
enum LicensingCopy {
    static let privacy = "Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use OpenReaction are never sent. Builds from source never contact the license service."
}
