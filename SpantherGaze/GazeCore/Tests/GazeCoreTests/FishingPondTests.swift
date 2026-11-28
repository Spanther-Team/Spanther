import XCTest
@testable import GazeCore

final class FishingPondTests: XCTestCase {
    let screen = Vec2(844, 390)
    let dt = 1.0 / 60

    func testLevels() {
        let one = FishingLevel.level(1), ten = FishingLevel.level(10)
        XCTAssertEqual(one.fishCount, 3)
        XCTAssertEqual(one.goal, 10)
        XCTAssertEqual(one.biteWindowSec, 1.1, accuracy: 1e-9)
        XCTAssertEqual(ten.fishCount, 5)
        XCTAssertEqual(ten.goal, 16)
        XCTAssertEqual(ten.biteWindowSec, 0.5, accuracy: 1e-9)
        XCTAssertEqual(FishingPond(level: 1, screen: screen, startTime: 0, seed: 1).fish.count, 3)
    }

    /// Looks at fish `id` every frame until `until`, returns the events.
    private func watch(_ p: inout FishingPond, _ id: Int, from t: inout Double, until: Double) -> [FishingEvent] {
        var events: [FishingEvent] = []
        while t < until {
            let aim = p.fish.first { $0.id == id }?.position
            events += p.update(time: t, aim: aim)
            t += dt
        }
        return events
    }

    private func biteTime(_ events: [FishingEvent]) -> Double? {
        for e in events { if case .bite(let f) = e, case .biting(let since, _) = f.state { return since } }
        return nil
    }

    func testHoldingMakesItBiteAndEarlyBlinksDoNothing() {
        var p = FishingPond(level: 1, screen: screen, startTime: 0, seed: 2)
        let id = p.fish[0].id
        let hold = FishSpecies.of(p.fish[0].kind).holdSec
        var t = 0.0
        var events = watch(&p, id, from: &t, until: hold * 0.5)
        XCTAssertNil(p.blink(onset: t, aim: p.fish[0].position), "a blink before the bite costs nothing")
        XCTAssertEqual(p.fish[0].state, .swimming)
        XCTAssertGreaterThan(p.fish[0].interest, 0.3)
        events += watch(&p, id, from: &t, until: hold + 0.2)
        let since = biteTime(events)
        XCTAssertNotNil(since)
        XCTAssertEqual(since ?? 0, hold, accuracy: 0.05)
    }

    func testHookReelAndLand() {
        var p = FishingPond(level: 1, screen: screen, startTime: 0, seed: 3)
        let id = p.fish[0].id
        let sp = FishSpecies.of(p.fish[0].kind)
        var t = 0.0
        let since = biteTime(watch(&p, id, from: &t, until: sp.holdSec + 0.1))!
        guard case .hooked(_, let reaction)? = p.blink(onset: since + 0.3, aim: p.fish.first { $0.id == id }!.position)
        else { return XCTFail("no hook") }
        XCTAssertEqual(reaction, 0.3, accuracy: 1e-9)
        XCTAssertEqual(p.hooked?.id, id)
        let events = watch(&p, id, from: &t, until: t + sp.reelSec + 0.2)
        XCTAssertTrue(events.contains { if case .landed(let f, let pts) = $0 { return f.id == id && pts == sp.points } else { return false } })
        XCTAssertNil(p.hooked)
        XCTAssertEqual(p.score, sp.points)
        _ = watch(&p, -1, from: &t, until: t + 1.1)
        XCTAssertEqual(p.fish.count, 3, "a new fish comes after a second")
        XCTAssertEqual(p.result(at: t).followShare ?? 0, 1, accuracy: 0.02)
    }

