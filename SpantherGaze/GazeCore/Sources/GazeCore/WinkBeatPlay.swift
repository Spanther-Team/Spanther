import Foundation

// Wink Beat judging: one play of one chart. The app feeds it closures (from `WinkBeatEyes`) and one call per frame
// with the track time and the blink-safe aim; it returns what happened for the screen to draw. Everything is in
// screen points and seconds of track time; the 3D stage and head parallax never reach it.

/// How an object was played. Points: 300, 100, 50, 0.
public enum WinkBeatGrade: String, Codable, Sendable, CaseIterable {
    case perfect, great, good, miss

    public var points: Int { switch self { case .perfect: return 300; case .great: return 100; case .good: return 50; case .miss: return 0 } }
    /// One step down, used when a slider was followed only part of the way. Good stays good.
    var lower: WinkBeatGrade { switch self { case .perfect: return .great; case .great: return .good; default: return self } }
}

/// The final letter. Our own thresholds on accuracy: SS 100%, S 95% with no miss, A 90%, B 80%, C 70%, D below.
public enum WinkBeatRank: String, Codable, Sendable, CaseIterable {
    case ss, s, a, b, c, d

    public static func of(accuracy: Double, misses: Int) -> WinkBeatRank {
        if accuracy >= 1 - 1e-9 { return .ss }
        if accuracy >= 0.95, misses == 0 { return .s }
        if accuracy >= 0.90 { return .a }
        if accuracy >= 0.80 { return .b }
        if accuracy >= 0.70 { return .c }
        return .d
    }

    /// As shown on the results screen.
    public var label: String { rawValue.uppercased() }
}

/// The judge's numbers for one play: the difficulty's windows and the zone sized to this player's calibration.
public struct WinkBeatRules: Equatable, Sendable {
    public var difficulty: WinkBeatDifficulty
    public var perfectSec: Double
    public var greatSec: Double
    public var goodSec: Double
    /// A wink plays an object only when the aim (just before the lid came down) is this close to it (pt).
    public var zonePt: Double
    /// A slider counts as followed while the aim is this close to the orb (pt): wider than the zone, because
    /// following a moving target lags a little.
    public var followPt: Double
    /// Spinner: petal ring radius (pt). The aim stands on the petal whose sector (an eighth of the circle around
    /// the centre) holds it, once it is at least `spinnerInnerPt` from the centre. Sectors, not small targets,
    /// because a calibration bias of 40 pt must not stop a hop from landing.
    public var spinnerRadiusPt: Double
    public var spinnerInnerPt: Double
    public var petals = 8
    /// Long blink: both eyes closed at least this long plays `any` objects on levels that accept it (s).
    public var longBlinkSec = 0.3

    /// Rules for a difficulty on a field. The zone grows by the calibration's measured error (capped at 90 pt) and
    /// never drops under the balance floor (calibration miss + 1.5 x spread, `BalanceConfig.zoneFloor`).
    public static func make(_ d: WinkBeatDifficulty, field: WinkBeatField, measuredErrorPt: Double = 0,
                            zoneFloorPt: Double = 0) -> WinkBeatRules {
        let zone = max(d.zoneBasePt + max(0, min(measuredErrorPt, 90)), zoneFloorPt)
        let radius = 0.32 * min(field.width, field.height)
        return WinkBeatRules(difficulty: d, perfectSec: d.perfectSec, greatSec: d.greatSec, goodSec: d.goodSec,
                             zonePt: zone, followPt: zone * 1.5, spinnerRadiusPt: radius, spinnerInnerPt: 0.3 * radius)
    }
}

/// A closure that may play an object: a one-eye wink, or a long blink (`side == .both`). `aim` is the aim from
/// just before the lid came down (`WinkBeatEyes` takes it), `time` the closure onset in track time.
public struct WinkBeatClosure: Equatable, Sendable {
    public var side: WinkSide
    public var time: Double
    public var aim: Vec2?
    public init(side: WinkSide, time: Double, aim: Vec2?) { self.side = side; self.time = time; self.aim = aim }
}

