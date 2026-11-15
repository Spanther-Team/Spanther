import Foundation

// The frozen probe: 90 seconds measured the same way from the first session of a course to the last. What the child
// sees is new every session (the order of the places, the pauses, the path the target glides along), all drawn from
// one seed. How hard it is does not change: a form is accepted only when every number of its difficulty lies within
// the protocol's tolerance (5%) of the protocol's target, and the generator keeps drawing until one does.
//
// Places are in field degrees: degrees of visual angle from the centre of the screen, x to the right and y down as
// the player sees the screen (FieldMapping in Transforms.swift turns them into screen pt at the measured distance).
// Times are seconds from the start of the probe. Game results, like the rest of the report: they tell how a play
// went, not what is wrong with anyone.

extension SeededRandom {
    /// The SplitMix64 finalizer: a seed and a salt in, an unrelated seed for a stream of its own out.
    static func mixed(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    // Written out instead of Double.random and shuffled(using:), whose algorithms may change between Swift
    // versions: a seed must give the same form on every build, for as long as its course runs.

    /// Uniform in 0..<1, from 53 random bits.
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }

    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }

    /// Uniform in 0..<n.
    mutating func index(_ n: Int) -> Int { min(n - 1, Int(unit() * Double(n))) }

    /// Fisher-Yates, from the last place down.
    mutating func shuffle(_ a: inout [Int]) {
        var i = a.count - 1
        while i > 0 {
            a.swapAt(i, index(i + 1))
            i -= 1
        }
    }
}

/// One version of the probe: everything that must stay the same for a course to be comparable from its first
/// session to its last. The values written here are version 1 and are frozen: a change of any of them is a new
/// version, never an edit, because a course keeps running the version it started with.
public struct ProbeProtocol: Sendable, Equatable {
    public var version = 1
    /// The version of the drawing code. A seed gives the same form only under the same generator version.
    public var generatorVersion = 1
    public var durationSec = 90.0
    /// A form passes when every number of its difficulty is within this share of the target.
    public var tolerance = 0.05

    // The field the probe uses (field deg from the centre). It fits an iPhone 13 held up to 40 cm away.
    public var fieldHalfWidthDeg = 9.0
    public var fieldHalfHeightDeg = 3.6

    // Jump targets: one at a time, in six zones (three columns, two rows), each held with the gaze for `holdSec`.
    public var columnsDeg = [-7.0, 0.0, 7.0]
    public var rowsDeg = [-2.0, 2.0]
    /// A target lands anywhere this far from its zone's centre, so no place is ever exactly repeated.
    public var jitterXDeg = 0.8
    public var jitterYDeg = 0.5
    /// A target waits this long for the hold, then leaves.
    public var targetLifeSec = 1.4
    public var holdSec = 0.5
    /// The first target of a block appears this long after the block starts.
    public var firstOnsetSec = 0.5
    /// The pause after a target's time, before the next one: an exponential cut to min...max, whose flat hazard
    /// keeps the next onset hard to predict.
    public var gapMinSec = 0.35
    public var gapMaxSec = 1.1
    public var gapScaleSec = 0.35
    /// Targets for the mean and the spread of the jumps from one target to the next (field deg).
    public var jumpMeanDeg = 9.45
    public var jumpSDDeg = 3.14

    /// Block 1, quiet: targets only.
    public var quietStartSec = 2.0
    public var quietCount = 18
    /// Block 3, distracted: every target comes with one distractor.
    public var distractedStartSec = 65.5
    public var distractedCount = 12

    /// A distractor appears this long after its target, in a zone of another column, and stays `distractorLifeSec`.
    public var distractorDelayMinSec = 0.15
    public var distractorDelayMaxSec = 0.55
    public var distractorDelayMeanSec = 0.35
    public var distractorLifeSec = 0.5
    /// Target for the mean distance from a target to its distractor (field deg).
    public var distractorEccentricityDeg = 9.8

