import XCTest
@testable import GazeCore

final class MoleGardenTests: XCTestCase {
    let screen = Vec2(844, 390)

    func testLevelsGetQuicker() {
        let one = MoleLevel.level(1), ten = MoleLevel.level(10)
        XCTAssertEqual(one.maxUp, 1)
        XCTAssertEqual(one.decoyShare, 0)
        XCTAssertEqual(one.upSec, 2.4, accuracy: 1e-9)
        XCTAssertEqual(ten.maxUp, 3)
        XCTAssertEqual(ten.upSec, 0.85, accuracy: 1e-9)
        for n in 1..<10 { XCTAssertGreaterThanOrEqual(MoleLevel.level(n).upSec, MoleLevel.level(n + 1).upSec) }
    }

    func testSameSeedSamePops() {
        func run(_ seed: UInt64) -> [Int] {
            var g = MoleGarden(level: 6, screen: screen, startTime: 0, seed: seed)
            var holes: [Int] = []
            for f in 0..<1800 {
                for e in g.update(time: Double(f) / 60, aim: nil) { if case .popped(let p) = e { holes.append(p.hole) } }
            }
            return holes
        }
        XCTAssertEqual(run(42), run(42))
        XCTAssertNotEqual(run(42), run(43))
        XCTAssertGreaterThan(run(42).count, 20)
    }

    /// Runs until the first pop and returns it.
    private func firstPop(_ g: inout MoleGarden, from t0: Double = 0) -> (MolePop, Double) {
        var t = t0
        while t < 10 {
            for e in g.update(time: t, aim: nil) { if case .popped(let p) = e { return (p, t) } }
            t += 1.0 / 60
        }
        XCTFail("no pop")
        return (MolePop(id: 0, hole: 0, kind: .mole, start: 0, hideAt: 0, bonkedAt: nil), t)
    }

    func testBonkScoresAndCombos() {
        var g = MoleGarden(level: 1, screen: screen, startTime: 0, seed: 1)
        var points: [Int] = []
        var t = 0.0
        while points.count < 3, t < 30 {
            for e in g.update(time: t, aim: nil) {
                if case .popped(let p) = e, p.kind != .hedgehog {
                    if case .hit(_, let pts, let reaction)? = g.bonk(onset: t + 0.4, aim: g.holeCenter(p.hole)) {
                        points.append(pts)
                        XCTAssertEqual(reaction, 0.4, accuracy: 1e-9)
                    }
                }
            }
            t += 1.0 / 60
        }
        XCTAssertEqual(points.count, 3)
        // Golden moles give 300; the combo adds 10 per mole in a row.
        for (i, p) in points.enumerated() { XCTAssertTrue(p == 100 + 10 * i || p == 300 + 10 * i, "\(p)") }
        XCTAssertEqual(g.combo, 3)
    }

    func testEmptyHoleIsAWhiffAndBreaksTheCombo() {
        var g = MoleGarden(level: 1, screen: screen, startTime: 0, seed: 1)
        let (p, t) = firstPop(&g)
        _ = g.bonk(onset: t + 0.3, aim: g.holeCenter(p.hole))
        XCTAssertEqual(g.combo, 1)
        let other = (p.hole + 1) % 6
        XCTAssertEqual(g.bonk(onset: t + 0.5, aim: g.holeCenter(other)), .whiff(hole: other))
        XCTAssertEqual(g.combo, 0)
        // Between the holes, away from every reach, with no lock: nowhere.
        XCTAssertEqual(g.bonk(onset: t + 0.6, aim: Vec2(10, 10)), .whiff(hole: nil))
        XCTAssertEqual(g.result(at: t + 1).whiffs, 2)
    }

    /// A blink that misses every reach still bonks the mole up nearby (G2OM-style picking), but not one too far.
    func testAssistReachBonksTheNearbyMole() {
        var g = MoleGarden(level: 1, screen: screen, startTime: 0, seed: 1)
        let (p, t) = firstPop(&g)
        let c = g.holeCenter(p.hole)
        let out = Vec2(c.x < screen.x / 2 ? -1 : 1, 0)
        let aim = c + out * (2 * g.reach)
        XCTAssertNil(g.nearestHole(to: aim))
        guard case .hit(let q, _, _)? = g.bonk(onset: t + 0.3, aim: aim) else { return XCTFail("the assist should bonk it") }
        XCTAssertEqual(q.hole, p.hole)
        XCTAssertTrue(g.lastAssisted)

        var h = MoleGarden(level: 1, screen: screen, startTime: 0, seed: 1)
        let (p2, t2) = firstPop(&h)
        let c2 = h.holeCenter(p2.hole)
        let far = c2 + Vec2(c2.x < screen.x / 2 ? -1 : 1, 0) * (2.6 * h.reach)
        XCTAssertEqual(h.bonk(onset: t2 + 0.3, aim: far), .whiff(hole: nil))
        XCTAssertFalse(h.lastAssisted)
    }

    func testLateGrace() {
        var g = MoleGarden(level: 1, screen: screen, startTime: 0, seed: 3)
        let (p, _) = firstPop(&g)
        if case .hit? = g.bonk(onset: p.hideAt + 0.1, aim: g.holeCenter(p.hole)) {} else { XCTFail("late blink inside grace") }
        var h = MoleGarden(level: 1, screen: screen, startTime: 0, seed: 3)
        let (q, _) = firstPop(&h)
        XCTAssertEqual(h.bonk(onset: q.hideAt + 0.2, aim: h.holeCenter(q.hole)), .whiff(hole: q.hole))
    }

