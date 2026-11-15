import XCTest
@testable import Feel

final class SkyStoneTests: XCTestCase {
    func testLightIsAUnitVectorUpperLeft() {
        XCTAssertEqual(FeelMath.length(SkyStone.light), 1.0, accuracy: 1e-12)
        XCTAssertLessThan(SkyStone.light.x, 0.0)
        XCTAssertGreaterThan(SkyStone.light.y, 0.0)
    }

    func testTwoHundredStones() {
        var withTone = [0, 0, 0]
        for seed in 0..<200 {
            let made = FeelCheck.stone(UInt64(seed))
            let stone = made.stone
            let radius = stone.radius
            let name = "seed \(seed)"

            XCTAssertTrue(FeelCheck.isConvexCCW(stone.outline), name)
            XCTAssertGreaterThanOrEqual(stone.outline.vertices.count, 5, name)
            XCTAssertLessThanOrEqual(stone.outline.vertices.count, 13, name)
            for v in stone.outline.vertices {
                let far = FeelMath.length(v)
                XCTAssertGreaterThanOrEqual(far, 0.82 * radius - 1e-9, name)
                XCTAssertLessThanOrEqual(far, radius + 1e-9, name)
            }

            var sum = 0.0
            var seen = [false, false, false]
            XCTAssertFalse(stone.facets.isEmpty, name)
            for facet in stone.facets {
                XCTAssertTrue(FeelCheck.isConvexCCW(facet.polygon), name)
                sum += facet.polygon.area
                for v in facet.polygon.vertices {
                    XCTAssertTrue(stone.outline.contains(v, tolerance: 1e-7), name)
                }
                XCTAssertTrue(facet.tone >= 0 && facet.tone <= 2, name)
                if facet.tone >= 0 && facet.tone <= 2 { seen[facet.tone] = true }
            }
            let area = stone.outline.area
            XCTAssertLessThan(abs(sum - area) / area, 1e-9, name)
            for tone in 0..<3 {
                if seen[tone] { withTone[tone] += 1 }
            }
        }
        // Typical stones show all three tones.
        for tone in 0..<3 {
            XCTAssertGreaterThanOrEqual(withTone[tone], 180, "tone \(tone)")
        }
    }

    func testFacetsDoNotOverlap() {
        // With the areas summing to the outline's, a point in two facets would mean a gap elsewhere: sample points
        // and count the facets each is strictly inside.
        for seed in 0..<40 {
            let made = FeelCheck.stone(UInt64(seed))
            let stone = made.stone
            var rng = made.rng
            for _ in 0..<60 {
                let p = SIMD2<Double>(rng.uniform(-stone.radius, stone.radius),
                                      rng.uniform(-stone.radius, stone.radius))
                if !stone.outline.contains(p, tolerance: -1e-6) { continue }
                var strict = 0
                var loose = 0
                for facet in stone.facets {
                    if facet.polygon.contains(p, tolerance: -1e-7) { strict += 1 }
                    if facet.polygon.contains(p, tolerance: 1e-7) { loose += 1 }
                }
                XCTAssertLessThanOrEqual(strict, 1, "seed \(seed)")
                XCTAssertGreaterThanOrEqual(loose, 1, "seed \(seed)")
            }
        }
    }

    func testSameSeedSameStone() {
        let a = FeelCheck.stone(11).stone
        let b = FeelCheck.stone(11).stone
        let c = FeelCheck.stone(12).stone
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
