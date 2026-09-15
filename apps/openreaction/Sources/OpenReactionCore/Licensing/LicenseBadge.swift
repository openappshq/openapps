import Foundation

/// The one-line license status shown where the user looks: the pill in the
/// settings window's header and the line in the status menu. Nothing while
/// the Mac is simply licensed; otherwise the trial's remaining time, or the
/// short reason the core feature is off (LICENSING.md, "States").
public enum LicenseBadge {
    public enum Tone: Equatable, Sendable {
        /// The feature runs (a trial, or the trial is starting).
        case trial
        /// The feature is off, or a licensed Mac must connect soon.
        case attention
    }

    public struct Label: Equatable, Sendable {
        public var text: String
        public var tone: Tone

        public init(text: String, tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }

    /// `storageError` and `trialStorageError` refine `trialUnavailable`: a
    /// record that cannot be read is said instead of "starting".
    public static func label(for state: LicenseState, storageError: Bool = false, trialStorageError: Bool = false) -> Label? {
        switch state {
        case .licensed:
            return nil
        case .grace(_, showWarning: false):
            return nil
        case .trial(let days):
            return Label(text: trialText(daysLeft: days), tone: .trial)
        case .trialUnavailable:
            if storageError { return Label(text: "Can’t read the license record", tone: .attention) }
            if trialStorageError { return Label(text: "Can’t read or save the free trial record", tone: .attention) }
            return Label(text: "Starting your free trial…", tone: .trial)
        case .trialEnded:
            return Label(text: "Trial ended", tone: .attention)
        case .trialNeedsConnection:
            return Label(text: "Connect to the internet to continue your free trial", tone: .attention)
        case .trialClockBehind:
            return Label(text: "Your Mac’s clock is behind", tone: .attention)
        case .grace(let days, showWarning: true):
            return Label(text: "Connect to the internet within \(days) day\(days == 1 ? "" : "s") to keep using OpenReaction", tone: .attention)
        case .checkRequired:
            return Label(text: "Connect to the internet to verify your license", tone: .attention)
        case .revoked:
            return Label(text: "License no longer active on this Mac", tone: .attention)
        }
    }

    /// "Free trial · N days left", or "less than a day left" on the last day.
    public static func trialText(daysLeft days: Int) -> String {
        days <= 1 ? "Free trial · less than a day left" : "Free trial · \(days) days left"
    }
}