    /// Block 2, pursuit: one target glides along a sum of sines. It leaves the centre over the ramp-in, is scored
    /// for the window, and returns to the centre over the ramp-out.
    public var pursuitStartSec = 38.5
    public var pursuitRampInSec = 1.5
    public var pursuitWindowSec = 24.0
    public var pursuitRampOutSec = 1.0
    public var pursuitEndSec = 65.5
    /// Whole cycles per window for each sine, and its amplitude (field deg). Whole cycles make the mean speed and
    /// acceleration over the window the same for every form, whatever the phases; a mix of even and odd counts
    /// keeps the second half of the window from mirroring the first.
    public var xHarmonics = [3, 5, 8, 11]
    public var xAmplitudesDeg = [3.6, 2.2, 1.4, 1.0]
    public var yHarmonics = [2, 5, 9]
    public var yAmplitudesDeg = [1.9, 0.9, 0.5]
    /// The path's difficulty is measured on samples this often.
    public var descriptorHz = 20.0
    /// How far ahead a straight-line guess of the path is tested (s).
    public var extrapolationSec = 0.2
    /// Targets for the path: mean and peak speed (deg/s), the error of the straight-line guess (deg), how much the
    /// path turns per degree travelled (rad/deg), and how much of its allowed reach it uses across and down.
    public var speedMeanDegPerSec = 3.67
    public var speedPeakDegPerSec = 10.0
    public var extrapolationErrorDeg = 0.1406
    public var turningRadPerDeg = 0.519
    public var reachXShare = 0.868
    public var reachYShare = 0.921

    /// The generator gives up after this many draws. A form needs a few hundred; this is never reached in practice.
    public var maxDraws = 200_000

    // Scoring.
    /// A look counts once the gaze has stayed on the target this long; a look that started sooner than
    /// `anticipationSec` after the target appeared was a guess, not a reaction.
    public var confirmSec = 0.1
    public var anticipationSec = 0.1
    /// A hold survives the gaze leaving the zone for this long, and losing the eyes (a blink) for this long.
    public var outGraceSec = 0.15
    public var blinkGraceSec = 0.3
    /// A distractor pulled the gaze when the gaze reached it within this long, and stayed `pullConfirmSec`.
    public var pullWindowSec = 0.6
    public var pullConfirmSec = 0.05
    /// A look-away: the gaze beyond the screen's edge by this margin for `lookAwayGazeSec`, or no gaze at all for
    /// `lookAwayLostSec` (longer than a blink).
    public var lookAwayMarginDeg = 3.0
    public var lookAwayGazeSec = 0.25
    public var lookAwayLostSec = 0.5
    /// The zone around a target: this base plus the calibration's measured error, kept within min...max (field deg).
    public var radiusBaseDeg = 2.0
    public var radiusMinDeg = 3.0
    public var radiusMaxDeg = 4.2

    private init() {}

    public static let v1 = ProbeProtocol()
    /// The version a new course starts with.
    public static let latest = v1

    /// The protocol a course was started with; nil when this build does not know the version.
    public static func version(_ v: Int) -> ProbeProtocol? { v == 1 ? v1 : nil }

    public enum Stage: String, Sendable { case leadIn, quiet, pursuit, distracted, done }

    public func stage(at t: Double) -> Stage {
        if t < quietStartSec { return .leadIn }
        if t < pursuitStartSec { return .quiet }
        if t < pursuitEndSec { return .pursuit }
        if t < durationSec { return .distracted }
        return .done
    }

    public var targetCount: Int { quietCount + distractedCount }
    /// The scored part of the pursuit block.
    public var pursuitScoredFromSec: Double { pursuitStartSec + pursuitRampInSec }
    public var pursuitScoredToSec: Double { pursuitScoredFromSec + pursuitWindowSec }

    /// Mean and spread of the pause between targets, from its distribution (s).
    public var gapMoments: (mean: Double, sd: Double) {
        let L = gapMaxSec - gapMinSec, t = gapScaleSec
        let q = exp(-L / t), K = 1 - q
        let m = t - L * q / K
        let m2 = (2 * t * t - (L * L + 2 * L * t + 2 * t * t) * q) / K
        return (gapMinSec + m, (m2 - m * m).squareRoot())
    }

    /// Root mean square speed (deg/s) and acceleration (deg/s²) of the path over its window: the same for every form.
    public var pathRMS: (speed: Double, acceleration: Double) {
        let w0 = 2 * Double.pi / pursuitWindowSec
        var v2 = 0.0, a2 = 0.0
        for (h, a) in zip(xHarmonics + yHarmonics, xAmplitudesDeg + yAmplitudesDeg) {
            let w = w0 * Double(h)
            v2 += a * w * (a * w) / 2
            a2 += a * w * w * (a * w * w) / 2
        }
        return (v2.squareRoot(), a2.squareRoot())
    }

