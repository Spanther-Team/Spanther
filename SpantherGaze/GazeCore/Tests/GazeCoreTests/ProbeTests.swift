import XCTest
@testable import GazeCore

final class ProbeTests: XCTestCase {
    private let rules = ProbeProtocol.v1

    private func check(_ plan: ProbePlan, _ name: String) throws -> Double {
        try XCTUnwrap(plan.difficulty.first { $0.name == name }, name).value
    }

    /// The forms the difficulty targets were calibrated with, from the reference prototype. Generator version 1
    /// must give exactly these for as long as a course runs on it: a change here is a new generator version.
    func testGeneratorVersionOneIsFrozen() throws {
        let plan = try XCTUnwrap(ProbePlan.make(seed: 0))
        XCTAssertEqual(plan.zoneSignature, "315024510423435120|051234320451")
        XCTAssertEqual(plan.draws, 577 + 13 + 156)
        XCTAssertEqual(plan.targets[0].onsetSec, 2.5, accuracy: 1e-9)
        XCTAssertEqual(plan.targets[0].position.x, -7.114038054908, accuracy: 1e-9)
        XCTAssertEqual(plan.targets[0].position.y, 1.684990603244, accuracy: 1e-9)
        XCTAssertEqual(plan.targets[17].onsetSec, 36.395989542979, accuracy: 1e-9)
        XCTAssertEqual(plan.targets[17].position.x, -7.359910845474, accuracy: 1e-9)
        XCTAssertEqual(plan.targets[17].position.y, -1.769634272100, accuracy: 1e-9)
        XCTAssertEqual(plan.targets[29].onsetSec, 87.909958786295, accuracy: 1e-9)
        XCTAssertEqual(plan.distractors[0].zone, 2)
        XCTAssertEqual(plan.distractors[0].onsetSec, 66.401845006848, accuracy: 1e-9)
        XCTAssertEqual(plan.distractors[0].position.x, 6.334820650261, accuracy: 1e-9)
        XCTAssertEqual(plan.distractors[0].position.y, -2.369212004282, accuracy: 1e-9)
        let phases = [5.451602318332, 0.868983258569, 5.098705477277, 0.753364412561, 1.465005931225, 5.461724582866,
                      6.260040122487]
        for (got, want) in zip(plan.xPhases + plan.yPhases, phases) { XCTAssertEqual(got, want, accuracy: 1e-9) }
        let reference: [(String, Double)] = [
            ("quiet.jumpMeanDeg", 9.517222774845), ("quiet.jumpSDDeg", 3.073539211677),
            ("quiet.gapMeanSec", 0.593881737822), ("quiet.gapSDSec", 0.201247020027),
            ("distracted.jumpMeanDeg", 9.850603974582), ("distracted.jumpSDDeg", 3.255784943144),
            ("distracted.gapMeanSec", 0.591814435118), ("distracted.gapSDSec", 0.195739554680),
            ("distractor.delayMeanSec", 0.348637487224), ("distractor.eccentricityMeanDeg", 10.089252057593),
            ("path.speedMeanDegPerSec", 3.720848272507), ("path.speedPeakDegPerSec", 9.800280410032),
            ("path.extrapolationErrorDeg", 0.143166117599), ("path.turningRadPerDeg", 0.541792642795),
            ("path.reachXShare", 0.878992240791), ("path.reachYShare", 0.951043261684),
        ]
        for (name, want) in reference { XCTAssertEqual(try check(plan, name), want, accuracy: 1e-9, name) }
        let mid = try XCTUnwrap(plan.pursuitPosition(at: 50.25))
        XCTAssertEqual(mid.x, 5.549622002858, accuracy: 1e-9)
        XCTAssertEqual(mid.y, 0.595404729581, accuracy: 1e-9)
        let rampIn = try XCTUnwrap(plan.pursuitPosition(at: 39.0))
        XCTAssertEqual(rampIn.x, -1.345874488967, accuracy: 1e-9)
        XCTAssertEqual(rampIn.y, 0.110954640219, accuracy: 1e-9)

        let seven = try XCTUnwrap(ProbePlan.make(seed: 7))
        XCTAssertEqual(seven.zoneSignature, "245310240531023451|512340124053")
        XCTAssertEqual(seven.draws, 435 + 6 + 24)
        XCTAssertEqual(seven.targets[17].onsetSec, 36.437548929603, accuracy: 1e-9)
        let other = try XCTUnwrap(ProbePlan.make(seed: 2026))
        XCTAssertEqual(other.zoneSignature, "053124320154045123|243105315402")
        XCTAssertEqual(other.draws, 70 + 49 + 162)
        XCTAssertEqual(other.targets[29].onsetSec, 88.296323681668, accuracy: 1e-9)
    }

