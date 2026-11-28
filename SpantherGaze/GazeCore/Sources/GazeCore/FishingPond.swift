import Foundation

// «Рыбалка»: fish swim in a pond seen from above. Hold the eyes on a fish, as on a meteor, and it is caught: the phone
// taps, the fish leaves the water and goes into the catch. No bite, no blink and no reeling (Aziz, 2026-11-28: "так же
// как с метеоритами, просто фокусируешься на ней ... без анимации того что она тянется"). Rules only: the 3D pond
// draws this state, in screen points like every other eye target.

public enum FishKind: String, Sendable, Equatable, CaseIterable, Codable {
    case crucian, perch, goldfish, catfish
}

public struct FishSpecies: Equatable, Sendable {
    public var kind: FishKind
    /// Drawn radius as a share of the screen's height.
    public var radius: Double
    /// Swimming speed on level 1 (pt/s).
    public var speed: Double
    /// Seconds of looking that catch it.
    public var holdSec: Double
    public var points: Int
    /// Share among new fish.
    public var weight: Double

    public static let all: [FishSpecies] = [
        FishSpecies(kind: .crucian, radius: 0.075, speed: 55, holdSec: 0.8, points: 100, weight: 0.45),
        FishSpecies(kind: .perch, radius: 0.068, speed: 80, holdSec: 0.9, points: 150, weight: 0.3),
        FishSpecies(kind: .catfish, radius: 0.1, speed: 40, holdSec: 1.3, points: 300, weight: 0.17),
        FishSpecies(kind: .goldfish, radius: 0.058, speed: 110, holdSec: 1.0, points: 400, weight: 0.08),
    ]

    public static func of(_ kind: FishKind) -> FishSpecies { all.first { $0.kind == kind }! }
}

public struct FishingLevel: Equatable, Sendable {
    public var speedScale: Double
    /// The species' holding times are multiplied by this.
    public var holdScale: Double
    /// Fish in the pond at once.
    public var fishCount: Int
    /// Fish to catch: the round ends as soon as they are all in, with three stars.
    public var goal: Int

    public static func level(_ n: Int, of count: Int = 10) -> FishingLevel {
        let t = count > 1 ? Double(min(max(n, 1), count) - 1) / Double(count - 1) : 0
        let d = t * t * (3 - 2 * t)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * d }
        return FishingLevel(speedScale: lerp(1, 1.9), holdScale: lerp(1, 1.25),
                            fishCount: n >= 7 ? 5 : n >= 3 ? 4 : 3, goal: Int(lerp(10, 18).rounded()))
    }
}

public struct FishingConfig: Equatable, Sendable {
    /// The longest a round lasts (s); it ends sooner once the goal is caught.
    public var roundSec = 90.0
    /// The pond, as fractions of a landscape screen: left, top, right, bottom (under the HUD at the top).
    public var pond = (minX: 0.07, minY: 0.18, maxX: 0.93, maxY: 0.9)
    /// The near shore with the jetty (fractions of the screen), for the drawing.
    public var shore = Vec2(0.5, 0.97)
    /// A fish's reach for the eye as a share of its drawn radius, before the zone floor.
    public var reachScale = 1.5
    /// A looked-at fish swims this much slower, so the eyes can stay on it.
    public var lookedSlowdown = 0.35
    /// Holding drains this much per second while the eyes are elsewhere (a full hold takes 1/this s to forget).
    public var forgetPerSec = 0.6
    /// A caught fish is replaced after this long (s), at the pond's far edge.
    public var respawnSec = 1.0
    public var levels = 10

    public init() {}

    public static func == (a: FishingConfig, b: FishingConfig) -> Bool {
        a.roundSec == b.roundSec && a.pond == b.pond && a.shore == b.shore && a.reachScale == b.reachScale
            && a.lookedSlowdown == b.lookedSlowdown && a.forgetPerSec == b.forgetPerSec
            && a.respawnSec == b.respawnSec && a.levels == b.levels
    }
}

public struct Fish: Equatable, Sendable {
    public var id: Int
    public var kind: FishKind
    /// Centre on the screen (pt) and heading (radians, 0 = right, y down).
    public var position: Vec2
    public var heading: Double
    /// 0...1: how much of the holding it takes is done.
    public var interest = 0.0
    /// Wander: two sine terms on the heading's turn rate.
    var phase: (Double, Double)
    var rate: (Double, Double)

    public static func == (a: Fish, b: Fish) -> Bool {
        a.id == b.id && a.kind == b.kind && a.position == b.position && a.heading == b.heading
            && a.interest == b.interest
    }
}

