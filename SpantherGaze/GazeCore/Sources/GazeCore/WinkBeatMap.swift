import Foundation

// Wink Beat beatmaps: hit circles, sliders and spinners on a 0...1 play field, timed in seconds of track time.
// One JSON file per song (`Resources/winkbeat-<id>.json`), written by `tools/winkbeat/make_map.py` and tuned by hand.
// Plain Swift like the rest of GazeCore, so maps are parsed and checked in the Linux tests.

/// A Wink Beat difficulty: how dense the map may be and how forgiving the judge is. All numbers are data, so a
/// child's level is a different row here, never a different code path.
public enum WinkBeatDifficulty: String, Codable, Sendable, CaseIterable {
    case easy, normal, hard

    /// Shortest time from one object's end to the next object's start (s).
    public var minGapSec: Double { switch self { case .easy: return 1.0; case .normal: return 0.55; case .hard: return 0.4 } }
    /// Most winks (circles and slider heads) per second over any 5 s window. Winking faster than about twice a
    /// second is hard for anyone, and much slower for children.
    public var maxWinksPerSec: Double { switch self { case .easy: return 0.85; case .normal: return 1.3; case .hard: return 2.0 } }
    /// Seconds an object is on screen before its time (the approach ring shrinks over this).
    public var leadSec: Double { switch self { case .easy: return 1.8; case .normal: return 1.35; case .hard: return 1.05 } }
    /// Hit zone radius before the calibration's error is added (screen pt).
    public var zoneBasePt: Double { switch self { case .easy: return 90; case .normal: return 70; case .hard: return 55 } }
    /// Judgement windows around the beat (s), after the player's learned delay. About 1.6 times a key press game's:
    /// a wink is slower and less precise than a finger. Phone CSVs tune these.
    public var perfectSec: Double { switch self { case .easy: return 0.12; case .normal: return 0.09; case .hard: return 0.08 } }
    public var greatSec: Double { switch self { case .easy: return 0.2; case .normal: return 0.16; case .hard: return 0.14 } }
    public var goodSec: Double { switch self { case .easy: return 0.3; case .normal: return 0.24; case .hard: return 0.21 } }
    /// A deliberate long blink plays `any` objects: for children who cannot close one eye alone.
    public var acceptsLongBlink: Bool { self == .easy }
    /// The track fails when the energy bar empties. Easy never fails.
    public var failable: Bool { self != .easy }
    /// Energy lost per second of play, and per miss.
    public var drainPerSec: Double { switch self { case .easy: return 0; case .normal: return 0.012; case .hard: return 0.02 } }
    public var missEnergy: Double { switch self { case .easy: return 0.06; case .normal: return 0.12; case .hard: return 0.16 } }
    /// Gaze hops between spinner petals asked per second of spinner.
    public var spinnerHopsPerSec: Double { switch self { case .easy: return 2.0; case .normal: return 2.5; case .hard: return 3.0 } }
    /// Fastest slider orb, in screen widths per second: eyes follow a target well up to about this speed.
    public var maxSliderSpeed: Double { switch self { case .easy: return 0.45; case .normal: return 0.6; case .hard: return 0.8 } }
    /// The same eye at most this many times in a row (fatigue). Easy uses `any` everywhere.
    public var maxSameEyeRun: Int { switch self { case .easy: return 0; case .normal: return 4; case .hard: return 4 } }

    // Since 2026-11-26 (Aziz's first phone runs): most players close both eyes on the beat, one-eye winks came out
    // half closed, and the tracked aim sat about 1.6 cm above the circles. Below Hard any closure plays, the eye
    // colours do not matter, and only the object due next can be locked, from far and from past the screen edge.

    /// A closure of both eyes (an ordinary blink) plays objects, and any eye plays any object. Hard keeps the
    /// left and right eye colours and never takes a blink.
    public var blinksPlay: Bool { self != .hard }
    /// Only the next object due can be locked, and from `WinkBeatRules.assistPt` away.
    public var lockAssist: Bool { self != .hard }
    /// Seconds after the first object during which the energy bar cannot empty, so a first try is never over
    /// in a few beats.
    public var noFailSec: Double { 30 }
}

