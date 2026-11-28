import Foundation

// «Рыбалка»: fish swim in a pond seen from above. Hold the eyes on a fish and it gets curious; once it bites, blink
// before it lets go of the bait, then reel it in by following it with the eyes to the shore. Rules only: the 3D pond
// draws this state, in screen points like every other eye target.
// Natural blinks never cost anything: a blink before the bite does nothing, so a player who blinks while holding a
// fish keeps it. Only the bite window asks for a blink.

public enum FishKind: String, Sendable, Equatable, CaseIterable, Codable {
    case crucian, perch, goldfish, catfish
}

public struct FishSpecies: Equatable, Sendable {
    public var kind: FishKind
    /// Drawn radius as a share of the screen's height.
    public var radius: Double
    /// Swimming speed on level 1 (pt/s).
    public var speed: Double
    /// Seconds of looking that make it bite.
    public var holdSec: Double
    /// Seconds of following that land it.
    public var reelSec: Double
    public var points: Int
    /// Share among new fish.
    public var weight: Double

    public static let all: [FishSpecies] = [
        FishSpecies(kind: .crucian, radius: 0.075, speed: 55, holdSec: 0.8, reelSec: 2.5, points: 100, weight: 0.45),
        FishSpecies(kind: .perch, radius: 0.068, speed: 80, holdSec: 0.9, reelSec: 3.0, points: 150, weight: 0.3),
        FishSpecies(kind: .catfish, radius: 0.1, speed: 40, holdSec: 1.3, reelSec: 4.0, points: 300, weight: 0.17),
        FishSpecies(kind: .goldfish, radius: 0.058, speed: 110, holdSec: 1.0, reelSec: 3.0, points: 400, weight: 0.08),
    ]

    public static func of(_ kind: FishKind) -> FishSpecies { all.first { $0.kind == kind }! }
}

public struct FishingLevel: Equatable, Sendable {
    public var speedScale: Double
    /// Time to blink once a fish bites (s).
    public var biteWindowSec: Double
    /// Fish in the pond at once.
    public var fishCount: Int
    /// Fish to land in the round for three stars.
    public var goal: Int
    /// How long the eyes may leave a hooked fish before the line snaps (s).
    public var slackSec: Double

    public static func level(_ n: Int, of count: Int = 10) -> FishingLevel {
        let t = count > 1 ? Double(min(max(n, 1), count) - 1) / Double(count - 1) : 0
        let d = t * t * (3 - 2 * t)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * d }
        return FishingLevel(speedScale: lerp(1, 1.9), biteWindowSec: lerp(1.1, 0.5),
                            fishCount: n >= 7 ? 5 : n >= 3 ? 4 : 3, goal: Int(lerp(10, 16).rounded()),
                            slackSec: lerp(1.2, 0.55))
    }
}

public struct FishingConfig: Equatable, Sendable {
    public var roundSec = 120.0
    /// The pond, as fractions of a landscape screen: left, top, right, bottom (under the HUD at the top).
    public var pond = (minX: 0.07, minY: 0.18, maxX: 0.93, maxY: 0.9)
    /// Where landed fish are pulled to (fractions of the screen): the shore at the bottom middle.
    public var shore = Vec2(0.5, 0.97)
    /// A fish's reach for the eye as a share of its drawn radius, before the zone floor; a hooked fish gets more.
    public var reachScale = 1.5
    /// A blink during a bite hooks the biting fish when the aim is within this many of its reaches, even if the
    /// lock has slipped off it: the fish bit because the player looked at it (as `MoleConfig.assistScale`). In
    /// Aziz's session of 2026-11-28 six of eight lost bites had a blink in time, with the aim 45 to 100 pt off the
    /// still fish.
    public var assistScale = 2.3
    public var hookedReachScale = 2.0
    /// Curiosity drains this much per second while the eyes are elsewhere (a full fish takes 1/this s to forget).
    public var forgetPerSec = 0.6
    /// A fish that let go of the bait swims off fast and cannot be held for this long (s).
    public var fleeSec = 1.6
    /// A landed or lost fish is replaced after this long (s), at the pond's far edge.
    public var respawnSec = 1.0
    /// How far a hooked fish swings from side to side on its way in, as a share of the screen's width.
    public var reelSwing = 0.12
    public var levels = 10

