import XCTest
@testable import Feel

final class FeelRandomTests: XCTestCase {
    /// The published SplitMix64 outputs for seed 0.
    func testSplitMixReference() {
        var rng = FeelRandom(seed: 0)
        let first: UInt64 = rng.next()
        let second: UInt64 = rng.next()
        let third: UInt64 = rng.next()
        XCTAssertEqual(first, 0xE220A8397B1DCDAF as UInt64)
        XCTAssertEqual(second, 0x6E789E6AA1B965F4 as UInt64)
        XCTAssertEqual(third, 0x06C45D188009454F as UInt64)
    }

    func testSameSeedSameStream() {
        var a = FeelRandom(seed: 42)
        var b = FeelRandom(seed: 42)
        var c = FeelRandom(seed: 43)
        var differs = false
        for _ in 0..<100 {
            let x: UInt64 = a.next()
            let y: UInt64 = b.next()
            let z: UInt64 = c.next()
            XCTAssertEqual(x, y)
            if x != z { differs = true }
        }
        XCTAssertTrue(differs)
    }

    func testRanges() {
        var rng = FeelRandom(seed: 7)
        var seen = [Bool](repeating: false, count: 5)
        var sum = 0.0
        for _ in 0..<2000 {
            let u = rng.unit()
            XCTAssertGreaterThanOrEqual(u, 0.0)
            XCTAssertLessThan(u, 1.0)
            sum += u
            let x = rng.uniform(-3.0, 5.0)
            XCTAssertGreaterThanOrEqual(x, -3.0)
            XCTAssertLessThan(x, 5.0)
            let k = rng.int(in: 3...7)
            XCTAssertGreaterThanOrEqual(k, 3)
            XCTAssertLessThanOrEqual(k, 7)
            seen[k - 3] = true
        }
        XCTAssertEqual(sum / 2000.0, 0.5, accuracy: 0.05)
        XCTAssertEqual(seen, [true, true, true, true, true])
        let only = rng.int(in: 4...4)
        XCTAssertEqual(only, 4)
    }
}

final class GeometryTests: XCTestCase {
    private let square = ConvexPolygon(vertices: [
        SIMD2<Double>(0.0, 0.0), SIMD2<Double>(2.0, 0.0), SIMD2<Double>(2.0, 2.0), SIMD2<Double>(0.0, 2.0),
    ])

    func testHullOfRandomPointsIsConvexCounterClockwiseAndContainsThem() {
        for seed in 0..<50 {
            var rng = FeelRandom(seed: UInt64(seed))
            var points: [SIMD2<Double>] = []
            for _ in 0..<40 {
                points.append(SIMD2<Double>(rng.uniform(-50.0, 50.0), rng.uniform(-50.0, 50.0)))
            }
            let hull = ConvexPolygon.hull(points)
            XCTAssertTrue(FeelCheck.isConvexCCW(hull), "seed \(seed)")
            XCTAssertGreaterThan(FeelCheck.signedArea(hull), 0.0, "seed \(seed)")
            for p in points {
                XCTAssertTrue(hull.contains(p), "seed \(seed)")
            }
            // Every hull vertex is one of the points.
            for v in hull.vertices {
                XCTAssertTrue(points.contains(v), "seed \(seed)")
            }
        }
    }

    func testHullDropsCollinearAndRepeatedPoints() {
        let points = [
            SIMD2<Double>(0.0, 0.0), SIMD2<Double>(1.0, 0.0), SIMD2<Double>(2.0, 0.0), SIMD2<Double>(2.0, 1.0),
            SIMD2<Double>(2.0, 2.0), SIMD2<Double>(1.0, 2.0), SIMD2<Double>(0.0, 2.0), SIMD2<Double>(0.0, 1.0),
            SIMD2<Double>(1.0, 1.0), SIMD2<Double>(2.0, 2.0),
        ]
        let hull = ConvexPolygon.hull(points)
        XCTAssertEqual(hull.vertices.count, 4)
        XCTAssertEqual(hull.area, 4.0, accuracy: 1e-12)
        XCTAssertTrue(FeelCheck.isConvexCCW(hull))

        let line = ConvexPolygon.hull([SIMD2<Double>(0.0, 0.0), SIMD2<Double>(1.0, 1.0), SIMD2<Double>(2.0, 2.0)])
        XCTAssertTrue(line.isEmpty)
        XCTAssertTrue(ConvexPolygon.hull([]).isEmpty)
    }

