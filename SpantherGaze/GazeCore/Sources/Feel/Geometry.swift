import Foundation

/// A point or a vector in the plane. Which frame it is in (stone-local pt or scene pt, both y up) is said where
/// it is used.
public typealias FeelPoint = SIMD2<Double>

/// Small vector helpers, written out so nothing here needs the simd module.
enum FeelMath {
    static func dot(_ a: FeelPoint, _ b: FeelPoint) -> Double {
        return a.x * b.x + a.y * b.y
    }

    /// The z of the 3-D cross product: positive when b is counter-clockwise from a (y up).
    static func cross(_ a: FeelPoint, _ b: FeelPoint) -> Double {
        return a.x * b.y - a.y * b.x
    }

    static func length(_ a: FeelPoint) -> Double {
        return (a.x * a.x + a.y * a.y).squareRoot()
    }

    static func distance(_ a: FeelPoint, _ b: FeelPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The distance from p to the segment a-b.
    static func distance(from p: FeelPoint, toSegment a: FeelPoint, _ b: FeelPoint) -> Double {
        let e = b - a
        let squared = e.x * e.x + e.y * e.y
        if squared <= 0 { return distance(p, a) }
        var t = dot(p - a, e) / squared
        if t < 0 { t = 0 }
        if t > 1 { t = 1 }
        let nearest = FeelPoint(a.x + e.x * t, a.y + e.y * t)
        return distance(p, nearest)
    }

    static func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double {
        return min(high, max(low, x))
    }
}

/// A convex polygon. Its points are in whatever frame the caller works in (stone-local pt for the stone and its
/// shards), with y up.
public struct ConvexPolygon: Sendable, Equatable {
    /// Counter-clockwise (y up), not closed: the first vertex is not repeated at the end.
    public var vertices: [SIMD2<Double>]

    /// Trusts the caller: the vertices are convex and counter-clockwise.
    public init(vertices: [SIMD2<Double>]) {
        self.vertices = vertices
    }

    /// The convex hull of the points (Andrew's monotone chain): counter-clockwise, collinear points dropped.
    /// Fewer than three different points, or points all on one line, give a polygon with fewer than 3 vertices.
    public static func hull(_ points: [SIMD2<Double>]) -> ConvexPolygon {
        let sorted = points.sorted { (a: FeelPoint, b: FeelPoint) -> Bool in
            if a.x != b.x { return a.x < b.x }
            return a.y < b.y
        }
        var unique: [FeelPoint] = []
        unique.reserveCapacity(sorted.count)
        for p in sorted {
            if let last = unique.last, last == p { continue }
            unique.append(p)
        }
        if unique.count < 3 { return ConvexPolygon(vertices: unique) }

        var lower: [FeelPoint] = []
        for p in unique {
            while lower.count >= 2 {
                let a = lower[lower.count - 2]
                let b = lower[lower.count - 1]
                if FeelMath.cross(b - a, p - b) <= 0 { lower.removeLast() } else { break }
            }
            lower.append(p)
        }
        var upper: [FeelPoint] = []
        var i = unique.count - 1
        while i >= 0 {
            let p = unique[i]
            while upper.count >= 2 {
                let a = upper[upper.count - 2]
                let b = upper[upper.count - 1]
                if FeelMath.cross(b - a, p - b) <= 0 { upper.removeLast() } else { break }
            }
            upper.append(p)
            i -= 1
        }
        // Each chain ends where the other starts.
        lower.removeLast()
        upper.removeLast()
        return ConvexPolygon(vertices: lower + upper)
    }

    /// In the square of the vertices' unit (pt² for pt). 0 with fewer than 3 vertices.
    public var area: Double {
        let n = vertices.count
        if n < 3 { return 0 }
        let origin = vertices[0]
        var twice = 0.0
        for i in 1..<(n - 1) {
            twice += FeelMath.cross(vertices[i] - origin, vertices[i + 1] - origin)
        }
        return abs(twice) * 0.5
    }

    /// The centre of area, in the vertices' frame. With no area: the mean of the vertices (zero if there are none).
    public var centroid: SIMD2<Double> {
        let n = vertices.count
        if n == 0 { return FeelPoint.zero }
        var mean = FeelPoint.zero
        for v in vertices { mean += v }
        mean = mean / Double(n)
        if n < 3 { return mean }
        var twice = 0.0
        var sum = FeelPoint.zero
        for i in 0..<n {
            let a = vertices[i] - mean
            let b = vertices[(i + 1) % n] - mean
            let w = FeelMath.cross(a, b)
            twice += w
            sum += (a + b) * w
        }
        if abs(twice) < 1e-12 { return mean }
        return mean + sum / (3.0 * twice)
    }

    /// Fewer than 3 vertices, or an area below 1e-9.
    public var isEmpty: Bool {
        return vertices.count < 3 || area < 1e-9
    }

    /// Inside or on the boundary (up to 1e-9 outside still counts). `p` is in the vertices' frame.
    public func contains(_ p: SIMD2<Double>) -> Bool {
        return contains(p, tolerance: 1e-9)
    }

    /// True when `p` is at most `tolerance` outside every edge. A negative tolerance asks for a point that far
    /// inside every edge.
    func contains(_ p: FeelPoint, tolerance: Double) -> Bool {
        let n = vertices.count
        if n < 3 { return false }
        for i in 0..<n {
            let a = vertices[i]
            let e = vertices[(i + 1) % n] - a
            let length = FeelMath.length(e)
            if length <= 0 { continue }
            if FeelMath.cross(e, p - a) < -tolerance * length { return false }
        }
        return true
    }

    /// Keeps the part where dot(normal, x) <= offset (Sutherland–Hodgman on one half-plane). `normal` need not
    /// have length 1. The result may have fewer than 3 vertices: then nothing is left.
    public func clipped(normal: SIMD2<Double>, offset: Double) -> ConvexPolygon {
        let n = vertices.count
        if n == 0 { return self }
        var kept: [FeelPoint] = []
        kept.reserveCapacity(n + 1)
        for i in 0..<n {
            let a = vertices[i]
            let b = vertices[(i + 1) % n]
            let da = FeelMath.dot(normal, a) - offset
            let db = FeelMath.dot(normal, b) - offset
            if da <= 0 { kept.append(a) }
            if (da < 0 && db > 0) || (da > 0 && db < 0) {
                let t = da / (da - db)
                kept.append(a + (b - a) * t)
            }
        }
        return ConvexPolygon(vertices: kept)
    }

    /// A point moved inside: `p` itself if it is inside, else the point on the segment from the centroid toward
    /// `p` at `fraction` of the way to the boundary. `p` and the result are in the vertices' frame.
    public func pulledInside(_ p: SIMD2<Double>, fraction: Double = 0.8) -> SIMD2<Double> {
        if contains(p) { return p }
        let n = vertices.count
        if n == 0 { return p }
        let c = centroid
        if n < 3 { return c }
        let d = p - c
        // The ray c + t d leaves the polygon at the smallest t at which it meets an edge it is heading out of.
        var reach = Double.infinity
        for i in 0..<n {
            let a = vertices[i]
            let e = vertices[(i + 1) % n] - a
            let outward = FeelPoint(e.y, -e.x)
            let heading = FeelMath.dot(outward, d)
            if heading <= 0 { continue }
            let t = FeelMath.dot(outward, a - c) / heading
            if t < reach { reach = t }
        }
        if !reach.isFinite { return c }
        return c + d * (max(0.0, reach) * fraction)
    }
}
