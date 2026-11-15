import XCTest
@testable import Feel

final class FractureTests: XCTestCase {
    private let square = ConvexPolygon(vertices: [
        SIMD2<Double>(-1.0, -1.0), SIMD2<Double>(1.0, -1.0), SIMD2<Double>(1.0, 1.0), SIMD2<Double>(-1.0, 1.0),
    ])

    func testCellsOfTwoSeedsHalveASquare() {
        let cells = Fracture.cells(of: square, seeds: [SIMD2<Double>(-0.5, 0.0), SIMD2<Double>(0.5, 0.0)])
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0].area, 2.0, accuracy: 1e-12)
        XCTAssertEqual(cells[1].area, 2.0, accuracy: 1e-12)
        XCTAssertTrue(cells[0].contains(SIMD2<Double>(-0.5, 0.0)))
        XCTAssertFalse(cells[0].contains(SIMD2<Double>(0.5, 0.0)))
    }

    func testOfTwoSeedsAtOnePlaceTheLaterCellIsEmpty() {
        let seeds = [SIMD2<Double>(0.2, 0.1), SIMD2<Double>(-0.6, 0.3), SIMD2<Double>(0.2, 0.1)]
        let cells = Fracture.cells(of: square, seeds: seeds)
        XCTAssertEqual(cells.count, 3)
        XCTAssertFalse(cells[0].isEmpty)
        XCTAssertTrue(cells[2].isEmpty)
        XCTAssertEqual(cells[0].area + cells[1].area, 4.0, accuracy: 1e-12)
    }

    func testFiveHundredStones() {
        for seed in 0..<500 {
            let made = FeelCheck.stone(UInt64(seed))
            let stone = made.stone
            var rng = made.rng
            let impact = FeelCheck.impact(radius: stone.radius, rng: &rng)
            let shards = Fracture.shatter(stone.outline, impact: impact, rng: &rng)
            let name = "seed \(seed)"

            XCTAssertGreaterThanOrEqual(shards.count, 6, name)
            XCTAssertLessThanOrEqual(shards.count, 14, name)

            var sum = 0.0
            for shard in shards {
                XCTAssertTrue(FeelCheck.isConvexCCW(shard.polygon), name)
                XCTAssertFalse(shard.polygon.isEmpty, name)
                XCTAssertEqual(shard.area, shard.polygon.area, accuracy: 1e-12, name)
                XCTAssertEqual(shard.centroid.x, shard.polygon.centroid.x, accuracy: 1e-12, name)
                XCTAssertEqual(shard.centroid.y, shard.polygon.centroid.y, accuracy: 1e-12, name)
                XCTAssertTrue(shard.polygon.contains(shard.seed, tolerance: 1e-7), name)
                XCTAssertTrue(shard.polygon.contains(shard.centroid, tolerance: 1e-7), name)
                for v in shard.polygon.vertices {
                    XCTAssertTrue(stone.outline.contains(v, tolerance: 1e-7), name)
                }
                sum += shard.area
            }
            let area = stone.outline.area
            XCTAssertLessThan(abs(sum - area) / area, 1e-9, name)

            // A grid of points inside the outline: each lies in exactly one shard. A point within 1e-7 of a shard's
            // edge may count for two.
            let r = stone.radius
            for ix in 0..<9 {
                for iy in 0..<9 {
                    let px = -r + 2.0 * r * (Double(ix) + 0.37) / 9.0
                    let py = -r + 2.0 * r * (Double(iy) + 0.61) / 9.0
                    let p = SIMD2<Double>(px, py)
                    if !stone.outline.contains(p, tolerance: -1e-6) { continue }
                    var strict = 0
                    var loose = 0
                    for shard in shards {
                        if shard.polygon.contains(p, tolerance: -1e-7) { strict += 1 }
                        if shard.polygon.contains(p, tolerance: 1e-7) { loose += 1 }
                    }
                    XCTAssertLessThanOrEqual(strict, 1, name)
                    XCTAssertGreaterThanOrEqual(loose, 1, name)
                }
            }
        }
    }

    func testSeedsKeepTheirCountStayInsideAndApart() {
        for seed in 0..<100 {
            let made = FeelCheck.stone(UInt64(seed))
            let stone = made.stone
            var rng = made.rng
            let impact = stone.outline.pulledInside(FeelCheck.impact(radius: stone.radius, rng: &rng))
            let count = rng.int(in: 8...14)
            let seeds = Fracture.seeds(in: stone.outline, impact: impact, count: count, rng: &rng)
            XCTAssertEqual(seeds.count, count)
            let apart = 0.12 * (stone.outline.area / Double(count)).squareRoot()
            var tooClose = 0
            for i in 0..<seeds.count {
                XCTAssertTrue(stone.outline.contains(seeds[i]), "seed \(seed)")
                for j in 0..<i {
                    if FeelMath.distance(seeds[i], seeds[j]) < apart { tooClose += 1 }
                }
            }
            // Giving up after 40 draws is allowed, but it should almost never be needed.
            XCTAssertEqual(tooClose, 0, "seed \(seed)")
        }
        var rng = FeelRandom(seed: 1)
        let none = Fracture.seeds(in: ConvexPolygon(vertices: []), impact: SIMD2<Double>(0.0, 0.0), count: 5,
                                  rng: &rng)
        XCTAssertTrue(none.isEmpty)
    }

    func testSeedsAreDenserNearTheImpact() {
        var seedMean = 0.0
        var evenMean = 0.0
        var within = 0
        var drawn = 0
        let runs = 500
        for seed in 0..<runs {
            let made = FeelCheck.stone(UInt64(seed))
            let stone = made.stone
            var rng = made.rng
            let impact = stone.outline.pulledInside(FeelCheck.impact(radius: stone.radius, rng: &rng))
            let seeds = Fracture.seeds(in: stone.outline, impact: impact, count: 12, rng: &rng)
            let radius = (stone.outline.area / Double.pi).squareRoot()
            var sum = 0.0
            for s in seeds {
                let d = FeelMath.distance(s, impact)
                sum += d
                if d < 0.45 * radius { within += 1 }
                drawn += 1
            }
            seedMean += sum / Double(seeds.count)

            // Points spread evenly over the outline, for comparison.
            var even = 0.0
            var taken = 0
            while taken < 60 {
                let p = SIMD2<Double>(rng.uniform(-stone.radius, stone.radius),
                                      rng.uniform(-stone.radius, stone.radius))
                if !stone.outline.contains(p) { continue }
                even += FeelMath.distance(p, impact)
                taken += 1
            }
            evenMean += even / 60.0
        }
        seedMean /= Double(runs)
        evenMean /= Double(runs)
        XCTAssertLessThan(seedMean, 0.85 * evenMean)
        // About half the seeds fall within 0.45 radius of the impact.
        let share = Double(within) / Double(drawn)
        XCTAssertGreaterThan(share, 0.35)
        XCTAssertLessThan(share, 0.8)
    }

    func testSameSeedSameShards() {
        let outline = FeelCheck.stone(5).stone.outline
        let impact = SIMD2<Double>(4.0, -6.0)
        var a = FeelRandom(seed: 99)
        var b = FeelRandom(seed: 99)
        var c = FeelRandom(seed: 100)
        let first = Fracture.shatter(outline, impact: impact, rng: &a)
        let second = Fracture.shatter(outline, impact: impact, rng: &b)
        let third = Fracture.shatter(outline, impact: impact, rng: &c)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, third)
    }

    func testAnImpactOutsideTheOutlineStillWorks() {
        let stone = FeelCheck.stone(8).stone
        var rng = FeelRandom(seed: 21)
        let far = SIMD2<Double>(10.0 * stone.radius, 10.0 * stone.radius)
        let shards = Fracture.shatter(stone.outline, impact: far, rng: &rng)
        XCTAssertGreaterThanOrEqual(shards.count, 6)
        var sum = 0.0
        for shard in shards {
            XCTAssertTrue(FeelCheck.isConvexCCW(shard.polygon))
            sum += shard.area
        }
        XCTAssertLessThan(abs(sum - stone.outline.area) / stone.outline.area, 1e-9)
    }

    func testSeedCountRange() {
        let outline = FeelCheck.stone(2).stone.outline
        var rng = FeelRandom(seed: 4)
        let few = Fracture.shatter(outline, impact: SIMD2<Double>(0.0, 0.0), seedCount: 3...3, rng: &rng)
        XCTAssertEqual(few.count, 3)
        let none = Fracture.shatter(ConvexPolygon(vertices: []), impact: SIMD2<Double>(0.0, 0.0), rng: &rng)
        XCTAssertTrue(none.isEmpty)
    }
}
