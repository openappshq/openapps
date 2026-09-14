import Foundation

/// Compile-time facts about licensing in this build. Present in every build
/// so the rest of the app can ask without `#if`.
enum Licensing {
    #if OPENAPPS_LICENSING
    static let isCompiledIn = true
    #else
    static let isCompiledIn = false
    #endif
}

/// Text shared by the License screen, About and README (LICENSING.md,
/// "Privacy copy").
enum LicensingCopy {
    static let privacy = "Official builds check your license with Dodo Payments, our payment provider. The license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use OpenReaction are never sent. Builds from source never contact the license service."
}