public enum WinkBeatEvent: Equatable, Sendable {
    /// An object's final judgement. `offsetSec`: wink time minus object time, nil when no wink played it.
    case judged(index: Int, grade: WinkBeatGrade, offsetSec: Double?)
    /// A slider's head was played (or missed); the slider goes on until its end.
    case head(index: Int, grade: WinkBeatGrade, offsetSec: Double?)
    /// A slider tick on the beat: whether the aim was on the orb.
    case sliderTick(index: Int, held: Bool)
    /// The aim reached a new petal around the ring. `hops`: best net hops in one direction so far, `needed`: hops
    /// asked for a full grade.
    case spinnerHop(index: Int, petal: Int, hops: Int, needed: Int)
    /// A closure in an object's window that could not play it.
    case rejected(index: Int, reason: WinkBeatRejection)
    /// The energy bar emptied on a level that fails.
    case failed
}

public enum WinkBeatRejection: String, Sendable {
    /// The other eye than the object asks for.
    case wrongEye
    /// A long blink where the object needs one eye, or on a level that does not take long blinks.
    case blink
    /// The aim was not on any object in the window.
    case offTarget
}

public struct WinkBeatPlay: Sendable {
    public let objects: [WinkBeatObject]
    public let rules: WinkBeatRules
    public let field: WinkBeatField
    public let beatSec: Double
    /// Head (circle, slider) or centre (spinner) of each object (pt).
    public let positions: [Vec2]
    /// Slider paths (pt); nil for other objects.
    public let paths: [WinkBeatPath?]

    /// The player's usual delay from the beat to the lid crossing the closed line (s), learned from hits and
    /// carried to the next play.
    public private(set) var latencySec: Double
    public private(set) var results: [WinkBeatGrade?]
    public private(set) var offsets: [Double?]
    public private(set) var playedBy: [WinkSide?]
    public private(set) var combo = 0
    public private(set) var maxCombo = 0
    public private(set) var score = 0
    /// 0...1. Starts full, drains on the levels that fail, refills on hits.
    public private(set) var energy = 1.0
    public private(set) var failed = false
    public private(set) var offTarget = 0
    public private(set) var wrongEye = 0
    /// Winks far from any object's window.
    public private(set) var stray = 0
    public private(set) var closuresLeft = 0
    public private(set) var closuresRight = 0
    public private(set) var longBlinks = 0

    private var heads: [WinkBeatGrade?]
    private var follow: [(inside: Double, total: Double)]
    private var nextTick: [Int]
    private var spinner: [(petal: Int?, net: Int, best: Int)]
    private var lastTime: Double?
    private var first = 0

    public init(objects: [WinkBeatObject], rules: WinkBeatRules, field: WinkBeatField, beatSec: Double,
                latencySec: Double = 0.08) {
        self.objects = objects
        self.rules = rules
        self.field = field
        self.beatSec = beatSec > 0 ? beatSec : 0.5
        self.latencySec = latencySec
        positions = objects.map { $0.kind == .spinner ? field.point(0.5, 0.5) : field.point($0.x, $0.y) }
        paths = objects.map { o in
            guard o.kind == .slider else { return nil }
            return WinkBeatPath(points: [field.point(o.x, o.y)] + (o.path ?? []).map(field.point))
        }
        let n = objects.count
        results = Array(repeating: nil, count: n)
        offsets = Array(repeating: nil, count: n)
        playedBy = Array(repeating: nil, count: n)
        heads = Array(repeating: nil, count: n)
        follow = Array(repeating: (0, 0), count: n)
        nextTick = Array(repeating: 1, count: n)
        spinner = Array(repeating: (nil, 0, 0), count: n)
    }