public enum FishingEvent: Equatable, Sendable {
    /// The eyes settled on a fish (the hold, and its haptic, begins).
    case looked(Fish)
    /// Caught: the points it gave and how long the eyes held it (s, from the first look of this hold).
    case caught(Fish, points: Int, holdSec: Double)
    case ended(FishingResult)
}

public struct FishingResult: Equatable, Sendable, Codable {
    public var level: Int
    public var goal: Int
    public var landed: Int
    public var landedKinds: [String: Int]
    public var score: Int
    /// Holds begun on a fish, caught or not.
    public var looks: Int
    /// Mean time from the first look of a hold to the catch (s), nil without catches.
    public var meanHoldSec: Double?
    public var durationSec: Double

    public var stars: Int {
        guard goal > 0 else { return 0 }
        let r = Double(landed) / Double(goal)
        return r >= 1 ? 3 : r >= 0.7 ? 2 : r >= 0.4 ? 1 : 0
    }

    /// Share of holds that ended in a catch.
    public var accuracy: Double { looks > 0 ? min(1, Double(landed) / Double(looks)) : 0 }
}

/// The whole «Рыбалка» round without drawing. Call `update` every tracking frame with the eye's aim (or the finger's).
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
    private var holdSum = 0.0
    /// When the current hold on `lockedFish` began.
    private var holdStart: Double?

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
        tally = FishingResult(level: self.level, goal: pace.goal, landed: 0, landedKinds: [:], score: 0, looks: 0,
                              meanHoldSec: nil, durationSec: 0)
        for _ in 0..<pace.fishCount { fish.append(newFish(anywhere: true)) }
    }

    public func radius(_ f: Fish) -> Double { FishSpecies.of(f.kind).radius * screen.y }

    public func reach(_ f: Fish) -> Double { max(radius(f) * config.reachScale, zoneFloor) }

    /// Seconds of looking that catch `f` on this level.
    public func holdSec(_ f: Fish) -> Double { FishSpecies.of(f.kind).holdSec * pace.holdScale }

    /// The fish under the eyes and how far its hold has come (0...1), for the ring and the haptic.
    public var holding: (fish: Fish, progress: Double)? {
        guard let id = lockedFish, let f = fish.first(where: { $0.id == id }) else { return nil }
        return (f, f.interest)
    }

    public func remaining(at time: Double) -> Double { max(0, startTime + config.roundSec - time) }

    public mutating func update(time: Double, aim: Vec2?) -> [FishingEvent] {
        guard !ended else { return [] }
        let dt = min(0.1, max(0, time - lastTime))
        lastTime = time
        var events: [FishingEvent] = []

        let end = startTime + config.roundSec
        if time >= end {
            finish(at: end, &events)
            return events
        }

        let before = lockedFish
        lockedFish = lock.update(aim: aim, time: time,
                                 targets: fish.map { GazeLock.Target(id: $0.id, position: $0.position, reach: reach($0)) })
        if lockedFish != before {
            holdStart = lockedFish == nil ? nil : time
            if let id = lockedFish, let f = fish.first(where: { $0.id == id }) {
                tally.looks += 1
                events.append(.looked(f))
            }
        }

        var caught: Int?
        for i in fish.indices {
            let sp = FishSpecies.of(fish[i].kind)
            let looked = lockedFish == fish[i].id
            swim(&fish[i], dt: dt, time: time, speed: sp.speed * pace.speedScale * (looked ? config.lookedSlowdown : 1))
            if looked {
                fish[i].interest = min(1, fish[i].interest + dt / holdSec(fish[i]))
                if fish[i].interest >= 1, caught == nil { caught = i }
            } else {
                fish[i].interest = max(0, fish[i].interest - dt * config.forgetPerSec)
            }
        }
        if let i = caught {
            let f = fish[i]
            let points = FishSpecies.of(f.kind).points
            let held = time - (holdStart ?? time)
            score += points
            holdSum += held
            tally.landed += 1
            tally.landedKinds[f.kind.rawValue, default: 0] += 1
            events.append(.caught(f, points: points, holdSec: held))
            fish.remove(at: i)
            respawns.append(time + config.respawnSec)
            lockedFish = nil
            holdStart = nil
            lock = GazeLock()
            if tally.landed >= pace.goal {
                finish(at: time, &events)
                return events
            }
        }
        while let r = respawns.first, r <= time {
            respawns.removeFirst()
            fish.append(newFish(anywhere: false))
        }
        return events
    }

    private mutating func finish(at time: Double, _ events: inout [FishingEvent]) {
        ended = true
        lockedFish = nil
        events.append(.ended(result(at: time)))
    }

    public func result(at time: Double) -> FishingResult {
        var r = tally
        r.score = score
        r.meanHoldSec = r.landed > 0 ? holdSum / Double(r.landed) : nil
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
}
