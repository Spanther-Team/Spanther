import XCTest
@testable import Feel

final class MotionTests: XCTestCase {
    private let target = SIMD2<Double>(120.0, -45.0)

    // MARK: Spring

    func testSpringSettlesOnAStillTarget() {
        var spring = DampedSpring()
        XCTAssertEqual(spring.frequency, 6.0)
        XCTAssertEqual(spring.dampingRatio, 0.55)
        XCTAssertEqual(spring.position, SIMD2<Double>(0.0, 0.0))
        for _ in 0..<180 { spring.step(toward: target, dt: 1.0 / 60.0) }
        let off = FeelMath.distance(spring.position, target)
        XCTAssertLessThan(off, 0.001 * FeelMath.length(target))
        XCTAssertLessThan(FeelMath.length(spring.velocity), 0.01)
    }

    func testSpringStepIsExactForAnyStepLength() {
        let ratios = [0.2, 0.55, 1.0, 2.5]
        for ratio in ratios {
            // 0.25 s: far from settled, so a wrong step would show.
            var coarse = DampedSpring(frequency: 6.0, dampingRatio: ratio, position: SIMD2<Double>(8.0, 3.0))
            var fine = coarse
            var whole = coarse
            for _ in 0..<15 { coarse.step(toward: target, dt: 1.0 / 60.0) }
            for _ in 0..<60 { fine.step(toward: target, dt: 1.0 / 240.0) }
            whole.step(toward: target, dt: 0.25)
            XCTAssertGreaterThan(FeelMath.distance(coarse.position, target), 0.01, "ratio \(ratio)")
            XCTAssertEqual(coarse.position.x, fine.position.x, accuracy: 1e-9, "ratio \(ratio)")
            XCTAssertEqual(coarse.position.y, fine.position.y, accuracy: 1e-9, "ratio \(ratio)")
            XCTAssertEqual(coarse.velocity.x, fine.velocity.x, accuracy: 1e-7, "ratio \(ratio)")
            XCTAssertEqual(coarse.velocity.y, fine.velocity.y, accuracy: 1e-7, "ratio \(ratio)")
            XCTAssertEqual(coarse.position.x, whole.position.x, accuracy: 1e-9, "ratio \(ratio)")
            XCTAssertEqual(coarse.position.y, whole.position.y, accuracy: 1e-9, "ratio \(ratio)")

            // And over 3 s, as the game runs it.
            var a = DampedSpring(frequency: 6.0, dampingRatio: ratio)
            var b = a
            for _ in 0..<180 { a.step(toward: target, dt: 1.0 / 60.0) }
            for _ in 0..<720 { b.step(toward: target, dt: 1.0 / 240.0) }
            XCTAssertEqual(a.position.x, b.position.x, accuracy: 1e-9, "ratio \(ratio)")
            XCTAssertEqual(a.position.y, b.position.y, accuracy: 1e-9, "ratio \(ratio)")
        }
    }

    func testSpringMatchesTheDifferentialEquation() {
        // Against a fine explicit integration of x'' = −w² (x − target) − 2 z w x'.
        for ratio in [0.3, 1.0, 1.8] {
            var spring = DampedSpring(frequency: 3.0, dampingRatio: ratio)
            spring.step(toward: SIMD2<Double>(1.0, 0.0), dt: 0.2)
            let w = 2.0 * Double.pi * 3.0
            var x = 0.0
            var v = 0.0
            let h = 1e-6
            for _ in 0..<200_000 {
                let a = -w * w * (x - 1.0) - 2.0 * ratio * w * v
                v += a * h
                x += v * h
            }
            XCTAssertEqual(spring.position.x, x, accuracy: 1e-4, "ratio \(ratio)")
            XCTAssertEqual(spring.velocity.x, v, accuracy: 1e-2, "ratio \(ratio)")
        }
    }

