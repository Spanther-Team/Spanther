import XCTest
@testable import GazeCore

/// The probe's scoring, fed by model children whose behaviour is known, so every number can be checked against
/// what the model did.
final class ProbeRunTests: XCTestCase {
    private let rules = ProbeProtocol.v1
    private let radius = 3.5

    private func form(_ seed: UInt64 = 0) throws -> ProbePlan { try XCTUnwrap(ProbePlan.make(seed: seed)) }

    private func newRun(_ plan: ProbePlan) -> ProbeRun {
        ProbeRun(plan: plan, radiusDeg: radius, screenHalfWidthDeg: 12, screenHalfHeightDeg: 5.5)
    }

    /// Runs the probe at `hz` frames a second up to `end`, with the gaze the model gives for each moment.
    private func play(_ plan: ProbePlan, hz: Double = 60, until end: Double = 90.5,
                      gaze: (Double) -> Vec2?) -> (run: ProbeRun, events: [ProbeRun.Event]) {
        var run = newRun(plan)
        var events: [ProbeRun.Event] = []
        for i in 0...Int((end * hz).rounded()) {
            let t = Double(i) / hz
            events += run.add(t: t, gaze: gaze(t))
        }
        return (run, events)
    }

    private func number(_ metrics: [String: Double], _ key: ProbeMetric, file: StaticString = #filePath,
                        line: UInt = #line) throws -> Double {
        try XCTUnwrap(metrics[key.rawValue], key.rawValue, file: file, line: line)
    }

    /// A child who looks at each target `reaction` seconds after it appears and stays there until the next one,
    /// follows the gliding target exactly, and starts each block from the centre.
    private func attentive(_ plan: ProbePlan, _ t: Double, reaction: Double = 0.3) -> Vec2 {
        if let place = plan.pursuitPosition(at: t) { return place }
        var place = Vec2(0, 0)
        let block: ProbePlan.Block = t < rules.pursuitStartSec ? .quiet : .distracted
        for target in plan.targets where target.block == block && target.onsetSec + reaction <= t {
            place = target.position
        }
        return place
    }

    /// The time of the first frame at or after `t`.
    private func frame(_ t: Double, hz: Double = 60) -> Double { (t * hz).rounded(.up) / hz }

    private func heldIndexes(_ events: [ProbeRun.Event]) -> [Int] {
        events.compactMap { if case .targetHeld(let i) = $0 { return i } else { return nil } }
    }

    private func expiredIndexes(_ events: [ProbeRun.Event]) -> [Int] {
        events.compactMap { if case .targetExpired(let i) = $0 { return i } else { return nil } }
    }

    // MARK: Whole probes

