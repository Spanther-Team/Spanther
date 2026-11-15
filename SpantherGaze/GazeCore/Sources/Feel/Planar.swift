import Foundation

// The pop's plane geometry. A stone has its own frame: its centre at the origin, y up (as in SpriteKit and in a
// Core Graphics bitmap), lengths in units of its radius unless a function says otherwise. Polygons list their
// corners counter-clockwise, so their area is positive.

/// A point or a vector. A plain struct, not SIMD2: the tests run in debug builds, where SIMD arithmetic is slow.
public struct FeelPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = FeelPoint(0, 0)

    public static func + (a: FeelPoint, b: FeelPoint) -> FeelPoint { FeelPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: FeelPoint, b: FeelPoint) -> FeelPoint { FeelPoint(a.x - b.x, a.y - b.y) }
    public static func * (a: FeelPoint, k: Double) -> FeelPoint { FeelPoint(a.x * k, a.y * k) }
    public static func / (a: FeelPoint, k: Double) -> FeelPoint { FeelPoint(a.x / k, a.y / k) }
    public static prefix func - (a: FeelPoint) -> FeelPoint { FeelPoint(-a.x, -a.y) }
    public static func += (a: inout FeelPoint, b: FeelPoint) { a = a + b }
    public static func -= (a: inout FeelPoint, b: FeelPoint) { a = a - b }
}

public enum Planar {
    public static func dot(_ a: FeelPoint, _ b: FeelPoint) -> Double { a.x * b.x + a.y * b.y }

    /// The z part of a × b: positive when b turns counter-clockwise from a.
    public static func cross(_ a: FeelPoint, _ b: FeelPoint) -> Double { a.x * b.y - a.y * b.x }

    public static func length(_ a: FeelPoint) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }

    public static func distance(_ a: FeelPoint, _ b: FeelPoint) -> Double { length(a - b) }

    /// `a` turned a quarter turn counter-clockwise.
    public static func perpendicular(_ a: FeelPoint) -> FeelPoint { FeelPoint(-a.y, a.x) }

    /// `a` turned by `angle` radians counter-clockwise.
    public static func rotate(_ a: FeelPoint, by angle: Double) -> FeelPoint {
        let c = cos(angle), s = sin(angle)
        return FeelPoint(c * a.x - s * a.y, s * a.x + c * a.y)
    }

    /// The shoelace formula: positive for counter-clockwise corners.
    public static func signedArea(_ p: [FeelPoint]) -> Double {
        guard p.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<p.count { s += cross(p[i], p[(i + 1) % p.count]) }
        return s / 2
    }

    public static func centroid(_ p: [FeelPoint]) -> FeelPoint {
        let a = signedArea(p)
        guard abs(a) > 1e-300 else {
            guard !p.isEmpty else { return .zero }
            return p.reduce(FeelPoint.zero, +) / Double(p.count)
        }
        var c = FeelPoint.zero
        for i in 0..<p.count {
            let q = p[i], r = p[(i + 1) % p.count]
            c += (q + r) * cross(q, r)
        }
        return c / (6 * a)
    }

    /// The distance from q to the nearest edge line of a convex counter-clockwise polygon: positive inside,
    /// negative outside.
    public static func inset(_ p: [FeelPoint], _ q: FeelPoint) -> Double {
        var d = Double.infinity
        for i in 0..<p.count {
            let a = p[i], e = p[(i + 1) % p.count] - a
            let l = length(e)
            if l > 0 { d = min(d, cross(e, q - a) / l) }
        }
        return d
    }

    /// Inside a convex counter-clockwise polygon or within `tolerance` of its edges.
    public static func contains(_ p: [FeelPoint], _ q: FeelPoint, tolerance: Double = 1e-12) -> Bool {
        p.count >= 3 && inset(p, q) >= -tolerance
    }

    /// The convex hull, counter-clockwise, by Andrew's monotone chain. Points inside it or on its edges are dropped.
    public static func convexHull(_ points: [FeelPoint]) -> [FeelPoint] {
        let s = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard s.count >= 3 else { return s }
        func chain(_ list: [FeelPoint]) -> [FeelPoint] {
            var out: [FeelPoint] = []
            for p in list {
                while out.count >= 2, cross(out[out.count - 1] - out[out.count - 2], p - out[out.count - 2]) <= 0 {
                    out.removeLast()
                }
                out.append(p)
            }
            return out
        }
        return Array(chain(s).dropLast() + chain(s.reversed()).dropLast())
    }

    /// Keeps the part of a convex polygon where dot(normal, p) <= offset (Sutherland-Hodgman against one line).
    /// `labels[i]` names the edge from corner i to corner i + 1; the new edge along the line is named `label`,
    /// and the parts of old edges keep their names. Empty when nothing is left.
    static func clip(_ poly: [FeelPoint], _ labels: [Int], normal n: FeelPoint, offset c: Double,
                     label: Int) -> (points: [FeelPoint], labels: [Int]) {
        let count = poly.count
        guard count >= 3, labels.count == count else { return ([], []) }
        var points: [FeelPoint] = []
        var names: [Int] = []
        points.reserveCapacity(count + 2)
        names.reserveCapacity(count + 2)
        for i in 0..<count {
            let a = poly[i], b = poly[(i + 1) % count]
            let da = dot(n, a) - c, db = dot(n, b) - c
            if da <= 0 {
                points.append(a)
                names.append(labels[i])
                if db > 0 {
                    points.append(a + (b - a) * (da / (da - db)))
                    names.append(label)
                }
            } else if db <= 0 {
                points.append(a + (b - a) * (da / (da - db)))
                names.append(labels[i])
            }
        }
        // A cut through a corner leaves an edge of no length: the corner goes, and the edge after it keeps its name.
        var removed = true
        while removed, points.count >= 3 {
            removed = false
            var k = 0
            while k < points.count, points.count >= 3 {
                if distance(points[k], points[(k + 1) % points.count]) <= 1e-12 {
                    points.remove(at: k)
                    names.remove(at: k)
                    removed = true
                } else {
                    k += 1
                }
            }
        }
        guard points.count >= 3, signedArea(points) > 1e-18 else { return ([], []) }
        return (points, names)
    }
}

/// SplitMix64, written out so a seed gives the same stone, the same cracks and the same sounds on every build and
/// on Linux, where the tests run. Never the system generator: a pop that looked wrong must be possible to make again.
public struct FeelRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// A stream of its own for one use of a seed: the same seed and salt always give the same stream, and
    /// different salts give unrelated ones.
    public static func stream(_ seed: UInt64, _ salt: UInt64) -> FeelRandom {
        var mix = FeelRandom(seed: seed ^ (salt &* 0xD1B5_4A32_D192_ED03))
        return FeelRandom(seed: mix.next())
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1, from 53 random bits.
    public mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }

    public mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }

    /// Uniform in 0..<n (0 when n < 1).
    public mutating func index(_ n: Int) -> Int { n < 1 ? 0 : min(n - 1, Int(unit() * Double(n))) }
}
