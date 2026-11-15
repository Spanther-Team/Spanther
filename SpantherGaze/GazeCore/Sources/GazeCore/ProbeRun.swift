import Foundation

// Scoring the probe. Fed one gaze sample per frame, it tells the screen what happened (a target held, a target
// gone, a distractor on) and, at the end, gives the probe's numbers. The live session and a replay of its log run
// this same code, so the two cannot disagree. Gaze points are in field degrees, like the plan.

/// The probe's numbers by the names they are stored under.
public enum ProbeMetric: String, CaseIterable, Sendable {
    /// Targets held for the hold time, as a share of the targets shown (0...1): all of them, the quiet block, the
    /// distracted block.
    case holdShare, holdShareQuiet, holdShareDistracted
    /// Quiet block: the median time from a target's appearing to the look that stayed on it (ms), and how much
    /// that time varied from target to target (standard deviation and interquartile range, ms).
    case firstLookMs, latencySdMs, latencyIqrMs
    /// Targets the gaze was on sooner than a reaction allows, as a share of the targets shown: a rise over a course
    /// would mean the child has learned where targets come, so it guards the other numbers.
    case anticipationShare
    /// Distracted block: the share of distractors the gaze went to (0...1), the median time to come back to the
    /// target (ms), and how many distractors counted.
    case distractorPullShare, distractorReturnMs, distractorEvents
    /// Pursuit: the share of the scored window with the gaze on the gliding target (0...1), how much of the
    /// target's motion the gaze made (1: all of it), and how far behind it ran (ms).
    case pursuitOnShare, pursuitGain, pursuitLagMs
    /// Glances off the screen per minute, and the share of the probe spent in them.
    case lookAwaysPerMin, awayShare
    /// Conditions, not results: frames with a gaze point as a share of all, frames per second, and the radius of
    /// the zone around a target (field deg).
    case validShare, fps, radiusDeg

    public enum Better: Sendable { case higher, lower, neither }

    /// Which way is an improvement, for colouring a change.
    public var better: Better {
        switch self {
        case .holdShare, .holdShareQuiet, .holdShareDistracted, .pursuitOnShare, .pursuitGain: return .higher
        case .firstLookMs, .latencySdMs, .latencyIqrMs, .distractorPullShare, .distractorReturnMs, .pursuitLagMs,
             .lookAwaysPerMin, .awayShare:
            return .lower
        case .anticipationShare, .distractorEvents, .validShare, .fps, .radiusDeg: return .neither
        }
    }

    /// The numbers the course chart shows, in its order.
    public static let charted: [ProbeMetric] = [
        .holdShare, .firstLookMs, .latencySdMs, .distractorPullShare, .distractorReturnMs, .pursuitOnShare,
        .pursuitGain, .lookAwaysPerMin,
    ]
}

public struct ProbeRun: Sendable {
    public enum Event: Equatable, Sendable {
        case targetAppeared(Int)
        /// The hold was completed: the target pops.
        case targetHeld(Int)
        /// Its time ran out without a hold: the target fades.
        case targetExpired(Int)
        /// Indexes into the plan's distractors.
        case distractorAppeared(Int)
        case distractorGone(Int)
    }

    public struct TargetRecord: Equatable, Sendable {
        public var appeared = false
        /// From the target's appearing to the start of the first look that stayed on it (s); nil: never looked at.
        public var latencySec: Double?
        /// When the hold was completed (probe time, s); nil: not held.
        public var heldAtSec: Double?
        public var expired = false
        /// Times the gaze left the target after a look had started.
        public var slips = 0
    }

    public struct DistractorRecord: Equatable, Sendable {
        public var appeared = false
        public var gone = false
        /// It appeared while its target was still waiting for the hold, and not where the gaze was already
        /// resting; only such distractors are counted.
        public var scorable = false
        /// When the gaze reached it (probe time, s); nil: the gaze did not go to it.
        public var pulledAtSec: Double?
        /// From then to the gaze being back on the target (s); nil: not back before the target left.
        public var returnSec: Double?
    }

    public let plan: ProbePlan
    /// The zone around a target, a distractor and the gliding target (field deg).
    public let radiusDeg: Double
    /// The screen's half-width and half-height (field deg): beyond them, plus a margin, the gaze is off the screen.
    public let screenHalfWidthDeg: Double
    public let screenHalfHeightDeg: Double

    public private(set) var targets: [TargetRecord]
    public private(set) var distractors: [DistractorRecord]
    /// The target to draw now; nil between targets and once it is held.
    public private(set) var visibleTarget: Int?
    public private(set) var visibleDistractor: Int?
    /// 0...1: how far the hold on the visible target has got.
    public private(set) var holdProgress = 0.0