    func testSpringDoesNotOvershootWhenDampedEnough() {
        for ratio in [1.0, 1.5, 3.0] {
            var spring = DampedSpring(frequency: 6.0, dampingRatio: ratio)
            let goal = SIMD2<Double>(10.0, -5.0)
            for _ in 0..<600 {
                spring.step(toward: goal, dt: 1.0 / 120.0)
                XCTAssertLessThanOrEqual(spring.position.x, 10.0 + 1e-9, "ratio \(ratio)")
                XCTAssertGreaterThanOrEqual(spring.position.y, -5.0 - 1e-9, "ratio \(ratio)")
            }
            XCTAssertEqual(spring.position.x, 10.0, accuracy: 0.01, "ratio \(ratio)")
        }
        // The default spring is under-damped: it does overshoot.
        var lively = DampedSpring()
        var highest = 0.0
        for _ in 0..<240 {
            lively.step(toward: SIMD2<Double>(10.0, 0.0), dt: 1.0 / 240.0)
            highest = max(highest, lively.position.x)
        }
        XCTAssertGreaterThan(highest, 10.2)
    }

    func testSpringIgnoresANonPositiveStep() {
        var spring = DampedSpring(position: SIMD2<Double>(1.0, 2.0))
        let before = spring
        spring.step(toward: target, dt: 0.0)
        spring.step(toward: target, dt: -1.0)
        XCTAssertEqual(spring, before)
    }

    // MARK: Squash

    func testSquash() {
        let duration = 0.06
        let start = Squash.scale(at: 0.0, duration: duration)
        let end = Squash.scale(at: duration, duration: duration)
        XCTAssertEqual(start.x, 1.0, accuracy: 1e-12)
        XCTAssertEqual(start.y, 1.0, accuracy: 1e-12)
        XCTAssertEqual(end.x, 1.0, accuracy: 1e-12)
        XCTAssertEqual(end.y, 1.0, accuracy: 1e-12)
        XCTAssertEqual(Squash.scale(at: -0.1), SIMD2<Double>(1.0, 1.0))
        XCTAssertEqual(Squash.scale(at: 0.5), SIMD2<Double>(1.0, 1.0))

        let middle = Squash.scale(at: duration / 2.0, duration: duration)
        XCTAssertEqual(middle.x, 1.14, accuracy: 1e-9)
        XCTAssertEqual(middle.y, 0.86, accuracy: 1e-9)
        for k in 1..<20 {
            let s = Squash.scale(at: duration * Double(k) / 20.0, duration: duration)
            XCTAssertGreaterThan(s.x, 1.0)
            XCTAssertLessThan(s.y, 1.0)
            XCTAssertLessThanOrEqual(s.x, 1.14 + 1e-12)
            XCTAssertGreaterThanOrEqual(s.y, 0.86 - 1e-12)
        }
    }

    // MARK: Shards

    private func shards(_ seed: UInt64) -> (shards: [Shard], impact: SIMD2<Double>, rng: FeelRandom) {
        let made = FeelCheck.stone(seed)
        var rng = made.rng
        let raw = FeelCheck.impact(radius: made.stone.radius, rng: &rng)
        let impact = made.stone.outline.pulledInside(raw)
        let shards = Fracture.shatter(made.stone.outline, impact: impact, rng: &rng)
        return (shards, impact, rng)
    }

    func testShardsFlyAwayFromTheImpact() {
        let center = SIMD2<Double>(200.0, 400.0)
        for seed in 0..<50 {
            let made = shards(UInt64(seed))
            var rng = made.rng
            var flight = ShardFlight.burst(made.shards, center: center, impact: made.impact, floorY: 0.0, rng: &rng)
            XCTAssertEqual(flight.bodies.count, made.shards.count)
            XCTAssertEqual(flight.gravity, 1400.0)
            XCTAssertEqual(flight.drag, 1.6)
            XCTAssertEqual(flight.restitution, 0.35)
            XCTAssertEqual(flight.floorY, 0.0)
            XCTAssertEqual(flight.age, 0.0)
            let source = center + made.impact
            var before: [Double] = []
            for i in 0..<flight.bodies.count {
                let body = flight.bodies[i]
                let home = center + made.shards[i].centroid
                XCTAssertEqual(body.position.x, home.x, accuracy: 1e-12)
                XCTAssertEqual(body.position.y, home.y, accuracy: 1e-12)
                XCTAssertFalse(body.bounced)
                XCTAssertGreaterThanOrEqual(abs(body.spin), 4.0)
                XCTAssertLessThanOrEqual(abs(body.spin), 12.0)
                before.append(FeelMath.distance(body.position, source))
            }
            flight.step(dt: 1.0 / 60.0)
            XCTAssertEqual(flight.age, 1.0 / 60.0, accuracy: 1e-12)
            for i in 0..<flight.bodies.count {
                let after = FeelMath.distance(flight.bodies[i].position, source)
                XCTAssertGreaterThan(after, before[i], "seed \(seed) shard \(i)")
            }
        }
    }