    /// A play of one chart of a map.
    public init(map: WinkBeatMap, difficulty: WinkBeatDifficulty, field: WinkBeatField, measuredErrorPt: Double = 0,
                zoneFloorPt: Double = 0, latencySec: Double = 0.08) {
        self.init(objects: map.chart(difficulty),
                  rules: .make(difficulty, field: field, measuredErrorPt: measuredErrorPt, zoneFloorPt: zoneFloorPt),
                  field: field, beatSec: map.beatSec, latencySec: latencySec)
    }

    /// Where a slider's orb ends (pt): its last path point, or its head after an odd number of turns.
    public static func tail(of o: WinkBeatObject, field: WinkBeatField) -> Vec2 {
        guard o.kind == .slider, let last = o.path?.last else { return field.point(o.x, o.y) }
        return (o.repeats ?? 0) % 2 == 1 ? field.point(o.x, o.y) : field.point(last)
    }

    // MARK: - Geometry for the screen

    /// The beat a wink is judged against: the object's time plus the player's delay.
    public func expected(_ i: Int) -> Double { objects[i].time + latencySec }

    /// The slider orb (pt) at track time `t`.
    public func orb(_ i: Int, at t: Double) -> Vec2? {
        guard let path = paths[i], let end = objects[i].end, end > objects[i].time else { return nil }
        return path.position(progress: (t - objects[i].time) / (end - objects[i].time), repeats: objects[i].repeats ?? 0)
    }

    /// Spinner petal `k` (pt), counted clockwise from the top.
    public func petal(_ i: Int, _ k: Int) -> Vec2 {
        let a = 2 * Double.pi * Double(k) / Double(rules.petals) - Double.pi / 2
        return positions[i] + Vec2(cos(a), sin(a)) * rules.spinnerRadiusPt
    }

    /// Hops a spinner asks for: its length times the difficulty's hop rate, at least half a ring.
    public func hopsNeeded(_ i: Int) -> Int {
        let o = objects[i]
        return max(rules.petals / 2, Int(((o.endTime - o.time) * rules.difficulty.spinnerHopsPerSec).rounded()))
    }

    /// Objects to draw at `t`: those whose approach has begun and which are not finished.
    public func visible(at t: Double) -> [Int] {
        objects.indices.filter { i in
            results[i] == nil && t >= objects[i].time - rules.difficulty.leadSec
        }
    }

    /// Lock targets for `GazeLock`: unplayed circles and slider heads in reach of their window.
    public func lockTargets(at t: Double) -> [GazeLock.Target] {
        objects.indices.compactMap { i in
            guard objects[i].needsWink, results[i] == nil, heads[i] == nil,
                  t >= objects[i].time - rules.difficulty.leadSec, t <= expected(i) + rules.goodSec else { return nil }
            return GazeLock.Target(id: i, position: positions[i], reach: rules.zonePt)
        }
    }

    // MARK: - Input

