import Foundation

/// A scripted Wink Beat player for tests and, later, the Simulator smoke test (which has no face tracking). It
/// looks at each object a little early, follows slider orbs with a short lag, hops spinner petals clockwise, winks
/// late by its latency with jitter, blinks naturally, and its tracked aim slides while a lid is down, like a real
/// face. Everything comes from a seed, so a run is the same every time.
public struct WinkBeatBot: Sendable {
    public struct Style: Equatable, Sendable {
        /// Wink delay after the object's time, and its random spread (s).
        public var latencySec = 0.08
        public var latencyJitterSec = 0.03
        /// Random aim scatter per frame (pt, standard deviation) and a fixed calibration bias (pt).
        public var aimNoisePt = 15.0
        public var aimBias = Vec2(0, 0)
        /// A natural blink about this often (s); 0 for none.
        public var blinkEverySec = 3.5
        /// How far the tracked aim slides while a lid is down (pt, downwards).
        public var closureShiftPt = 60.0
        /// Play `any` objects with long blinks instead of winks (a child who cannot wink).
        public var longBlinks = false
        /// Play every object with a short blink of both eyes, whatever eye it asks for (most players on the phone).
        public var beatBlinks = false
        /// Skip every n-th wink (0: none).
        public var skipEvery = 0
        /// Only blink, never wink.
        public var blinksOnly = false
        public var seed: UInt64 = 1
        public init() {}
    }

    struct Closure { var start: Double; var duration: Double; var side: WinkSide }

    public let style: Style
    /// Geometry of the play the bot looks at.
    let geometry: WinkBeatPlay
    let closures: [Closure]

    public init(play: WinkBeatPlay, style: Style = Style()) {
        self.style = style
        geometry = play
        var rng = Rng(seed: style.seed)
        var list: [Closure] = []
        var winkIndex = 0, alternate = WinkSide.left
        for o in play.objects where o.needsWink && !style.blinksOnly {
            winkIndex += 1
            if style.skipEvery > 0, winkIndex % style.skipEvery == 0 { continue }
            let start = o.time + style.latencySec + Self.gaussian(&rng) * style.latencyJitterSec
            if style.beatBlinks {
                list.append(Closure(start: start, duration: 0.13, side: .both))
                continue
            }
            switch o.side {
            case .left: list.append(Closure(start: start, duration: 0.13, side: .left))
            case .right: list.append(Closure(start: start, duration: 0.13, side: .right))
            case .any:
                if style.longBlinks {
                    list.append(Closure(start: start, duration: 0.42, side: .both))
                } else {
                    list.append(Closure(start: start, duration: 0.13, side: alternate))
                    alternate = alternate == .left ? .right : .left
                }
            }
        }
        if style.blinkEverySec > 0, let last = play.objects.last?.endTime, let firstTime = play.objects.first?.time {
            var t = firstTime - 1.5
            while t < last + 1 {
                t += style.blinkEverySec * (0.7 + 0.6 * rng.next())
                let blink = Closure(start: t, duration: 0.12, side: .both)
                // Not on top of a wink: lids closing together would read as one blink.
                if !list.contains(where: { t > $0.start - 0.15 && t < $0.start + $0.duration + 0.05 }) { list.append(blink) }
            }
        }
        closures = list.sorted { $0.start < $1.start }
    }

    /// The tracked aim (pt) and lid closures (0 open ... 1 closed) at `t`.
    public func frame(at t: Double, index: Int) -> (aim: Vec2?, left: Double, right: Double) {
        var left = 0.1, right = 0.1
        var closed = false
        for c in closures where t >= c.start && t < c.start + c.duration {
            closed = true
            switch c.side {
            case .left: left = 0.9; right = max(right, 0.3)
            case .right: right = 0.9; left = max(left, 0.3)
            case .both: left = 0.9; right = 0.9
            }
        }
        var rng = Rng(seed: style.seed &* 0x9E37_79B9 &+ UInt64(max(0, index)))
        var aim = target(at: t) + style.aimBias + Vec2(Self.gaussian(&rng), Self.gaussian(&rng)) * style.aimNoisePt
        if closed { aim = aim + Vec2(0, style.closureShiftPt) }
        return (aim, left, right)
    }

    /// Where the bot means to look at `t` (pt).
    func target(at t: Double) -> Vec2 {
        let p = geometry
        for (i, o) in p.objects.enumerated() {
            let done: Double
            switch o.kind {
            case .circle: done = o.time + style.latencySec + 0.15
            case .slider, .spinner: done = o.endTime
            }
            guard t < done else { continue }
            switch o.kind {
            case .circle:
                return p.positions[i]
            case .slider:
                return t < o.time ? p.positions[i] : (p.orb(i, at: t - 0.05) ?? p.positions[i])
            case .spinner:
                guard t >= o.time, o.endTime > o.time else { return p.petal(i, 0) }
                let rate = 1.15 * Double(p.hopsNeeded(i)) / (o.endTime - o.time)
                let hop = Int((t - o.time) * rate)
                return p.petal(i, hop % p.rules.petals)
            }
        }
        return p.positions.last ?? Vec2(p.field.width / 2, p.field.height / 2)
    }

    static func gaussian(_ rng: inout Rng) -> Double {
        let u1 = max(1e-12, rng.next()), u2 = rng.next()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    /// Plays a whole chart through `WinkBeatEyes`, the gaze lock and the judge, at 60 frames per second, the way
    /// the app does. Returns the finished play and how many short two-eye blinks the eyes saw (ordinary blinks,
    /// and blinks sent to play on levels where blinks play). `eyes`: nil takes the play's difficulty.
    public static func run(_ play: WinkBeatPlay, style: Style = Style(),
                           eyes config: WinkBeatEyesConfig? = nil) -> (play: WinkBeatPlay, blinks: Int) {
        var play = play
        let bot = WinkBeatBot(play: play, style: style)
        var eyes = WinkBeatEyes(config: config ?? WinkBeatEyesConfig(blinksPlay: play.rules.difficulty.blinksPlay))
        var lock = GazeLock()
        var blinks = 0
        guard let firstObject = play.objects.first, let last = play.objects.map(\.endTime).max() else { return (play, 0) }
        let start = firstObject.time - play.rules.difficulty.leadSec - 1
        var index = 0
        var t = start
        while t < last + 1.5, !play.finished {
            let f = bot.frame(at: t, index: index)
            let seen = eyes.update(time: t, aim: f.aim, left: f.left, right: f.right)
            let locked = lock.update(aim: play.onField(seen.aim), time: t, targets: play.lockTargets(at: t))
            for c in seen.closures {
                switch c {
                case .blink, .beatBlink: blinks += 1
                default: break
                }
                if let j = c.forJudge { play.closure(j, prefer: locked) }
            }
            play.frame(time: t, aim: seen.aim)
            index += 1
            t = start + Double(index) / 60
        }
        return (play, blinks)
    }
}
