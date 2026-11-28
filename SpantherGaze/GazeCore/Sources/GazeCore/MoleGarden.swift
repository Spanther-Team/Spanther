import Foundation

// «Кроты»: moles pop out of six holes in a garden bed; the player looks at a hole and blinks (or winks) to bonk the
// mole in it. This is the rules core only; the 3D garden draws its state. The holes sit at fixed spots on the screen,
// so a hit is decided in screen points like every other eye target, and the drawing places its camera to match them.
// A hedgehog sometimes comes out instead of a mole: it must be left alone.

/// One level's pace. Level 1 is calm enough for a first play, level 10 is quick with three moles up at once.
public struct MoleLevel: Equatable, Sendable {
    /// How long a mole stays fully up (s).
    public var upSec: Double
    /// Time from one pop to the next (s), varied by ±25%.
    public var gapSec: Double
    /// Moles (and hedgehogs) up at once, at most.
    public var maxUp: Int
    /// Share of pops that are a hedgehog.
    public var decoyShare: Double
    /// Share of pops that are a golden mole (worth more).
    public var goldenShare: Double

    public init(upSec: Double, gapSec: Double, maxUp: Int, decoyShare: Double, goldenShare: Double) {
        self.upSec = upSec
        self.gapSec = gapSec
        self.maxUp = maxUp
        self.decoyShare = decoyShare
        self.goldenShare = goldenShare
    }

    /// Level `n` of `count`, on the S-curve the meteors use (BALANCE.md): calm early levels, steep middle.
    public static func level(_ n: Int, of count: Int = 10) -> MoleLevel {
        let t = count > 1 ? Double(min(max(n, 1), count) - 1) / Double(count - 1) : 0
        let d = t * t * (3 - 2 * t)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * d }
        return MoleLevel(upSec: lerp(2.4, 0.85),
                         gapSec: lerp(1.5, 0.55),
                         maxUp: n >= 8 ? 3 : n >= 4 ? 2 : 1,
                         decoyShare: n >= 7 ? 0.22 : n >= 3 ? 0.14 : 0,
                         goldenShare: 0.08)
    }
}

public struct MoleConfig: Equatable, Sendable {
    /// One round (s). The round always ends at this time; stars say how it went.
    public var roundSec = 120.0
    /// The first pop comes this long after the start (s).
    public var firstPopSec = 1.2
    /// A mole takes this long to come up, and as long to go down (s).
    public var riseSec = 0.22
    public var hideSec = 0.22
    /// A bonked mole sits dizzy this long before it goes down (s); its hole is busy meanwhile.
    public var dizzySec = 0.7
    /// A blink that began this soon after the mole started to go down still counts (s).
    public var lateGraceSec = 0.12
    /// The holes, as fractions of a landscape screen (x across, y down), row by row.
    public var holes: [Vec2] = [Vec2(0.25, 0.40), Vec2(0.5, 0.40), Vec2(0.75, 0.40),
                                Vec2(0.25, 0.76), Vec2(0.5, 0.76), Vec2(0.75, 0.76)]
    /// A hole's drawn radius as a share of the screen's height.
    public var holeRadius = 0.11
    /// Reach of a hole for the eye (its lock zone) as a share of its drawn radius, before the zone floor.
    public var reachScale = 1.3
    /// A blink that finds no mole in reach still bonks the nearest mole up within this many reaches of the aim
    /// (never a hedgehog): the game asks which creature the player looks at, not whether the aim fell inside a
    /// circle, the way gaze interaction picks objects (Tobii's G2OM). In Aziz's session of 2026-11-28 the aim sat
    /// 70 to 135 pt left of the left-hand holes (reach 56 pt) at his blinks; 2.3 reaches (128 pt) take most of those
    /// and stay under the 140 pt between two holes one above the other.
    public var assistScale = 2.3
    public var molePoints = 100
    public var goldenPoints = 300
    /// Taken away for bonking a hedgehog (the score never goes under 0).
    public var decoyPenalty = 150
    /// Extra points per mole in a row, and the cap of that extra.
    public var comboStep = 10
    public var comboCap = 100
    public var levels = 10

    public init() {}
}

public enum MoleKind: String, Sendable, Equatable {
    case mole, golden, hedgehog
}

/// One pop: a mole (or hedgehog) that comes out of `hole`.
public struct MolePop: Equatable, Sendable {
    public enum State: Equatable, Sendable { case rising, up, hiding, dizzy, gone }
    public var id: Int
    public var hole: Int
    public var kind: MoleKind
    /// Starts coming up (s).
    public var start: Double
    /// Starts going down (s), unless bonked first.
    public var hideAt: Double
    /// When it was bonked (the blink's onset), nil if not.
    public var bonkedAt: Double?