    func testAreaAndCentroid() {
        XCTAssertEqual(square.area, 4.0, accuracy: 1e-12)
        XCTAssertEqual(square.centroid.x, 1.0, accuracy: 1e-12)
        XCTAssertEqual(square.centroid.y, 1.0, accuracy: 1e-12)
        XCTAssertFalse(square.isEmpty)

        let triangle = ConvexPolygon(vertices: [
            SIMD2<Double>(0.0, 0.0), SIMD2<Double>(4.0, 0.0), SIMD2<Double>(0.0, 3.0),
        ])
        XCTAssertEqual(triangle.area, 6.0, accuracy: 1e-12)
        XCTAssertEqual(triangle.centroid.x, 4.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(triangle.centroid.y, 1.0, accuracy: 1e-12)

        XCTAssertEqual(ConvexPolygon(vertices: []).area, 0.0)
        XCTAssertTrue(ConvexPolygon(vertices: [SIMD2<Double>(0.0, 0.0), SIMD2<Double>(1.0, 0.0)]).isEmpty)
    }

    func testContains() {
        XCTAssertTrue(square.contains(SIMD2<Double>(1.0, 1.0)))
        XCTAssertTrue(square.contains(SIMD2<Double>(2.0, 1.0)), "on an edge")
        XCTAssertTrue(square.contains(SIMD2<Double>(0.0, 0.0)), "on a corner")
        XCTAssertFalse(square.contains(SIMD2<Double>(2.001, 1.0)))
        XCTAssertFalse(square.contains(SIMD2<Double>(1.0, -0.001)))
    }

    func testClippingASquare() {
        // Keep x <= 0.5: a strip 0.5 wide and 2 tall.
        let strip = square.clipped(normal: SIMD2<Double>(1.0, 0.0), offset: 0.5)
        XCTAssertEqual(strip.area, 1.0, accuracy: 1e-12)
        XCTAssertTrue(FeelCheck.isConvexCCW(strip))

        // Keep x + y <= 1: the corner triangle.
        let corner = square.clipped(normal: SIMD2<Double>(1.0, 1.0), offset: 1.0)
        XCTAssertEqual(corner.area, 0.5, accuracy: 1e-12)
        XCTAssertEqual(corner.vertices.count, 3)

        // The two sides of one line share the square between them.
        let other = square.clipped(normal: SIMD2<Double>(-1.0, -1.0), offset: -1.0)
        XCTAssertEqual(corner.area + other.area, 4.0, accuracy: 1e-12)

        let all = square.clipped(normal: SIMD2<Double>(1.0, 0.0), offset: 5.0)
        XCTAssertEqual(all.area, 4.0, accuracy: 1e-12)
        let nothing = square.clipped(normal: SIMD2<Double>(1.0, 0.0), offset: -1.0)
        XCTAssertTrue(nothing.isEmpty)
    }

    func testPulledInside() {
        let inside = SIMD2<Double>(0.5, 1.5)
        XCTAssertEqual(square.pulledInside(inside), inside)

        // From the centroid (1, 1) toward (10, 1) the boundary is at (2, 1): 0.8 of the way there is (1.8, 1).
        let pulled = square.pulledInside(SIMD2<Double>(10.0, 1.0))
        XCTAssertEqual(pulled.x, 1.8, accuracy: 1e-12)
        XCTAssertEqual(pulled.y, 1.0, accuracy: 1e-12)

        let onEdge = square.pulledInside(SIMD2<Double>(1.0, -7.0), fraction: 1.0)
        XCTAssertEqual(onEdge.x, 1.0, accuracy: 1e-12)
        XCTAssertEqual(onEdge.y, 0.0, accuracy: 1e-12)

        var rng = FeelRandom(seed: 3)
        for _ in 0..<200 {
            let p = SIMD2<Double>(rng.uniform(-20.0, 20.0), rng.uniform(-20.0, 20.0))
            XCTAssertTrue(square.contains(square.pulledInside(p)))
        }
    }
}