    /// A blink in the bite window hooks the biting fish when the aim has slipped off it, up to the assist reach.
    func testAssistReachHooksTheBitingFish() {
        func setUp() -> (FishingPond, Int, Double, Vec2, Double) {
            var p = FishingPond(level: 1, screen: screen, startTime: 0, seed: 3)
            let id = p.fish[0].id
            var t = 0.0
            _ = biteTime(watch(&p, id, from: &t, until: FishSpecies.of(p.fish[0].kind).holdSec + 0.1))
            let f = p.fish.first { $0.id == id }!
            let toCentre = Vec2(screen.x / 2, screen.y / 2) - f.position
            let dir = toCentre.length > 1 ? toCentre * (1 / toCentre.length) : Vec2(1, 0)
            return (p, id, t, dir, p.reach(f))
        }
        let (p0, id, t, dir, reach) = setUp()
        var p = p0
        let f = p.fish.first { $0.id == id }!
        let aim = f.position + dir * (2 * reach)
        _ = p.update(time: t, aim: aim)
        guard case .hooked(let hooked, _)? = p.blink(onset: t, aim: aim) else { return XCTFail("the assist should hook it") }
        XCTAssertEqual(hooked.id, id)
        XCTAssertTrue(p.lastAssisted)

        let (q0, qid, qt, qdir, qreach) = setUp()
        var q = q0
        let g = q.fish.first { $0.id == qid }!
        let far = g.position + qdir * (2.6 * qreach)
        _ = q.update(time: qt, aim: far)
        XCTAssertNil(q.blink(onset: qt, aim: far))
        XCTAssertFalse(q.lastAssisted)
    }

    func testMissedWindowLetsGo() {
        var p = FishingPond(level: 1, screen: screen, startTime: 0, seed: 4)
        let id = p.fish[0].id
        var t = 0.0
        let events = watch(&p, id, from: &t, until: FishSpecies.of(p.fish[0].kind).holdSec + 1.3)
        XCTAssertTrue(events.contains { if case .letGo = $0 { return true } else { return false } })
        if case .fleeing = p.fish.first(where: { $0.id == id })!.state {} else { XCTFail("not fleeing") }
        XCTAssertNotEqual(p.lockedFish, id, "a fleeing fish cannot be held")
        XCTAssertEqual(p.result(at: t).letGo, 1)
    }

    func testLookingAwaySnapsTheLine() {
        var p = FishingPond(level: 1, screen: screen, startTime: 0, seed: 5)
        let id = p.fish[0].id
        var t = 0.0
        let since = biteTime(watch(&p, id, from: &t, until: FishSpecies.of(p.fish[0].kind).holdSec + 0.1))!
        XCTAssertNotNil(p.blink(onset: since + 0.2, aim: nil))
        var snapped = false
        while t < since + 3 {
            for e in p.update(time: t, aim: Vec2(-500, -500)) { if case .snapped = e { snapped = true } }
            t += dt
        }
        XCTAssertTrue(snapped)
        XCTAssertNil(p.hooked)
        XCTAssertEqual(p.result(at: t).snapped, 1)
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

    /// A player with the tracker's error: aim 12 pt off with 20 pt of jitter, 0.35 to 0.6 s to blink after a bite,
    /// 0.15 s behind a moving fish.
    func testBotCanWin() {
        let one = play(level: 1, seed: 21), ten = play(level: 10, seed: 22)
        XCTAssertEqual(one.stars, 3, "\(one)")
        XCTAssertGreaterThanOrEqual(ten.stars, 1, "\(ten)")
        XCTAssertLessThan(ten.accuracy, one.accuracy + 1e-9)
    }

    private func play(level: Int, seed: UInt64) -> FishingResult {
        var p = FishingPond(level: level, screen: screen, startTime: 0, seed: seed, zoneFloor: 60)
        var rng = SeededRandom(seed: seed &+ 7)
        func gauss() -> Double {
            let u = max(1e-9, Double.random(in: 0..<1, using: &rng)), v = Double.random(in: 0..<1, using: &rng)
            return sqrt(-2 * log(u)) * cos(2 * .pi * v)
        }
        var target: Int?
        var blinkAt: Double?
        var trail: [(Double, Vec2)] = []
        var t = 0.0
        while true {
            if target == nil || !p.fish.contains(where: { $0.id == target }) {
                target = p.hooked?.id ?? p.fish.filter { if case .fleeing = $0.state { return false } else { return true } }
                    .min { $0.position.y < $1.position.y }?.id
            }
            if let h = p.hooked { target = h.id }
            if let f = p.fish.first(where: { $0.id == target }) { trail.append((t, f.position)) }
            trail.removeAll { $0.0 < t - 0.15 }
            let seen = trail.first?.1
            let aim = seen.map { Vec2($0.x + 12 + 20 * gauss(), $0.y - 8 + 20 * gauss()) }
            for e in p.update(time: t, aim: aim) {
                if case .bite = e { blinkAt = t + 0.35 + 0.25 * Double.random(in: 0..<1, using: &rng) }
                if case .ended(let r) = e { return r }
            }
            if let b = blinkAt, t >= b {
                _ = p.blink(onset: t, aim: aim)
                blinkAt = nil
            }
            t += dt
        }
    }
}
