import Foundation

// The cracks that grow while the gaze charges a stone. They start at the gaze point and run along exactly the
// edges the shards will part on, so the burst opens the lines the child has been watching.

/// One straight piece of a crack.
public struct CrackSegment: Sendable, Equatable {
    /// The end nearer the impact along the cracks, stone-local pt.
    public var a: SIMD2<Double>
    /// The far end, stone-local pt.
    public var b: SIMD2<Double>
    /// Pt along the cracks from the impact to `a`. distanceA <= distanceB.
    public var distanceA: Double
    /// Pt along the cracks from the impact to `b`: distanceA plus the segment's length.
    public var distanceB: Double

    public init(a: SIMD2<Double>, b: SIMD2<Double>, distanceA: Double, distanceB: Double) {
        self.a = a
        self.b = b
        self.distanceA = distanceA
        self.distanceB = distanceB
    }
}

public struct CrackPattern: Sendable, Equatable {
    /// Sorted by distanceA, so what `revealed` returns is always a prefix.
    public var segments: [CrackSegment]
    /// Pt. The largest distanceB: progress 1 reveals everything.
    public var maxDistance: Double

    public init(segments: [CrackSegment], maxDistance: Double) {
        self.segments = segments
        self.maxDistance = maxDistance
    }

    /// A crack front travels this many times slower along the rim than along a crack. The rim is never drawn, but
    /// a crack on the far side of the stone may only be reachable around it.
    static let rimCost = 3.0

    /// The interior edges of the shards (those not on the outline), plus straight cracks from the impact to the
    /// corners of the shard that contains it. All points are stone-local pt; `impact` is pulled inside the outline
    /// the same way `Fracture.shatter` does it, so pass the same impact to both.
    ///
    /// Distances are shortest paths from the impact over that graph (Dijkstra; corners closer than 1e-6 × radius
    /// are one corner). The front may also pass along the rim, `rimCost` times slower and unseen, so every crack
    /// has a distance. A crack the front reaches from both ends is cut where the two fronts meet, so along every
    /// segment the distance grows by exactly the segment's length. Edges longer than `step` pt are cut into pieces
    /// of at most `step` pt.
    public static func along(_ shards: [Shard], impact: SIMD2<Double>, outline: ConvexPolygon,
                             step: Double = 4) -> CrackPattern {
        if shards.isEmpty { return CrackPattern(segments: [], maxDistance: 0) }
        let hit = outline.isEmpty ? impact : outline.pulledInside(impact)
        let merge = mergeDistance(outline: outline, shards: shards)
        let piece = max(step, 1e-3)

        // Corners: each shard's vertices as indices into `nodes`, with nearly equal points merged.
        var nodes: [FeelPoint] = []
        var loops: [[Int]] = []
        loops.reserveCapacity(shards.count)
        for shard in shards {
            var loop: [Int] = []
            loop.reserveCapacity(shard.polygon.vertices.count)
            for v in shard.polygon.vertices {
                loop.append(index(of: v, in: &nodes, merge: merge))
            }
            loops.append(loop)
        }
        var total = 0
        for loop in loops { total += loop.count }
        // Room for every corner and the impact, so a pair of indices makes one key.
        let span = total + 2

        // Edges, each once. A hidden edge lies on the rim.
        var edgeA: [Int] = []
        var edgeB: [Int] = []
        var edgeLength: [Double] = []
        var edgeHidden: [Bool] = []
        var known: Set<Int> = []
        for loop in loops {
            let n = loop.count
            if n < 2 { continue }
            for i in 0..<n {
                let u = loop[i]
                let v = loop[(i + 1) % n]
                if u == v { continue }
                let key = min(u, v) * span + max(u, v)
                if known.contains(key) { continue }
                known.insert(key)
                edgeA.append(u)
                edgeB.append(v)
                edgeLength.append(FeelMath.distance(nodes[u], nodes[v]))
                edgeHidden.append(isRim(nodes[u], nodes[v], outline: outline, tolerance: merge))
            }
        }

        // The impact, and the cracks from it to the corners of the shard it is in.
        var homeShard = -1
        for i in 0..<shards.count {
            if shards[i].polygon.contains(hit, tolerance: merge) {
                homeShard = i
                break
            }
        }
        if homeShard < 0 {
            var nearest = Double.infinity
            for i in 0..<shards.count {
                let d = FeelMath.distance(shards[i].centroid, hit)
                if d < nearest {
                    nearest = d
                    homeShard = i
                }
            }
        }
        let home = index(of: hit, in: &nodes, merge: merge)
        if homeShard >= 0 {
            for v in loops[homeShard] {
                if v == home { continue }
                let key = min(home, v) * span + max(home, v)
                if known.contains(key) { continue }
                known.insert(key)
                edgeA.append(home)
                edgeB.append(v)
                edgeLength.append(FeelMath.distance(nodes[home], nodes[v]))
                edgeHidden.append(false)
            }
        }

        // Dijkstra from the impact. The graph is small (well under 100 corners), so plain scans do.
        let count = nodes.count
        var distance = [Double](repeating: Double.infinity, count: count)
        var done = [Bool](repeating: false, count: count)
        distance[home] = 0
        for _ in 0..<count {
            var best = -1
            for i in 0..<count {
                if done[i] || !distance[i].isFinite { continue }
                if best < 0 || distance[i] < distance[best] { best = i }
            }
            if best < 0 { break }
            done[best] = true
            for e in 0..<edgeA.count {
                var other = -1
                if edgeA[e] == best {
                    other = edgeB[e]
                } else if edgeB[e] == best {
                    other = edgeA[e]
                }
                if other < 0 || done[other] { continue }
                let cost = edgeHidden[e] ? edgeLength[e] * rimCost : edgeLength[e]
                let through = distance[best] + cost
                if through < distance[other] { distance[other] = through }
            }
        }
        // A corner nothing leads to (it should not happen): the straight distance, so every number stays finite.
        for i in 0..<count {
            if !distance[i].isFinite { distance[i] = FeelMath.distance(nodes[i], nodes[home]) }
        }

        // The visible edges, each cut where the fronts from its two ends meet, then into pieces.
        var unsorted: [CrackSegment] = []
        for e in 0..<edgeA.count {
            if edgeHidden[e] { continue }
            var u = edgeA[e]
            var v = edgeB[e]
            if distance[v] < distance[u] { swap(&u, &v) }
            let length = edgeLength[e]
            if length <= 0 { continue }
            let meet = FeelMath.clamp((length + distance[v] - distance[u]) * 0.5, 0.0, length)
            let middle = nodes[u] + (nodes[v] - nodes[u]) * (meet / length)
            cut(from: nodes[u], to: middle, start: distance[u], piece: piece, into: &unsorted)
            cut(from: nodes[v], to: middle, start: distance[v], piece: piece, into: &unsorted)
        }

        // By distanceA, ties in the order made: the same on every platform whatever the sort does with ties.
        var order: [Int] = []
        order.reserveCapacity(unsorted.count)
        for i in 0..<unsorted.count { order.append(i) }
        order.sort { (i: Int, j: Int) -> Bool in
            let di = unsorted[i].distanceA
            let dj = unsorted[j].distanceA
            if di != dj { return di < dj }
            return i < j
        }
        var segments: [CrackSegment] = []
        segments.reserveCapacity(order.count)
        var farthest = 0.0
        for i in order {
            segments.append(unsorted[i])
            farthest = max(farthest, unsorted[i].distanceB)
        }
        return CrackPattern(segments: segments, maxDistance: farthest)
    }