    func testProtocolTimelineAndConstants() {
        XCTAssertEqual(rules.stage(at: 0), .leadIn)
        XCTAssertEqual(rules.stage(at: 2), .quiet)
        XCTAssertEqual(rules.stage(at: 38.5), .pursuit)
        XCTAssertEqual(rules.stage(at: 65.5), .distracted)
        XCTAssertEqual(rules.stage(at: 90), .done)
        XCTAssertEqual(rules.pursuitScoredFromSec, 40, accuracy: 1e-12)
        XCTAssertEqual(rules.pursuitScoredToSec, 64, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(rules.pursuitScoredToSec + rules.pursuitRampOutSec, rules.pursuitEndSec)
        XCTAssertEqual(rules.targetCount, 30)
        XCTAssertEqual(rules.gapMoments.mean, 0.6003157526584706, accuracy: 1e-12)
        XCTAssertEqual(rules.gapMoments.sd, 0.19442187459980778, accuracy: 1e-9)
        XCTAssertEqual(rules.pathRMS.speed, 4.2979, accuracy: 1e-4)
        // The longest a block can run (every pause at the top of its tolerance) still ends inside the block.
        let longest = { (count: Int) in
            self.rules.firstOnsetSec + Double(count) * self.rules.targetLifeSec
                + Double(count - 1) * self.rules.gapMoments.mean * (1 + self.rules.tolerance)
        }
        XCTAssertLessThanOrEqual(rules.quietStartSec + longest(rules.quietCount), rules.pursuitStartSec)
        XCTAssertLessThanOrEqual(rules.distractedStartSec + longest(rules.distractedCount), rules.durationSec)
        // The whole path stays inside the field, and the field holds every target.
        XCTAssertLessThanOrEqual(rules.xAmplitudesDeg.reduce(0, +), rules.fieldHalfWidthDeg)
        XCTAssertLessThanOrEqual(rules.yAmplitudesDeg.reduce(0, +), rules.fieldHalfHeightDeg)
        XCTAssertLessThanOrEqual((rules.columnsDeg.max() ?? 0) + rules.jitterXDeg, rules.fieldHalfWidthDeg)
        XCTAssertLessThanOrEqual((rules.rowsDeg.max() ?? 0) + rules.jitterYDeg, rules.fieldHalfHeightDeg)
        // The largest zone is smaller than the shortest jump, so the gaze must always travel to a new target.
        XCTAssertLessThan(rules.radiusMaxDeg, rules.columnsDeg[1] - rules.columnsDeg[0] - 2 * rules.jitterXDeg)
        XCTAssertEqual(rules.hitRadiusDeg(calibrationErrorDeg: nil), 3.0)
        XCTAssertEqual(rules.hitRadiusDeg(calibrationErrorDeg: 1.5), 3.5)
        XCTAssertEqual(rules.hitRadiusDeg(calibrationErrorDeg: 9), 4.2)
        XCTAssertNil(ProbeProtocol.version(99))
        XCTAssertEqual(ProbeProtocol.version(1), rules)
    }

    /// A thousand sessions: every form passes every difficulty check, no two show their targets in the same order,
    /// and each one keeps the rules that make it a fair measurement.
    func testAThousandFormsAllPassTheDifficultyCheck() throws {
        var signatures = Set<String>()
        var mostDraws = 0
        for seed: UInt64 in 0..<1000 {
            let plan = try XCTUnwrap(ProbePlan.make(seed: seed), "seed \(seed)")
            XCTAssertLessThanOrEqual(plan.worstDeviation, rules.tolerance + 1e-12, "seed \(seed)")
            mostDraws = max(mostDraws, plan.draws)
            signatures.insert(plan.zoneSignature)
            try assertShape(plan, seed)
        }
        XCTAssertEqual(signatures.count, 1000, "no two forms show their targets in the same order")
        XCTAssertLessThan(mostDraws, rules.maxDraws / 10, "the draw limit is far from being reached")
    }

    private func assertShape(_ plan: ProbePlan, _ seed: UInt64) throws {
        let tag = "seed \(seed)"
        XCTAssertEqual(plan.targets.count, rules.targetCount, tag)
        XCTAssertEqual(plan.distractors.count, rules.distractedCount, tag)
        for block in [ProbePlan.Block.quiet, .distracted] {
            let targets = plan.targets.filter { $0.block == block }
            let start = block == .quiet ? rules.quietStartSec : rules.distractedStartSec
            let end = block == .quiet ? rules.pursuitStartSec : rules.durationSec
            XCTAssertEqual(targets.count, block == .quiet ? rules.quietCount : rules.distractedCount, tag)
            XCTAssertEqual(targets[0].onsetSec, start + rules.firstOnsetSec, accuracy: 1e-9, tag)
            XCTAssertNotEqual(targets[0].zone % 3, 1, "\(tag): the first target is away from the centre")
            XCTAssertLessThanOrEqual(targets[targets.count - 1].onsetSec + rules.targetLifeSec, end, tag)
            var visits = [Int](repeating: 0, count: 6)
            for (i, t) in targets.enumerated() {
                visits[t.zone] += 1
                XCTAssertLessThanOrEqual(abs(t.position.x - rules.columnsDeg[t.zone % 3]), rules.jitterXDeg, tag)
                XCTAssertLessThanOrEqual(abs(t.position.y - rules.rowsDeg[t.zone / 3]), rules.jitterYDeg, tag)
                guard i > 0 else { continue }
                let before = targets[i - 1]
                XCTAssertNotEqual(t.zone % 3, before.zone % 3, "\(tag): two targets in a row share a column")
                let pause = t.onsetSec - before.onsetSec - rules.targetLifeSec
                XCTAssertGreaterThanOrEqual(pause, rules.gapMinSec - 1e-9, tag)
                XCTAssertLessThanOrEqual(pause, rules.gapMaxSec + 1e-9, tag)
                XCTAssertEqual(t.jumpDeg, t.position.distance(to: before.position), accuracy: 1e-9, tag)
            }
            XCTAssertEqual(visits, [Int](repeating: targets.count / 6, count: 6), "\(tag): every zone equally often")
        }
        for d in plan.distractors {
            let target = plan.targets[d.targetIndex]
            XCTAssertEqual(target.block, .distracted, tag)
            XCTAssertNotEqual(d.zone % 3, target.zone % 3, "\(tag): a distractor sits in another column")
            let delay = d.onsetSec - target.onsetSec
            XCTAssertGreaterThanOrEqual(delay, rules.distractorDelayMinSec - 1e-9, tag)
            XCTAssertLessThanOrEqual(delay, rules.distractorDelayMaxSec + 1e-9, tag)
            XCTAssertEqual(d.eccentricityDeg, d.position.distance(to: target.position), accuracy: 1e-9, tag)
        }
        XCTAssertEqual(Set(plan.distractors.map(\.targetIndex)).count, rules.distractedCount, tag)

        // The gliding target leaves the centre at rest, returns to it, and never leaves the field.
        let reachX = rules.xAmplitudesDeg.reduce(0, +), reachY = rules.yAmplitudesDeg.reduce(0, +)
        XCTAssertNil(plan.pursuitPosition(at: rules.pursuitStartSec - 0.01), tag)
        XCTAssertNil(plan.pursuitPosition(at: rules.pursuitEndSec), tag)
        var t = rules.pursuitStartSec
        var last = try XCTUnwrap(plan.pursuitPosition(at: t), tag)
        XCTAssertEqual(last.length, 0, accuracy: 1e-12, tag)
        while t < rules.pursuitEndSec - 1.0 / 30 {
            t += 1.0 / 30
            let p = try XCTUnwrap(plan.pursuitPosition(at: t), tag)
            XCTAssertLessThanOrEqual(abs(p.x), reachX + 1e-9, tag)
            XCTAssertLessThanOrEqual(abs(p.y), reachY + 1e-9, tag)
            XCTAssertLessThan(p.distance(to: last), 0.6, "\(tag): the target never jumps")
            last = p
        }
        XCTAssertEqual(last.length, 0, accuracy: 1e-9, tag)
    }

    func testTheSameSeedGivesTheSameFormAndAnotherSeedAnother() throws {
        let a = try XCTUnwrap(ProbePlan.make(seed: 42)), again = try XCTUnwrap(ProbePlan.make(seed: 42))
        let b = try XCTUnwrap(ProbePlan.make(seed: 43))
        XCTAssertEqual(a, again)
        XCTAssertEqual(a.fingerprint, again.fingerprint)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.zoneSignature, b.zoneSignature)
        XCTAssertLessThanOrEqual(a.fingerprint, ProbePlan.seedMask)
        // A new session avoids the orders this child has already seen.
        let next = try XCTUnwrap(ProbePlan.fresh(from: 42, avoiding: [a.zoneSignature]))
        XCTAssertEqual(next.seed, 43)
        XCTAssertEqual(try XCTUnwrap(ProbePlan.fresh(from: 42)).seed, 42)
        // A protocol no form can satisfy gives none instead of hanging.
        var impossible = rules
        impossible.jumpMeanDeg = 40
        impossible.maxDraws = 2000
        XCTAssertNil(ProbePlan.make(seed: 1, rules: impossible))
    }