    func testHedgehogCostsPointsNeverBelowZero() {
        var g = MoleGarden(level: 9, screen: screen, startTime: 0, seed: 5)
        var t = 0.0, hedgehog: MolePop?
        while hedgehog == nil, t < 60 {
            for e in g.update(time: t, aim: nil) { if case .popped(let p) = e, p.kind == .hedgehog { hedgehog = p } }
            t += 1.0 / 60
        }
        guard let h = hedgehog else { return XCTFail("no hedgehog in a minute of level 9") }
        // Near the hedgehog but out of its reach: the assist never picks a hedgehog.
        let c = g.holeCenter(h.hole)
        var probe = g
        if case .hedgehogHit? = probe.bonk(onset: t, aim: c + Vec2(c.x < screen.x / 2 ? -1 : 1, 0) * (1.6 * g.reach)) {
            XCTFail("the assist bonked a hedgehog")
        }
        XCTAssertEqual(g.bonk(onset: t, aim: g.holeCenter(h.hole)), .hedgehogHit({ var x = h; x.bonkedAt = t; return x }()))
        XCTAssertEqual(g.score, 0)
        XCTAssertEqual(g.result(at: t).hedgehogHits, 1)
    }

    func testEscapesAndTheEnd() {
        var config = MoleConfig()
        config.roundSec = 20
        var g = MoleGarden(level: 1, screen: screen, startTime: 0, seed: 9, config: config)
        var escaped = 0, ended: MoleResult?
        var t = 0.0
        while ended == nil, t < 25 {
            for e in g.update(time: t, aim: nil) {
                if case .escaped = e { escaped += 1 }
                if case .ended(let r) = e { ended = r }
            }
            t += 1.0 / 60
        }
        guard let r = ended else { return XCTFail("no end") }
        XCTAssertEqual(r.escaped, escaped)
        XCTAssertGreaterThan(escaped, 5)
        XCTAssertEqual(r.hits, 0)
        XCTAssertEqual(r.stars, 0)
        XCTAssertEqual(r.durationSec, 20, accuracy: 1e-9)
        XCTAssertTrue(g.update(time: t + 1, aim: nil).isEmpty)
    }

    func testRiseCurve() {
        let c = MoleConfig()
        let p = MolePop(id: 0, hole: 0, kind: .mole, start: 1, hideAt: 3, bonkedAt: nil)
        XCTAssertEqual(p.rise(at: 0.5, config: c), 0)
        XCTAssertEqual(p.rise(at: 1 + c.riseSec / 2, config: c), 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.rise(at: 2, config: c), 1)
        XCTAssertEqual(p.state(at: 3.1, config: c), .hiding)
        XCTAssertEqual(p.state(at: 3.3, config: c), .gone)
        var b = p
        b.bonkedAt = 2
        XCTAssertEqual(b.state(at: 2.5, config: c), .dizzy)
        XCTAssertEqual(b.rise(at: 2.5, config: c), 1)
    }

    /// A player with a phone tracker's error: reaction 0.5 to 0.8 s, 0.45 s to blink and look on, one look in seven 0.45 s late, aim 15 pt off with 25 pt of jitter, who
    /// sometimes bonks a hedgehog. Level 1 must give three stars, level 10 at least one.
    func testBotCanWin() {
        XCTAssertEqual(play(level: 1, seed: 11).stars, 3)
        XCTAssertGreaterThanOrEqual(play(level: 5, seed: 12).stars, 2)
        XCTAssertGreaterThanOrEqual(play(level: 10, seed: 13).stars, 1)
        XCTAssertLessThan(play(level: 10, seed: 13).accuracy, play(level: 1, seed: 11).accuracy)
    }

    private func play(level: Int, seed: UInt64) -> MoleResult {
        var g = MoleGarden(level: level, screen: screen, startTime: 0, seed: seed, zoneFloor: 70)
        var rng = SeededRandom(seed: seed &+ 100)
        func gauss() -> Double {
            let u = max(1e-9, Double.random(in: 0..<1, using: &rng)), v = Double.random(in: 0..<1, using: &rng)
            return sqrt(-2 * log(u)) * cos(2 * .pi * v)
        }
        var noticed: [(pop: MolePop, at: Double)] = []
        var target: (pop: MolePop, settledAt: Double)?
        var aim = Vec2(422, 200)
        var busyUntil = 0.0
        var result: MoleResult?
        var t = 0.0
        while result == nil {
            for e in g.update(time: t, aim: aim) {
                if case .popped(let p) = e { noticed.append((p, t + 0.5 + 0.3 * Double.random(in: 0..<1, using: &rng)
                                   + (Double.random(in: 0..<1, using: &rng) < 0.15 ? 0.45 : 0))) }
                if case .ended(let r) = e { result = r }
            }
            if target == nil, t >= busyUntil,
               let i = noticed.firstIndex(where: { $0.at <= t && g.pop(in: $0.pop.hole, at: t)?.id == $0.pop.id }) {
                let n = noticed.remove(at: i)
                let leaveAlone = n.pop.kind == .hedgehog && Double.random(in: 0..<1, using: &rng) < 0.85
                if !leaveAlone { target = (n.pop, t + 0.15) }
            }
            if let tg = target {
                let c = g.holeCenter(tg.pop.hole)
                aim = Vec2(c.x + 15 + 25 * gauss(), c.y - 10 + 25 * gauss())
                if t >= tg.settledAt {
                    _ = g.bonk(onset: t, aim: aim)
                    target = nil
                    busyUntil = t + 0.45
                }
            }
            noticed.removeAll { g.pop(in: $0.pop.hole, at: t)?.id != $0.pop.id && $0.at < t }
            t += 1.0 / 60
        }
        return result!
    }
}
