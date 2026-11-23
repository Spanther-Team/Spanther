import Foundation

/// The sync check (skill `avaudio-rhythm-sync`, section 3): a steady click track; the player taps the screen on every
/// click; the median of how late the taps land, in heard track time with no offset, is this device's offset for the
/// output in use. Taps, not winks: a wink adds the eyes' own delay, which `WinkBeatPlay` learns by itself in play.
public struct WinkBeatSync: Sendable {
    public enum Result: Equatable, Sendable {
        case tooFewTaps
        /// Enough taps, but spread too widely to trust (the offset is still shown).
        case uneven(offset: Double)
        case steady(offset: Double)
    }

    /// The offsets a device may keep (s).
    public static let range: ClosedRange<Double> = -0.2...0.4

    public let beatSec: Double
    /// Track times of the clicks (s).
    public let clicks: [Double]
    /// The first clicks do not count: the player is still finding the beat.
    public let warmUp: Int
    /// Fewest counted taps for a result.
    public let minTaps: Int
    /// Median distance (s) from the offset above which the taps are too uneven to trust.
    public let maxSpread: Double

    /// The first tap on each click: the click's index and how late the tap was (s, negative: early).
    public private(set) var deltas: [Int: Double] = [:]

    public init(bpm: Double = 100, count: Int = 16, leadIn: Double = 1.0, warmUp: Int = 2, minTaps: Int = 8,
                maxSpread: Double = 0.04) {
        beatSec = 60 / bpm
        clicks = (0..<max(1, count)).map { leadIn + Double($0) * 60 / bpm }
        self.warmUp = warmUp
        self.minTaps = minTaps
        self.maxSpread = maxSpread
    }

    /// Half a beat after the last click: later taps cannot count, and the check is over.
    public var endSec: Double { clicks[clicks.count - 1] + beatSec / 2 }

    /// A tap at heard track time `t`. Returns the click it counts for, or nil when it is too far from every click
    /// or that click already has a tap.
    @discardableResult
    public mutating func tap(at t: Double) -> Int? {
        let i = Int(((t - clicks[0]) / beatSec).rounded())
        guard i >= 0, i < clicks.count, deltas[i] == nil else { return nil }
        let d = t - clicks[i]
        guard abs(d) < beatSec * 0.45 else { return nil }
        deltas[i] = d
        return i
    }

    /// The delays that count (after the warm-up), in click order.
    public var counted: [Double] {
        deltas.filter { $0.key >= warmUp }.sorted { $0.key < $1.key }.map(\.value)
    }

    public var result: Result {
        let c = counted
        guard c.count >= minTaps else { return .tooFewTaps }
        let m = Self.median(c)
        let offset = min(Self.range.upperBound, max(Self.range.lowerBound, m))
        let spread = Self.median(c.map { abs($0 - m) })
        return spread <= maxSpread ? .steady(offset: offset) : .uneven(offset: offset)
    }

    /// The latest click at or before `t`, nil before the first.
    public func click(atOrBefore t: Double) -> Int? {
        guard t >= clicks[0] else { return nil }
        return min(clicks.count - 1, Int(((t - clicks[0]) / beatSec).rounded(.down)))
    }

    /// The click track, mono at `sampleRate`, from track time 0 to 0.3 s after `endSec`: a short tick on each click,
    /// higher on every fourth (the start of a bar). Each tick starts on its click's sample.
    public func samples(sampleRate: Double) -> [Float] {
        let n = Int(((endSec + 0.3) * sampleRate).rounded(.up))
        var out = [Float](repeating: 0, count: n)
        let length = Int(0.04 * sampleRate), attack = max(1, Int(0.0005 * sampleRate))
        for (i, c) in clicks.enumerated() {
            let start = Int((c * sampleRate).rounded())
            let hz = i % 4 == 0 ? 2200.0 : 1500.0
            for k in 0..<length where start + k < n {
                let s = Double(k) / sampleRate
                let env = min(1, Double(k) / Double(attack)) * exp(-s / 0.008)
                out[start + k] += Float(0.6 * env * sin(2 * Double.pi * hz * s))
            }
        }
        return out
    }

    /// Milliseconds on the 5 ms step the screen nudges by.
    public static func steppedMs(_ sec: Double) -> Int { Int((sec * 1000 / 5).rounded()) * 5 }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
