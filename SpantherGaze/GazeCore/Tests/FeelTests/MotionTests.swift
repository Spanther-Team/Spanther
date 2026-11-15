import XCTest
@testable import Feel

final class MotionTests: XCTestCase {
    // MARK: Springs

    func testAnUnderdampedSpringOvershootsByTheTextbookAmount() {
        var s = FeelSpring(value: 0, target: 1, frequencyHz: 4, dampingRatio: 0.5)
        var peak = 0.0
        for _ in 0..<8000 {
            s.step(0.0002)
            peak = max(peak, s.value)
        }
        // A step input overshoots by exp(-pi z / sqrt(1 - z^2)): 16.3% at z = 0.5.
        XCTAssertEqual(peak - 1, exp(-Double.pi * 0.5 / (1 - 0.25).squareRoot()), accuracy: 1e-4)
        XCTAssertEqual(s.value, 1, accuracy: 1e-6)
        XCTAssertEqual(s.velocity, 0, accuracy: 1e-4)
    }

    func testTheSpringIsTheSameAtAnyFrameRate() {
        for z in [0.3, 1.0, 1.8] {
            var a = FeelSpring(value: 2, target: -1, frequencyHz: 3, dampingRatio: z)
            var b = a
            a.velocity = 5
            b.velocity = 5
            for _ in 0..<30 { a.step(1.0 / 30) }
            for _ in 0..<120 { b.step(1.0 / 120) }
            XCTAssertEqual(a.value, b.value, accuracy: 1e-9, "z \(z)")
            XCTAssertEqual(a.velocity, b.velocity, accuracy: 1e-8, "z \(z)")
            // One long frame lands where the short ones do, and does not blow up.
            var c = FeelSpring(value: 2, target: -1, frequencyHz: 3, dampingRatio: z)
            c.velocity = 5
            c.step(1)
            XCTAssertEqual(c.value, a.value, accuracy: 1e-9, "z \(z)")
        }
    }

    func testACriticalOrHeavySpringNeverOvershoots() {
        for z in [1.0, 2.5] {
            var s = FeelSpring(value: 0, target: 1, frequencyHz: 5, dampingRatio: z)
            var last = 0.0
            for _ in 0..<2000 {
                s.step(0.001)
                XCTAssertLessThanOrEqual(s.value, 1 + 1e-12)
                XCTAssertGreaterThanOrEqual(s.value, last - 1e-12)
                last = s.value
            }
            XCTAssertEqual(s.value, 1, accuracy: z > 2 ? 2e-2 : 1e-6)
        }
        var still = FeelSpring(value: 3, frequencyHz: 5, dampingRatio: 0.7)
        still.step(0)
        still.step(.nan)
        XCTAssertEqual(still.value, 3)
        still.step(0.5)
        XCTAssertEqual(still.value, 3)
    }

    // MARK: Shards

    func testAPieceFallsAsGravityAndDragSay() {
        var rules = ShardFlight.Rules()
        rules.lifeSec = 10
        let v0 = FeelPoint(120, 300)
        var f = ShardFlight(pieces: [ShardFlight.Piece(position: FeelPoint(10, 500), velocity: v0, angle: 0, spin: 4,
                                                       radius: 3)], rules: rules)
        for _ in 0..<60 { f.step(1.0 / 60) }
        // v(t) = g/k + (v0 - g/k) e^(-kt), x(t) = x0 + (g/k) t + (v0 - g/k)(1 - e^(-kt)) / k.
        let k = rules.drag, g = rules.gravity, e = exp(-k)
        let terminal = g / k
        let x = FeelPoint(10, 500) + terminal + (v0 - terminal) * ((1 - e) / k)
        let v = terminal + (v0 - terminal) * e
        let p = f.pieces[0]
        XCTAssertEqual(p.position.x, x.x, accuracy: 1e-9)
        XCTAssertEqual(p.position.y, x.y, accuracy: 1e-9)
        XCTAssertEqual(p.velocity.x, v.x, accuracy: 1e-9)
        XCTAssertEqual(p.velocity.y, v.y, accuracy: 1e-9)
        XCTAssertEqual(p.spin, 4 * exp(-rules.spinDrag), accuracy: 1e-9)
        XCTAssertEqual(p.angle, 4 * (1 - exp(-rules.spinDrag)) / rules.spinDrag, accuracy: 1e-9)
        // Thirty frames a second fly the same way.
        var slow = ShardFlight(pieces: [ShardFlight.Piece(position: FeelPoint(10, 500), velocity: v0, angle: 0, spin: 4,
                                                          radius: 3)], rules: rules)
        for _ in 0..<30 { slow.step(1.0 / 30) }
        XCTAssertEqual(slow.pieces[0].position.y, p.position.y, accuracy: 1e-9)
    }