    func testEachShardBouncesOnceThenFallsThrough() {
        let center = SIMD2<Double>(200.0, 400.0)
        let floorY = 60.0
        for seed in 0..<20 {
            let made = shards(UInt64(seed))
            var rng = made.rng
            var flight = ShardFlight.burst(made.shards, center: center, impact: made.impact, floorY: floorY,
                                           rng: &rng)
            var bounces = [Int](repeating: 0, count: flight.bodies.count)
            var turnsUp = [Int](repeating: 0, count: flight.bodies.count)
            for _ in 0..<300 {
                let before = flight.bodies
                flight.step(dt: 1.0 / 60.0)
                for i in 0..<flight.bodies.count {
                    let body = flight.bodies[i]
                    XCTAssertTrue(body.position.x.isFinite && body.position.y.isFinite && body.angle.isFinite)
                    if body.bounced && !before[i].bounced {
                        bounces[i] += 1
                        // Right after its bounce a shard is on or above the floor, moving up.
                        XCTAssertGreaterThanOrEqual(body.position.y, floorY - 1e-9, "seed \(seed) shard \(i)")
                    }
                    if !body.bounced {
                        XCTAssertGreaterThanOrEqual(body.position.y, floorY - 1e-9, "seed \(seed) shard \(i)")
                    }
                    if before[i].velocity.y < 0 && body.velocity.y > 0 { turnsUp[i] += 1 }
                    XCTAssertFalse(before[i].bounced && !body.bounced, "a bounce is not taken back")
                }
            }
            // After 5 s every shard has bounced exactly once and has fallen through the floor.
            for i in 0..<flight.bodies.count {
                XCTAssertEqual(bounces[i], 1, "seed \(seed) shard \(i)")
                XCTAssertLessThanOrEqual(turnsUp[i], 1, "seed \(seed) shard \(i)")
                XCTAssertTrue(flight.bodies[i].bounced)
                XCTAssertLessThan(flight.bodies[i].position.y, floorY, "seed \(seed) shard \(i)")
            }
            XCTAssertEqual(flight.age, 5.0, accuracy: 1e-9)
        }
    }

    func testDragTakesEnergyAway() {
        let made = shards(3)
        var rng = made.rng
        var flight = ShardFlight.burst(made.shards, center: SIMD2<Double>(0.0, 0.0), impact: made.impact,
                                       floorY: -1e9, rng: &rng)
        flight.gravity = 0.0
        var energy = Double.infinity
        for _ in 0..<120 {
            flight.step(dt: 1.0 / 60.0)
            var now = 0.0
            for body in flight.bodies {
                now += 0.5 * FeelMath.dot(body.velocity, body.velocity)
            }
            XCTAssertLessThan(now, energy)
            energy = now
        }
        // With drag 1.6/s the speed falls by e^−3.2 in 2 s.
        var slow = 0.0
        for body in flight.bodies { slow = max(slow, FeelMath.length(body.velocity)) }
        XCTAssertLessThan(slow, 600.0 * exp(-3.2) + 1e-6)
    }