    /// A closure that may play an object. `prefer`: the object the aim is locked on (`GazeLock`); it is played
    /// when its window holds the closure, even if an earlier object's window does too.
    @discardableResult
    public mutating func closure(_ c: WinkBeatClosure, prefer: Int? = nil) -> [WinkBeatEvent] {
        guard !failed else { return [] }
        switch c.side {
        case .left: closuresLeft += 1
        case .right: closuresRight += 1
        case .both: longBlinks += 1
        }
        var sideOK: [Int] = []
        var rejected: (Int, WinkBeatRejection)?
        var i = first
        while i < objects.count, expected(i) < c.time - rules.goodSec { i += 1 }
        while i < objects.count, expected(i) <= c.time + rules.goodSec {
            defer { i += 1 }
            let o = objects[i]
            guard o.needsWink, results[i] == nil, heads[i] == nil else { continue }
            if c.side == .both {
                guard o.side == .any, rules.difficulty.acceptsLongBlink else {
                    if rejected == nil || i == prefer { rejected = (i, .blink) }
                    continue
                }
            } else if o.side != .any, o.side.rawValue != c.side.rawValue {
                if rejected == nil || i == prefer { rejected = (i, .wrongEye) }
                continue
            }
            sideOK.append(i)
        }
        let aimed = sideOK.filter { k in c.aim.map { $0.distance(to: positions[k]) <= rules.zonePt } ?? false }
        guard let k = aimed.contains(where: { $0 == prefer }) ? prefer : aimed.first else {
            if let r = rejected, sideOK.isEmpty {
                if r.1 == .wrongEye { wrongEye += 1 }
                return [.rejected(index: r.0, reason: r.1)]
            }
            if let s = sideOK.first {
                offTarget += 1
                return [.rejected(index: s, reason: .offTarget)]
            }
            if c.side != .both { stray += 1 }
            return []
        }
        let offset = c.time - objects[k].time
        let d = abs(c.time - expected(k))
        let grade: WinkBeatGrade = d <= rules.perfectSec ? .perfect : d <= rules.greatSec ? .great : .good
        // Learn the delay slowly and within reason, so one odd wink does not move the windows.
        latencySec = min(0.3, max(-0.05, latencySec + 0.15 * (offset - latencySec)))
        offsets[k] = offset
        playedBy[k] = c.side
        if objects[k].kind == .slider {
            heads[k] = grade
            return [.head(index: k, grade: grade, offsetSec: offset)]
        }
        return record(k, grade, offset)
    }

    /// One frame at track time `t` with the blink-safe aim (pt, nil when there is none). Declares misses, follows
    /// sliders and spinners, drains energy. Call it every frame, after the frame's closures.
    @discardableResult
    public mutating func frame(time t: Double, aim: Vec2?) -> [WinkBeatEvent] {
        guard !failed else { return [] }
        let dt = lastTime.map { min(0.1, max(0, t - $0)) } ?? 0
        lastTime = t
        var events: [WinkBeatEvent] = []
        // A long blink is known only once it has lasted; wait that long before calling a miss.
        let wait = rules.goodSec + (rules.difficulty.acceptsLongBlink ? rules.longBlinkSec : 0)
        for i in first..<objects.count {
            let o = objects[i]
            if o.time - rules.difficulty.leadSec > t { break }
            guard results[i] == nil else { continue }
            switch o.kind {
            case .circle:
                if expected(i) + wait < t { events += record(i, .miss, nil) }
            case .slider:
                if heads[i] == nil, expected(i) + wait < t {
                    heads[i] = .miss
                    events.append(.head(index: i, grade: .miss, offsetSec: nil))
                }
                events += followSlider(i, t: t, dt: dt, aim: aim)
            case .spinner:
                events += spin(i, t: t, aim: aim)
            }
        }
        while first < objects.count, results[first] != nil { first += 1 }
        if dt > 0, rules.difficulty.drainPerSec > 0, let start = objects.first?.time, let stop = objects.last?.endTime,
           t >= start, t <= stop {
            events += changeEnergy(-rules.difficulty.drainPerSec * dt)
        }
        return events
    }

    private mutating func followSlider(_ i: Int, t: Double, dt: Double, aim: Vec2?) -> [WinkBeatEvent] {
        let o = objects[i]
        guard let end = o.end, t >= o.time, let orbNow = orb(i, at: t) else { return [] }
        var events: [WinkBeatEvent] = []
        let inside = aim.map { $0.distance(to: orbNow) <= rules.followPt } ?? false
        if t <= end {
            follow[i].total += dt
            if inside { follow[i].inside += dt }
        }
        // Ticks on the beat between head and end.
        while o.time + Double(nextTick[i]) * beatSec < end - 1e-6, o.time + Double(nextTick[i]) * beatSec <= t {
            nextTick[i] += 1
            events.append(.sliderTick(index: i, held: inside))
            if inside {
                score += 10
                events += changeEnergy(0.005)
            }
        }
        if t >= end, heads[i] != nil {
            let share = follow[i].total > 0 ? follow[i].inside / follow[i].total : (inside ? 1 : 0)
            let head = heads[i] ?? .miss
            let grade: WinkBeatGrade
            if share >= 0.85 {
                grade = head == .miss ? .good : head
            } else if share >= 0.6 {
                grade = head == .miss ? .good : head.lower
            } else {
                grade = .miss
            }
            events += record(i, grade, offsets[i])
        }
        return events
    }