public enum WinkBeatKind: String, Codable, Sendable, CaseIterable {
    /// Look at it and wink as the approach ring closes.
    case circle
    /// Wink on the head, then follow the moving orb with the gaze to the end.
    case slider
    /// Hop the gaze from petal to petal around a ring until it ends. No wink.
    case spinner
}

/// One object of a chart. `time` and `end` are seconds of track time as heard (0 = first sample of the audio file).
/// `x`, `y`: the 0...1 play field, x left to right, y top to bottom (spinners sit in the middle and ignore them).
public struct WinkBeatObject: Codable, Equatable, Sendable {
    public var kind: WinkBeatKind
    public var time: Double
    public var x: Double
    public var y: Double
    /// Which eye plays it. Spinners take no wink and are always `any`.
    public var side: NoteSide
    /// Slider and spinner end (s).
    public var end: Double?
    /// Slider: the points the orb passes through after the head, in order (play field). The path is a smooth
    /// curve through the head and these points.
    public var path: [[Double]]?
    /// Slider: how many times the orb turns back at an end (0 = head to tail once).
    public var repeats: Int?

    public init(kind: WinkBeatKind, time: Double, x: Double = 0.5, y: Double = 0.5, side: NoteSide = .any,
                end: Double? = nil, path: [[Double]]? = nil, repeats: Int? = nil) {
        self.kind = kind; self.time = time; self.x = x; self.y = y; self.side = side
        self.end = end; self.path = path; self.repeats = repeats
    }

    enum CodingKeys: String, CodingKey { case kind, time, x, y, side, end, path, repeats }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(WinkBeatKind.self, forKey: .kind)
        time = try c.decode(Double.self, forKey: .time)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        side = try c.decodeIfPresent(NoteSide.self, forKey: .side) ?? .any
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        path = try c.decodeIfPresent([[Double]].self, forKey: .path)
        repeats = try c.decodeIfPresent(Int.self, forKey: .repeats)
    }

    /// When the object is over: `end` for sliders and spinners, `time` for circles.
    public var endTime: Double { kind == .circle ? time : (end ?? time) }
    /// Circles and sliders start with a wink; spinners do not.
    public var needsWink: Bool { kind != .spinner }
}

/// Maps the 0...1 play field to screen points. The field covers the whole screen; maps keep objects inside
/// 0.08...0.92 so zones stay on screen.
public struct WinkBeatField: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    /// An iPhone 13 in landscape (pt): what maps are checked against.
    public static let reference = WinkBeatField(width: 844, height: 390)
    public func point(_ x: Double, _ y: Double) -> Vec2 { Vec2(x * width, y * height) }
    public func point(_ p: [Double]) -> Vec2 { point(p.count > 0 ? p[0] : 0.5, p.count > 1 ? p[1] : 0.5) }
}

/// A smooth slider path through points (screen pt): a Catmull-Rom curve, sampled and measured by arc length so the
/// orb moves at an even speed.
public struct WinkBeatPath: Equatable, Sendable {
    public let samples: [Vec2]
    /// Arc length from the start to each sample (pt).
    public let distances: [Double]
    public var length: Double { distances.last ?? 0 }