    func testSubStepsMakeTheStepLengthMatterLittle() {
        let made = shards(9)
        var rng = made.rng
        let start = ShardFlight.burst(made.shards, center: SIMD2<Double>(0.0, 0.0), impact: made.impact,
                                      floorY: -1e9, rng: &rng)
        var coarse = start
        var fine = start
        for _ in 0..<30 { coarse.step(dt: 1.0 / 60.0) }
        for _ in 0..<60 { fine.step(dt: 1.0 / 120.0) }
        for i in 0..<coarse.bodies.count {
            XCTAssertEqual(coarse.bodies[i].position.x, fine.bodies[i].position.x, accuracy: 1e-6)
            XCTAssertEqual(coarse.bodies[i].position.y, fine.bodies[i].position.y, accuracy: 1e-6)
        }
    }

    func testSameSeedSameBurst() {
        let made = shards(14)
        var a = FeelRandom(seed: 5)
        var b = FeelRandom(seed: 5)
        let first = ShardFlight.burst(made.shards, center: SIMD2<Double>(1.0, 2.0), impact: made.impact,
                                      floorY: 0.0, rng: &a)
        let second = ShardFlight.burst(made.shards, center: SIMD2<Double>(1.0, 2.0), impact: made.impact,
                                       floorY: 0.0, rng: &b)
        XCTAssertEqual(first, second)
    }

    // MARK: Motes

    func testMotesGoFromTheBurstToTheJar() {
        let origin = SIMD2<Double>(180.0, 420.0)
        let jar = SIMD2<Double>(40.0, 60.0)
        var counts = Set<Int>()
        for seed in 0..<60 {
            var rng = FeelRandom(seed: UInt64(seed))
            let paths = MotePath.toJar(from: origin, jar: jar, rng: &rng)
            XCTAssertTrue(paths.count >= 3 && paths.count <= 5)
            counts.insert(paths.count)
            for path in paths {
                XCTAssertEqual(path.start, origin)
                XCTAssertEqual(path.end, jar)
                XCTAssertTrue(path.delay >= 0.0 && path.delay <= 0.12)
                XCTAssertTrue(path.duration >= 0.55 && path.duration <= 0.8)
                XCTAssertEqual(path.point(at: -1.0), path.start)
                XCTAssertEqual(path.point(at: 0.0), path.start)
                XCTAssertEqual(path.point(at: path.delay), path.start)
                XCTAssertEqual(path.point(at: path.delay + path.duration), path.end)
                XCTAssertEqual(path.point(at: 10.0), path.end)
                var bowed = 0.0
                for k in 0...50 {
                    let p = path.point(at: path.delay + path.duration * Double(k) / 50.0)
                    XCTAssertTrue(p.x.isFinite && p.y.isFinite)
                    // The distance from the straight line origin → jar.
                    let line = jar - origin
                    let off = abs(FeelMath.cross(line, p - origin)) / FeelMath.length(line)
                    bowed = max(bowed, off)
                }
                XCTAssertGreaterThan(bowed, 5.0, "the path curves")
                // Just after setting off it is still near the start, just before arriving near the end.
                let early = path.point(at: path.delay + 0.01 * path.duration)
                let late = path.point(at: path.delay + 0.99 * path.duration)
                XCTAssertLessThan(FeelMath.distance(early, path.start), 1.0)
                XCTAssertLessThan(FeelMath.distance(late, path.end), 1.0)
            }
        }
        XCTAssertEqual(counts, Set([3, 4, 5]))
    }

    func testAMoteWithNoWayToGoStaysFinite() {
        var rng = FeelRandom(seed: 2)
        let here = SIMD2<Double>(5.0, 5.0)
        for path in MotePath.toJar(from: here, jar: here, rng: &rng) {
            for k in 0...10 {
                let p = path.point(at: Double(k) / 10.0)
                XCTAssertTrue(p.x.isFinite && p.y.isFinite)
            }
        }
        let still = MotePath(start: here, control: here, end: SIMD2<Double>(9.0, 9.0), delay: 0.1, duration: 0.0)
        XCTAssertEqual(still.point(at: 0.05), here)
        XCTAssertEqual(still.point(at: 0.2), SIMD2<Double>(9.0, 9.0))
    }
}