    /// The segments whose near end is revealed at progress 0...1 (distanceA <= progress × maxDistance). At 0 only
    /// the segments that start at the impact itself; at 1 everything.
    public func revealed(at progress: Double) -> [CrackSegment] {
        let p = FeelMath.clamp(progress, 0.0, 1.0)
        if p >= 1 { return segments }
        let front = p * maxDistance
        var shown: [CrackSegment] = []
        for s in segments {
            if s.distanceA <= front { shown.append(s) }
        }
        return shown
    }

    /// Corners closer than this (pt) are one corner: 1e-6 × the stone's radius, the largest distance from the
    /// outline's centroid to any corner.
    static func mergeDistance(outline: ConvexPolygon, shards: [Shard]) -> Double {
        let centre = outline.centroid
        var radius = 0.0
        for v in outline.vertices { radius = max(radius, FeelMath.distance(v, centre)) }
        for shard in shards {
            for v in shard.polygon.vertices { radius = max(radius, FeelMath.distance(v, centre)) }
        }
        return max(1e-6 * radius, 1e-12)
    }

    /// True when both points lie on one edge of the outline (within `tolerance` pt): a piece of the rim.
    static func isRim(_ p: FeelPoint, _ q: FeelPoint, outline: ConvexPolygon, tolerance: Double) -> Bool {
        let n = outline.vertices.count
        if n < 2 { return false }
        for i in 0..<n {
            let a = outline.vertices[i]
            let b = outline.vertices[(i + 1) % n]
            if FeelMath.distance(from: p, toSegment: a, b) <= tolerance
                && FeelMath.distance(from: q, toSegment: a, b) <= tolerance {
                return true
            }
        }
        return false
    }

    /// The index of `p` in `nodes`: an existing point closer than `merge`, or `p` appended.
    private static func index(of p: FeelPoint, in nodes: inout [FeelPoint], merge: Double) -> Int {
        for i in 0..<nodes.count {
            if FeelMath.distance(nodes[i], p) < merge { return i }
        }
        nodes.append(p)
        return nodes.count - 1
    }

    /// Appends the straight run p → q in pieces of at most `piece` pt; `start` is the distance at p.
    private static func cut(from p: FeelPoint, to q: FeelPoint, start: Double, piece: Double,
                            into out: inout [CrackSegment]) {
        let length = FeelMath.distance(p, q)
        if length < 1e-9 { return }
        let parts = max(1, Int((length / piece).rounded(.up)))
        let d = q - p
        for k in 0..<parts {
            let t0 = Double(k) / Double(parts)
            let t1 = Double(k + 1) / Double(parts)
            out.append(CrackSegment(a: p + d * t0, b: p + d * t1,
                                    distanceA: start + length * t0, distanceB: start + length * t1))
        }
    }
}
