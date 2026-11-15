import Foundation

/// A damped spring moved by its exact solution, so it behaves the same at 30 or 60 frames a second and never blows
/// up after a long frame. The stone leans toward the gaze on one (an x and a y spring) and squashes on another.
public struct FeelSpring: Sendable, Equatable {
    public var value: Double
    public var velocity: Double
    public var target: Double
    /// The undamped frequency (Hz): how quickly it gets there.
    public let frequencyHz: Double
    /// 1 gets there without overshooting; below 1 it overshoots (0.5: by about 16%), above 1 it creeps.
    public let dampingRatio: Double

    public init(value: Double = 0, target: Double? = nil, frequencyHz: Double, dampingRatio: Double) {
        self.value = value
        velocity = 0
        self.target = target ?? value
        self.frequencyHz = frequencyHz
        self.dampingRatio = dampingRatio
    }

    public mutating func step(_ dt: Double) {
        guard dt > 0, dt.isFinite else { return }
        let w = 2 * Double.pi * max(1e-6, frequencyHz)
        let z = max(0, dampingRatio)
        let x0 = value - target, v0 = velocity
        let x: Double, v: Double
        if z < 1 - 1e-6 {
            let wd = w * (1 - z * z).squareRoot()
            let e = exp(-z * w * dt), c = cos(wd * dt), s = sin(wd * dt)
            let b = (v0 + z * w * x0) / wd
            x = e * (x0 * c + b * s)
            v = e * (v0 * c - (z * w * b + wd * x0) * s)
        } else if z <= 1 + 1e-6 {
            let e = exp(-w * dt), b = v0 + w * x0
            x = (x0 + b * dt) * e
            v = (v0 - w * b * dt) * e
        } else {
            let root = (z * z - 1).squareRoot()
            let r1 = -w * (z - root), r2 = -w * (z + root)
            let c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2
            let e1 = exp(r1 * dt), e2 = exp(r2 * dt)
            x = c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        }
        value = target + x
        velocity = v
    }
}

/// The pieces of a stone after the lock, moved by our own small integrator instead of SpriteKit's physics: gravity,
/// air drag, spin, and one bounce on the ground, after which they fall through it and fade. Coordinates are the
/// scene's (points, y up). Each step is the exact solution for gravity and linear drag, so the flight is the same
/// at any frame rate until the bounce.
public struct ShardFlight: Sendable, Equatable {
    public struct Rules: Sendable, Equatable {
        /// pt/s², pointing down in a y-up scene.
        public var gravity = FeelPoint(0, -900)
        /// Linear drag on the speed and on the spin (1/s).
        public var drag = 1.4
        public var spinDrag = 1.0
        /// The share of the downward speed kept in the bounce, and of the sideways speed lost.
        public var restitution = 0.32
        public var friction = 0.35
        public var lifeSec = 1.0
        /// The last part of the life, over which everything fades out.
        public var fadeSec = 0.35
        public var maxStepSec = 1.0 / 120
        public init() {}
    }

    public struct Piece: Sendable, Equatable {
        public var position: FeelPoint
        public var velocity: FeelPoint
        public var angle: Double
        /// rad/s, counter-clockwise.
        public var spin: Double
        /// From the piece's centre to its farthest corner (pt): it touches the ground at position.y - radius.
        public let radius: Double
        public var bounced = false

        public init(position: FeelPoint, velocity: FeelPoint, angle: Double, spin: Double, radius: Double) {
            self.position = position
            self.velocity = velocity
            self.angle = angle
            self.spin = spin
            self.radius = radius
        }
    }

    public let rules: Rules
    /// The ground (pt, y up); -infinity for none.
    public let floorY: Double
    public private(set) var pieces: [Piece]
    public private(set) var age = 0.0

    public init(pieces: [Piece], floorY: Double = -.infinity, rules: Rules = Rules()) {
        self.pieces = pieces
        self.floorY = floorY
        self.rules = rules
    }

    /// 1 until the fade, then down to 0 at the end of the life.
    public var alpha: Double {
        let left = rules.lifeSec - age
        guard rules.fadeSec > 0 else { return left > 0 ? 1 : 0 }
        return min(1, max(0, left / rules.fadeSec))
    }

    public var isOver: Bool { age >= rules.lifeSec }

