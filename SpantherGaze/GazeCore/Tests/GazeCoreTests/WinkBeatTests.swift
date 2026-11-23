@testable import GazeCore
import XCTest

final class WinkBeatTests: XCTestCase {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("SpantherGaze/Resources")
    let field = WinkBeatField.reference

    func bundledMap() throws -> WinkBeatMap {
        let url = Self.resources.appendingPathComponent("winkbeat-198.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no map at \(url.path)") }
        return try WinkBeatMap.load(from: Data(contentsOf: url))
    }

    func play(_ objects: [WinkBeatObject], _ d: WinkBeatDifficulty = .normal, latency: Double = 0) -> WinkBeatPlay {
        WinkBeatPlay(objects: objects, rules: .make(d, field: field), field: field, beatSec: 0.5, latencySec: latency)
    }

    // MARK: - Map

    /// The test level: it loads, its audio is in the bundle, and every chart passes the rules.
    func testBundledMapIsPlayable() throws {
        let map = try bundledMap()
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.resources.appendingPathComponent(map.audio).path))
        XCTAssertEqual(map.bpm, 99)
        for d in WinkBeatDifficulty.allCases {
            let chart = map.chart(d)
            XCTAssertGreaterThan(chart.count, 30, "\(d)")
            XCTAssertEqual(map.validate(d), [], "\(d)")
            XCTAssertTrue(chart.contains { $0.kind == .slider }, "\(d) has sliders")
            XCTAssertTrue(chart.contains { $0.kind == .spinner }, "\(d) has a spinner")
            XCTAssertLessThanOrEqual(chart.last!.endTime, map.durationSec)
        }
    }

    func testValidationFindsBrokenCharts() {
        func issues(_ objects: [WinkBeatObject], _ d: WinkBeatDifficulty = .normal) -> [String] {
            WinkBeatMap(id: "t", title: "t", author: "t", license: "t", audio: "t.m4a", bpm: 120, firstBeatSec: 0,
                        durationSec: 60, charts: [d.rawValue: objects]).validate(d).map(\.message)
        }
        XCTAssertEqual(issues([WinkBeatObject(kind: .circle, time: 1, x: 0.2, y: 0.5),
                               WinkBeatObject(kind: .circle, time: 4, x: 0.8, y: 0.5)]), [])
        XCTAssertTrue(issues([WinkBeatObject(kind: .circle, time: 1, x: 0.2, y: 0.5),
                              WinkBeatObject(kind: .circle, time: 1.2, x: 0.8, y: 0.5)]).contains { $0.contains("after the previous") })
        XCTAssertTrue(issues([WinkBeatObject(kind: .circle, time: 1, x: 0.95, y: 0.5)]).contains { $0.contains("outside") })
        XCTAssertTrue(issues([WinkBeatObject(kind: .circle, time: 1, x: 0.4, y: 0.5),
                              WinkBeatObject(kind: .circle, time: 2, x: 0.5, y: 0.5)]).contains { $0.contains("overlaps") })
        XCTAssertTrue(issues([WinkBeatObject(kind: .slider, time: 1, x: 0.1, y: 0.5, end: 1.2, path: [[0.9, 0.5]])])
            .contains { $0.contains("too fast") })
        XCTAssertTrue(issues([WinkBeatObject(kind: .spinner, time: 1, end: 1.5)]).contains { $0.contains("1 s") })
        XCTAssertTrue(issues([WinkBeatObject(kind: .circle, time: 1, x: 0.2, y: 0.5, side: .left)], .easy)
            .contains { $0.contains("side any") })
        // Five lefts in a row on normal.
        let lefts: [WinkBeatObject] = (0..<5).map { (i: Int) -> WinkBeatObject in
            let x: Double = i % 2 == 0 ? 0.2 : 0.8
            return WinkBeatObject(kind: .circle, time: 1 + Double(i) * 2, x: x, y: 0.5, side: .left)
        }
        XCTAssertTrue(issues(lefts).contains { $0.contains("same eye") })
        // Twelve winks in 5 s on easy.
        let dense: [WinkBeatObject] = (0..<6).map { (i: Int) -> WinkBeatObject in
            let x: Double = i % 2 == 0 ? 0.15 : 0.85
            let y: Double = i % 3 == 0 ? 0.2 : 0.8
            return WinkBeatObject(kind: .circle, time: 1 + Double(i), x: x, y: y)
        }
        XCTAssertTrue(issues(dense, .easy).contains { $0.contains("winks in 5 s") })
    }

    func testObjectDefaultsDecode() throws {
        let json = #"[{"kind":"spinner","time":3,"end":5},{"kind":"circle","time":1,"x":0.3,"y":0.4}]"#
        let objects = try JSONDecoder().decode([WinkBeatObject].self, from: Data(json.utf8))
        XCTAssertEqual(objects[0], WinkBeatObject(kind: .spinner, time: 3, x: 0.5, y: 0.5, side: .any, end: 5))
        XCTAssertEqual(objects[1].side, .any)
    }

    // MARK: - Slider path

    func testPathRunsThroughItsPointsAtEvenSpeed() {
        let path = WinkBeatPath(points: [Vec2(0, 0), Vec2(100, 0), Vec2(200, 0)])
        XCTAssertEqual(path.length, 200, accuracy: 1e-6)
        XCTAssertEqual(path.position(progress: 0).x, 0, accuracy: 1e-6)
        XCTAssertEqual(path.position(progress: 0.25).x, 50, accuracy: 1e-6)
        XCTAssertEqual(path.position(progress: 1).x, 200, accuracy: 1e-6)
        // One turn back: out in the first half, home in the second.
        XCTAssertEqual(path.position(progress: 0.5, repeats: 1).x, 200, accuracy: 1e-6)
        XCTAssertEqual(path.position(progress: 0.75, repeats: 1).x, 100, accuracy: 1e-6)
        XCTAssertEqual(path.position(progress: 1, repeats: 1).x, 0, accuracy: 1e-6)
        let curve = WinkBeatPath(points: [Vec2(0, 0), Vec2(100, 80), Vec2(200, 0)])
        XCTAssertEqual(curve.position(progress: 1).distance(to: Vec2(200, 0)), 0, accuracy: 1e-6)
        XCTAssertGreaterThan(curve.length, 2 * Vec2(100, 80).length - 1)
    }

    // MARK: - Judge

    func testWindowsGradeAWink() {
        var p = play([WinkBeatObject(kind: .circle, time: 2, x: 0.3, y: 0.5)])
        let spot = p.positions[0]
        p.closure(WinkBeatClosure(side: .left, time: 2.05, aim: spot))
        XCTAssertEqual(p.results[0], .perfect)
        XCTAssertEqual(p.offsets[0] ?? 0, 0.05, accuracy: 1e-9)
        for (dt, grade) in [(0.12, WinkBeatGrade.great), (0.2, .good)] {
            var q = play([WinkBeatObject(kind: .circle, time: 2, x: 0.3, y: 0.5)])
            q.closure(WinkBeatClosure(side: .right, time: 2 + dt, aim: spot))
            XCTAssertEqual(q.results[0], grade)
        }
        // Outside the good window: nothing played, then the frame calls it a miss.
        var late = play([WinkBeatObject(kind: .circle, time: 2, x: 0.3, y: 0.5)])
        XCTAssertEqual(late.closure(WinkBeatClosure(side: .left, time: 2.3, aim: spot)), [])
        XCTAssertEqual(late.stray, 1)
        late.frame(time: 2.3, aim: spot)
        XCTAssertEqual(late.results[0], .miss)
    }

    func testAimOffTheObjectDoesNotUseItUp() {
        var p = play([WinkBeatObject(kind: .circle, time: 2, x: 0.3, y: 0.5)])
        let far = p.positions[0] + Vec2(p.rules.zonePt + 5, 0)
        XCTAssertEqual(p.closure(WinkBeatClosure(side: .left, time: 2, aim: far)), [.rejected(index: 0, reason: .offTarget)])
        XCTAssertNil(p.results[0])
        p.closure(WinkBeatClosure(side: .left, time: 2.05, aim: p.positions[0]))
        XCTAssertEqual(p.results[0], .perfect)
    }

    func testEyeRules() {
        var p = play([WinkBeatObject(kind: .circle, time: 2, x: 0.3, y: 0.5, side: .left)])
        XCTAssertEqual(p.closure(WinkBeatClosure(side: .right, time: 2, aim: p.positions[0])),
                       [.rejected(index: 0, reason: .wrongEye)])
        XCTAssertEqual(p.closure(WinkBeatClosure(side: .both, time: 2, aim: p.positions[0])),
                       [.rejected(index: 0, reason: .blink)])
        p.closure(WinkBeatClosure(side: .left, time: 2, aim: p.positions[0]))
        XCTAssertEqual(p.results[0], .perfect)
        // A long blink plays `any` objects on easy only.
        var easy = play([WinkBeatObject(kind: .circle, time: 2, x: 0.3, y: 0.5)], .easy)
        easy.closure(WinkBeatClosure(side: .both, time: 2, aim: easy.positions[0]))
        XCTAssertEqual(easy.results[0], .perfect)
        var normal = play([WinkBeatObject(kind: .circle, time: 2, x: 0.3, y: 0.5)], .normal)
        normal.closure(WinkBeatClosure(side: .both, time: 2, aim: normal.positions[0]))
        XCTAssertNil(normal.results[0])
    }

    func testLockedObjectWinsOverAnEarlierOne() {
        var p = play([WinkBeatObject(kind: .circle, time: 2, x: 0.2, y: 0.5),
                      WinkBeatObject(kind: .circle, time: 2.2, x: 0.8, y: 0.5)], .hard)
        // Both zones hold the aim only in this made-up case: aim halfway, both windows open, lock on #1.
        p.closure(WinkBeatClosure(side: .left, time: 2.1, aim: p.positions[1]), prefer: 1)
        XCTAssertNil(p.results[0])
        XCTAssertEqual(p.results[1], .great)
    }

    func testSliderNeedsTheHeadAndTheFollow() {
        let slider = WinkBeatObject(kind: .slider, time: 1, x: 0.3, y: 0.5, end: 2, path: [[0.5, 0.4], [0.6, 0.5]])
        // Head on time, orb followed all the way: the head's grade.
        var p = play([slider])
        XCTAssertEqual(p.closure(WinkBeatClosure(side: .left, time: 1, aim: p.positions[0])),
                       [.head(index: 0, grade: .perfect, offsetSec: 0)])
        var ticks = 0
        for f in 0...70 {
            let t = 1 + Double(f) / 60
            for e in p.frame(time: t, aim: p.orb(0, at: t)) { if case .sliderTick(_, true) = e { ticks += 1 } }
        }
        XCTAssertEqual(p.results[0], .perfect)
        XCTAssertEqual(ticks, 1, "one tick on the beat between head and end (beat 0.5 s)")
        // Head on time, then the aim leaves: a miss.
        var q = play([slider])
        q.closure(WinkBeatClosure(side: .left, time: 1, aim: q.positions[0]))
        for f in 0...70 { q.frame(time: 1 + Double(f) / 60, aim: Vec2(0, 0)) }
        XCTAssertEqual(q.results[0], .miss)
        // Head missed, orb followed: good, so following still pays.
        var r = play([slider])
        for f in 0...70 { let t = 1 + Double(f) / 60; r.frame(time: t, aim: r.orb(0, at: t)) }
        XCTAssertEqual(r.results[0], .good)
    }

    func testSpinnerCountsHopsAndIgnoresEdgeJitter() {
        let spinner = WinkBeatObject(kind: .spinner, time: 1, end: 3)
        var p = play([spinner])
        let needed = p.hopsNeeded(0)
        XCTAssertEqual(needed, 5)
        // Jitter across one sector edge for the whole spinner: no progress.
        for f in 0...130 {
            let t = 1 + Double(f) / 60
            p.frame(time: t, aim: p.petal(0, f % 2 == 0 ? 0 : 1))
        }
        XCTAssertEqual(p.results[0], .miss)
        // Hopping around the ring: full grade.
        var q = play([spinner])
        for f in 0...130 {
            let t = 1 + Double(f) / 60
            q.frame(time: t, aim: q.petal(0, (f / 10) % 8))
        }
        XCTAssertEqual(q.results[0], .perfect)
        // Near the centre counts for nothing.
        var r = play([spinner])
        for f in 0...130 { r.frame(time: 1 + Double(f) / 60, aim: r.positions[0] + Vec2(Double(f % 3), 0)) }
        XCTAssertEqual(r.results[0], .miss)
    }

    func testEnergyFailsOnNormalButNotOnEasy() {
        let objects: [WinkBeatObject] = (0..<12).map { (i: Int) -> WinkBeatObject in
            let x: Double = i % 2 == 0 ? 0.2 : 0.8
            return WinkBeatObject(kind: .circle, time: 1 + Double(i) * 1.2, x: x, y: 0.5)
        }
        var normal = play(objects, .normal)
        var easy = play(objects, .easy)
        var failedAt: Double?
        for f in 0..<(60 * 16) {
            let t = Double(f) / 60
            if normal.frame(time: t, aim: nil).contains(.failed) { failedAt = t }
            easy.frame(time: t, aim: nil)
        }
        XCTAssertNotNil(failedAt)
        XCTAssertTrue(normal.failed)
        XCTAssertFalse(easy.failed)
        XCTAssertTrue(easy.finished)
        XCTAssertEqual(easy.rank, .d)
    }

    func testRanks() {
        XCTAssertEqual(WinkBeatRank.of(accuracy: 1, misses: 0), .ss)
        XCTAssertEqual(WinkBeatRank.of(accuracy: 0.96, misses: 0), .s)
        XCTAssertEqual(WinkBeatRank.of(accuracy: 0.96, misses: 1), .a)
        XCTAssertEqual(WinkBeatRank.of(accuracy: 0.85, misses: 0), .b)
        XCTAssertEqual(WinkBeatRank.of(accuracy: 0.72, misses: 3), .c)
        XCTAssertEqual(WinkBeatRank.of(accuracy: 0.5, misses: 9), .d)
    }

    func testComboAndScore() {
        let objects: [WinkBeatObject] = (0..<3).map { (i: Int) -> WinkBeatObject in
            let x: Double = i % 2 == 0 ? 0.2 : 0.8
            return WinkBeatObject(kind: .circle, time: 1 + Double(i) * 1.2, x: x, y: 0.5)
        }
        var p = play(objects)
        for i in 0..<3 { p.closure(WinkBeatClosure(side: .left, time: objects[i].time, aim: p.positions[i])) }
        XCTAssertEqual(p.combo, 3)
        XCTAssertEqual(p.score, 300 + (300 + 12) + (300 + 24))
        XCTAssertEqual(p.accuracy, 1)
        XCTAssertEqual(p.rank, .ss)
    }

    // MARK: - Eyes

    func testBlinksNeverPlayAndTheAimHoldsThroughThem() {
        var eyes = WinkBeatEyes()
        var closures: [WinkBeatEyes.Closure] = []
        var heldAims: [Vec2?] = []
        for f in 0..<120 {
            let t = Double(f) / 60
            let blinking = t >= 1.0 && t < 1.12
            // The tracked aim jumps while the lids are down.
            let raw = blinking ? Vec2(100, 300) : Vec2(100, 100)
            let out = eyes.update(time: t, aim: raw, left: blinking ? 0.9 : 0.1, right: blinking ? 0.9 : 0.1)
            closures += out.closures
            if t >= 1.0 && t < 1.2 { heldAims.append(out.aim) }
        }
        XCTAssertEqual(closures.count, 1)
        if case let .blink(onset, duration) = closures[0] {
            XCTAssertEqual(onset, 1.0, accuracy: 1e-9)
            XCTAssertEqual(duration, 0.1333, accuracy: 0.02)
        } else { XCTFail("expected an ordinary blink, got \(closures)") }
        XCTAssertNil(closures[0].forJudge)
        XCTAssertTrue(heldAims.allSatisfy { $0 == Vec2(100, 100) }, "aim held through the blink and the settle time")
    }

    func testAWinkIsJudgedWithTheAimFromBeforeTheLidCameDown() {
        var eyes = WinkBeatEyes()
        var wink: WinkBeatClosure?
        for f in 0..<90 {
            let t = Double(f) / 60
            let closed = t >= 1.0 && t < 1.13
            let raw = closed ? Vec2(100, 180) : Vec2(100, 100)
            for c in eyes.update(time: t, aim: raw, left: closed ? 0.9 : 0.1, right: closed ? 0.3 : 0.1).closures {
                wink = c.forJudge
            }
        }
        XCTAssertEqual(wink?.side, .left)
        XCTAssertEqual(wink?.time ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(wink?.aim, Vec2(100, 100))
    }

    func testLongBlinkIsSentOnceItHasLasted() {
        var eyes = WinkBeatEyes()
        var out: [WinkBeatEyes.Closure] = []
        for f in 0..<120 {
            let t = Double(f) / 60
            let closed = t >= 1.0 && t < 1.45
            out += eyes.update(time: t, aim: Vec2(50, 50), left: closed ? 0.9 : 0.1, right: closed ? 0.9 : 0.1).closures
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.forJudge, WinkBeatClosure(side: .both, time: 1.0, aim: Vec2(50, 50)))
    }

    // MARK: - Whole plays of the test level

    func testPerfectBotGetsSSOnEveryChart() throws {
        let map = try bundledMap()
        for d in WinkBeatDifficulty.allCases {
            var style = WinkBeatBot.Style()
            style.latencyJitterSec = 0; style.aimNoisePt = 0; style.blinkEverySec = 0
            let run = WinkBeatBot.run(WinkBeatPlay(map: map, difficulty: d, field: field), style: style)
            XCTAssertTrue(run.play.finished, "\(d)")
            XCTAssertEqual(run.play.count(.miss), 0, "\(d)")
            XCTAssertGreaterThanOrEqual(run.play.accuracy, 0.97, "\(d): \(WinkBeatGrade.allCases.map { run.play.count($0) })")
            XCTAssertEqual(run.play.maxCombo, map.chart(d).count, "\(d)")
        }
    }

    /// A realistic player: aim scatter, a calibration bias, late and uneven winks, natural blinks every few
    /// seconds, and the aim sliding 60 pt whenever a lid is down. Blinks must never play objects, and the level
    /// stays clearly winnable.
    func testRealisticBotWinsAndBlinksNeverHit() throws {
        let map = try bundledMap()
        for (d, minAccuracy) in [(WinkBeatDifficulty.easy, 0.8), (.normal, 0.75), (.hard, 0.7)] {
            var style = WinkBeatBot.Style()
            style.aimBias = Vec2(30, -25); style.aimNoisePt = 25; style.latencyJitterSec = 0.06; style.seed = 3
            let run = WinkBeatBot.run(WinkBeatPlay(map: map, difficulty: d, field: field, measuredErrorPt: 35), style: style)
            let p = run.play
            XCTAssertFalse(p.failed, "\(d)")
            XCTAssertGreaterThan(run.blinks, 8, "\(d): the bot blinked")
            print("WinkBeat realistic \(d): accuracy \(p.accuracy) rank \(p.rank) grades \(WinkBeatGrade.allCases.map { p.count($0) }) blinks \(run.blinks) offTarget \(p.offTarget) energy \(p.energy)")
            XCTAssertFalse(p.playedBy.contains(.both), "\(d): no blink played an object")
            XCTAssertGreaterThanOrEqual(p.accuracy, minAccuracy,
                                        "\(d): \(WinkBeatGrade.allCases.map { p.count($0) }) offTarget \(p.offTarget)")
        }
    }

    func testOnlyBlinkingPlaysNothing() throws {
        let map = try bundledMap()
        var style = WinkBeatBot.Style()
        style.blinksOnly = true; style.blinkEverySec = 1.5
        let p = WinkBeatBot.run(WinkBeatPlay(map: map, difficulty: .normal, field: field), style: style).play
        XCTAssertTrue(p.playedBy.allSatisfy { $0 == nil })
        // Nothing but misses, until the energy bar empties and the track fails.
        XCTAssertTrue(p.failed)
        for (i, o) in map.chart(.normal).enumerated() where o.needsWink {
            XCTAssertTrue(p.results[i] == nil || p.results[i] == .miss, "#\(i)")
        }
    }

    func testChildWithLongBlinksCanPlayEasy() throws {
        let map = try bundledMap()
        var style = WinkBeatBot.Style()
        style.longBlinks = true; style.aimNoisePt = 20
        let p = WinkBeatBot.run(WinkBeatPlay(map: map, difficulty: .easy, field: field, measuredErrorPt: 35), style: style).play
        XCTAssertGreaterThanOrEqual(p.accuracy, 0.8, "\(WinkBeatGrade.allCases.map { p.count($0) })")
        XCTAssertGreaterThan(p.longBlinks, 40)
    }
}