    public init() {}

    public static func == (a: FishingConfig, b: FishingConfig) -> Bool {
        a.roundSec == b.roundSec && a.pond == b.pond && a.shore == b.shore && a.reachScale == b.reachScale
            && a.assistScale == b.assistScale
            && a.hookedReachScale == b.hookedReachScale && a.forgetPerSec == b.forgetPerSec && a.fleeSec == b.fleeSec
            && a.respawnSec == b.respawnSec && a.reelSwing == b.reelSwing && a.levels == b.levels
    }
}

public struct Fish: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case swimming
        /// Took the bait at `since`; a blink before `until` hooks it.
        case biting(since: Double, until: Double)
        /// Hooked at `since`, from `from` (pt). `progress` 0...1 is how far it has been reeled in.
        case hooked(since: Double, from: Vec2, progress: Double, offSince: Double?)
        case fleeing(until: Double)
    }
    public var id: Int
    public var kind: FishKind
    /// Centre on the screen (pt) and heading (radians, 0 = right, y down).
    public var position: Vec2
    public var heading: Double
    /// 0...1: how close it is to biting.
    public var interest = 0.0
    public var state: State = .swimming
    /// Wander: two sine terms on the heading's turn rate.
    var phase: (Double, Double)
    var rate: (Double, Double)

    public static func == (a: Fish, b: Fish) -> Bool {
        a.id == b.id && a.kind == b.kind && a.position == b.position && a.heading == b.heading
            && a.interest == b.interest && a.state == b.state
    }
}

public enum FishingEvent: Equatable, Sendable {
    case bite(Fish)
    /// Hooked: the time from the bite to the blink (s).
    case hooked(Fish, reactionSec: Double)
    case letGo(Fish)
    case landed(Fish, points: Int)
    case snapped(Fish)
    case ended(FishingResult)
}

public struct FishingResult: Equatable, Sendable, Codable {
    public var level: Int
    public var goal: Int
    public var landed: Int
    public var landedKinds: [String: Int]
    public var score: Int
    public var bites: Int
    public var letGo: Int
    public var snapped: Int
    /// Mean time from a bite to the hooking blink (s), nil without hooks.
    public var meanHookSec: Double?
    /// Share of reeling time the eyes were on the fish.
    public var followShare: Double?
    public var durationSec: Double

    public var stars: Int {
        guard goal > 0 else { return 0 }
        let r = Double(landed) / Double(goal)
        return r >= 1 ? 3 : r >= 0.7 ? 2 : r >= 0.4 ? 1 : 0
    }

    /// Share of bites that were hooked.
    public var accuracy: Double { bites > 0 ? Double(bites - letGo) / Double(bites) : 0 }
}

/// The whole «Рыбалка» round without drawing. Call `update` every tracking frame with the eye's aim and `blink` for
/// every closure the eyes decide (with the aim from before its onset).
public struct FishingPond: Sendable {
    public let config: FishingConfig
    public let level: Int
    public let pace: FishingLevel
    public let screen: Vec2
    public var zoneFloor: Double
    public let startTime: Double
    public private(set) var fish: [Fish] = []
    public private(set) var lockedFish: Int?
    public private(set) var score = 0
    public private(set) var ended = false

    private var lock = GazeLock()
    private var random: SeededRandom
    private var nextID = 0
    private var respawns: [Double] = []
    private var lastTime: Double
    private var tally: FishingResult
    private var hookSum = 0.0
    private var reelOn = 0.0, reelAll = 0.0

    public init(level: Int, screen: Vec2, startTime: Double, seed: UInt64, zoneFloor: Double = 0,
                config: FishingConfig = FishingConfig()) {
        self.config = config
        self.level = min(max(level, 1), config.levels)
        pace = FishingLevel.level(self.level, of: config.levels)
        self.screen = screen
        self.zoneFloor = zoneFloor
        self.startTime = startTime
        lastTime = startTime
        random = SeededRandom(seed: seed)
        tally = FishingResult(level: self.level, goal: pace.goal, landed: 0, landedKinds: [:], score: 0, bites: 0,
                              letGo: 0, snapped: 0, meanHookSec: nil, followShare: nil, durationSec: 0)
        for _ in 0..<pace.fishCount { fish.append(newFish(anywhere: true)) }
    }

