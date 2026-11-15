import XCTest
@testable import Feel

/// Helpers shared by the Feel tests.
enum FeelCheck {
    /// Twice the signed area: positive for a counter-clockwise polygon (y up).
    static func signedArea(_ p: ConvexPolygon) -> Double {
        let v = p.vertices
        let n = v.count
        if n < 3 { return 0 }
        var twice = 0.0
        for i in 0..<n {
            let a = v[i]
            let b = v[(i + 1) % n]
            twice += a.x * b.y - a.y * b.x
        }
        return twice * 0.5
    }

    /// At least 3 vertices, a positive (counter-clockwise) area, and no corner that turns clockwise by more than
    /// rounding.
    static func isConvexCCW(_ p: ConvexPolygon) -> Bool {
        let v = p.vertices
        let n = v.count
        if n < 3 { return false }
        if signedArea(p) <= 0 { return false }
        for i in 0..<n {
            let e1 = v[(i + 1) % n] - v[i]
            let e2 = v[(i + 2) % n] - v[(i + 1) % n]
            let turn = FeelMath.cross(e1, e2)
            let scale = FeelMath.length(e1) * FeelMath.length(e2)
            if turn < -1e-9 * scale - 1e-12 { return false }
        }
        return true
    }

    /// A stone of 30...60 pt radius from a seed, and the generator after making it.
    static func stone(_ seed: UInt64) -> (stone: SkyStone, rng: FeelRandom) {
        var rng = FeelRandom(seed: seed)
        let radius = rng.uniform(30.0, 60.0)
        let stone = SkyStone.make(radius: radius, rng: &rng)
        return (stone, rng)
    }

    /// A point up to 1.3 radius from the stone's centre (stone-local pt): sometimes outside the stone, like a gaze
    /// that lands in the hit zone around it.
    static func impact(radius: Double, rng: inout FeelRandom) -> SIMD2<Double> {
        let angle = rng.uniform(0.0, 2.0 * Double.pi)
        let far = 1.3 * radius * rng.unit().squareRoot()
        return SIMD2<Double>(far * cos(angle), far * sin(angle))
    }

    /// Energy of the buffer at one frequency (Goertzel), in arbitrary units.
    static func goertzel(_ x: [Float], frequency: Double, sampleRate: Double) -> Double {
        let coefficient = 2.0 * cos(2.0 * Double.pi * frequency / sampleRate)
        var s1 = 0.0
        var s2 = 0.0
        for v in x {
            let s = Double(v) + coefficient * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - coefficient * s1 * s2
    }

    /// 20 log10 of the peak.
    static func peakDB(_ x: [Float]) -> Double {
        return 20.0 * log10(Double(PopSynth.peak(x)))
    }
}
