import Foundation

/// How a stone breaks where the gaze rests on it: Voronoi cells cut out of its outline, more and smaller near the
/// impact, and the cracks between them with the distance from the impact along the cracks. Made when the hold
/// begins, off the main thread; the cracks grow along those very edges while the hold fills, so the shards that
/// fly at the lock are the pieces the player watched forming. Units: the stone's frame (Planar).
public struct StoneFracture: Sendable, Equatable {
    public struct Shard: Sendable, Equatable {
        /// Convex, counter-clockwise, in the stone's frame.
        public let polygon: [FeelPoint]
        public let centroid: FeelPoint
        public let area: Double
        /// The Voronoi site the cell grew round.
        public let site: FeelPoint
    }

    /// A straight piece of crack. The distance along the cracks from the impact grows evenly from `from` to `to`.
    public struct Crack: Sendable, Equatable {
        public let from: FeelPoint
        public let to: FeelPoint
        public let fromDistance: Double
        public let toDistance: Double
    }

    /// Where the cracks start: the gaze point, moved a little inside the stone when it rested on the rim or off it.
    public let impact: FeelPoint
    public let shards: [Shard]
    public let cracks: [Crack]
    /// The farthest any crack reaches from the impact: the reveal is complete at this distance.
    public let reach: Double

    /// `cells`: how many shards, drawn from this range by the seed.
    public static func make(outline: [FeelPoint], impact: FeelPoint, seed: UInt64,
                            cells: ClosedRange<Int> = 8...14) -> StoneFracture {
        let area = Planar.signedArea(outline)
        guard outline.count >= 3, area > 0 else { return StoneFracture(impact: impact, shards: [], cracks: [], reach: 0) }
        // The radius of a disc of the same area: the scale every distance below is taken in.
        let size = (area / .pi).squareRoot()
        let p = inside(outline, impact, margin: 0.18 * size)
        var rng = FeelRandom.stream(seed, 0x4652_4143)
        let count = max(4, cells.lowerBound + rng.index(cells.count))

        // Three sites on a circle round the impact, so the impact is a corner where three cells meet and the
        // cracks run out of it. Every other site lies farther out, so none of them takes that corner away.
        let ring = min(0.24 * size, 0.85 * Planar.inset(outline, p))
        let turn = rng.uniform(0, 2 * .pi)
        var sites: [FeelPoint] = (0..<3).map { k in
            let a = turn + (Double(k) + rng.uniform(-0.18, 0.18)) * 2 * .pi / 3
            return p + FeelPoint(cos(a), sin(a)) * ring
        }
        // The rest: more of them near the impact (distance from it drawn as u^1.5), kept apart from each other by a
        // gap that widens with the distance, so the shards grow from small round the impact to large far from it.
        let inner = 1.45 * ring
        let farthest = max(inner, outline.map { Planar.distance($0, p) }.max() ?? size)
        var spacing = 0.3 * size
        var tries = 0
        while sites.count < count, tries < 4000 {
            tries += 1
            if tries % 400 == 0 { spacing *= 0.8 }
            let a = rng.uniform(0, 2 * .pi)
            let q = p + FeelPoint(cos(a), sin(a)) * (inner + (farthest - inner) * pow(rng.unit(), 1.5))
            let gap = spacing * (0.45 + 0.85 * Planar.distance(q, p) / farthest)
            guard Planar.inset(outline, q) > 0.02 * size, sites.allSatisfy({ Planar.distance($0, q) >= gap }) else {
                continue
            }
            sites.append(q)
        }

        // Each cell: the outline cut by the bisector with every other site. An edge keeps the name of the site
        // whose bisector made it (-1: the outline), which is how the cracks are found below.
        var shards: [Shard] = []
        var edges: [Int: (a: FeelPoint, b: FeelPoint)] = [:]
        let n = sites.count
        for i in 0..<n {
            var poly = outline
            var names = [Int](repeating: -1, count: outline.count)
            for j in 0..<n where j != i {
                let normal = sites[j] - sites[i]
                let offset = (Planar.dot(sites[j], sites[j]) - Planar.dot(sites[i], sites[i])) / 2
                (poly, names) = Planar.clip(poly, names, normal: normal, offset: offset, label: j)
                if poly.isEmpty { break }
            }
            guard !poly.isEmpty else { continue }
            let cellArea = Planar.signedArea(poly)
            shards.append(Shard(polygon: poly, centroid: Planar.centroid(poly), area: cellArea, site: sites[i]))
            for k in 0..<poly.count where names[k] >= 0 {
                let a = poly[k], b = poly[(k + 1) % poly.count]
                let key = min(i, names[k]) * n + max(i, names[k])
                // Two cells share at most one edge; their two copies can differ by rounding, so the longer stays.
                if let old = edges[key], Planar.distance(old.a, old.b) >= Planar.distance(a, b) { continue }
                edges[key] = (a, b)
            }
        }

        // The cracks as a graph: corners merged where they coincide, edges between them.
        let tolerance = 1e-9 * size
        var nodes: [FeelPoint] = []
        func node(_ q: FeelPoint) -> Int {
            if let i = nodes.firstIndex(where: { Planar.distance($0, q) <= tolerance }) { return i }
            nodes.append(q)
            return nodes.count - 1
        }
        var links: [(u: Int, v: Int, length: Double)] = []
        for key in edges.keys.sorted() {
            guard let e = edges[key] else { continue }
            let length = Planar.distance(e.a, e.b)
            guard length > tolerance else { continue }
            let u = node(e.a), v = node(e.b)
            if u != v { links.append((u, v, length)) }
        }
        let distances = crackDistances(nodes: nodes, links: links, from: p)

        // A point partway along an edge is reached through the nearer of its two ends: the distance rises from
        // each end to the point where the two ways meet, so each edge is one or two evenly growing pieces.
        var cracks: [Crack] = []
        for link in links {
            let a = nodes[link.u], b = nodes[link.v]
            let da = distances[link.u], db = distances[link.v], l = link.length
            let t = min(1, max(0, (db - da + l) / (2 * l)))
            let meet = a + (b - a) * t
            let dm = da + t * l
            if t * l > tolerance { cracks.append(Crack(from: a, to: meet, fromDistance: da, toDistance: dm)) }
            if (1 - t) * l > tolerance { cracks.append(Crack(from: b, to: meet, fromDistance: db, toDistance: dm)) }
        }
        let reach = cracks.map(\.toDistance).max() ?? 0
        return StoneFracture(impact: p, shards: shards, cracks: cracks, reach: reach)
    }