    public func radius(_ f: Fish) -> Double { FishSpecies.of(f.kind).radius * screen.y }

    public func reach(_ f: Fish) -> Double {
        if case .hooked = f.state { return max(radius(f) * config.hookedReachScale, zoneFloor * 1.2) }
        return max(radius(f) * config.reachScale, zoneFloor)
    }

    /// The hooked fish, if one is on the line.
    public var hooked: Fish? { fish.first { if case .hooked = $0.state { return true } else { return false } } }

    public func remaining(at time: Double) -> Double { max(0, startTime + config.roundSec - time) }

    public mutating func update(time: Double, aim: Vec2?) -> [FishingEvent] {
        guard !ended else { return [] }
        let dt = min(0.1, max(0, time - lastTime))
        lastTime = time
        var events: [FishingEvent] = []

        let end = startTime + config.roundSec
        if time >= end {
            ended = true
            events.append(.ended(result(at: end)))
            return events
        }

        // What the eyes may hold: the hooked fish alone, else every fish that is not fleeing.
        let holdable: [Fish] = hooked.map { [$0] } ?? fish.filter {
            if case .fleeing = $0.state { return false } else { return true }
        }
        lockedFish = lock.update(aim: aim, time: time,
                                 targets: holdable.map { GazeLock.Target(id: $0.id, position: $0.position, reach: reach($0)) })

        var gone: [Int] = []
        for i in fish.indices {
            let sp = FishSpecies.of(fish[i].kind)
            let looked = lockedFish == fish[i].id
            switch fish[i].state {
            case .swimming:
                swim(&fish[i], dt: dt, time: time, speed: sp.speed * pace.speedScale * (looked ? 0.35 : 1))
                if looked {
                    fish[i].interest = min(1, fish[i].interest + dt / sp.holdSec)
                    if fish[i].interest >= 1 {
                        fish[i].state = .biting(since: time, until: time + pace.biteWindowSec)
                        tally.bites += 1
                        events.append(.bite(fish[i]))
                    }
                } else {
                    fish[i].interest = max(0, fish[i].interest - dt * config.forgetPerSec)
                }
            case .biting(_, let until):
                if time > until {
                    fish[i].state = .fleeing(until: time + config.fleeSec)
                    fish[i].interest = 0
                    tally.letGo += 1
                    events.append(.letGo(fish[i]))
                }
            case .hooked(let since, let from, var progress, var offSince):
                reelAll += dt
                let on = aim.map { $0.distance(to: fish[i].position) <= reach(fish[i]) } ?? false
                if on {
                    reelOn += dt
                    offSince = nil
                    progress = min(1, progress + dt / sp.reelSec)
                } else if offSince == nil {
                    offSince = time
                }
                fish[i].position = reelPosition(from: from, progress: progress, since: since, time: time)
                if progress >= 1 {
                    let points = sp.points
                    score += points
                    tally.landed += 1
                    tally.landedKinds[fish[i].kind.rawValue, default: 0] += 1
                    events.append(.landed(fish[i], points: points))
                    gone.append(fish[i].id)
                } else if let off = offSince, time - off > pace.slackSec {
                    tally.snapped += 1
                    fish[i].state = .fleeing(until: time + config.fleeSec)
                    fish[i].interest = 0
                    events.append(.snapped(fish[i]))
                } else {
                    fish[i].state = .hooked(since: since, from: from, progress: progress, offSince: offSince)
                }
            case .fleeing(let until):
                swim(&fish[i], dt: dt, time: time, speed: sp.speed * pace.speedScale * 2.2)
                if time > until { fish[i].state = .swimming }
            }
        }
        if !gone.isEmpty {
            fish.removeAll { gone.contains($0.id) }
            respawns += gone.map { _ in time + config.respawnSec }
        }
        while let r = respawns.first, r <= time {
            respawns.removeFirst()
            fish.append(newFish(anywhere: false))
        }
        return events
    }