    /// Speed and acceleration over the window come from the amplitudes and the cycle counts alone, so every form has
    /// the same ones; and the path's mean place is the centre.
    func testEveryPathHasTheSameSpeedAndAcceleration() throws {
        let rms = rules.pathRMS
        for seed: UInt64 in [3, 99, 512, 77_777] {
            let plan = try XCTUnwrap(ProbePlan.make(seed: seed))
            XCTAssertEqual(try check(plan, "path.speedRMSDegPerSec"), rms.speed, accuracy: 1e-9)
            XCTAssertEqual(try check(plan, "path.accelerationRMSDegPerSec2"), rms.acceleration, accuracy: 1e-9)
            var sum = Vec2(0, 0)
            let n = 2400
            for i in 0..<n { sum = sum + plan.pathOffset(at: rules.pursuitWindowSec * Double(i) / Double(n)) }
            XCTAssertEqual(sum.x / Double(n), 0, accuracy: 1e-9)
            XCTAssertEqual(sum.y / Double(n), 0, accuracy: 1e-9)
            // The path closes after one window and does not repeat inside it.
            XCTAssertEqual(plan.pathOffset(at: 0).distance(to: plan.pathOffset(at: rules.pursuitWindowSec)), 0, accuracy: 1e-9)
            let half = plan.pathOffset(at: rules.pursuitWindowSec / 2)
            XCTAssertGreaterThan(half.distance(to: plan.pathOffset(at: 0)) + (half + plan.pathOffset(at: 0)).length, 0.1)
        }
    }