    public init(points: [Vec2], samplesPerSegment: Int = 16) {
        guard points.count >= 2 else {
            samples = points.isEmpty ? [.zero] : points
            distances = Array(repeating: 0, count: max(1, points.count))
            return
        }
        var s: [Vec2] = [points[0]]
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
            for k in 1...samplesPerSegment {
                let t = Double(k) / Double(samplesPerSegment), t2 = t * t, t3 = t2 * t
                // Uniform Catmull-Rom: passes through p1 at t = 0 and p2 at t = 1.
                let a = p1 * 2
                let b = (p2 - p0) * t
                let c = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
                let d = (p1 * 3 - p0 - p2 * 3 + p3) * t3
                s.append((a + b + c + d) * 0.5)
            }
        }
        var d: [Double] = [0]
        for i in 1..<s.count { d.append(d[i - 1] + s[i].distance(to: s[i - 1])) }
        samples = s
        distances = d
    }

    /// The point `distance` pt along the path, clamped to its ends.
    public func position(atDistance distance: Double) -> Vec2 {
        guard samples.count > 1, length > 0 else { return samples[0] }
        let target = min(max(0, distance), length)
        var lo = 0, hi = distances.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if distances[mid] <= target { lo = mid } else { hi = mid }
        }
        let span = distances[hi] - distances[lo]
        let f = span > 0 ? (target - distances[lo]) / span : 0
        return samples[lo] + (samples[hi] - samples[lo]) * f
    }

    /// Where the orb is at `progress` (0 at the head time, 1 at the end), turning back `repeats` times.
    public func position(progress: Double, repeats: Int = 0) -> Vec2 {
        let spans = Double(max(0, repeats) + 1)
        let s = min(max(0, progress), 1) * spans
        let span = min(floor(s), spans - 1)
        var f = s - span
        if Int(span) % 2 == 1 { f = 1 - f }
        return position(atDistance: f * length)
    }
}

/// A problem found in a chart. `index` is the object it is about, nil for the whole chart.
public struct WinkBeatIssue: Equatable, Sendable, CustomStringConvertible {
    public var index: Int?
    public var message: String
    public init(_ index: Int?, _ message: String) { self.index = index; self.message = message }
    public var description: String { index.map { "#\($0): \(message)" } ?? message }
}

/// One song with its charts.
public struct WinkBeatMap: Codable, Equatable, Sendable {
    public var format: Int
    public var id: String
    public var title: String
    public var author: String
    public var license: String
    /// Audio file in the app bundle.
    public var audio: String
    public var bpm: Double
    /// Track time of the first beat (s): the grid for metronome, slider ticks and visual pulses.
    public var firstBeatSec: Double
    public var durationSec: Double
    /// Objects per difficulty, keyed by `WinkBeatDifficulty.rawValue`.
    public var charts: [String: [WinkBeatObject]]

    public init(format: Int = 1, id: String, title: String, author: String, license: String, audio: String,
                bpm: Double, firstBeatSec: Double, durationSec: Double, charts: [String: [WinkBeatObject]]) {
        self.format = format; self.id = id; self.title = title; self.author = author; self.license = license
        self.audio = audio; self.bpm = bpm; self.firstBeatSec = firstBeatSec; self.durationSec = durationSec
        self.charts = charts
    }

    public var beatSec: Double { 60 / bpm }

    public static func load(from data: Data) throws -> WinkBeatMap {
        try JSONDecoder().decode(WinkBeatMap.self, from: data)
    }

    public func chart(_ d: WinkBeatDifficulty) -> [WinkBeatObject] { charts[d.rawValue] ?? [] }