    /// How far out of the hole it is at `time`: 0 inside, 1 fully up. Drawing uses this.
    public func rise(at time: Double, config: MoleConfig) -> Double {
        if let b = bonkedAt {
            let leave = b + config.dizzySec
            return time < leave ? 1 : max(0, 1 - (time - leave) / config.hideSec)
        }
        if time < start { return 0 }
        if time < start + config.riseSec { return (time - start) / config.riseSec }
        if time < hideAt { return 1 }
        return max(0, 1 - (time - hideAt) / config.hideSec)
    }

    public func state(at time: Double, config: MoleConfig) -> State {
        if let b = bonkedAt {
            if time < b + config.dizzySec { return .dizzy }
            return time < b + config.dizzySec + config.hideSec ? .hiding : .gone
        }
        if time < start + config.riseSec { return .rising }
        if time < hideAt { return .up }
        return time < hideAt + config.hideSec ? .hiding : .gone
    }
}

public enum MoleEvent: Equatable, Sendable {
    case popped(MolePop)
    /// A mole bonked: the points it gave and the time from its start to the blink (s).
    case hit(MolePop, points: Int, reactionSec: Double)
    case hedgehogHit(MolePop)
    /// A blink on an empty hole, or away from every hole (nil).
    case whiff(hole: Int?)
    case escaped(MolePop)
    case hedgehogLeft(MolePop)
    case ended(MoleResult)
}

public struct MoleResult: Equatable, Sendable, Codable {
    public var level: Int
    public var score: Int
    public var hits: Int
    public var golden: Int
    public var escaped: Int
    public var whiffs: Int
    public var hedgehogHits: Int
    public var hedgehogsLeft: Int
    public var bestCombo: Int
    /// Mean time from a mole's start to the blink that bonked it (s), nil without hits.
    public var meanReactionSec: Double?
    public var durationSec: Double

    /// Share of moles bonked (hedgehogs aside).
    public var accuracy: Double {
        let moles = hits + escaped
        return moles > 0 ? Double(hits) / Double(moles) : 0
    }

    /// 0 to 3. One star opens the next level.
    public var stars: Int {
        let a = accuracy
        return a >= 0.85 ? 3 : a >= 0.7 ? 2 : a >= 0.5 ? 1 : 0
    }
}

/// The whole «Кроты» round without drawing. Call `update` every tracking frame with the eye's aim, and `bonk` for every
/// closure the eyes decide (blink or wink, with the aim from before its onset, as `WinkBeatEyes` gives it).
public struct MoleGarden: Sendable {
    public let config: MoleConfig
    public let level: Int
    public let pace: MoleLevel
    /// Screen size (pt), landscape.
    public let screen: Vec2
    /// The reach floor from the player's calibration (`BalanceConfig.zoneFloor`), 0 for touch.
    public var zoneFloor: Double
    public private(set) var pops: [MolePop] = []
    public private(set) var lockedHole: Int?
    public private(set) var score = 0
    public private(set) var combo = 0
    public private(set) var ended = false
    public let startTime: Double

    private var lock = GazeLock()
    private var random: SeededRandom
    private var nextPop: Double
    private var nextID = 0
    private var lastHole: Int?
    private var tally = MoleResult(level: 0, score: 0, hits: 0, golden: 0, escaped: 0, whiffs: 0, hedgehogHits: 0,
                                   hedgehogsLeft: 0, bestCombo: 0, meanReactionSec: nil, durationSec: 0)
    private var reactionSum = 0.0

    public init(level: Int, screen: Vec2, startTime: Double, seed: UInt64, zoneFloor: Double = 0,
                config: MoleConfig = MoleConfig()) {
        self.config = config
        self.level = min(max(level, 1), config.levels)
        pace = MoleLevel.level(self.level, of: config.levels)
        self.screen = screen
        self.startTime = startTime
        self.zoneFloor = zoneFloor
        random = SeededRandom(seed: seed)
        nextPop = startTime + config.firstPopSec
        tally.level = self.level
    }

    /// Hole `i`'s centre on the screen (pt).
    public func holeCenter(_ i: Int) -> Vec2 {
        let h = config.holes[i]
        return Vec2(h.x * screen.x, h.y * screen.y)
    }

    /// Drawn radius of a hole (pt).
    public var holeRadiusPt: Double { config.holeRadius * screen.y }

    /// How far from a hole's centre the eye still counts as on it (pt).
    public var reach: Double { max(holeRadiusPt * config.reachScale, zoneFloor) }

    /// Seconds left in the round at `time`.
    public func remaining(at time: Double) -> Double { max(0, startTime + config.roundSec - time) }

    /// The pop drawn in `hole` at `time`, if any.
    public func pop(in hole: Int, at time: Double) -> MolePop? {
        pops.last { $0.hole == hole && $0.state(at: time, config: config) != .gone }
    }