    /// The radius of the zone around a target (field deg) for a calibration whose check showed this mean error.
    public func hitRadiusDeg(calibrationErrorDeg: Double?) -> Double {
        guard let e = calibrationErrorDeg, e.isFinite else { return radiusMinDeg }
        return min(radiusMaxDeg, max(radiusMinDeg, radiusBaseDeg + e))
    }
}

/// One form of the probe: what one session shows, drawn from its seed.
public struct ProbePlan: Sendable, Equatable {
    public enum Block: String, Sendable, Codable { case quiet, distracted }

    public struct Target: Sendable, Equatable {
        /// 0..<targetCount, in the order shown.
        public let index: Int
        public let block: Block
        /// 0..<6: the column is zone % 3 (left, middle, right), the row is zone / 3 (top, bottom).
        public let zone: Int
        public let onsetSec: Double
        /// Field deg.
        public let position: Vec2
        /// The jump to it from the target before it, or from the centre for the first of a block (field deg).
        public let jumpDeg: Double
    }

    public struct Distractor: Sendable, Equatable {
        public let targetIndex: Int
        public let zone: Int
        public let onsetSec: Double
        /// Field deg.
        public let position: Vec2
        /// Its distance from its target (field deg).
        public let eccentricityDeg: Double
    }

    /// One number of the form's difficulty beside the protocol's target for it.
    public struct Check: Sendable, Equatable {
        public let name: String
        public let value: Double
        public let target: Double
        /// How far the value is from the target, as a share of the target.
        public var deviation: Double { target != 0 ? abs(value - target) / abs(target) : abs(value) }
    }

    public let rules: ProbeProtocol
    public let seed: UInt64
    public let targets: [Target]
    public let distractors: [Distractor]
    /// The phase of each sine of the path (rad), across and down.
    public let xPhases: [Double]
    public let yPhases: [Double]
    public let difficulty: [Check]
    /// How many draws the generator needed before every check passed.
    public let draws: Int

    /// Seeds stay below 2^53, so a spreadsheet or a script reading the JSON keeps them exact.
    public static let seedMask: UInt64 = (1 << 53) - 1

