import XCTest
@testable import Feel

final class CracksTests: XCTestCase {
    func testTwoHundredStones() {
        let step = 4.0
        for seed in 0..<200 {
            let made = FeelCheck.stone(UInt64(seed))
            let stone = made.stone
            var rng = made.rng
            let impact = FeelCheck.impact(radius: stone.radius, rng: &rng)
            let shards = Fracture.shatter(stone.outline, impact: impact, rng: &rng)
            let pattern = CrackPattern.along(shards, impact: impact, outline: stone.outline, step: step)
            let hit = stone.outline.pulledInside(impact)
            let name = "seed \(seed)"

            XCTAssertFalse(pattern.segments.isEmpty, name)
            var startsAtImpact = false
            var farthest = 0.0
            var last = 0.0
            for s in pattern.segments {
                XCTAssertTrue(stone.outline.contains(s.a, tolerance: 1e-6), name)
                XCTAssertTrue(stone.outline.contains(s.b, tolerance: 1e-6), name)
                XCTAssertTrue(s.distanceA.isFinite && s.distanceB.isFinite, name)
                XCTAssertGreaterThanOrEqual(s.distanceA, 0.0, name)
                XCTAssertGreaterThanOrEqual(s.distanceB, s.distanceA, name)
                let length = FeelMath.distance(s.a, s.b)
                XCTAssertEqual(s.distanceB - s.distanceA, length, accuracy: 1e-6, name)
                XCTAssertLessThanOrEqual(length, step + 1e-9, name)
                XCTAssertGreaterThanOrEqual(s.distanceA, last, "sorted by distanceA, \(name)")
                last = s.distanceA
                farthest = max(farthest, s.distanceB)
                if s.distanceA == 0 && FeelMath.distance(s.a, hit) < 1e-6 { startsAtImpact = true }
            }
            XCTAssertTrue(startsAtImpact, name)
            XCTAssertEqual(pattern.maxDistance, farthest, accuracy: 1e-12, name)

            // Reveal: nothing but the starts at 0, everything at 1, never fewer as progress grows.
            for s in pattern.revealed(at: 0.0) {
                XCTAssertEqual(s.distanceA, 0.0, accuracy: 1e-12, name)
            }
            XCTAssertEqual(pattern.revealed(at: 1.0).count, pattern.segments.count, name)
            XCTAssertEqual(pattern.revealed(at: 7.0).count, pattern.segments.count, name)
            var shownBefore = 0
            for k in 0...20 {
                let progress = Double(k) / 20.0
                let shown = pattern.revealed(at: progress)
                XCTAssertGreaterThanOrEqual(shown.count, shownBefore, name)
                shownBefore = shown.count
                for s in shown {
                    XCTAssertLessThanOrEqual(s.distanceA, progress * pattern.maxDistance + 1e-12, name)
                }
            }

            // Every interior edge of every shard is covered by cracks; no crack runs along the rim.
            let merge = CrackPattern.mergeDistance(outline: stone.outline, shards: shards)
            for shard in shards {
                let v = shard.polygon.vertices
                for i in 0..<v.count {
                    let a = v[i]
                    let b = v[(i + 1) % v.count]
                    if FeelMath.distance(a, b) < 1e-3 { continue }
                    if CrackPattern.isRim(a, b, outline: stone.outline, tolerance: merge) { continue }
                    let middle = (a + b) * 0.5
                    var covered = false
                    for s in pattern.segments {
                        if FeelMath.distance(from: middle, toSegment: s.a, s.b) < 1e-4 {
                            covered = true
                            break
                        }
                    }
                    XCTAssertTrue(covered, name)
                }
            }
            for s in pattern.segments {
                XCTAssertFalse(CrackPattern.isRim(s.a, s.b, outline: stone.outline, tolerance: merge), name)
            }
        }
    }

    func testASquareInTwoHalves() {
        let square = ConvexPolygon(vertices: [
            SIMD2<Double>(-10.0, -10.0), SIMD2<Double>(10.0, -10.0), SIMD2<Double>(10.0, 10.0),
            SIMD2<Double>(-10.0, 10.0),
        ])
        let seeds = [SIMD2<Double>(-5.0, 0.0), SIMD2<Double>(5.0, 0.0)]
        let cells = Fracture.cells(of: square, seeds: seeds)
        var shards: [Shard] = []
        for i in 0..<cells.count {
            shards.append(Shard(polygon: cells[i], seed: seeds[i], centroid: cells[i].centroid, area: cells[i].area))
        }
        let impact = SIMD2<Double>(-5.0, 0.0)
        let pattern = CrackPattern.along(shards, impact: impact, outline: square, step: 4.0)

        // Four spokes from the impact to the left half's corners, and the one shared edge x = 0.
        // The spokes to (0, ±10) are sqrt(125) long; the shared edge is reached from both of its ends, so the
        // two fronts meet in its middle, 10 further on.
        let spoke = (125.0).squareRoot()
        XCTAssertEqual(pattern.maxDistance, spoke + 10.0, accuracy: 1e-9)
        var onSharedEdge = 0.0
        for s in pattern.segments {
            if abs(s.a.x) < 1e-9 && abs(s.b.x) < 1e-9 { onSharedEdge += FeelMath.distance(s.a, s.b) }
        }
        XCTAssertEqual(onSharedEdge, 20.0, accuracy: 1e-9)
        var total = 0.0
        for s in pattern.segments { total += FeelMath.distance(s.a, s.b) }
        XCTAssertEqual(total, 20.0 + 4.0 * spoke, accuracy: 1e-9)
    }

    func testNoShardsNoCracks() {
        let pattern = CrackPattern.along([], impact: SIMD2<Double>(0.0, 0.0), outline: ConvexPolygon(vertices: []))
        XCTAssertTrue(pattern.segments.isEmpty)
        XCTAssertEqual(pattern.maxDistance, 0.0)
        XCTAssertTrue(pattern.revealed(at: 1.0).isEmpty)
    }

    func testSameInputSamePattern() {
        let made = FeelCheck.stone(31)
        var rng = made.rng
        let impact = SIMD2<Double>(3.0, 5.0)
        let shards = Fracture.shatter(made.stone.outline, impact: impact, rng: &rng)
        let a = CrackPattern.along(shards, impact: impact, outline: made.stone.outline)
        let b = CrackPattern.along(shards, impact: impact, outline: made.stone.outline)
        XCTAssertEqual(a, b)
    }
}