    /// A blink or wink that began at `onset`. Hooks a biting fish under the eyes; anything else does nothing.
    public mutating func blink(onset: Double, aim: Vec2?) -> FishingEvent? {
        guard !ended else { return nil }
        func biting(_ f: Fish) -> Bool {
            guard case .biting(let since, let until) = f.state else { return false }
            return onset >= since - 0.05 && onset <= until
        }
        lastAssisted = false
        var found = fish.firstIndex { f in
            biting(f) && (f.id == lockedFish || (aim.map { $0.distance(to: f.position) <= reach(f) } ?? false))
        }
        if found == nil, let a = aim {
            found = fish.indices.filter { biting(fish[$0]) && a.distance(to: fish[$0].position) <= reach(fish[$0]) * config.assistScale }
                .min { a.distance(to: fish[$0].position) < a.distance(to: fish[$1].position) }
            lastAssisted = found != nil
        }
        guard let i = found else { return nil }
        guard case .biting(let since, _) = fish[i].state else { return nil }
        fish[i].state = .hooked(since: onset, from: fish[i].position, progress: 0, offSince: nil)
        let reaction = max(0, onset - since)
        hookSum += reaction
        return .hooked(fish[i], reactionSec: reaction)
    }

    /// Whether the last hook found its fish through the assist reach (`FishingConfig.assistScale`).
    public private(set) var lastAssisted = false

    public func result(at time: Double) -> FishingResult {
        var r = tally
        r.score = score
        let hooks = r.bites - r.letGo
        r.meanHookSec = hooks > 0 ? hookSum / Double(hooks) : nil
        r.followShare = reelAll > 0 ? reelOn / reelAll : nil
        r.durationSec = min(config.roundSec, max(0, time - startTime))
        return r
    }

    // MARK: Movement

    private func pondRect() -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (config.pond.minX * screen.x, config.pond.minY * screen.y, config.pond.maxX * screen.x, config.pond.maxY * screen.y)
    }

    private mutating func newFish(anywhere: Bool) -> Fish {
        let r = Double.random(in: 0..<1, using: &random)
        var acc = 0.0
        let kind = FishSpecies.all.first { acc += $0.weight; return r < acc }?.kind ?? .crucian
        let p = pondRect()
        let x = Double.random(in: p.minX + 40...p.maxX - 40, using: &random)
        let y = anywhere ? Double.random(in: p.minY + 30...p.maxY - 30, using: &random) : p.minY + 30
        let heading = anywhere ? Double.random(in: 0..<(2 * .pi), using: &random) : .pi / 2
        let f = Fish(id: nextID, kind: kind, position: Vec2(x, y), heading: heading,
                     phase: (Double.random(in: 0..<6.3, using: &random), Double.random(in: 0..<6.3, using: &random)),
                     rate: (Double.random(in: 0.3...0.7, using: &random), Double.random(in: 0.9...1.6, using: &random)))
        nextID += 1
        return f
    }

    private func swim(_ f: inout Fish, dt: Double, time: Double, speed: Double) {
        let t = time - startTime
        f.heading += dt * (0.9 * sin(f.rate.0 * t + f.phase.0) + 0.5 * sin(f.rate.1 * t + f.phase.1))
        var x = f.position.x + cos(f.heading) * speed * dt
        var y = f.position.y + sin(f.heading) * speed * dt
        let p = pondRect(), m = radius(f)
        if x < p.minX + m || x > p.maxX - m {
            f.heading = .pi - f.heading
            x = min(max(x, p.minX + m), p.maxX - m)
        }
        if y < p.minY + m || y > p.maxY - m {
            f.heading = -f.heading
            y = min(max(y, p.minY + m), p.maxY - m)
        }
        f.position = Vec2(x, y)
    }

    /// A hooked fish on its way to the shore: straight in, swinging less as it comes closer.
    private func reelPosition(from: Vec2, progress: Double, since: Double, time: Double) -> Vec2 {
        let shore = Vec2(config.shore.x * screen.x, config.shore.y * screen.y - 30)
        let base = from + (shore - from) * progress
        let swing = config.reelSwing * screen.x * (1 - progress) * sin((time - since) * 2.2)
        let p = pondRect()
        return Vec2(min(max(base.x + swing, p.minX), p.maxX), base.y)
    }
}
