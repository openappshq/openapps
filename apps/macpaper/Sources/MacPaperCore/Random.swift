import Foundation

/// SplitMix64: a small, fast generator whose sequence for a seed is the same
/// on every Mac and every OS version. Every random choice a document makes
/// (control points, palette order, noise, grain) comes from this, so a seed
/// reproduces a wallpaper exactly.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in 0..<1.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// A double in `range`.
    public mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }
}

/// Position-keyed noise: one value per integer cell and seed, independent of
/// the order pixels are visited, so a render is the same whatever the
/// renderer's tiling or threading.
public enum Hash {
    /// A well-mixed 64-bit hash of three integers.
    @inline(__always)
    public static func mix(_ x: Int64, _ y: Int64, _ seed: UInt64) -> UInt64 {
        var h = seed ^ 0x9E37_79B9_7F4A_7C15
        h = (h ^ UInt64(bitPattern: x)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 31)) &* 0x94D0_49BB_1331_11EB
        h = (h ^ UInt64(bitPattern: y)) &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 29
        h &*= 0x94D0_49BB_1331_11EB
        h ^= h >> 32
        return h
    }

    /// The hash as a value in 0..<1.
    @inline(__always)
    public static func unit(_ x: Int64, _ y: Int64, _ seed: UInt64) -> Double {
        Double(mix(x, y, seed) >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

extension UInt64 {
    /// A seed for a new document: from the system generator, never the
    /// clock, so two documents made in the same second differ.
    public static func randomSeed() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }
}