    /// The point on the way from the stone's centre to `q` nearest `q` that lies at least `margin` inside.
    static func inside(_ outline: [FeelPoint], _ q: FeelPoint, margin: Double) -> FeelPoint {
        guard Planar.inset(outline, q) < margin else { return q }
        let centre = Planar.centroid(outline)
        guard Planar.inset(outline, centre) >= margin else { return centre }
        // The inset is concave along the segment (a minimum of linear functions), so bisection finds the border.
        var lo = 0.0, hi = 1.0
        for _ in 0..<48 {
            let mid = (lo + hi) / 2
            if Planar.inset(outline, centre + (q - centre) * mid) >= margin { lo = mid } else { hi = mid }
        }
        return centre + (q - centre) * lo
    }

    /// Shortest distances along the cracks from the corner at the impact (Dijkstra). A corner the cracks from the
    /// impact cannot reach (clipping can leave a crack that touches no other) starts at twice its straight
    /// distance, so it still lights up, a little after the cracks round it.
    static func crackDistances(nodes: [FeelPoint], links: [(u: Int, v: Int, length: Double)],
                               from p: FeelPoint) -> [Double] {
        guard !nodes.isEmpty else { return [] }
        var dist = nodes.map { 2 * Planar.distance($0, p) }
        if let source = nodes.indices.min(by: { Planar.distance(nodes[$0], p) < Planar.distance(nodes[$1], p) }) {
            dist[source] = Planar.distance(nodes[source], p)
        }
        var neighbours = [[(Int, Double)]](repeating: [], count: nodes.count)
        for l in links {
            neighbours[l.u].append((l.v, l.length))
            neighbours[l.v].append((l.u, l.length))
        }
        var done = [Bool](repeating: false, count: nodes.count)
        for _ in 0..<nodes.count {
            var best = -1
            for i in nodes.indices where !done[i] && (best < 0 || dist[i] < dist[best]) { best = i }
            guard best >= 0 else { break }
            done[best] = true
            for (j, length) in neighbours[best] where !done[j] { dist[j] = min(dist[j], dist[best] + length) }
        }
        return dist
    }

    /// The cracks as drawn: each straight piece broken into short strokes nudged sideways by up to `jitter`, so
    /// the line looks split rather than ruled. The ends of every piece stay where they are, so cracks still meet,
    /// and the distance runs evenly along each piece as before. The shards keep their straight edges: at the lock
    /// they fly within a frame, before the difference could show.
    public func drawnCracks(jitter: Double = 0.025, strokeLength: Double = 0.12, seed: UInt64) -> [Crack] {
        var rng = FeelRandom.stream(seed, 0x4A41_4747)
        var out: [Crack] = []
        for c in cracks {
            let d = c.to - c.from
            let l = Planar.length(d)
            let m = max(1, Int((l / max(1e-6, strokeLength)).rounded(.up)))
            let side = l > 0 ? Planar.perpendicular(d) / l : .zero
            var last = c.from, lastDistance = c.fromDistance
            for k in 1...m {
                let t = Double(k) / Double(m)
                let nudge = rng.uniform(-jitter, jitter)
                let q = k == m ? c.to : c.from + d * t + side * nudge
                let qd = k == m ? c.toDistance : c.fromDistance + (c.toDistance - c.fromDistance) * t
                out.append(Crack(from: last, to: q, fromDistance: lastDistance, toDistance: qd))
                last = q
                lastDistance = qd
            }
        }
        return out
    }
}