    private var cursor = 0
    private var dwellStart: Double?
    private var lastInside = 0.0
    private var dwellConfirmed = false
    private var distractorCursor = 0
    private var pullStart: Double?
    private var awaitingReturn: Int?
    private var returnStart: Double?
    private var pursuitFrames = 0
    private var pursuitOn = 0
    /// Frames with no gaze since the last seen one, not yet counted: a gap no longer than a blink is neither on
    /// nor off the glider, so a child who blinks is not scored below one who does not.
    private var pursuitPendingNil = 0
    private var pursuitNilSince: Double?
    private var fitTimes: [Double] = []
    private var fitX: [Double] = []
    private var fitY: [Double] = []
    private var frames = 0
    private var validFrames = 0
    private var firstT: Double?
    private var lastT = 0.0
    private var seen: Vec2?
    private var seenT = 0.0
    private var awayStart: Double?
    private var awaySawGaze = false
    private var lookAways = 0
    private var awaySec = 0.0

    public init(plan: ProbePlan, radiusDeg: Double, screenHalfWidthDeg: Double, screenHalfHeightDeg: Double) {
        self.plan = plan
        self.radiusDeg = radiusDeg
        self.screenHalfWidthDeg = screenHalfWidthDeg
        self.screenHalfHeightDeg = screenHalfHeightDeg
        targets = Array(repeating: TargetRecord(), count: plan.targets.count)
        distractors = Array(repeating: DistractorRecord(), count: plan.distractors.count)
    }

    /// The probe has run its whole time.
    public var finished: Bool { firstT != nil && lastT >= plan.rules.durationSec }

    /// One frame: the probe time (s) and the gaze point (field deg), nil when the eyes were not seen. Frames must
    /// come in order; one that goes back in time is ignored.
    public mutating func add(t: Double, gaze: Vec2?) -> [Event] {
        var events: [Event] = []
        guard t.isFinite, t >= 0, firstT == nil || t >= lastT else { return events }
        if firstT == nil { firstT = t }
        lastT = t
        frames += 1
        let g = gaze.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
        if let g {
            validFrames += 1
            seen = g
            seenT = t
        }
        trackAway(t, g)
        stepTargets(t, g, &events)
        stepDistractors(t, g, &events)
        stepPursuit(t, g)
        return events
    }

    // MARK: Look-aways

    private mutating func trackAway(_ t: Double, _ g: Vec2?) {
        let margin = plan.rules.lookAwayMarginDeg
        let offScreen = g.map { abs($0.x) > screenHalfWidthDeg + margin || abs($0.y) > screenHalfHeightDeg + margin } ?? false
        if g == nil || offScreen {
            if awayStart == nil {
                awayStart = t
                awaySawGaze = false
            }
            if offScreen { awaySawGaze = true }
        } else if let start = awayStart {
            closeAway(start, t)
        }
    }

    /// A stretch without the gaze on the screen ends: it was a look-away if it lasted long enough. With the gaze
    /// seen off the screen it was a glance for sure; with no gaze at all it may have been a blink, so it must be
    /// longer than one.
    private mutating func closeAway(_ start: Double, _ end: Double) {
        let r = plan.rules
        let length = end - start
        if length >= (awaySawGaze ? r.lookAwayGazeSec : r.lookAwayLostSec) {
            lookAways += 1
            awaySec += length
        }
        awayStart = nil
    }

    // MARK: Jump targets