    public mutating func step(_ dt: Double) {
        guard dt > 0, dt.isFinite, !isOver else { return }
        let n = max(1, Int((dt / max(1e-4, rules.maxStepSec)).rounded(.up)))
        let h = dt / Double(n)
        let k = max(0, rules.drag), g = rules.gravity
        let e = exp(-k * h)
        let decay = k > 0 ? (1 - e) / k : h
        let terminal = k > 0 ? g / k : FeelPoint.zero
        let ks = max(0, rules.spinDrag)
        let es = exp(-ks * h)
        let spinDecay = ks > 0 ? (1 - es) / ks : h
        for _ in 0..<n {
            for i in pieces.indices {
                var p = pieces[i]
                if k > 0 {
                    p.position += terminal * h + (p.velocity - terminal) * decay
                    p.velocity = terminal + (p.velocity - terminal) * e
                } else {
                    p.position += p.velocity * h + g * (0.5 * h * h)
                    p.velocity += g * h
                }
                p.angle += p.spin * spinDecay
                p.spin *= es
                if !p.bounced, p.velocity.y < 0, p.position.y - p.radius < floorY {
                    p.position.y = floorY + p.radius
                    p.velocity.y = -p.velocity.y * rules.restitution
                    p.velocity.x *= 1 - rules.friction
                    p.spin *= 0.6
                    p.bounced = true
                }
                pieces[i] = p
            }
        }
        age += dt
    }

    /// Throws the shards of a fracture out from its impact. `centre`, `rotation` and `scale` place the stone in the
    /// scene (pt, rad, pt per stone unit). Smaller shards fly faster and spin more; all get a little lift first.
    public static func burst(_ fracture: StoneFracture, centre: FeelPoint, rotation: Double, scale: Double,
                             floorY: Double = -.infinity, seed: UInt64, speed: Double = 240,
                             rules: Rules = Rules()) -> ShardFlight {
        var rng = FeelRandom.stream(seed, 0x464C_4954)
        let shards = fracture.shards
        let mean = shards.isEmpty ? 1 : shards.reduce(0) { $0 + $1.area } / Double(shards.count)
        var pieces: [Piece] = []
        for shard in shards {
            var away = shard.centroid - fracture.impact
            var d = Planar.length(away)
            if d < 1e-6 {
                let a = rng.uniform(0, 2 * .pi)
                away = FeelPoint(cos(a), sin(a))
                d = 1
            }
            let small = min(1.8, max(0.6, (mean / max(shard.area, 1e-12)).squareRoot()))
            let out = Planar.rotate(away / d, by: rotation) * (speed * small * rng.uniform(0.85, 1.15))
            let reach = shard.polygon.map { Planar.distance($0, shard.centroid) }.max() ?? 0
            pieces.append(Piece(position: centre + Planar.rotate(shard.centroid, by: rotation) * scale,
                                velocity: out + FeelPoint(0, 0.35 * speed), angle: rotation,
                                spin: rng.uniform(-1, 1) * 7 * small, radius: reach * scale))
        }
        return ShardFlight(pieces: pieces, floorY: floorY, rules: rules)
    }
}

/// A mote of light that flies from the broken stone to where the catch is counted, along a gentle curve.
public struct MotePath: Sendable, Equatable {
    public let start: FeelPoint
    /// The quadratic Bézier's middle point: off to one side of the straight way.
    public let control: FeelPoint
    public let end: FeelPoint
    /// From the lock to setting off, and the flight itself (s).
    public let delaySec: Double
    public let durationSec: Double

    /// Where the mote is `t` seconds after the lock; nil before it sets off and after it has arrived.
    public func position(at t: Double) -> FeelPoint? {
        guard durationSec > 0 else { return nil }
        let u = (t - delaySec) / durationSec
        // The last frame of the flight may land a rounding error past its end: it still counts as arrived.
        guard u >= 0, u <= 1 + 1e-9 else { return nil }
        let k = min(1, u * u * (3 - 2 * u))
        let a = 1 - k
        return start * (a * a) + control * (2 * a * k) + end * (k * k)
    }

    /// `count` motes, one after another, curving to alternate sides.
    public static func spray(from: FeelPoint, to: FeelPoint, count: Int, seed: UInt64,
                             durationSec: ClosedRange<Double> = 0.55...0.8, staggerSec: Double = 0.06) -> [MotePath] {
        var rng = FeelRandom.stream(seed, 0x4D4F_5445)
        let d = to - from
        let l = Planar.length(d)
        let side = l > 0 ? Planar.perpendicular(d) / l : .zero
        var sign = rng.unit() < 0.5 ? -1.0 : 1.0
        return (0..<max(0, count)).map { i in
            let control = from + d * rng.uniform(0.35, 0.6) + side * (sign * l * rng.uniform(0.25, 0.5))
            sign = -sign
            return MotePath(start: from, control: control, end: to, delaySec: Double(i) * staggerSec,
                            durationSec: rng.uniform(durationSec.lowerBound, durationSec.upperBound))
        }
    }
}