    /// The petal whose sector holds `aim`, or nil near the centre.
    public func petal(_ i: Int, holding aim: Vec2) -> Int? {
        let v = aim - positions[i]
        guard v.length >= rules.spinnerInnerPt else { return nil }
        var a = atan2(v.y, v.x) + Double.pi / 2
        if a < 0 { a += 2 * Double.pi }
        return Int((a / (2 * Double.pi / Double(rules.petals))).rounded()) % rules.petals
    }

    private mutating func spin(_ i: Int, t: Double, aim: Vec2?) -> [WinkBeatEvent] {
        let o = objects[i]
        guard t >= o.time else { return [] }
        var events: [WinkBeatEvent] = []
        let needed = hopsNeeded(i)
        if t <= o.endTime, let a = aim, let k = petal(i, holding: a), k != spinner[i].petal {
            if let p = spinner[i].petal {
                let n = rules.petals
                var step = ((k - p) % n + n) % n
                if step > n / 2 { step -= n }
                // A hop to a neighbour (or one skipped in a fast saccade) turns the ring; a jump across does not.
                if abs(step) <= 2 {
                    spinner[i].net += step
                    let net = abs(spinner[i].net)
                    // Only new progress scores, so jitter on a sector edge earns nothing.
                    if net > spinner[i].best {
                        for reached in (spinner[i].best + 1)...net {
                            score += 10
                            if reached > needed, (reached - needed) % n == 0 { score += 100 }
                        }
                        spinner[i].best = net
                        events.append(.spinnerHop(index: i, petal: k, hops: net, needed: needed))
                        events += changeEnergy(0.003)
                    }
                }
            }
            spinner[i].petal = k
        }
        if t > o.endTime {
            let progress = Double(spinner[i].best) / Double(needed)
            let grade: WinkBeatGrade = progress >= 1 ? .perfect : progress >= 0.66 ? .great : progress >= 0.33 ? .good : .miss
            events += record(i, grade, nil)
        }
        return events
    }

    private mutating func record(_ i: Int, _ g: WinkBeatGrade, _ offset: Double?) -> [WinkBeatEvent] {
        results[i] = g
        var events: [WinkBeatEvent] = [.judged(index: i, grade: g, offsetSec: offset)]
        if g == .miss {
            combo = 0
            events += changeEnergy(-rules.difficulty.missEnergy)
        } else {
            score += g.points + g.points * min(combo, 100) / 25
            combo += 1
            maxCombo = max(maxCombo, combo)
            events += changeEnergy(g == .perfect ? 0.05 : g == .great ? 0.03 : 0.01)
        }
        return events
    }

    private mutating func changeEnergy(_ delta: Double) -> [WinkBeatEvent] {
        energy = min(1, max(0, energy + delta))
        if energy <= 0, rules.difficulty.failable, !failed {
            failed = true
            return [.failed]
        }
        return []
    }

    // MARK: - Results

    public var finished: Bool { failed || results.allSatisfy { $0 != nil } }

    public func count(_ g: WinkBeatGrade) -> Int { results.filter { $0 == g }.count }

    /// Points earned over the most possible for the objects judged so far (1 before the first).
    public var accuracy: Double {
        let judged = results.compactMap { $0 }
        guard !judged.isEmpty else { return 1 }
        return Double(judged.map(\.points).reduce(0, +)) / Double(300 * judged.count)
    }

    /// The letter for the play so far; on a finished play, the final rank.
    public var rank: WinkBeatRank { WinkBeatRank.of(accuracy: accuracy, misses: count(.miss)) }

    /// Wink time minus object time of the winks that played objects (s).
    public var playedOffsets: [Double] { offsets.compactMap { $0 } }
}