    /// Two sessions never glide along the same path: the discrete Fréchet distance (the shortest leash that lets
    /// one walker follow each path, at any pace) between any two of forty paths stays above 1.5 degrees.
    func testPathsOfDifferentSeedsStayApart() throws {
        let hz = 4.0
        let n = Int(rules.pursuitWindowSec * hz)
        var curves: [[Vec2]] = []
        for seed: UInt64 in 0..<40 {
            let plan = try XCTUnwrap(ProbePlan.make(seed: seed))
            curves.append((0..<n).map { plan.pathOffset(at: Double($0) / hz) })
        }
        var nearest = Double.infinity
        for i in 0..<curves.count {
            for j in (i + 1)..<curves.count { nearest = min(nearest, frechet(curves[i], curves[j])) }
        }
        XCTAssertGreaterThan(nearest, 1.5)
    }

    private func frechet(_ p: [Vec2], _ q: [Vec2]) -> Double {
        var before = [Double](repeating: 0, count: q.count)
        for i in 0..<p.count {
            var row = [Double](repeating: 0, count: q.count)
            for j in 0..<q.count {
                let d = p[i].distance(to: q[j])
                if i == 0 && j == 0 {
                    row[j] = d
                } else if i == 0 {
                    row[j] = max(row[j - 1], d)
                } else if j == 0 {
                    row[j] = max(before[0], d)
                } else {
                    row[j] = max(min(before[j], before[j - 1], row[j - 1]), d)
                }
            }
            before = row
        }
        return before[q.count - 1]
    }