    /// The form of a seed; the same seed always gives the same form. Nil only if no form passed within
    /// `maxDraws` draws, which the tests show does not happen.
    public static func make(seed: UInt64, rules: ProbeProtocol = .v1) -> ProbePlan? {
        let base = SeededRandom.mixed(seed ^ 0x5350_414E_5448_4552)
        var quietRng = SeededRandom(seed: SeededRandom.mixed(base ^ 1))
        var pathRng = SeededRandom(seed: SeededRandom.mixed(base ^ 2))
        var distractedRng = SeededRandom(seed: SeededRandom.mixed(base ^ 3))
        guard let q = hold(&quietRng, rules: rules, count: rules.quietCount, start: rules.quietStartSec, distracted: false),
              let p = path(&pathRng, rules: rules),
              let d = hold(&distractedRng, rules: rules, count: rules.distractedCount, start: rules.distractedStartSec,
                           distracted: true)
        else { return nil }

        var targets: [Target] = []
        for i in 0..<q.order.count {
            targets.append(Target(index: i, block: .quiet, zone: q.order[i], onsetSec: q.onsets[i], position: q.places[i],
                                  jumpDeg: q.jumps[i]))
        }
        let offset = targets.count
        for i in 0..<d.order.count {
            targets.append(Target(index: offset + i, block: .distracted, zone: d.order[i], onsetSec: d.onsets[i],
                                  position: d.places[i], jumpDeg: d.jumps[i]))
        }
        let distractors = d.distractors.map {
            Distractor(targetIndex: offset + $0.targetIndex, zone: $0.zone, onsetSec: $0.onsetSec, position: $0.position,
                       eccentricityDeg: $0.eccentricityDeg)
        }
        let gap = rules.gapMoments
        let rms = rules.pathRMS
        let checks = [
            Check(name: "quiet.jumpMeanDeg", value: q.jumpMean, target: rules.jumpMeanDeg),
            Check(name: "quiet.jumpSDDeg", value: q.jumpSD, target: rules.jumpSDDeg),
            Check(name: "quiet.gapMeanSec", value: q.gapMean, target: gap.mean),
            Check(name: "quiet.gapSDSec", value: q.gapSD, target: gap.sd),
            Check(name: "quiet.rightwardShare", value: q.rightShare, target: 0.5),
            Check(name: "distracted.jumpMeanDeg", value: d.jumpMean, target: rules.jumpMeanDeg),
            Check(name: "distracted.jumpSDDeg", value: d.jumpSD, target: rules.jumpSDDeg),
            Check(name: "distracted.gapMeanSec", value: d.gapMean, target: gap.mean),
            Check(name: "distracted.gapSDSec", value: d.gapSD, target: gap.sd),
            Check(name: "distracted.rightwardShare", value: d.rightShare, target: 0.5),
            Check(name: "distractor.delayMeanSec", value: d.delayMean, target: rules.distractorDelayMeanSec),
            Check(name: "distractor.eccentricityMeanDeg", value: d.eccentricityMean, target: rules.distractorEccentricityDeg),
            Check(name: "distractor.leftShare", value: d.leftShare, target: 0.5),
            Check(name: "path.speedRMSDegPerSec", value: p.d.speedRMS, target: rms.speed),
            Check(name: "path.accelerationRMSDegPerSec2", value: p.d.accelerationRMS, target: rms.acceleration),
            Check(name: "path.speedMeanDegPerSec", value: p.d.speedMean, target: rules.speedMeanDegPerSec),
            Check(name: "path.speedPeakDegPerSec", value: p.d.speedPeak, target: rules.speedPeakDegPerSec),
            Check(name: "path.extrapolationErrorDeg", value: p.d.extrapolation, target: rules.extrapolationErrorDeg),
            Check(name: "path.turningRadPerDeg", value: p.d.turning, target: rules.turningRadPerDeg),
            Check(name: "path.reachXShare", value: p.d.reachX, target: rules.reachXShare),
            Check(name: "path.reachYShare", value: p.d.reachY, target: rules.reachYShare),
        ]
        return ProbePlan(rules: rules, seed: seed, targets: targets, distractors: distractors, xPhases: p.xPhases,
                         yPhases: p.yPhases, difficulty: checks, draws: q.draws + p.draws + d.draws)
    }

    /// A form for a new session: the first seed from `seed` on whose order of places none of the child's earlier
    /// sessions had (`signatures` holds their `zoneSignature`s).
    public static func fresh(from seed: UInt64, avoiding signatures: Set<String> = [], rules: ProbeProtocol = .v1) -> ProbePlan? {
        var s = seed & seedMask
        for _ in 0..<64 {
            if let plan = make(seed: s, rules: rules), !signatures.contains(plan.zoneSignature) { return plan }
            s = (s &+ 1) & seedMask
        }
        return nil
    }

    /// The largest share by which a number of the difficulty misses its target.
    public var worstDeviation: Double { difficulty.map(\.deviation).max() ?? 0 }

    /// The order of the zones, quiet block then distracted block: two forms with the same signature show their
    /// targets in the same zones in the same order (though never at the same places or times).
    public var zoneSignature: String {
        var s = ""
        for t in targets {
            if t.block == .distracted && s.count == rules.quietCount { s += "|" }
            s += String(t.zone)
        }
        return s
    }