    func testAnAttentiveChildHoldsEveryTargetAndFollowsThePath() throws {
        let plan = try form()
        let (run, events) = play(plan) { self.attentive(plan, $0) }
        let m = run.metrics()
        XCTAssertTrue(run.finished)

        XCTAssertEqual(events.compactMap { if case .targetAppeared(let i) = $0 { return i } else { return nil } },
                       Array(0..<30))
        XCTAssertEqual(heldIndexes(events), Array(0..<30))
        XCTAssertEqual(expiredIndexes(events), [])
        XCTAssertEqual(events.compactMap { if case .distractorAppeared(let i) = $0 { return i } else { return nil } },
                       Array(0..<12))
        XCTAssertEqual(events.compactMap { if case .distractorGone(let i) = $0 { return i } else { return nil } },
                       Array(0..<12))

        XCTAssertEqual(try number(m, .holdShare), 1)
        XCTAssertEqual(try number(m, .holdShareQuiet), 1)
        XCTAssertEqual(try number(m, .holdShareDistracted), 1)
        XCTAssertEqual(try number(m, .anticipationShare), 0)
        // The look lands on the first frame after the reaction time: 300 ms and up to one frame more.
        let firstLook = try number(m, .firstLookMs)
        XCTAssertGreaterThanOrEqual(firstLook, 300 - 1e-6)
        XCTAssertLessThan(firstLook, 300 + 1000.0 / 60)
        XCTAssertLessThan(try number(m, .latencySdMs), 1000.0 / 60)
        XCTAssertLessThan(try number(m, .latencyIqrMs), 1000.0 / 60)
        for (i, record) in run.targets.enumerated() {
            let latency = try XCTUnwrap(record.latencySec, "target \(i)")
            XCTAssertEqual(latency, frame(plan.targets[i].onsetSec + 0.3) - plan.targets[i].onsetSec, accuracy: 1e-9)
            XCTAssertEqual(record.slips, 0)
        }

        // No distractor pulled the gaze. One that lit up where the gaze was still resting is not counted at all.
        var counted = 0
        for (j, d) in plan.distractors.enumerated() {
            let gaze = attentive(plan, frame(d.onsetSec))
            let home = plan.targets[d.targetIndex].position
            let resting = gaze.distance(to: d.position) <= radius && gaze.distance(to: d.position) < gaze.distance(to: home)
            XCTAssertEqual(run.distractors[j].scorable, !resting, "distractor \(j)")
            XCTAssertNil(run.distractors[j].pulledAtSec)
            if !resting { counted += 1 }
        }
        XCTAssertGreaterThanOrEqual(counted, 6)
        XCTAssertEqual(try number(m, .distractorEvents), Double(counted))
        XCTAssertEqual(try number(m, .distractorPullShare), 0)
        XCTAssertNil(m[ProbeMetric.distractorReturnMs.rawValue])

        XCTAssertEqual(try number(m, .pursuitOnShare), 1)
        XCTAssertEqual(try number(m, .pursuitGain), 1, accuracy: 1e-6)
        XCTAssertEqual(try number(m, .pursuitLagMs), 0, accuracy: 1e-3)

        XCTAssertEqual(try number(m, .lookAwaysPerMin), 0)
        XCTAssertEqual(try number(m, .awayShare), 0)
        XCTAssertEqual(try number(m, .validShare), 1)
        XCTAssertEqual(try number(m, .fps), 60, accuracy: 1e-6)
        XCTAssertEqual(try number(m, .radiusDeg), radius)
        // Every number has a name the chart knows.
        for key in m.keys { XCTAssertNotNil(ProbeMetric(rawValue: key), key) }
        for key in ProbeMetric.charted where key != .distractorReturnMs { XCTAssertNotNil(m[key.rawValue], key.rawValue) }
    }

    func testTheResultCarriesWhatRebuildsTheForm() throws {
        let plan = try form(2026)
        let (run, _) = play(plan) { self.attentive(plan, $0) }
        let result = run.result(qualityPassed: true)
        XCTAssertEqual(result.version, 1)
        XCTAssertEqual(result.generatorVersion, 1)
        XCTAssertEqual(result.seed, 2026)
        XCTAssertEqual(result.fingerprint, plan.fingerprint)
        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.qualityPassed)
        XCTAssertEqual(result.metrics, run.metrics())
        // The seed and the fingerprint survive the log's JSON, and the form built again from them is the same one.
        let back = try JSONDecoder().decode(ProbeResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(back, result)
        let rebuilt = try XCTUnwrap(ProbeProtocol.version(back.version).flatMap { ProbePlan.make(seed: back.seed, rules: $0) })
        XCTAssertEqual(rebuilt.fingerprint, back.fingerprint)
        XCTAssertEqual(rebuilt, plan)

        // A probe stopped half-way says so, and a frame that goes back in time changes nothing.
        var (half, _) = play(plan, until: 50) { self.attentive(plan, $0) }
        XCTAssertFalse(half.finished)
        XCTAssertFalse(half.result(qualityPassed: false).completed)
        XCTAssertFalse(half.result(qualityPassed: false).qualityPassed)
        let before = half.metrics()
        XCTAssertEqual(half.add(t: 20, gaze: Vec2(0, 0)), [])
        XCTAssertEqual(half.add(t: .nan, gaze: Vec2(0, 0)), [])
        XCTAssertEqual(half.metrics(), before)
    }