    func testAPieceBouncesOnceAndThenFallsThrough() {
        var rules = ShardFlight.Rules()
        rules.drag = 0
        rules.lifeSec = 2.9
        var f = ShardFlight(pieces: [ShardFlight.Piece(position: FeelPoint(0, 100), velocity: FeelPoint(50, 0), angle: 0,
                                                       spin: 2, radius: 5)], floorY: 0, rules: rules)
        var bounceSpeed: Double?
        var lowest = Double.infinity
        for _ in 0..<180 {
            let before = f.pieces[0]
            f.step(1.0 / 60)
            let after = f.pieces[0]
            if !before.bounced, after.bounced {
                bounceSpeed = after.velocity.y
                XCTAssertEqual(after.position.y, 5, accuracy: 1e-12)
                XCTAssertEqual(after.velocity.x, 50 * (1 - rules.friction), accuracy: 1e-9)
            }
            lowest = min(lowest, after.position.y)
        }
        // It hit the ground at about sqrt(2 g h) and kept a third of that, upward.
        let hit = (2 * 900 * 95.0).squareRoot()
        XCTAssertEqual(try XCTUnwrap(bounceSpeed), rules.restitution * hit, accuracy: 0.03 * hit)
        // The second time down it goes through the ground and out of sight.
        XCTAssertLessThan(lowest, -100)
        XCTAssertTrue(f.isOver)
        XCTAssertEqual(f.alpha, 0)
    }

    func testThePiecesFadeAtTheEndOfTheirLife() {
        var rules = ShardFlight.Rules()
        rules.lifeSec = 1
        rules.fadeSec = 0.4
        var f = ShardFlight(pieces: [], rules: rules)
        XCTAssertEqual(f.alpha, 1)
        f.step(0.6)
        XCTAssertEqual(f.alpha, 1, accuracy: 1e-12)
        f.step(0.2)
        XCTAssertEqual(f.alpha, 0.5, accuracy: 1e-9)
        XCTAssertFalse(f.isOver)
        f.step(0.25)
        XCTAssertTrue(f.isOver)
        XCTAssertEqual(f.alpha, 0)
        // Over is over: a later step changes nothing.
        let age = f.age
        f.step(1)
        XCTAssertEqual(f.age, age)
    }

    func testABurstThrowsTheShardsOutFromTheImpact() {
        let stone = SkyStone.make(seed: 4)
        let fracture = StoneFracture.make(outline: stone.outline, impact: FeelPoint(0.3, 0.1), seed: 4)
        let centre = FeelPoint(200, 300), turn = 0.7, scale = 40.0
        let f = ShardFlight.burst(fracture, centre: centre, rotation: turn, scale: scale, seed: 4, speed: 240)
        XCTAssertEqual(f.pieces.count, fracture.shards.count)
        let mean = fracture.shards.reduce(0) { $0 + $1.area } / Double(fracture.shards.count)
        var smallSpeed = 0.0, largeSpeed = 0.0, small = 0, large = 0
        for (shard, piece) in zip(fracture.shards, f.pieces) {
            // Each piece starts where its shard was on the screen, turned with the stone.
            let at = centre + Planar.rotate(shard.centroid, by: turn) * scale
            XCTAssertEqual(piece.position.x, at.x, accuracy: 1e-9)
            XCTAssertEqual(piece.position.y, at.y, accuracy: 1e-9)
            XCTAssertEqual(piece.angle, turn)
            // It flies away from the impact (the lift aside).
            let away = Planar.rotate(shard.centroid - fracture.impact, by: turn)
            let out = piece.velocity - FeelPoint(0, 0.35 * 240)
            XCTAssertGreaterThan(Planar.dot(out, away), 0)
            XCTAssertGreaterThan(piece.radius, 0)
            if shard.area < mean {
                smallSpeed += Planar.length(out)
                small += 1
            } else {
                largeSpeed += Planar.length(out)
                large += 1
            }
        }
        XCTAssertGreaterThan(small, 0)
        XCTAssertGreaterThan(large, 0)
        XCTAssertGreaterThan(smallSpeed / Double(small), largeSpeed / Double(large))
        XCTAssertEqual(f, ShardFlight.burst(fracture, centre: centre, rotation: turn, scale: scale, seed: 4, speed: 240))
    }

    // MARK: Motes

    func testMotesLeaveTheStoneAndLandInTheJar() throws {
        let from = FeelPoint(100, 100), to = FeelPoint(40, 360)
        let motes = MotePath.spray(from: from, to: to, count: 4, seed: 8)
        XCTAssertEqual(motes.count, 4)
        let l = Planar.distance(from, to)
        var sides: [Bool] = []
        for (i, m) in motes.enumerated() {
            XCTAssertEqual(m.delaySec, Double(i) * 0.06, accuracy: 1e-12)
            XCTAssertTrue((0.55...0.8).contains(m.durationSec))
            XCTAssertNil(m.position(at: m.delaySec - 0.01))
            XCTAssertEqual(try XCTUnwrap(m.position(at: m.delaySec)), from)
            let end = try XCTUnwrap(m.position(at: m.delaySec + m.durationSec))
            XCTAssertEqual(end.x, to.x, accuracy: 1e-9)
            XCTAssertEqual(end.y, to.y, accuracy: 1e-9)
            XCTAssertNil(m.position(at: m.delaySec + m.durationSec + 0.01))
            // The curve bows out to one side by a quarter to a half of the way.
            let bow = Planar.cross((to - from) / l, m.control - from)
            XCTAssertTrue((0.25 * l...0.5 * l).contains(abs(bow)))
            sides.append(bow > 0)
        }
        // Alternate sides, so the motes fan out.
        XCTAssertEqual(sides, [sides[0], !sides[0], sides[0], !sides[0]])
    }
}
