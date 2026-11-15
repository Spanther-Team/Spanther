import Foundation

// Feel: the math of the burst. Everything a sky-stone does when the gaze breaks it is worked out here, in plain
// Swift with no Apple framework, so it builds and tests on any platform: the stone's shape, the pieces it will
// part into, the cracks that run along those pieces' edges, how the pieces fly, and the sounds. The app only draws
// and plays what this module hands it.
//
// Every draw comes from FeelRandom, never from Double.random or shuffled(), so a seed gives the same stone, the same
// shards and the same sounds on every platform and Swift version.

/// SplitMix64. The same seed gives the same numbers on every platform.
public struct FeelRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1, from the top 53 bits.
    public mutating func unit() -> Double {
        let bits: UInt64 = next()
        return Double(bits >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Uniform in a..<b.
    public mutating func uniform(_ a: Double, _ b: Double) -> Double {
        return a + (b - a) * unit()
    }

    /// Uniform over the whole numbers of `range`, both ends included. Always takes one draw.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let u = unit()
        let n = range.upperBound - range.lowerBound + 1
        if n <= 1 { return range.lowerBound }
        return range.lowerBound + min(n - 1, Int(u * Double(n)))
    }
}
