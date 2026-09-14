import CryptoKit
import Foundation

/// The in-app trial's record (LICENSING.md, "Stored records"): a Keychain
/// item of its own, never deleted by the app.
public struct TrialRecord: Codable, Equatable, Sendable {
    /// Trial start on the local clock: the registry's start converted to
    /// local time, or the local clock at a provisional start.
    public var startedAt: Date
    /// Highest local clock value observed while the record exists; only
    /// ever raised.
    public var lastSeenAt: Date
    /// The trial registry has answered for this Mac.
    public var registered: Bool
    /// A random id standing in for the hardware UUID when that cannot be
    /// read, kept so the device hash stays the same across launches.
    public var fallbackDeviceID: String?

    public init(startedAt: Date, lastSeenAt: Date? = nil, registered: Bool, fallbackDeviceID: String? = nil) {
        self.startedAt = startedAt
        self.lastSeenAt = max(lastSeenAt ?? startedAt, startedAt)
        self.registered = registered
        self.fallbackDeviceID = fallbackDeviceID
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case lastSeenAt = "last_seen_at"
        case registered
        case fallbackDeviceID = "device_id"
    }

    /// `max(now, last_seen_at) − started_at`: setting the clock back never
    /// gives time back.
    public func elapsed(now: Date) -> TimeInterval {
        max(0, max(now, lastSeenAt).timeIntervalSince(startedAt))
    }
}

/// How long the trial lasts. Official builds use `standard`; a debug build
/// may shorten the day to exercise the whole flow.
public struct TrialTiming: Equatable, Sendable {
    /// One trial "day": the unit remaining time is shown in, and the
    /// offline limit of an unregistered trial.
    public let day: TimeInterval

    public init(day: TimeInterval) {
        self.day = max(1, day)
    }

    public static let standard = TrialTiming(day: 24 * 60 * 60)

    /// 3 days.
    public var duration: TimeInterval { 3 * day }
    /// An unregistered trial runs for at most one day.
    public var offlineLimit: TimeInterval { day }
}

/// Where the trial record lives (a Keychain item in the app; memory in
/// tests). Only a read that positively finds nothing returns nil.
public protocol TrialStore: Sendable {
    func loadTrial() throws(LicenseStoreError) -> TrialRecord?
    func saveTrial(_ trial: TrialRecord) throws(LicenseStoreError)
}

/// Outcome of `POST /api/trial`.
public enum TrialRegistrationResult: Equatable, Sendable {
    /// `200 {started_at, now}`, both on the registry's clock.
    case registered(startedAt: Date, now: Date)
    /// `429`: no call before `retryAfter` seconds.
    case rateLimited(retryAfter: TimeInterval)
    /// Anything else, including no answer: offline.
    case unreachable
}

/// The trial registry. Sends only the app id, the device hash and the
/// environment.
public protocol TrialRegistryClient: Sendable {
    func register(device: String) async -> TrialRegistrationResult
}

/// Reads this Mac's hardware UUID; nil when it cannot be read.
public protocol DeviceIdentity: Sendable {
    func hardwareUUID() -> String?
}

public enum TrialDevice {
    /// Lowercase hex SHA-256 of `openapps-trial-v1:<app id>:<hardware id>`.
    /// The app id salts it, so one Mac's hashes for two apps differ, and the
    /// raw id never leaves the Mac.
    public static func hash(app: String, hardwareID: String) -> String {
        SHA256.hash(data: Data("openapps-trial-v1:\(app):\(hardwareID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// The registry's HTTP answer, decoded by the contract. Kept here, free of
/// URLSession, so the rules are tested with the core.
public enum TrialRegistryResponse {
    public static func result(statusCode: Int, retryAfter: String?, body: Data, now: Date = Date()) -> TrialRegistrationResult {
        switch statusCode {
        case 200:
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let started = (object["started_at"] as? String).flatMap(parseISO8601),
                  let serverNow = (object["now"] as? String).flatMap(parseISO8601) else { return .unreachable }
            return .registered(startedAt: started, now: serverNow)
        case 429:
            return .rateLimited(retryAfter: retryAfterSeconds(retryAfter, now: now))
        default:
            return .unreachable
        }
    }

    public static func requestBody(app: String, device: String, environment: String) -> Data {
        // Fixed keys and hex/identifier values: no escaping concerns, and
        // nothing else is ever sent.
        (try? JSONSerialization.data(withJSONObject: ["app": app, "device": device, "env": environment], options: [.sortedKeys])) ?? Data()
    }

    static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Seconds or an HTTP date, bounded to 1 s … 1 day; 60 s when absent
    /// or unusable.
    static func retryAfterSeconds(_ header: String?, now: Date) -> TimeInterval {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return 60 }
        let seconds: TimeInterval
        if let number = TimeInterval(value), number.isFinite {
            seconds = number
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: value) else { return 60 }
            seconds = date.timeIntervalSince(now)
        }
        return min(max(1, seconds), 86_400)
    }
}
