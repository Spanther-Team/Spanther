import XCTest
@testable import GazeCore

final class FishingPondTests: XCTestCase {
    let screen = Vec2(844, 390)
    let dt = 1.0 / 60

    func testLevels() {
        let one = FishingLevel.level(1), ten = FishingLevel.level(10)
        XCTAssertEqual(one.fishCount, 3)
        XCTAssertEqual(one.goal, 10)
        XCTAssertEqual(one.holdScale, 1, accuracy: 1e-9)
        XCTAssertEqual(ten.fishCount, 5)
        XCTAssertEqual(ten.goal, 18)
        XCTAssertEqual(ten.holdScale, 1.25, accuracy: 1e-9)
        XCTAssertEqual(FishingPond(level: 1, screen: screen, startTime: 0, seed: 1).fish.count, 3)
    }

    /// Looks at fish `id` every frame until `until` or until it is gone, returns the events.
    private func watch(_ p: inout FishingPond, _ id: Int, from t: inout Double, until: Double) -> [FishingEvent] {
        var events: [FishingEvent] = []
        while t < until {
            let aim = p.fish.first { $0.id == id }?.position
            events += p.update(time: t, aim: aim)
            t += dt
        }
        return events
    }

    private func caught(_ events: [FishingEvent]) -> (Fish, Int, Double)? {
        for e in events { if case let .caught(f, points, held) = e { return (f, points, held) } }
        return nil
    }

    /// Holding the eyes on a fish catches it after its holding time, at once: no bite, no blink, no reeling.
    func testHoldingCatches() {
        var p = FishingPond(level: 1, screen: screen, startTime: 0, seed: 3)
        let first = p.fish[0]
        let hold = p.holdSec(first)
        var t = 0.0
        var events = watch(&p, first.id, from: &t, until: hold * 0.5)
        XCTAssertTrue(events.contains { if case .looked(let f) = $0 { return f.id == first.id } else { return false } })
        XCTAssertEqual(p.holding?.fish.id, first.id)
        XCTAssertEqual(p.holding?.progress ?? 0, 0.5, accuracy: 0.06)
        XCTAssertNil(caught(events))
        events += watch(&p, first.id, from: &t, until: hold + 0.1)
        guard let (f, points, held) = caught(events) else { return XCTFail("not caught") }
        XCTAssertEqual(f.id, first.id)
        XCTAssertEqual(points, FishSpecies.of(first.kind).points)
        XCTAssertEqual(held, hold, accuracy: 0.05)
        XCTAssertFalse(p.fish.contains { $0.id == first.id }, "the catch leaves the pond at once")
        XCTAssertNil(p.holding)
        XCTAssertEqual(p.score, points)
        XCTAssertEqual(p.result(at: t).landed, 1)
        _ = watch(&p, -1, from: &t, until: t + 1.1)
        XCTAssertEqual(p.fish.count, 3, "a new fish comes after a second")
    }

    /// Looking away lets the hold drain; a glance back does not start from full.
    func testLookingAwayDrainsTheHold() {
        var p = FishingPond(level: 1, screen: screen, startTime: 0, seed: 4)
        let id = p.fish[0].id
        let hold = p.holdSec(p.fish[0])
        var t = 0.0
        _ = watch(&p, id, from: &t, until: hold * 0.6)
        let half = p.fish.first { $0.id == id }!.interest
        while t < hold * 0.6 + 0.5 {
            _ = p.update(time: t, aim: Vec2(-500, -500))
            t += dt
        }
        XCTAssertNil(p.holding)
        XCTAssertLessThan(p.fish.first { $0.id == id }!.interest, half - 0.25)
        XCTAssertEqual(p.result(at: t).landed, 0)
    }

    func testTheRoundEndsAtTheGoal() {
        var config = FishingConfig()
        config.roundSec = 600
        var p = FishingPond(level: 1, screen: screen, startTime: 0, seed: 5, config: config)
        var t = 0.0, result: FishingResult?
        while result == nil, t < 600 {
            let aim = p.holding?.fish.position ?? p.fish.first?.position
            for e in p.update(time: t, aim: aim) { if case .ended(let r) = e { result = r } }
            t += dt
        }
        guard let r = result else { return XCTFail("no end") }
        XCTAssertEqual(r.landed, r.goal)
        XCTAssertEqual(r.stars, 3)
        XCTAssertLessThan(r.durationSec, 60)
        XCTAssertTrue(p.ended)
        XCTAssertTrue(p.update(time: t + 1, aim: nil).isEmpty)
    }

    func testFishStayInThePondAndTheRoundEnds() {
        var config = FishingConfig()
        config.roundSec = 60
        var p = FishingPond(level: 10, screen: screen, startTime: 0, seed: 6, config: config)
        var t = 0.0, ended = false
        while t < 61 {
            for e in p.update(time: t, aim: nil) { if case .ended = e { ended = true } }
            for f in p.fish {
                XCTAssertGreaterThanOrEqual(f.position.x, 0.07 * 844 - 1)
                XCTAssertLessThanOrEqual(f.position.x, 0.93 * 844 + 1)
                XCTAssertGreaterThanOrEqual(f.position.y, 0.18 * 390 - 1)
                XCTAssertLessThanOrEqual(f.position.y, 0.9 * 390 + 1)
            }
            t += dt
        }
        XCTAssertTrue(ended)
    }

    /// A player with the tracker's error: aim 12 pt off with 20 pt of jitter, 0.15 s behind a moving fish, 0.4 s to
    /// find the next fish.
    func testBotCanWin() {
        let one = play(level: 1, seed: 21), ten = play(level: 10, seed: 22)
        XCTAssertEqual(one.stars, 3, "\(one)")
        XCTAssertGreaterThanOrEqual(ten.stars, 1, "\(ten)")
        XCTAssertGreaterThan(ten.meanHoldSec ?? 0, one.meanHoldSec ?? 0)
    }

    private func play(level: Int, seed: UInt64) -> FishingResult {
        var p = FishingPond(level: level, screen: screen, startTime: 0, seed: seed, zoneFloor: 60)
        var rng = SeededRandom(seed: seed &+ 7)
        func gauss() -> Double {
            let u = max(1e-9, Double.random(in: 0..<1, using: &rng)), v = Double.random(in: 0..<1, using: &rng)
            return sqrt(-2 * log(u)) * cos(2 * .pi * v)
        }
        var target: Int?
        var lookFrom = 0.0
        var trail: [(Double, Vec2)] = []
        var t = 0.0
        while true {
            if target == nil || !p.fish.contains(where: { $0.id == target }) {
                target = p.fish.min { $0.position.y < $1.position.y }?.id
                lookFrom = t + 0.4
                trail.removeAll()
            }
            if let f = p.fish.first(where: { $0.id == target }) { trail.append((t, f.position)) }
            trail.removeAll { $0.0 < t - 0.15 }
            let seen = t >= lookFrom ? trail.first?.1 : nil
            let aim = seen.map { Vec2($0.x + 12 + 20 * gauss(), $0.y - 8 + 20 * gauss()) }
            for e in p.update(time: t, aim: aim) {
                if case .ended(let r) = e { return r }
            }
            t += dt
        }
    }
}