    /// Checks a chart against the difficulty's rules on the reference screen. An empty list means it is playable.
    public func validate(_ d: WinkBeatDifficulty, field: WinkBeatField = .reference) -> [WinkBeatIssue] {
        let objects = chart(d)
        var issues: [WinkBeatIssue] = []
        if objects.isEmpty { return [WinkBeatIssue(nil, "no objects")] }
        if bpm <= 0 { issues.append(WinkBeatIssue(nil, "bpm must be positive")) }
        func inField(_ x: Double, _ y: Double) -> Bool { (0.08...0.92).contains(x) && (0.08...0.92).contains(y) }
        var winkTimes: [Double] = []
        var run = (side: NoteSide.any, count: 0)
        var lefts = 0, rights = 0
        for (i, o) in objects.enumerated() {
            if o.time < 0 || o.endTime > durationSec { issues.append(WinkBeatIssue(i, "outside the track")) }
            if i > 0 {
                let prev = objects[i - 1]
                if o.time < prev.time { issues.append(WinkBeatIssue(i, "not sorted by time")) }
                let gap = o.time - prev.endTime
                if gap < d.minGapSec - 1e-6 {
                    issues.append(WinkBeatIssue(i, String(format: "starts %.2f s after the previous object ends (min %.2f)",
                                                          gap, d.minGapSec)))
                }
            }
            switch o.kind {
            case .circle:
                if !inField(o.x, o.y) { issues.append(WinkBeatIssue(i, "position outside 0.08...0.92")) }
            case .slider:
                guard let end = o.end, end > o.time else { issues.append(WinkBeatIssue(i, "slider needs end after time")); break }
                guard let path = o.path, !path.isEmpty, path.allSatisfy({ $0.count == 2 }) else {
                    issues.append(WinkBeatIssue(i, "slider needs a path of [x, y] points")); break
                }
                if !inField(o.x, o.y) || !path.allSatisfy({ inField($0[0], $0[1]) }) {
                    issues.append(WinkBeatIssue(i, "slider path outside 0.08...0.92"))
                }
                let curve = WinkBeatPath(points: [field.point(o.x, o.y)] + path.map(field.point))
                let speed = curve.length * Double((o.repeats ?? 0) + 1) / (end - o.time) / field.width
                if speed > d.maxSliderSpeed + 1e-6 {
                    issues.append(WinkBeatIssue(i, String(format: "slider orb too fast: %.2f widths/s (max %.2f)",
                                                          speed, d.maxSliderSpeed)))
                }
            case .spinner:
                guard let end = o.end, end - o.time >= 1.0 else { issues.append(WinkBeatIssue(i, "spinner needs 1 s or more")); break }
                if o.side != .any { issues.append(WinkBeatIssue(i, "spinners take no wink: side must be any")) }
            }
            guard o.needsWink else { continue }
            winkTimes.append(o.time)
            if d == .easy, o.side != .any { issues.append(WinkBeatIssue(i, "easy uses side any")) }
            if o.side == .left { lefts += 1 } else if o.side == .right { rights += 1 }
            if o.side != .any, o.side == run.side { run.count += 1 } else { run = (o.side, 1) }
            if d.maxSameEyeRun > 0, o.side != .any, run.count > d.maxSameEyeRun {
                issues.append(WinkBeatIssue(i, "same eye \(run.count) times in a row (max \(d.maxSameEyeRun))"))
            }
        }
        // Density: winks in any 5 s window.
        var lo = 0
        for (hi, t) in winkTimes.enumerated() {
            while t - winkTimes[lo] >= 5 { lo += 1 }
            let count = hi - lo + 1
            if Double(count) > d.maxWinksPerSec * 5 + 1e-6 {
                issues.append(WinkBeatIssue(nil, String(format: "%d winks in 5 s around %.1f s (max %.0f)",
                                                        count, t, d.maxWinksPerSec * 5)))
                break
            }
        }
        if lefts + rights >= 10 {
            let share = Double(lefts) / Double(lefts + rights)
            if share < 0.35 || share > 0.65 { issues.append(WinkBeatIssue(nil, "left and right eyes unbalanced")) }
        }
        // Objects on screen together must not share a hit zone, or the lock cannot tell them apart.
        let zone = d.zoneBasePt
        for i in objects.indices where objects[i].needsWink {
            var j = i + 1
            while j < objects.count, objects[j].time - objects[i].endTime < d.leadSec {
                let a = objects[i], b = objects[j]
                if b.needsWink {
                    let tail = a.kind == .slider ? WinkBeatPlay.tail(of: a, field: field) : field.point(a.x, a.y)
                    if field.point(b.x, b.y).distance(to: tail) < 2 * zone ||
                        field.point(b.x, b.y).distance(to: field.point(a.x, a.y)) < 2 * zone {
                        issues.append(WinkBeatIssue(j, "hit zone overlaps object #\(i)"))
                    }
                }
                j += 1
            }
        }
        return issues
    }
}