    func testFieldMappingTurnsDegreesIntoScreenPointsAndBack() {
        // An iPhone 13 held sideways, 30 cm away.
        let near = FieldMapping(size: Vec2(844, 390), ptPerCm: 60.4, distanceCm: 30,
                                fieldHalfWidthDeg: rules.fieldHalfWidthDeg, fieldHalfHeightDeg: rules.fieldHalfHeightDeg)
        XCTAssertEqual(near.fit, 1)
        XCTAssertEqual(near.screen(fromField: Vec2(0, 0)), Vec2(422, 195))
        let right = near.screen(fromField: Vec2(7, 0))
        XCTAssertEqual(right.x, 422 + 60.4 * 30 * tan(7 * Double.pi / 180), accuracy: 1e-9)
        XCTAssertEqual(right.y, 195, accuracy: 1e-9)
        XCTAssertGreaterThan(near.screen(fromField: Vec2(0, 2)).y, 195, "y grows downward")
        let back = near.field(fromScreen: near.screen(fromField: Vec2(-6.3, 2.4)))
        XCTAssertEqual(back.x, -6.3, accuracy: 1e-9)
        XCTAssertEqual(back.y, 2.4, accuracy: 1e-9)
        XCTAssertEqual(near.length(fromDeg: 1), 60.4 * 30 * tan(Double.pi / 180), accuracy: 1e-9)
        XCTAssertEqual(near.screenHalfDeg.x, atan(422 / (60.4 * 30)) * 180 / Double.pi, accuracy: 1e-9)

        // The same phone at 40 cm still shows the whole field: the same angles take more of the screen.
        let far = FieldMapping(size: Vec2(844, 390), ptPerCm: 60.4, distanceCm: 40,
                               fieldHalfWidthDeg: rules.fieldHalfWidthDeg, fieldHalfHeightDeg: rules.fieldHalfHeightDeg)
        XCTAssertEqual(far.fit, 1)
        XCTAssertGreaterThan(far.screen(fromField: Vec2(7, 0)).x, right.x)

        // A small phone held far away: the field shrinks to fit, and the mapping says by how much.
        let small = FieldMapping(size: Vec2(667, 375), ptPerCm: 64.1, distanceCm: 40,
                                 fieldHalfWidthDeg: rules.fieldHalfWidthDeg, fieldHalfHeightDeg: rules.fieldHalfHeightDeg)
        XCTAssertLessThan(small.fit, 1)
        let corner = small.screen(fromField: Vec2(rules.fieldHalfWidthDeg, rules.fieldHalfHeightDeg))
        XCTAssertLessThanOrEqual(corner.x, 667 - 30 + 1e-9)
        XCTAssertLessThanOrEqual(corner.y, 375 - 30 + 1e-9)
        XCTAssertEqual(small.field(fromScreen: corner).x, rules.fieldHalfWidthDeg, accuracy: 1e-9)
    }
}