    private mutating func stepTargets(_ t: Double, _ g: Vec2?, _ events: inout [Event]) {
        let r = plan.rules
        while cursor < plan.targets.count, t >= plan.targets[cursor].onsetSec + r.targetLifeSec {
            if !targets[cursor].appeared {
                targets[cursor].appeared = true
                events.append(.targetAppeared(cursor))
            }
            targets[cursor].expired = true
            events.append(.targetExpired(cursor))
            finishTarget()
        }
        visibleTarget = nil
        holdProgress = 0
        guard cursor < plan.targets.count else { return }
        let target = plan.targets[cursor]
        guard t >= target.onsetSec else { return }
        if !targets[cursor].appeared {
            targets[cursor].appeared = true
            events.append(.targetAppeared(cursor))
        }
        visibleTarget = cursor

        let inside = g.map { $0.distance(to: target.position) <= radiusDeg } ?? false
        if inside {
            if dwellStart == nil {
                dwellStart = t
                dwellConfirmed = false
            }
            lastInside = t
            let start = dwellStart ?? t
            if !dwellConfirmed, t - start >= r.confirmSec {
                dwellConfirmed = true
                if targets[cursor].latencySec == nil { targets[cursor].latencySec = max(0, start - target.onsetSec) }
            }
            if let d = awaitingReturn {
                if returnStart == nil { returnStart = t }
                if let back = returnStart, t - back >= r.confirmSec, let pulled = distractors[d].pulledAtSec {
                    distractors[d].returnSec = max(0, back - pulled)
                    awaitingReturn = nil
                    returnStart = nil
                }
            }
            if t - start >= r.holdSec {
                // Back on the target as the hold ends: the return counts, however short the look back has been.
                if let d = awaitingReturn, let back = returnStart, let pulled = distractors[d].pulledAtSec {
                    distractors[d].returnSec = max(0, back - pulled)
                }
                targets[cursor].heldAtSec = t
                events.append(.targetHeld(cursor))
                finishTarget()
                visibleTarget = nil
                return
            }
            holdProgress = min(1, (t - start) / r.holdSec)
        } else if let start = dwellStart {
            // A short slip out of the zone, or a blink, does not undo the look; a longer one does.
            if t - lastInside > (g == nil ? r.blinkGraceSec : r.outGraceSec) {
                if dwellConfirmed { targets[cursor].slips += 1 }
                clearDwell()
            } else {
                holdProgress = min(1, (t - start) / r.holdSec)
            }
        }
    }

    private mutating func clearDwell() {
        dwellStart = nil
        dwellConfirmed = false
        returnStart = nil
    }

    private mutating func finishTarget() {
        if let d = awaitingReturn, plan.distractors[d].targetIndex == cursor { awaitingReturn = nil }
        cursor += 1
        clearDwell()
    }

    // MARK: Distractors

    private mutating func stepDistractors(_ t: Double, _ g: Vec2?, _ events: inout [Event]) {
        let r = plan.rules
        visibleDistractor = nil
        while distractorCursor < plan.distractors.count {
            let i = distractorCursor
            let d = plan.distractors[i]
            guard t >= d.onsetSec else { return }
            let target = targets[d.targetIndex]
            let waiting = target.heldAtSec == nil && !target.expired
            let home = plan.targets[d.targetIndex].position
            if !distractors[i].appeared {
                distractors[i].appeared = true
                // A distractor that lights up where the gaze already rests (the place of the target before, say)
                // has not pulled it there, so it cannot be counted either way.
                let resting = seen.map { t - seenT <= r.blinkGraceSec && drawn($0, to: d.position, from: home) } ?? false
                distractors[i].scorable = waiting && !resting
                events.append(.distractorAppeared(i))
                pullStart = nil
            }
            if t >= d.onsetSec + r.distractorLifeSec {
                if !distractors[i].gone {
                    distractors[i].gone = true
                    events.append(.distractorGone(i))
                }
            } else {
                visibleDistractor = i
            }
            if distractors[i].scorable, distractors[i].pulledAtSec == nil, waiting, t <= d.onsetSec + r.pullWindowSec {
                if g.map({ drawn($0, to: d.position, from: home) }) ?? false {
                    if pullStart == nil { pullStart = t }
                    if let start = pullStart, t - start >= r.pullConfirmSec {
                        distractors[i].pulledAtSec = start
                        awaitingReturn = i
                        returnStart = nil
                    }
                } else {
                    pullStart = nil
                }
            }
            guard t > d.onsetSec + max(r.distractorLifeSec, r.pullWindowSec) else { return }
            distractorCursor += 1
            pullStart = nil
        }
    }

    /// The gaze is at the distractor: inside its zone and nearer to it than to the target.
    private func drawn(_ p: Vec2, to distractor: Vec2, from home: Vec2) -> Bool {
        let far = p.distance(to: distractor)
        return far <= radiusDeg && far < p.distance(to: home)
    }

    // MARK: Pursuit

