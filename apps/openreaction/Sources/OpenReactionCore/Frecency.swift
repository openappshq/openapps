import Foundation

/// Use counts that decay over time, so both frequent and recent choices rank
/// higher and stale habits fade. Each use adds 1 to a value that halves every
/// `halfLifeDays`.
///
/// Persisted, so it only keeps what ranking needs: the emoji, a decayed count
/// and the day (not the time) it was last used. Nothing about the surrounding
/// text is ever recorded.
public struct Frecency: Codable, Equatable, Sendable {
    private struct Entry: Codable, Equatable, Sendable {
        var value: Double
        /// Days since 1970-01-01 (UTC) of the last use.
        var day: Int
    }

    public let halfLifeDays: Double
    public let limit: Int
    private var entries: [String: Entry]

    public init(halfLifeDays: Double = 14, limit: Int = 200) {
        self.halfLifeDays = halfLifeDays
        self.limit = limit
        entries = [:]
    }

    public var isEmpty: Bool { entries.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case halfLifeDays, limit, entries
        // Keys written by the first release, which stored exact timestamps.
        case legacyHalfLife = "halfLife"
    }

    private struct LegacyEntry: Decodable {
        let value: Double
        let updated: Date
    }

    /// Reads the current format, and converts entries from the first release
    /// (a half-life in seconds and an exact `updated` date per emoji) to day
    /// buckets so re-saving drops the timestamps.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 200
        if let days = try container.decodeIfPresent(Double.self, forKey: .halfLifeDays) {
            halfLifeDays = days
            entries = try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        } else {
            let seconds = try container.decodeIfPresent(Double.self, forKey: .legacyHalfLife) ?? 14 * 86_400
            halfLifeDays = max(1, seconds / 86_400)
            let legacy = try container.decodeIfPresent([String: LegacyEntry].self, forKey: .entries) ?? [:]
            entries = legacy.mapValues { Entry(value: $0.value, day: Self.day(of: $0.updated)) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(halfLifeDays, forKey: .halfLifeDays)
        try container.encode(limit, forKey: .limit)
        try container.encode(entries, forKey: .entries)
    }

    public mutating func record(_ item: String, now: Date = Date()) {
        let today = Self.day(of: now)
        entries[item] = Entry(value: score(item, now: now) + 1, day: today)
        if entries.count > limit {
            let weakest = entries.min { score(forEntry: $0.value, day: today) < score(forEntry: $1.value, day: today) }
            if let weakest { entries.removeValue(forKey: weakest.key) }
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    public func score(_ item: String, now: Date = Date()) -> Double {
        entries[item].map { score(forEntry: $0, day: Self.day(of: now)) } ?? 0
    }

    /// Scores for every tracked item at `now`.
    public func scores(now: Date = Date()) -> [String: Double] {
        let today = Self.day(of: now)
        return entries.mapValues { score(forEntry: $0, day: today) }
    }

    static func day(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    private func score(forEntry entry: Entry, day: Int) -> Double {
        let elapsedDays = Double(max(0, day - entry.day))
        return entry.value * pow(0.5, elapsedDays / halfLifeDays)
    }
}
