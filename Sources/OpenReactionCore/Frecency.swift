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