    func testNoGazeAtAllIsOneLongLookAway() throws {
        let plan = try form()
        let (run, events) = play(plan) { _ in nil }
        let m = run.metrics()
        XCTAssertEqual(heldIndexes(events), [])
        XCTAssertEqual(expiredIndexes(events), Array(0..<30))
        XCTAssertEqual(try number(m, .holdShare), 0)
        XCTAssertEqual(try number(m, .anticipationShare), 0)
        XCTAssertNil(m[ProbeMetric.firstLookMs.rawValue])
        XCTAssertNil(m[ProbeMetric.latencySdMs.rawValue])
        XCTAssertEqual(try number(m, .distractorEvents), 12)
        XCTAssertEqual(try number(m, .distractorPullShare), 0)
        XCTAssertEqual(try number(m, .pursuitOnShare), 0)
        XCTAssertNil(m[ProbeMetric.pursuitGain.rawValue])
        XCTAssertNil(m[ProbeMetric.pursuitLagMs.rawValue])
        XCTAssertEqual(try number(m, .lookAwaysPerMin), 60 / 90.5, accuracy: 1e-9)
        XCTAssertEqual(try number(m, .awayShare), 1, accuracy: 1e-9)
        XCTAssertEqual(try number(m, .validShare), 0)
    }

    // MARK: Looks and holds

    func testAGazeThatWaitsWhereTheTargetWillComeIsAnticipation() throws {
        let plan = try form()
        let (run, events) = play(plan) { t in
            var place = Vec2(0, 0)
            for target in plan.targets where target.onsetSec - 0.2 <= t { place = target.position }
            return place
        }
        let m = run.metrics()
        XCTAssertEqual(heldIndexes(events), Array(0..<30))
        XCTAssertEqual(try number(m, .anticipationShare), 1)
        XCTAssertEqual(try number(m, .holdShare), 1)
        // A look that was there before the target is not a reaction: it gives no reaction time.
        XCTAssertNil(m[ProbeMetric.firstLookMs.rawValue])
        XCTAssertNil(m[ProbeMetric.latencySdMs.rawValue])
        // The target is held before a late distractor lights up; such a distractor has nothing to pull from.
        for (j, d) in plan.distractors.enumerated() {
            let held = try XCTUnwrap(run.targets[d.targetIndex].heldAtSec)
            if frame(d.onsetSec) > held { XCTAssertFalse(run.distractors[j].scorable, "distractor \(j)") }
        }
    }

    func testABlinkOrAShortSlipDoesNotUndoAHoldAndALongSlipDoes() throws {
        let plan = try form()
        let target = plan.targets[0]
        XCTAssertEqual(target.onsetSec, 2.5, accuracy: 1e-12)
        let centre = Vec2(0, 0), off = target.position + Vec2(5, 0)
        XCTAssertGreaterThan(centre.distance(to: target.position), radius)
        // A hold ends on the frame that completes it, or on the next one where the frame times round that way.
        func assertHeld(_ record: ProbeRun.TargetRecord, at t: Double, line: UInt = #line) throws {
            let held = try XCTUnwrap(record.heldAtSec, line: line)
            XCTAssertGreaterThanOrEqual(held, t - 1e-9, line: line)
            XCTAssertLessThanOrEqual(held, t + 1.0 / 60 + 1e-9, line: line)
        }

        // On the target 0.3 s after it appears; 0.2 s into the look the eyes close for 0.2 s.
        let blink = play(plan, until: 5) { t in
            t < 2.8 ? centre : (t >= 3.0 && t < 3.2 ? nil : target.position)
        }.run.targets[0]
        XCTAssertEqual(try XCTUnwrap(blink.latencySec), 0.3, accuracy: 1e-9)
        try assertHeld(blink, at: 3.3)
        XCTAssertEqual(blink.slips, 0)

        // The gaze slips out of the zone for 0.1 s: noise, not a new look.
        let slip = play(plan, until: 5) { t in
            t < 2.8 ? centre : (t >= 3.0 && t < 3.1 ? off : target.position)
        }.run.targets[0]
        try assertHeld(slip, at: 3.3)
        XCTAssertEqual(slip.slips, 0)

        // Out for 0.3 s: the hold starts again when the gaze is back, and the time of the first look stays.
        let long = play(plan, until: 5) { t in
            t < 2.8 ? centre : (t >= 3.0 && t < 3.3 ? off : target.position)
        }
        XCTAssertEqual(try XCTUnwrap(long.run.targets[0].latencySec), 0.3, accuracy: 1e-9)
        try assertHeld(long.run.targets[0], at: 3.8)
        XCTAssertEqual(long.run.targets[0].slips, 1)
        XCTAssertEqual(heldIndexes(long.events), [0])

        // A blink longer than a blink is a new look too, and with it the time runs out.
        let lost = play(plan, until: 5) { t in
            t < 2.8 ? centre : (t >= 3.0 && t < 3.5 ? nil : target.position)
        }
        XCTAssertNil(lost.run.targets[0].heldAtSec)
        XCTAssertTrue(lost.run.targets[0].expired)
        XCTAssertEqual(lost.run.targets[0].slips, 1)
        XCTAssertEqual(expiredIndexes(lost.events), [0])
    }

