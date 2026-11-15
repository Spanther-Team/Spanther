import Foundation

// The pre-fracture: at the start of a hold the stone is already cut into the pieces it will part into, so the
// cracks the child sees growing (Cracks.swift) run along exactly the edges the shards fly apart on. The pieces are
// the Voronoi cells of a handful of seeds, smaller and closer together near the gaze point.

/// One piece of the stone.
public struct Shard: Sendable, Equatable {
    /// Stone-local pt.
    public var polygon: ConvexPolygon
    /// The Voronoi seed this piece grew from, stone-local pt. It lies inside the polygon.
    public var seed: SIMD2<Double>
    /// The polygon's centre of area, stone-local pt.
    public var centroid: SIMD2<Double>
    /// Pt².
    public var area: Double

    public init(polygon: ConvexPolygon, seed: SIMD2<Double>, centroid: SIMD2<Double>, area: Double) {
        self.polygon = polygon
        self.seed = seed
        self.centroid = centroid
        self.area = area
    }
}

public enum Fracture {
    /// The Voronoi cell of each seed, cut out of the outline by half-planes (the perpendicular bisector to every
    /// other seed). Same order as `seeds`; a cell may be empty. Of two seeds at the same place the later one gets
    /// an empty cell. Seeds and cells are in the outline's frame (stone-local pt).
    public static func cells(of outline: ConvexPolygon, seeds: [SIMD2<Double>]) -> [ConvexPolygon] {
        var result: [ConvexPolygon] = []
        result.reserveCapacity(seeds.count)
        for i in 0..<seeds.count {
            var cell = outline
            for j in 0..<seeds.count {
                if j == i { continue }
                let normal = seeds[j] - seeds[i]
                if normal.x == 0 && normal.y == 0 {
                    if j < i {
                        cell = ConvexPolygon(vertices: [])
                        break
                    }
                    continue
                }
                let middle = (seeds[i] + seeds[j]) * 0.5
                cell = cell.clipped(normal: normal, offset: FeelMath.dot(normal, middle))
                if cell.vertices.count < 3 { break }
            }
            result.append(cell)
        }
        return result
    }

    /// `count` seeds inside the outline, denser near `impact` (stone-local pt, as are the seeds). Each seed is drawn
    /// at a random angle and at a distance reach × u^k from the impact, with k chosen so that half the draws fall
    /// within 0.45 radius (radius: that of the circle with the outline's area; reach: the impact's distance to the
    /// farthest corner). Draws outside the outline are drawn again, so "about half" in the end. No seed is closer
    /// than 0.12 × sqrt(area / count) to another: such a draw is drawn again too, up to 40 times, after which the
    /// last draw inside the outline is taken as it is. An empty outline gives no seeds.
    public static func seeds(in outline: ConvexPolygon, impact: SIMD2<Double>, count: Int,
                             rng: inout FeelRandom) -> [SIMD2<Double>] {
        if count <= 0 || outline.isEmpty { return [] }
        let area = outline.area
        let radius = (area / Double.pi).squareRoot()
        var reach = 0.0
        for v in outline.vertices { reach = max(reach, FeelMath.distance(v, impact)) }
        let half = min(0.9, 0.45 * radius / max(reach, 1e-9))
        let power = log(half) / log(0.5)
        let apart = 0.12 * (area / Double(count)).squareRoot()

        var seeds: [FeelPoint] = []
        seeds.reserveCapacity(count)
        for _ in 0..<count {
            var chosen: FeelPoint? = nil
            var lastInside: FeelPoint? = nil
            var tries = 0
            while tries < 40 && chosen == nil {
                tries += 1
                let angle = rng.uniform(0.0, 2.0 * Double.pi)
                let far = reach * pow(rng.unit(), power)
                let p = FeelPoint(impact.x + far * cos(angle), impact.y + far * sin(angle))
                if !outline.contains(p) { continue }
                lastInside = p
                var clear = true
                for s in seeds {
                    if FeelMath.distance(s, p) < apart {
                        clear = false
                        break
                    }
                }
                if clear { chosen = p }
            }
            if let p = chosen {
                seeds.append(p)
            } else if let p = lastInside {
                seeds.append(p)
            } else {
                seeds.append(outline.pulledInside(impact))
            }
        }
        return seeds
    }

    /// The shards: seeds (their count drawn from `seedCount`) and their non-empty cells, in the seeds' order.
    /// `impact` (stone-local pt) is pulled inside the outline first, because the gaze's hit zone is larger than the
    /// stone. An empty outline gives no shards.
    public static func shatter(_ outline: ConvexPolygon, impact: SIMD2<Double>, seedCount: ClosedRange<Int> = 8...14,
                               rng: inout FeelRandom) -> [Shard] {
        if outline.isEmpty { return [] }
        let hit = outline.pulledInside(impact)
        let count = max(1, rng.int(in: seedCount))
        let seeds = Fracture.seeds(in: outline, impact: hit, count: count, rng: &rng)
        let cells = Fracture.cells(of: outline, seeds: seeds)
        var shards: [Shard] = []
        shards.reserveCapacity(cells.count)
        for i in 0..<cells.count {
            let cell = cells[i]
            if cell.isEmpty { continue }
            shards.append(Shard(polygon: cell, seed: seeds[i], centroid: cell.centroid, area: cell.area))
        }
        return shards
    }
}