    private mutating func stepPursuit(_ t: Double, _ g: Vec2?) {
        let r = plan.rules
        guard t >= r.pursuitScoredFromSec, t <= r.pursuitScoredToSec, let place = plan.pursuitPosition(at: t) else { return }
        guard let g else {
            // No gaze: a blink's worth of frames waits, and is dropped once the gaze comes back soon enough.
            // A longer loss counts off the glider, its waiting frames included.
            if let since = pursuitNilSince, t - since > r.blinkGraceSec {
                pursuitFrames += pursuitPendingNil + 1
                pursuitPendingNil = 0
            } else {
                if pursuitNilSince == nil { pursuitNilSince = t }
                pursuitPendingNil += 1
            }
            return
        }
        pursuitPendingNil = 0
        pursuitNilSince = nil
        pursuitFrames += 1
        let far = g.distance(to: place)
        if far <= radiusDeg { pursuitOn += 1 }
        // The fit describes how the child follows while following: a glance elsewhere is left to the on-target
        // share and to the look-aways.
        if far <= 2 * radiusDeg {
            fitTimes.append(t - r.pursuitScoredFromSec)
            fitX.append(g.x)
            fitY.append(g.y)
        }
    }

    /// How the gaze followed each sine of the path along one axis, by least squares over the frames given: the
    /// share of the sine's swing the gaze made (gain), how late it ran (lag, s), and the sine's weight in the
    /// target's speed. Nil when the frames are too few to tell.
    static func follow(times: [Double], values: [Double], harmonics: [Int], amplitudes: [Double], phases: [Double],
                       windowSec: Double) -> [(gain: Double, lagSec: Double, weight: Double)]? {
        let k = harmonics.count, dim = 1 + 2 * k
        guard k > 0, times.count == values.count, times.count >= 8 * dim else { return nil }
        var A = [[Double]](repeating: [Double](repeating: 0, count: dim), count: dim)
        var b = [Double](repeating: 0, count: dim)
        var row = [Double](repeating: 0, count: dim)
        let w0 = 2 * Double.pi / windowSec
        for n in 0..<times.count {
            row[0] = 1
            for j in 0..<k {
                let angle = w0 * Double(harmonics[j]) * times[n] + phases[j]
                row[1 + 2 * j] = sin(angle)
                row[2 + 2 * j] = cos(angle)
            }
            for p in 0..<dim {
                b[p] += row[p] * values[n]
                for q in p..<dim { A[p][q] += row[p] * row[q] }
            }
        }
        for p in 0..<dim {
            for q in 0..<p { A[p][q] = A[q][p] }
        }
        guard let beta = RidgeModel.solve(A, b) else { return nil }
        var parts: [(gain: Double, lagSec: Double, weight: Double)] = []
        for j in 0..<k {
            // The gaze's part at this frequency is s * sin + c * cos = gain * A * sin(angle - lag).
            let s = beta[1 + 2 * j], c = beta[2 + 2 * j]
            let w = w0 * Double(harmonics[j])
            let speed = amplitudes[j] * w
            parts.append((gain: (s * s + c * c).squareRoot() / amplitudes[j], lagSec: atan2(-c, s) / w, weight: speed * speed))
        }
        return parts
    }

    // MARK: The numbers

    /// The probe's numbers by ProbeMetric name. A number that could not be measured is left out.
    public func metrics() -> [String: Double] {
        var run = self
        if let start = run.awayStart { run.closeAway(start, run.lastT) }
        return run.computed()
    }

    /// The record of this probe for the session's log.
    public func result(qualityPassed: Bool) -> ProbeResult {
        ProbeResult(version: plan.rules.version, generatorVersion: plan.rules.generatorVersion, seed: plan.seed,
                    qualityPassed: qualityPassed, completed: finished, metrics: metrics(), fingerprint: plan.fingerprint)
    }