    func testTheScreenIsToldWhatToDraw() throws {
        let plan = try form()
        let target = plan.targets[0]
        var run = newRun(plan)
        var appearedAt: Double?
        for i in 0...300 {
            let t = Double(i) / 60
            let events = run.add(t: t, gaze: t < 2.8 ? Vec2(0, 0) : target.position)
            if events.contains(.targetAppeared(0)) { appearedAt = t }
            switch i {
            case 140:   // 2.33 s: the lead-in has ended, the first target has not come yet
                XCTAssertNil(run.visibleTarget)
            case 160:   // 2.67 s: on the screen, not looked at
                XCTAssertEqual(run.visibleTarget, 0)
                XCTAssertEqual(run.holdProgress, 0)
            case 183:   // 3.05 s: half of the hold
                XCTAssertEqual(run.visibleTarget, 0)
                XCTAssertEqual(run.holdProgress, 0.5, accuracy: 0.02)
            case 200:   // held at 3.3 s: gone, the next one not yet due
                XCTAssertNil(run.visibleTarget)
                XCTAssertEqual(run.holdProgress, 0)
            default:
                break
            }
            XCTAssertNil(run.visibleDistractor)
        }
        XCTAssertEqual(try XCTUnwrap(appearedAt), 2.5, accuracy: 1e-12)
        XCTAssertFalse(run.finished)
    }

    // MARK: Distractors

    /// Every second distractor draws the gaze 0.2 s after it lights up, for 0.3 s.
    func testPullsAndReturnsAreTimed() throws {
        let plan = try form()
        let (run, _) = play(plan) { t in
            for (j, d) in plan.distractors.enumerated() where j % 2 == 0 && t >= d.onsetSec + 0.2 && t < d.onsetSec + 0.5 {
                return d.position
            }
            return self.attentive(plan, t)
        }
        let m = run.metrics()
        var counted = 0, pulled = 0
        for (j, d) in plan.distractors.enumerated() {
            let record = run.distractors[j]
            if record.scorable { counted += 1 }
            guard record.scorable, j % 2 == 0 else {
                XCTAssertNil(record.pulledAtSec, "distractor \(j)")
                continue
            }
            pulled += 1
            let at = try XCTUnwrap(record.pulledAtSec, "distractor \(j)")
            XCTAssertEqual(at, frame(d.onsetSec + 0.2), accuracy: 1e-9, "distractor \(j)")
            let back = try XCTUnwrap(record.returnSec, "distractor \(j)")
            XCTAssertEqual(back, frame(d.onsetSec + 0.5) - at, accuracy: 1e-9, "distractor \(j)")
            XCTAssertEqual(back, 0.3, accuracy: 0.02)

            // The look away costs the hold its start. Where enough of the target's time was left, it is held still.
            let delay = d.onsetSec - plan.targets[d.targetIndex].onsetSec
            let target = run.targets[d.targetIndex]
            if delay < 0.4 - 0.04 { XCTAssertNotNil(target.heldAtSec, "target \(d.targetIndex)") }
            if delay > 0.4 + 0.04 {
                XCTAssertNil(target.heldAtSec, "target \(d.targetIndex)")
                XCTAssertTrue(target.expired)
            }
        }
        XCTAssertGreaterThanOrEqual(pulled, 3)
        XCTAssertEqual(try number(m, .distractorEvents), Double(counted))
        XCTAssertEqual(try number(m, .distractorPullShare), Double(pulled) / Double(counted), accuracy: 1e-12)
        XCTAssertEqual(try number(m, .distractorReturnMs), 300, accuracy: 20)
        // The quiet block has no distractors and loses nothing.
        XCTAssertEqual(try number(m, .holdShareQuiet), 1)
    }