    /// One frame: moves the round on to `time`, with the eye's aim (pt, nil when there is none).
    public mutating func update(time: Double, aim: Vec2?) -> [MoleEvent] {
        guard !ended else { return [] }
        var events: [MoleEvent] = []
        let targets = config.holes.indices.map { GazeLock.Target(id: $0, position: holeCenter($0), reach: reach) }
        lockedHole = lock.update(aim: aim, time: time, targets: targets)

        // Pops that went back down.
        var kept: [MolePop] = []
        for p in pops {
            if p.state(at: time, config: config) == .gone {
                if p.bonkedAt == nil {
                    if p.kind == .hedgehog {
                        tally.hedgehogsLeft += 1
                        events.append(.hedgehogLeft(p))
                    } else {
                        tally.escaped += 1
                        combo = 0
                        events.append(.escaped(p))
                    }
                }
            } else {
                kept.append(p)
            }
        }
        pops = kept

        let end = startTime + config.roundSec
        if time >= end {
            ended = true
            for p in pops where p.bonkedAt == nil && p.kind != .hedgehog { tally.escaped += 1; events.append(.escaped(p)) }
            pops = []
            events.append(.ended(result(at: end)))
            return events
        }

        // New pops: none that could not finish coming up before the end.
        if time >= nextPop, time + config.riseSec + pace.upSec <= end {
            let busy = Set(pops.map(\.hole))
            if pops.count < pace.maxUp {
                var free = config.holes.indices.filter { !busy.contains($0) }
                if free.count > 1, let last = lastHole { free.removeAll { $0 == last } }
                if let hole = free.randomElement(using: &random) {
                    let r = Double.random(in: 0..<1, using: &random)
                    let kind: MoleKind = r < pace.decoyShare ? .hedgehog
                        : r < pace.decoyShare + pace.goldenShare ? .golden : .mole
                    let up = kind == .golden ? pace.upSec * 0.8 : pace.upSec
                    let p = MolePop(id: nextID, hole: hole, kind: kind, start: time,
                                    hideAt: time + config.riseSec + up, bonkedAt: nil)
                    nextID += 1
                    lastHole = hole
                    pops.append(p)
                    events.append(.popped(p))
                }
            }
            nextPop = time + pace.gapSec * Double.random(in: 0.75...1.25, using: &random)
        }
        return events
    }

    /// A blink or wink that began at `onset`, with the aim from just before it (pt; nil: the lock decides).
    public mutating func bonk(onset: Double, aim: Vec2?) -> MoleEvent? {
        guard !ended, onset >= startTime else { return nil }
        lastAssisted = false
        let hole = aim.flatMap(nearestHole(to:)) ?? lockedHole
        func bonkable(_ p: MolePop) -> Bool {
            p.bonkedAt == nil && onset >= p.start && onset <= p.hideAt + config.lateGraceSec
        }
        var found = hole.flatMap { h in pops.lastIndex { $0.hole == h && bonkable($0) } }
        if found == nil, let a = aim {
            // The nearest mole up within the assist reach, if the aim missed every one.
            var best: (Int, Double)?
            for (j, p) in pops.enumerated() where p.kind != .hedgehog && bonkable(p) {
                let d = a.distance(to: holeCenter(p.hole))
                if d <= reach * config.assistScale, d < (best?.1 ?? .infinity) { best = (j, d) }
            }
            found = best?.0
            lastAssisted = found != nil
        }
        guard let i = found else {
            tally.whiffs += 1
            combo = 0
            return .whiff(hole: hole)
        }
        pops[i].bonkedAt = onset
        let p = pops[i]
        if p.kind == .hedgehog {
            tally.hedgehogHits += 1
            combo = 0
            score = max(0, score - config.decoyPenalty)
            return .hedgehogHit(p)
        }
        combo += 1
        tally.bestCombo = max(tally.bestCombo, combo)
        let base = p.kind == .golden ? config.goldenPoints : config.molePoints
        let points = base + min(config.comboCap, config.comboStep * (combo - 1))
        score += points
        tally.hits += 1
        if p.kind == .golden { tally.golden += 1 }
        let reaction = onset - p.start
        reactionSum += reaction
        return .hit(p, points: points, reactionSec: reaction)
    }

    /// Whether the last bonk found its mole through the assist reach (`MoleConfig.assistScale`).
    public private(set) var lastAssisted = false

    /// The nearest hole whose reach holds `aim`.
    public func nearestHole(to aim: Vec2) -> Int? {
        var best: (Int, Double)?
        for i in config.holes.indices {
            let d = aim.distance(to: holeCenter(i))
            if d <= reach, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// The round so far (or as it ended).
    public func result(at time: Double) -> MoleResult {
        var r = tally
        r.score = score
        r.meanReactionSec = r.hits > 0 ? reactionSum / Double(r.hits) : nil
        r.durationSec = min(config.roundSec, max(0, time - startTime))
        return r
    }
}
