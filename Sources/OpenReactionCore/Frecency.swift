import Foundation

/// Use counts that decay over time, so both frequent and recent choices rank
/// higher and stale habits fade. Each use adds 1 to a value that halves every
/// `halfLife`.
public struct Frecency: Codable, Equatable, Sendable {
    private struct Entry: Codable, Equatable, Sendable {
        var value: Double
        var updated: Date
    }

    public let halfLife: TimeInterval
    public let limit: Int
    private var entries: [String: Entry]

    public init(halfLife: TimeInterval = 14 * 24 * 60 * 60, limit: Int = 200) {
        self.halfLife = halfLife
        self.limit = limit
        entries = [:]
    }

    public mutating func record(_ item: String, now: Date = Date()) {
        let current = score(item, now: now)
        entries[item] = Entry(value: current + 1, updated: now)
        if entries.count > limit {
            let weakest = entries.min { score(forEntry: $0.value, now: now) < score(forEntry: $1.value, now: now) }
            if let weakest { entries.removeValue(forKey: weakest.key) }
        }
    }

    public func score(_ item: String, now: Date = Date()) -> Double {
        entries[item].map { score(forEntry: $0, now: now) } ?? 0
    }

    /// Scores for every tracked item at `now`.
    public func scores(now: Date = Date()) -> [String: Double] {
        entries.mapValues { score(forEntry: $0, now: now) }
    }

    private func score(forEntry entry: Entry, now: Date) -> Double {
        let elapsed = max(0, now.timeIntervalSince(entry.updated))
        return entry.value * pow(0.5, elapsed / halfLife)
    }
}