    /// A slow child still looks at the place of the target before when a distractor lights up in that same zone.
    /// Nothing pulled the gaze there, so that distractor is not counted.
    func testADistractorWhereTheGazeAlreadyRestsIsNotCounted() throws {
        var checked = 0
        for seed in UInt64(0)..<40 where checked < 3 {
            let plan = try form(seed)
            let same = plan.distractors.indices.filter {
                $0 > 0 && plan.distractors[$0].zone == plan.targets[plan.distractors[$0].targetIndex - 1].zone
            }
            guard let j = same.first else { continue }
            checked += 1
            let (run, events) = play(plan) { self.attentive(plan, $0, reaction: 0.6) }
            let m = run.metrics()
            XCTAssertTrue(run.distractors[j].appeared)
            XCTAssertFalse(run.distractors[j].scorable, "seed \(seed), distractor \(j)")
            XCTAssertNil(run.distractors[j].pulledAtSec)
            XCTAssertLessThan(try number(m, .distractorEvents), 12)
            XCTAssertEqual(try number(m, .distractorPullShare), 0)
            XCTAssertEqual(heldIndexes(events), Array(0..<30))
        }
        XCTAssertEqual(checked, 3)
    }

    /// A glance at the distractor shorter than the slip the hold forgives: the pull is counted, the return is
    /// timed, and the hold is still completed.
    func testAQuickGlanceIsAPullEvenWhenTheHoldSurvives() throws {
        let plan = try form()
        let (calm, _) = play(plan) { self.attentive(plan, $0) }
        // A counted distractor that lights up while the hold is under way.
        let j = try XCTUnwrap(plan.distractors.indices.first {
            let delay = plan.distractors[$0].onsetSec - plan.targets[plan.distractors[$0].targetIndex].onsetSec
            return calm.distractors[$0].scorable && delay > 0.34 && delay < 0.5
        })
        let d = plan.distractors[j]
        let from = frame(d.onsetSec + 0.1), to = from + 6.0 / 60
        let (run, _) = play(plan) { t in
            t >= from - 1e-9 && t < to - 1e-9 ? d.position : self.attentive(plan, t)
        }
        let record = run.distractors[j]
        XCTAssertEqual(try XCTUnwrap(record.pulledAtSec), from, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(record.returnSec), 0.1, accuracy: 1e-9)
        XCTAssertNotNil(run.targets[d.targetIndex].heldAtSec)
        XCTAssertEqual(run.targets[d.targetIndex].slips, 0)
        let m = run.metrics()
        let pulls = try number(m, .distractorPullShare) * number(m, .distractorEvents)
        XCTAssertEqual(pulls, 1, accuracy: 1e-9)
    }

    // MARK: Pursuit

