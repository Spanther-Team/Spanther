import XCTest
@testable import Feel

final class FractureTests: XCTestCase {
    private func assertConvex(_ p: [FeelPoint], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(p.count, 3, what, file: file, line: line)
        XCTAssertGreaterThan(Planar.signedArea(p), 0, what, file: file, line: line)
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count], c = p[(i + 2) % p.count]
            XCTAssertGreaterThanOrEqual(Planar.cross(b - a, c - b), -1e-12, "\(what): corner \(i + 1)", file: file, line: line)
        }
    }

    /// Distance from q to the nearest edge of p (unsigned).
    private func edgeDistance(_ p: [FeelPoint], _ q: FeelPoint) -> Double {
        var best = Double.infinity
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count], e = b - a
            let t = min(1, max(0, Planar.dot(q - a, e) / max(1e-300, Planar.dot(e, e))))
            best = min(best, Planar.distance(q, a + e * t))
        }
        return best
    }

    private func randomPoint(in p: [FeelPoint], _ rng: inout FeelRandom) -> FeelPoint {
        while true {
            let q = FeelPoint(rng.uniform(-1, 1), rng.uniform(-1, 1))
            if Planar.contains(p, q, tolerance: 0) { return q }
        }
    }

    // MARK: Geometry

    func testPolygonBasics() {
        let square = [FeelPoint(0, 0), FeelPoint(2, 0), FeelPoint(2, 2), FeelPoint(0, 2)]
        XCTAssertEqual(Planar.signedArea(square), 4, accuracy: 1e-12)
        XCTAssertEqual(Planar.signedArea(square.reversed()), -4, accuracy: 1e-12)
        XCTAssertEqual(Planar.centroid(square), FeelPoint(1, 1))
        XCTAssertTrue(Planar.contains(square, FeelPoint(1, 1)))
        XCTAssertTrue(Planar.contains(square, FeelPoint(2, 1)))
        XCTAssertFalse(Planar.contains(square, FeelPoint(2.01, 1)))
        XCTAssertEqual(Planar.inset(square, FeelPoint(0.5, 1)), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Planar.inset(square, FeelPoint(3, 1)), -1, accuracy: 1e-12)
        let turned = Planar.rotate(FeelPoint(1, 0), by: .pi / 2)
        XCTAssertEqual(turned.x, 0, accuracy: 1e-12)
        XCTAssertEqual(turned.y, 1, accuracy: 1e-12)
        // The hull drops the points inside and on the edges, and runs counter-clockwise.
        let hull = Planar.convexHull(square + [FeelPoint(1, 1), FeelPoint(1, 0), FeelPoint(0.5, 0.5)])
        XCTAssertEqual(Set(hull), Set(square))
        XCTAssertEqual(Planar.signedArea(hull), 4, accuracy: 1e-12)
    }

    func testAClipKeepsOneSideAndNamesTheNewEdge() {
        let square = [FeelPoint(0, 0), FeelPoint(2, 0), FeelPoint(2, 2), FeelPoint(0, 2)]
        let half = Planar.clip(square, [10, 11, 12, 13], normal: FeelPoint(1, 0), offset: 1, label: 7)
        XCTAssertEqual(half.points, [FeelPoint(0, 0), FeelPoint(1, 0), FeelPoint(1, 2), FeelPoint(0, 2)])
        XCTAssertEqual(half.labels, [10, 7, 12, 13])
        // A cut through two corners leaves no edge of zero length behind.
        let corner = Planar.clip(square, [10, 11, 12, 13], normal: FeelPoint(1, 1), offset: 2, label: 7)
        XCTAssertEqual(corner.points, [FeelPoint(0, 0), FeelPoint(2, 0), FeelPoint(0, 2)])
        XCTAssertEqual(corner.labels, [10, 7, 13])
        XCTAssertTrue(Planar.clip(square, [10, 11, 12, 13], normal: FeelPoint(1, 0), offset: -1, label: 7).points.isEmpty)
        XCTAssertEqual(Planar.clip(square, [10, 11, 12, 13], normal: FeelPoint(1, 0), offset: 5, label: 7).labels,
                       [10, 11, 12, 13])
    }

    // MARK: Sky-stones

    func testSkyStonesAreConvexFacetedAndNeverTheSame() {
        var shapes = Set<[FeelPoint]>()
        var lit = 0.0, shadow = 0.0
        for seed in UInt64(0)..<200 {
            let s = SkyStone.make(seed: seed)
            assertConvex(s.outline, "seed \(seed)")
            XCTAssertGreaterThanOrEqual(s.outline.count, 5)
            XCTAssertEqual(s.outline.map { Planar.length($0) }.max() ?? 0, 1, accuracy: 1e-12)
            XCTAssertTrue(Planar.contains(s.outline, .zero))
            XCTAssertTrue(Planar.contains(s.outline, s.apex))
            XCTAssertEqual(s.facets.count, s.outline.count)
            XCTAssertEqual(s.facets.reduce(0) { $0 + Planar.signedArea($1.points) }, Planar.signedArea(s.outline),
                           accuracy: 1e-9)
            XCTAssertEqual(Set(s.facets.map(\.tone)), [0, 1, 2], "seed \(seed)")
            // The lit facets face the light at the upper left, the shadowed ones face away from it.
            let light = FeelPoint(-0.6, 0.8)
            for f in s.facets {
                let mid = (f.points[1] + f.points[2]) / 2 - s.apex
                let facing = Planar.dot(mid / Planar.length(mid), light)
                if f.tone == 0 { lit += facing }
                if f.tone == 2 { shadow += facing }
            }
            shapes.insert(s.outline)
        }
        XCTAssertEqual(shapes.count, 200)
        XCTAssertGreaterThan(lit, shadow)
        XCTAssertEqual(SkyStone.make(seed: 9), SkyStone.make(seed: 9))
        XCTAssertEqual(SkyStone.make(seed: 9, corners: 2).outline.count >= 5, true)
    }

    // MARK: Fracture

    func testFracturesTileTheStoneWithConvexShards() throws {
        for seed in UInt64(0)..<150 {
            let stone = SkyStone.make(seed: seed)
            var rng = FeelRandom(seed: seed &+ 77)
            // Sometimes on the rim or off the stone: the gaze zone is wider than the stone.
            let impact = FeelPoint(rng.uniform(-1.2, 1.2), rng.uniform(-1.2, 1.2))
            let f = StoneFracture.make(outline: stone.outline, impact: impact, seed: seed)
            let what = "seed \(seed)"
            XCTAssertTrue((8...14).contains(f.shards.count), "\(what): \(f.shards.count) shards")
            XCTAssertGreaterThanOrEqual(Planar.inset(stone.outline, f.impact), 0.18 * (Planar.signedArea(stone.outline) / .pi).squareRoot() - 1e-9)
            if Planar.inset(stone.outline, impact) >= 0.5 {
                XCTAssertEqual(f.impact, impact, what)
            }
            XCTAssertEqual(f.shards.reduce(0) { $0 + $1.area }, Planar.signedArea(stone.outline), accuracy: 1e-9, what)
            for shard in f.shards {
                assertConvex(shard.polygon, what)
                XCTAssertEqual(shard.area, Planar.signedArea(shard.polygon), accuracy: 1e-15)
                XCTAssertTrue(Planar.contains(shard.polygon, shard.site, tolerance: 1e-9), what)
                XCTAssertTrue(Planar.contains(shard.polygon, shard.centroid), what)
            }
            // Every point of the stone lies in exactly one shard: no gaps, no overlaps.
            for _ in 0..<60 {
                let q = randomPoint(in: stone.outline, &rng)
                XCTAssertEqual(f.shards.filter { Planar.contains($0.polygon, q, tolerance: 0) }.count, 1, what)
            }
        }
    }

    func testCracksStartAtTheImpactAndRunBetweenShards() throws {
        for seed in UInt64(0)..<150 {
            let stone = SkyStone.make(seed: seed &+ 1000)
            var rng = FeelRandom(seed: seed)
            let f = StoneFracture.make(outline: stone.outline, impact: FeelPoint(rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6)),
                                       seed: seed)
            let what = "seed \(seed)"
            XCTAssertFalse(f.cracks.isEmpty, what)
            // Three cracks leave the impact: it is the corner where the three cells round it meet.
            let first = f.cracks.filter { $0.fromDistance < 1e-9 }
            XCTAssertEqual(first.count, 3, what)
            for c in first { XCTAssertLessThan(Planar.distance(c.from, f.impact), 1e-9, what) }
            var cover = 0.0
            for c in f.cracks {
                let length = Planar.distance(c.from, c.to)
                cover += length
                // The distance grows by exactly the length of the piece, outward.
                XCTAssertEqual(c.toDistance - c.fromDistance, length, accuracy: 1e-9, what)
                XCTAssertGreaterThanOrEqual(c.fromDistance, -1e-12)
                XCTAssertLessThanOrEqual(c.toDistance, f.reach + 1e-12)
                // It runs along an edge two shards share, never along the rim.
                guard length > 1e-6 else { continue }
                let mid = (c.from + c.to) / 2
                XCTAssertEqual(f.shards.filter { edgeDistance($0.polygon, mid) < 1e-9 }.count, 2, what)
                XCTAssertGreaterThan(Planar.inset(stone.outline, mid), 1e-9, what)
                // No crack runs ahead of a straight front from the impact.
                XCTAssertGreaterThanOrEqual(c.fromDistance, Planar.distance(c.from, f.impact) - 1e-9, what)
                XCTAssertGreaterThanOrEqual(c.toDistance, Planar.distance(c.to, f.impact) - 1e-9, what)
            }
            // The cracks are the shared edges, each once: half of the inner perimeter of all shards.
            var inner = 0.0
            for s in f.shards {
                for i in 0..<s.polygon.count {
                    let a = s.polygon[i], b = s.polygon[(i + 1) % s.polygon.count]
                    if Planar.inset(stone.outline, (a + b) / 2) > 1e-9 { inner += Planar.distance(a, b) }
                }
            }
            XCTAssertEqual(cover, inner / 2, accuracy: 1e-7, what)
            XCTAssertGreaterThan(f.reach, 0)
        }
    }

    func testShardsAreSmallerNearTheImpact() {
        var near = 0.0, far = 0.0
        for seed in UInt64(0)..<120 {
            let stone = SkyStone.make(seed: seed)
            let f = StoneFracture.make(outline: stone.outline, impact: FeelPoint(0.25, -0.2), seed: seed)
            let sorted = f.shards.sorted {
                Planar.distance($0.centroid, f.impact) < Planar.distance($1.centroid, f.impact)
            }
            near += sorted.prefix(3).reduce(0) { $0 + $1.area }
            far += sorted.suffix(3).reduce(0) { $0 + $1.area }
        }
        // The three cells round the impact come out at under half the area of the three farthest (0.47 here).
        XCTAssertLessThan(near, 0.55 * far)
    }

    func testTheSameSeedBreaksTheSameWayAndAnotherSeedNot() {
        let stone = SkyStone.make(seed: 3)
        let a = StoneFracture.make(outline: stone.outline, impact: FeelPoint(0.1, 0.2), seed: 41)
        XCTAssertEqual(a, StoneFracture.make(outline: stone.outline, impact: FeelPoint(0.1, 0.2), seed: 41))
        XCTAssertNotEqual(a.shards, StoneFracture.make(outline: stone.outline, impact: FeelPoint(0.1, 0.2), seed: 42).shards)
        // The count follows the range asked for.
        for seed in UInt64(0)..<40 {
            XCTAssertEqual(StoneFracture.make(outline: stone.outline, impact: .zero, seed: seed, cells: 6...6).shards.count, 6)
        }
        // Nothing to break: nothing comes back.
        XCTAssertTrue(StoneFracture.make(outline: [FeelPoint(0, 0), FeelPoint(1, 0)], impact: .zero, seed: 1).shards.isEmpty)
    }

    func testDrawnCracksAreRoughButKeepTheirEndsAndDistances() {
        let stone = SkyStone.make(seed: 12)
        let f = StoneFracture.make(outline: stone.outline, impact: FeelPoint(-0.2, 0.1), seed: 12)
        let drawn = f.drawnCracks(jitter: 0.03, strokeLength: 0.1, seed: 5)
        XCTAssertGreaterThan(drawn.count, f.cracks.count)
        var i = 0
        for c in f.cracks {
            // The strokes of one piece follow on from each other, from its start to its end.
            var at = c.from, distance = c.fromDistance
            let line = c.to - c.from, l = Planar.length(line)
            while i < drawn.count, drawn[i].from == at, distance < c.toDistance - 1e-12 {
                XCTAssertEqual(drawn[i].fromDistance, distance, accuracy: 1e-12)
                XCTAssertGreaterThan(drawn[i].toDistance, drawn[i].fromDistance - 1e-12)
                // Within the jitter of the straight line.
                if l > 0 {
                    XCTAssertLessThanOrEqual(abs(Planar.cross(line / l, drawn[i].to - c.from)), 0.03 + 1e-12)
                }
                at = drawn[i].to
                distance = drawn[i].toDistance
                i += 1
            }
            XCTAssertEqual(at, c.to)
            XCTAssertEqual(distance, c.toDistance, accuracy: 1e-12)
        }
        XCTAssertEqual(i, drawn.count)
    }
}