    /// 53 bits that change when anything the child would see changes: the places and times to a millionth, the
    /// phases to a billionth. Stored with the session, so a later build can prove it rebuilt the same form.
    public var fingerprint: UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        func eat(_ v: Int) {
            var x = UInt64(bitPattern: Int64(v))
            for _ in 0..<8 {
                h = (h ^ (x & 0xFF)) &* 0x0000_0100_0000_01B3
                x >>= 8
            }
        }
        func eatReal(_ v: Double, _ scale: Double) { eat(Int((v * scale).rounded())) }
        eat(rules.version)
        eat(rules.generatorVersion)
        for t in targets {
            eat(t.zone)
            eatReal(t.onsetSec, 1e6)
            eatReal(t.position.x, 1e6)
            eatReal(t.position.y, 1e6)
        }
        for d in distractors {
            eat(d.zone)
            eatReal(d.onsetSec, 1e6)
            eatReal(d.position.x, 1e6)
            eatReal(d.position.y, 1e6)
        }
        for p in xPhases + yPhases { eatReal(p, 1e9) }
        return h & Self.seedMask
    }

    // MARK: What is on the screen at a moment

    /// The target whose time includes `t`, by the schedule (a held target leaves sooner; ProbeRun knows that).
    public func scheduledTarget(at t: Double) -> Target? {
        targets.first { t >= $0.onsetSec && t < $0.onsetSec + rules.targetLifeSec }
    }

    public func scheduledDistractor(at t: Double) -> Distractor? {
        distractors.first { t >= $0.onsetSec && t < $0.onsetSec + rules.distractorLifeSec }
    }

    /// The path at `tau` seconds into its window, without the ramps (field deg). It repeats every window.
    public func pathOffset(at tau: Double) -> Vec2 {
        let w0 = 2 * Double.pi / rules.pursuitWindowSec
        var x = 0.0, y = 0.0
        for k in 0..<rules.xHarmonics.count {
            x += rules.xAmplitudesDeg[k] * sin(w0 * Double(rules.xHarmonics[k]) * tau + xPhases[k])
        }
        for k in 0..<rules.yHarmonics.count {
            y += rules.yAmplitudesDeg[k] * sin(w0 * Double(rules.yHarmonics[k]) * tau + yPhases[k])
        }
        return Vec2(x, y)
    }

    /// Where the gliding target is at `t` (field deg); nil outside the pursuit block. It starts at rest in the
    /// centre and ends there, so nothing ever jumps.
    public func pursuitPosition(at t: Double) -> Vec2? {
        let u = t - rules.pursuitStartSec
        guard u >= 0, t < rules.pursuitEndSec else { return nil }
        let scored = rules.pursuitRampInSec + rules.pursuitWindowSec
        let envelope = PursuitPlan.ramp(u, 0, rules.pursuitRampInSec)
            * (1 - PursuitPlan.ramp(u, scored, scored + rules.pursuitRampOutSec))
        return pathOffset(at: u - rules.pursuitRampInSec) * envelope
    }

    // MARK: Drawing a form

    private struct Hold {
        var order: [Int] = []
        var places: [Vec2] = []
        var jumps: [Double] = []
        var onsets: [Double] = []
        var distractors: [Distractor] = []
        var draws = 0
        var jumpMean = 0.0, jumpSD = 0.0, gapMean = 0.0, gapSD = 0.0, rightShare = 0.0
        var delayMean = 0.0, eccentricityMean = 0.0, leftShare = 0.0
    }

    private static func near(_ x: Double, _ target: Double, _ tolerance: Double) -> Bool {
        abs(x - target) <= tolerance * abs(target)
    }

    /// One block of jump targets. The order: bags of the six zones, shuffled, so every zone comes equally often;
    /// two targets in a row never share a column (the gaze always has to travel), the first one is never in the
    /// middle column (the gaze starts at the centre), and jumps to the right and to the left come equally often.
    private static func hold(_ rng: inout SeededRandom, rules r: ProbeProtocol, count n: Int, start: Double,
                             distracted: Bool) -> Hold? {
        guard n >= 6, n % 6 == 0, r.columnsDeg.count == 3, r.rowsDeg.count == 2 else { return nil }
        var h = Hold()
        let tol = r.tolerance

        while true {
            h.draws += 1
            if h.draws > r.maxDraws { return nil }
            h.order.removeAll(keepingCapacity: true)
            for _ in 0..<(n / 6) {
                var bag = [0, 1, 2, 3, 4, 5]
                rng.shuffle(&bag)
                h.order.append(contentsOf: bag)
            }
            if h.order[0] % 3 == 1 { continue }
            var clash = false
            for i in 1..<n where h.order[i] % 3 == h.order[i - 1] % 3 {
                clash = true
                break
            }
            if clash { continue }

            h.places.removeAll(keepingCapacity: true)
            for z in h.order {
                let x = r.columnsDeg[z % 3] + rng.uniform(-r.jitterXDeg, r.jitterXDeg)
                let y = r.rowsDeg[z / 3] + rng.uniform(-r.jitterYDeg, r.jitterYDeg)
                h.places.append(Vec2(x, y))
            }
            h.jumps.removeAll(keepingCapacity: true)
            var px = 0.0, py = 0.0, right = 0, sum = 0.0
            for p in h.places {
                let dx = p.x - px, dy = p.y - py
                let a = (dx * dx + dy * dy).squareRoot()
                h.jumps.append(a)
                sum += a
                if dx > 0 { right += 1 }
                px = p.x
                py = p.y
            }
            let mean = sum / Double(n)
            var ss = 0.0
            for a in h.jumps { ss += (a - mean) * (a - mean) }
            let sd = (ss / Double(n)).squareRoot()
            if right * 2 != n { continue }
            if !(near(mean, r.jumpMeanDeg, tol) && near(sd, r.jumpSDDeg, tol)) { continue }
            h.jumpMean = mean
            h.jumpSD = sd
            h.rightShare = Double(right) / Double(n)
            break
        }

        let K = 1 - exp(-(r.gapMaxSec - r.gapMinSec) / r.gapScaleSec)
        let moments = r.gapMoments
        var gaps: [Double] = []
        while true {
            h.draws += 1
            if h.draws > r.maxDraws { return nil }
            gaps.removeAll(keepingCapacity: true)
            var sum = 0.0
            for _ in 0..<(n - 1) {
                let g = r.gapMinSec - r.gapScaleSec * log(1 - rng.unit() * K)
                gaps.append(g)
                sum += g
            }
            let mean = sum / Double(n - 1)
            var ss = 0.0
            for g in gaps { ss += (g - mean) * (g - mean) }
            let sd = (ss / Double(n - 1)).squareRoot()
            if near(mean, moments.mean, tol) && near(sd, moments.sd, tol) {
                h.gapMean = mean
                h.gapSD = sd
                break
            }
        }
        h.onsets = [start + r.firstOnsetSec]
        for g in gaps { h.onsets.append(h.onsets[h.onsets.count - 1] + r.targetLifeSec + g) }

        guard distracted else { return h }
        while true {
            h.draws += 1
            if h.draws > r.maxDraws { return nil }
            h.distractors.removeAll(keepingCapacity: true)
            var left = 0, delaySum = 0.0, eccentricitySum = 0.0
            for i in 0..<n {
                let z = h.order[i]
                let delay = rng.uniform(r.distractorDelayMinSec, r.distractorDelayMaxSec)
                var others: [Int] = []
                for k in 0..<6 where k % 3 != z % 3 { others.append(k) }
                let dz = others[rng.index(others.count)]
                let x = r.columnsDeg[dz % 3] + rng.uniform(-r.jitterXDeg, r.jitterXDeg)
                let y = r.rowsDeg[dz / 3] + rng.uniform(-r.jitterYDeg, r.jitterYDeg)
                let dx = x - h.places[i].x, dy = y - h.places[i].y
                let e = (dx * dx + dy * dy).squareRoot()
                if x < h.places[i].x { left += 1 }
                delaySum += delay
                eccentricitySum += e
                h.distractors.append(Distractor(targetIndex: i, zone: dz, onsetSec: h.onsets[i] + delay,
                                                position: Vec2(x, y), eccentricityDeg: e))
            }
            let delayMean = delaySum / Double(n), eccentricityMean = eccentricitySum / Double(n)
            if left * 2 != n { continue }
            if !(near(delayMean, r.distractorDelayMeanSec, tol) && near(eccentricityMean, r.distractorEccentricityDeg, tol)) {
                continue
            }
            h.delayMean = delayMean
            h.eccentricityMean = eccentricityMean
            h.leftShare = Double(left) / Double(n)
            return h
        }
    }

    /// What makes a path easy or hard to follow, measured over its window.
    struct PathDescriptors: Equatable {
        var speedRMS = 0.0, accelerationRMS = 0.0
        var speedMean = 0.0, speedPeak = 0.0, extrapolation = 0.0, turning = 0.0, reachX = 0.0, reachY = 0.0
    }

    private struct PathDraw {
        var xPhases: [Double]
        var yPhases: [Double]
        var draws: Int
        var d: PathDescriptors
    }

    /// Place, speed and acceleration along one axis at each descriptor sample of the window. The sines advance by
    /// rotation, so the samples take no library calls and come out the same on every platform.
    private static func series(_ harmonics: [Int], _ amplitudes: [Double], _ phases: [Double],
                               rules r: ProbeProtocol) -> (x: [Double], v: [Double], a: [Double]) {
        let n = Int(r.pursuitWindowSec * r.descriptorHz)
        let w0 = 2 * Double.pi / r.pursuitWindowSec
        var xs = [Double](repeating: 0, count: n)
        var vs = [Double](repeating: 0, count: n)
        var acs = [Double](repeating: 0, count: n)
        for k in 0..<harmonics.count {
            let a = amplitudes[k]
            let w = w0 * Double(harmonics[k])
            let step = w / r.descriptorHz
            var c = cos(phases[k]), s = sin(phases[k])
            let cd = cos(step), sd = sin(step)
            for i in 0..<n {
                xs[i] += a * s
                vs[i] += a * w * c
                acs[i] -= a * w * w * s
                let c2 = c * cd - s * sd
                s = s * cd + c * sd
                c = c2
            }
        }
        return (xs, vs, acs)
    }

    static func descriptors(xPhases: [Double], yPhases: [Double], rules r: ProbeProtocol) -> PathDescriptors {
        let (x, vx, ax) = series(r.xHarmonics, r.xAmplitudesDeg, xPhases, rules: r)
        let (y, vy, ay) = series(r.yHarmonics, r.yAmplitudesDeg, yPhases, rules: r)
        let n = x.count
        guard n > 1 else { return PathDescriptors() }
        let ahead = Int((r.extrapolationSec * r.descriptorHz).rounded())
        var speedSum = 0.0, peak = 0.0, miss = 0.0, turn = 0.0, reachX = 0.0, reachY = 0.0, v2 = 0.0, a2 = 0.0
        for i in 0..<n {
            let s = (vx[i] * vx[i] + vy[i] * vy[i]).squareRoot()
            speedSum += s
            peak = max(peak, s)
            var j = (i + ahead) % n
            let ex = x[j] - x[i] - r.extrapolationSec * vx[i], ey = y[j] - y[i] - r.extrapolationSec * vy[i]
            miss += (ex * ex + ey * ey).squareRoot()
            j = (i + 1) % n
            turn += abs(atan2(vx[i] * vy[j] - vy[i] * vx[j], vx[i] * vx[j] + vy[i] * vy[j]))
            reachX = max(reachX, abs(x[i]))
            reachY = max(reachY, abs(y[i]))
            v2 += vx[i] * vx[i] + vy[i] * vy[i]
            a2 += ax[i] * ax[i] + ay[i] * ay[i]
        }
        let speedMean = speedSum / Double(n)
        var sumX = 0.0, sumY = 0.0
        for a in r.xAmplitudesDeg { sumX += a }
        for a in r.yAmplitudesDeg { sumY += a }
        return PathDescriptors(speedRMS: (v2 / Double(n)).squareRoot(), accelerationRMS: (a2 / Double(n)).squareRoot(),
                               speedMean: speedMean, speedPeak: peak, extrapolation: miss / Double(n),
                               turning: turn / (speedMean * r.pursuitWindowSec), reachX: reachX / sumX,
                               reachY: reachY / sumY)
    }

    private static func path(_ rng: inout SeededRandom, rules r: ProbeProtocol) -> PathDraw? {
        guard r.xHarmonics.count == r.xAmplitudesDeg.count, r.yHarmonics.count == r.yAmplitudesDeg.count,
              !r.xHarmonics.isEmpty, !r.yHarmonics.isEmpty else { return nil }
        let tol = r.tolerance
        var draws = 0
        while true {
            draws += 1
            if draws > r.maxDraws { return nil }
            var xPhases: [Double] = [], yPhases: [Double] = []
            for _ in r.xHarmonics { xPhases.append(rng.uniform(0, 2 * Double.pi)) }
            for _ in r.yHarmonics { yPhases.append(rng.uniform(0, 2 * Double.pi)) }
            let d = descriptors(xPhases: xPhases, yPhases: yPhases, rules: r)
            if near(d.speedMean, r.speedMeanDegPerSec, tol) && near(d.speedPeak, r.speedPeakDegPerSec, tol)
                && near(d.extrapolation, r.extrapolationErrorDeg, tol) && near(d.turning, r.turningRadPerDeg, tol)
                && near(d.reachX, r.reachXShare, tol) && near(d.reachY, r.reachYShare, tol) {
                return PathDraw(xPhases: xPhases, yPhases: yPhases, draws: draws, d: d)
            }
        }
    }
}