    func testPursuitGainAndLagAreRecovered() throws {
        let plan = try form()
        let from = rules.pursuitScoredFromSec, to = rules.pursuitScoredToSec
        let (run, _) = play(plan) { t in
            guard t >= from, t <= to else { return self.attentive(plan, t) }
            return plan.pathOffset(at: t - from - 0.2) * 0.8
        }
        let m = run.metrics()
        XCTAssertEqual(try number(m, .pursuitGain), 0.8, accuracy: 1e-6)
        XCTAssertEqual(try number(m, .pursuitLagMs), 200, accuracy: 1e-3)
        XCTAssertGreaterThan(try number(m, .pursuitOnShare), 0.9)

        // A gaze that runs ahead of the target has a lag below zero.
        let (ahead, _) = play(plan) { t in
            guard t >= from, t <= to else { return self.attentive(plan, t) }
            return plan.pathOffset(at: t - from + 0.05)
        }
        XCTAssertEqual(try number(ahead.metrics(), .pursuitGain), 1, accuracy: 1e-6)
        XCTAssertEqual(try number(ahead.metrics(), .pursuitLagMs), -50, accuracy: 1e-3)
    }

    func testPursuitNumbersSurviveNoiseBlinksAndAGlanceAway() throws {
        let plan = try form(7)
        var noise = SeededRandom(seed: 11)
        let from = rules.pursuitScoredFromSec, to = rules.pursuitScoredToSec
        let (run, _) = play(plan) { t in
            guard t >= from, t <= to else { return self.attentive(plan, t) }
            let tau = t - from
            let shake = Vec2(noise.uniform(-1, 1), noise.uniform(-1, 1))
            if tau.truncatingRemainder(dividingBy: 6) >= 5.7 { return nil }             // a blink every six seconds
            if tau >= 10, tau < 12 { return plan.pathOffset(at: tau) + Vec2(8, 0) }    // two seconds on something else
            return plan.pathOffset(at: tau - 0.12) * 0.9 + shake
        }
        let m = run.metrics()
        XCTAssertEqual(try number(m, .pursuitGain), 0.9, accuracy: 0.03)
        XCTAssertEqual(try number(m, .pursuitLagMs), 120, accuracy: 15)
        // Two seconds away and three blinks outside them: about 2.9 s of the 24 s cannot be on the target.
        let on = try number(m, .pursuitOnShare)
        XCTAssertGreaterThan(on, 0.8)
        XCTAssertLessThan(on, 0.885)
    }

    func testAGazeThatDoesNotFollowHasNoGain() throws {
        let plan = try form()
        let (run, _) = play(plan) { t in self.rules.stage(at: t) == .pursuit ? Vec2(0, 0) : self.attentive(plan, t) }
        let m = run.metrics()
        // Staring at the centre is on the target now and then, and makes none of its motion.
        XCTAssertLessThan(try number(m, .pursuitOnShare), 0.8)
        if let gain = m[ProbeMetric.pursuitGain.rawValue] { XCTAssertEqual(gain, 0, accuracy: 1e-6) }
        XCTAssertNil(m[ProbeMetric.pursuitLagMs.rawValue])
    }

    // MARK: Look-aways