    private func computed() -> [String: Double] {
        var m: [String: Double] = [:]
        func put(_ key: ProbeMetric, _ value: Double?) {
            if let v = value, v.isFinite { m[key.rawValue] = v }
        }
        func share(_ part: Int, _ whole: Int) -> Double? { whole > 0 ? Double(part) / Double(whole) : nil }
        let r = plan.rules

        var shown = 0, shownQuiet = 0, shownDistracted = 0, held = 0, heldQuiet = 0, heldDistracted = 0, guessed = 0
        var latencies: [Double] = []
        for i in 0..<targets.count where targets[i].appeared {
            let quiet = plan.targets[i].block == .quiet
            shown += 1
            if quiet { shownQuiet += 1 } else { shownDistracted += 1 }
            if targets[i].heldAtSec != nil {
                held += 1
                if quiet { heldQuiet += 1 } else { heldDistracted += 1 }
            }
            if let latency = targets[i].latencySec {
                if latency < r.anticipationSec {
                    guessed += 1
                } else if quiet {
                    latencies.append(latency * 1000)
                }
            }
        }
        put(.holdShare, share(held, shown))
        put(.holdShareQuiet, share(heldQuiet, shownQuiet))
        put(.holdShareDistracted, share(heldDistracted, shownDistracted))
        put(.anticipationShare, share(guessed, shown))
        if latencies.count >= 3 { put(.firstLookMs, CourseStats.median(latencies)) }
        if latencies.count >= 5 {
            put(.latencySdMs, CourseStats.sd(latencies))
            if let q1 = CourseStats.quantile(latencies, 0.25), let q3 = CourseStats.quantile(latencies, 0.75) {
                put(.latencyIqrMs, q3 - q1)
            }
        }

        var counted = 0, pulled = 0
        var returns: [Double] = []
        for d in distractors where d.scorable {
            counted += 1
            if d.pulledAtSec != nil {
                pulled += 1
                if let back = d.returnSec { returns.append(back * 1000) }
            }
        }
        put(.distractorEvents, Double(counted))
        put(.distractorPullShare, share(pulled, counted))
        put(.distractorReturnMs, CourseStats.median(returns))

        put(.pursuitOnShare, share(pursuitOn, pursuitFrames))
        if pursuitFrames > 0, fitTimes.count * 2 >= pursuitFrames,
           let x = Self.follow(times: fitTimes, values: fitX, harmonics: r.xHarmonics, amplitudes: r.xAmplitudesDeg,
                               phases: plan.xPhases, windowSec: r.pursuitWindowSec),
           let y = Self.follow(times: fitTimes, values: fitY, harmonics: r.yHarmonics, amplitudes: r.yAmplitudesDeg,
                               phases: plan.yPhases, windowSec: r.pursuitWindowSec) {
            var power = 0.0, weight = 0.0, lag = 0.0, lagWeight = 0.0
            for part in x + y {
                power += part.weight * part.gain * part.gain
                weight += part.weight
                lag += part.weight * part.gain * part.lagSec
                lagWeight += part.weight * part.gain
            }
            if weight > 0 {
                put(.pursuitGain, (power / weight).squareRoot())
                if lagWeight > 1e-9 * weight { put(.pursuitLagMs, 1000 * lag / lagWeight) }
            }
        }

        if let first = firstT, lastT - first >= 1 {
            let length = lastT - first
            put(.lookAwaysPerMin, Double(lookAways) * 60 / length)
            put(.awayShare, awaySec / length)
            put(.fps, Double(frames - 1) / length)
        }
        put(.validShare, share(validFrames, frames))
        put(.radiusDeg, radiusDeg)
        return m
    }
}

/// Whether a probe's numbers belong on the course chart. A session that fails is kept, with its numbers, but
/// drawn hollow and left out of the trend: a poor calibration or a dropped frame rate would otherwise pass for a
/// change in the child.
public enum ProbeQuality {
    public enum Issue: String, Sendable, CaseIterable {
        /// The calibration check showed more error than allowed, or there was no check.
        case calibration
        /// The eyes were nearer or farther than the range the field is built for.
        case distance
        /// Too many frames without a gaze point.
        case tracking
        /// The tracking ran too slowly to time looks (night vision runs at 30 frames a second, for one).
        case frameRate
        /// The probe was stopped before its end.
        case incomplete
    }

    public static let distanceRangeCm = 25.0...40.0
    public static let minValidShare = 0.75
    public static let minFps = 50.0

    /// `maxErrorCm`: 1.5 for a child, 1.0 for an adult (the accuracy the tracker is built to).
    public static func issues(conditions: Conditions, metrics: [String: Double], completed: Bool,
                              maxErrorCm: Double = 1.5) -> [Issue] {
        var issues: [Issue] = []
        if !((conditions.calibrationErrorCm ?? .infinity) <= maxErrorCm) { issues.append(.calibration) }
        if !(conditions.distanceCm.map { distanceRangeCm.contains($0) } ?? false) { issues.append(.distance) }
        if !((metrics[ProbeMetric.validShare.rawValue] ?? 0) >= minValidShare) { issues.append(.tracking) }
        if !((metrics[ProbeMetric.fps.rawValue] ?? conditions.trackingFps ?? 0) >= minFps) { issues.append(.frameRate) }
        if !completed { issues.append(.incomplete) }
        return issues
    }

    /// The calibration limit the gate judges by: 1.5 cm for a child, 1.0 for an adult (a clinician trying the
    /// probe on themselves). The session's record and the export must use the same rule, or a failed session
    /// shows no reason.
    public static func maxErrorCm(sessionStart: Date, birthYear: Int?) -> Double {
        let year = Calendar.current.component(.year, from: sessionStart)
        let adult = birthYear.map { year - $0 >= 18 } ?? false
        return adult ? 1.0 : 1.5
    }
}