    func testLookAwaysAreCountedAndBlinksAreNot() throws {
        let plan = try form()
        let (run, _) = play(plan, until: 12) { t in
            if t >= 3.0, t < 4.2 { return nil }               // the face is lost for 1.2 s
            if t >= 6.0, t < 6.4 { return Vec2(20, 0) }       // the gaze is off the screen for 0.4 s
            if t >= 8.0, t < 8.2 { return nil }               // a blink
            if t >= 9.0, t < 9.2 { return Vec2(20, 0) }       // off the screen too briefly to tell
            if t >= 10.0, t < 10.5 { return Vec2(14, 0) }     // on the bezel, inside the margin
            return Vec2(0, 0)
        }
        let m = run.metrics()
        XCTAssertEqual(try number(m, .lookAwaysPerMin), 2 * 60 / 12.0, accuracy: 1e-9)
        XCTAssertEqual(try number(m, .awayShare), (1.2 + 0.4) / 12, accuracy: 1e-9)
        XCTAssertEqual(try number(m, .validShare), Double(721 - 72 - 12) / 721, accuracy: 1e-12)
        XCTAssertEqual(try number(m, .fps), 60, accuracy: 1e-6)

        // Eyes closed and then seen off the screen: one glance, timed from its start.
        let (mixed, _) = play(plan, until: 6) { t in
            if t >= 2.0, t < 2.2 { return nil }
            if t >= 2.2, t < 2.4 { return Vec2(0, -12) }
            return Vec2(0, 0)
        }
        XCTAssertEqual(try number(mixed.metrics(), .lookAwaysPerMin), 60 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(try number(mixed.metrics(), .awayShare), 0.4 / 6, accuracy: 1e-9)

        // A glance still going on when the probe is stopped is counted up to the stop.
        let (open, _) = play(plan, until: 6) { t in t >= 5.0 ? nil : Vec2(0, 0) }
        XCTAssertEqual(try number(open.metrics(), .lookAwaysPerMin), 60 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(try number(open.metrics(), .awayShare), 1.0 / 6, accuracy: 1e-9)
    }

    // MARK: Quality

    func testTheQualityGate() throws {
        let good = Conditions(calibrationErrorCm: 0.9, distanceCm: 32)
        let fine: [String: Double] = [ProbeMetric.validShare.rawValue: 0.95, ProbeMetric.fps.rawValue: 60]
        XCTAssertEqual(ProbeQuality.issues(conditions: good, metrics: fine, completed: true), [])

        XCTAssertEqual(ProbeQuality.issues(conditions: Conditions(calibrationErrorCm: 1.6, distanceCm: 32), metrics: fine,
                                           completed: true), [.calibration])
        XCTAssertEqual(ProbeQuality.issues(conditions: Conditions(distanceCm: 32), metrics: fine, completed: true),
                       [.calibration])
        // An adult is held to the accuracy the tracker is built to.
        XCTAssertEqual(ProbeQuality.issues(conditions: Conditions(calibrationErrorCm: 1.2, distanceCm: 32), metrics: fine,
                                           completed: true, maxErrorCm: 1.0), [.calibration])
        XCTAssertEqual(ProbeQuality.issues(conditions: Conditions(calibrationErrorCm: 0.9, distanceCm: 45), metrics: fine,
                                           completed: true), [.distance])
        XCTAssertEqual(ProbeQuality.issues(conditions: Conditions(calibrationErrorCm: 0.9), metrics: fine, completed: true),
                       [.distance])
        XCTAssertEqual(ProbeQuality.issues(conditions: good, metrics: [ProbeMetric.validShare.rawValue: 0.6,
                                                                       ProbeMetric.fps.rawValue: 60], completed: true),
                       [.tracking])
        XCTAssertEqual(ProbeQuality.issues(conditions: good, metrics: [ProbeMetric.validShare.rawValue: 0.95,
                                                                       ProbeMetric.fps.rawValue: 30], completed: true),
                       [.frameRate])
        XCTAssertEqual(ProbeQuality.issues(conditions: good, metrics: fine, completed: false), [.incomplete])
        // Without the probe's own frame rate the session's is used.
        let noFps: [String: Double] = [ProbeMetric.validShare.rawValue: 0.95]
        XCTAssertEqual(ProbeQuality.issues(conditions: good, metrics: noFps, completed: true), [.frameRate])
        XCTAssertEqual(ProbeQuality.issues(conditions: Conditions(calibrationErrorCm: 0.9, distanceCm: 32, trackingFps: 58),
                                           metrics: noFps, completed: true), [])
        XCTAssertEqual(ProbeQuality.issues(conditions: Conditions(), metrics: [:], completed: false),
                       ProbeQuality.Issue.allCases)

        // A probe run at 30 frames a second (night vision) is kept off the chart by its own numbers.
        let plan = try form()
        let (slow, _) = play(plan, hz: 30, until: 91) { self.attentive(plan, $0) }
        XCTAssertEqual(try number(slow.metrics(), .fps), 30, accuracy: 1e-6)
        XCTAssertEqual(ProbeQuality.issues(conditions: good, metrics: slow.metrics(), completed: slow.finished), [.frameRate])
        let (full, _) = play(plan) { self.attentive(plan, $0) }
        XCTAssertEqual(ProbeQuality.issues(conditions: good, metrics: full.metrics(), completed: full.finished), [])
    }
}
