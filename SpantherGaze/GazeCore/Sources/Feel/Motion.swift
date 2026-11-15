import Foundation

// How things move around the burst: the stone's lean toward the gaze while it charges, the squash at the lock, the
// shards' flight, and the motes that curve into the collection jar. Points are scene pt (SpriteKit: y up) unless
// said otherwise; times are seconds.

/// The stone's lean toward the gaze point while it charges: a spring that follows a target and settles on it.
public struct DampedSpring: Sendable, Equatable {
    /// In the target's frame and unit (the app uses pt).
    public var position: SIMD2<Double>
    /// Per second.
    public var velocity: SIMD2<Double>
    /// Natural frequency, Hz.
    public var frequency: Double
    /// 1 = critical: the fastest approach with no overshoot. Below 1 it overshoots and rings.
    public var dampingRatio: Double

    public init(frequency: Double = 6, dampingRatio: Double = 0.55, position: SIMD2<Double> = .zero) {
        self.position = position
        self.velocity = FeelPoint.zero
        self.frequency = frequency
        self.dampingRatio = dampingRatio
    }

    /// Exact step for a target held still over dt seconds (closed form for the under-, critically and over-damped
    /// cases), so any dt is stable and two half steps give the same as one whole step.
    public mutating func step(toward target: SIMD2<Double>, dt: Double) {
        if !(dt > 0) || !(frequency > 0) { return }
        let w = 2.0 * Double.pi * frequency
        let z = max(0.0, dampingRatio)
        let x = position - target
        let v = velocity
        if abs(z - 1.0) < 1e-5 {
            // x(t) = e^(−wt) (x + (v + w x) t)
            let e = exp(-w * dt)
            let b = v + x * w
            let moved = x + b * dt
            let rate = v - b * (w * dt)
            position = target + moved * e
            velocity = rate * e
        } else if z < 1.0 {
            // x(t) = e^(−zwt) (x cos(wd t) + ((v + z w x) / wd) sin(wd t))
            let wd = w * (1.0 - z * z).squareRoot()
            let e = exp(-z * w * dt)
            let c = cos(wd * dt)
            let s = sin(wd * dt) / wd
            let lean = v + x * (z * w)
            let moved = x * c + lean * s
            let pull = v * (z * w) + x * (w * w)
            let rate = v * c - pull * s
            position = target + moved * e
            velocity = rate * e
        } else {
            // x(t) = c1 e^(r1 t) + c2 e^(r2 t), with the two real roots r1 > r2 of r² + 2 z w r + w² = 0.
            let root = (z * z - 1.0).squareRoot()
            let r1 = -w * (z - root)
            let r2 = -w * (z + root)
            let c1 = (v - x * r2) / (r1 - r2)
            let c2 = x - c1
            let e1 = exp(r1 * dt)
            let e2 = exp(r2 * dt)
            let moved = c1 * e1 + c2 * e2
            let rate = c1 * (r1 * e1) + c2 * (r2 * e2)
            position = target + moved
            velocity = rate
        }
    }
}

public enum Squash {
    /// The widest and flattest the stone gets: x scale 1 + depth, y scale 1 − depth.
    static let depth = 0.14

    /// The lock's squash: scale (x, y) at t seconds after the lock. x widens and y flattens along half a sine, up to
    /// 1.14 / 0.86 at the middle, and both are back at 1 at `duration`. (1, 1) outside 0...duration.
    public static func scale(at t: Double, duration: Double = 0.06) -> SIMD2<Double> {
        if !(duration > 0) || !(t > 0) || t >= duration { return FeelPoint(1.0, 1.0) }
        let s = sin(Double.pi * t / duration)
        return FeelPoint(1.0 + depth * s, 1.0 - depth * s)
    }
}

/// One shard in flight.
public struct ShardBody: Sendable, Equatable {
    /// The shard's centroid, scene pt (y up).
    public var position: SIMD2<Double>
    /// Pt/s.
    public var velocity: SIMD2<Double>
    /// Rad, counter-clockwise, 0 at the burst.
    public var angle: Double
    /// Rad/s.
    public var spin: Double
    /// True once it has bounced off the floor: from then on it falls through.
    public var bounced: Bool

    public init(position: SIMD2<Double>, velocity: SIMD2<Double>, angle: Double = 0, spin: Double = 0,
                bounced: Bool = false) {
        self.position = position
        self.velocity = velocity
        self.angle = angle
        self.spin = spin
        self.bounced = bounced
    }
}

/// The shards' flight after the burst: thrown out from the gaze point, pulled down, slowed by the air, one bounce.
public struct ShardFlight: Sendable, Equatable {
    /// Same order as the shards given to `burst`.
    public var bodies: [ShardBody]
    /// Pt/s², pulls toward −y.
    public var gravity: Double
    /// Linear, 1/s: the speed falls by e every 1/drag seconds.
    public var drag: Double
    /// Scene pt. Each shard bounces once off this height, then falls through it.
    public var floorY: Double
    /// The share of the downward speed a shard keeps, upward, at its bounce.
    public var restitution: Double
    /// Seconds since the burst.
    public var age: Double

    public init(bodies: [ShardBody], gravity: Double = 1400, drag: Double = 1.6, floorY: Double,
                restitution: Double = 0.35, age: Double = 0) {
        self.bodies = bodies
        self.gravity = gravity
        self.drag = drag
        self.floorY = floorY
        self.restitution = restitution
        self.age = age
    }

    /// The shards of a stone whose centre is at `center` (scene pt) fly away from `impact` (stone-local pt, the
    /// one the stone was shattered at): each along the line from the impact through its centroid, turned by up to
    /// ±25°, at `speed` × (0.6…1.2) pt/s, larger shards slower (× 0.8…1.25 by size), plus an upward kick of
    /// 0.35 × speed. Spin ±(4…12) rad/s. A shard that starts below the floor does not bounce.
    public static func burst(_ shards: [Shard], center: SIMD2<Double>, impact: SIMD2<Double>, floorY: Double,
                             speed: Double = 260, rng: inout FeelRandom) -> ShardFlight {
        var total = 0.0
        for shard in shards { total += shard.area }
        let mean = shards.isEmpty ? 0.0 : total / Double(shards.count)
        let spread = 25.0 * Double.pi / 180.0

        var bodies: [ShardBody] = []
        bodies.reserveCapacity(shards.count)
        for shard in shards {
            let away = shard.centroid - impact
            // Drawn for every shard, used only for one that sits on the impact, so the draws stay in step.
            var heading = rng.uniform(0.0, 2.0 * Double.pi)
            if FeelMath.length(away) > 1e-9 { heading = atan2(away.y, away.x) }
            heading += rng.uniform(-spread, spread)
            var size = 1.0
            if mean > 0 && shard.area > 0 {
                size = FeelMath.clamp(pow(mean / shard.area, 0.25), 0.8, 1.25)
            }
            let pace = speed * rng.uniform(0.6, 1.2) * size
            let velocity = FeelPoint(pace * cos(heading), pace * sin(heading) + 0.35 * speed)
            let side = rng.unit() < 0.5 ? -1.0 : 1.0
            let spin = side * rng.uniform(4.0, 12.0)
            let start = center + shard.centroid
            bodies.append(ShardBody(position: start, velocity: velocity, angle: 0, spin: spin,
                                    bounced: start.y < floorY))
        }
        return ShardFlight(bodies: bodies, floorY: floorY)
    }

    /// Moves every shard on by dt seconds: semi-implicit Euler in sub-steps of at most 1/120 s (velocity first,
    /// then position with the new velocity).
    public mutating func step(dt: Double) {
        if !(dt > 0) || !dt.isFinite { return }
        // The 1e-9 keeps a dt of exactly 1/60 or 1/120 s from gaining a sub-step through rounding.
        let parts = min(100_000, max(1, Int((min(dt, 1000.0) * 120.0 - 1e-9).rounded(.up))))
        let h = dt / Double(parts)
        let slow = exp(-drag * h)
        let spinSlow = exp(-0.5 * drag * h)
        for _ in 0..<parts {
            for i in 0..<bodies.count {
                var body = bodies[i]
                body.velocity.y -= gravity * h
                body.velocity = body.velocity * slow
                body.position = body.position + body.velocity * h
                body.spin *= spinSlow
                body.angle += body.spin * h
                if !body.bounced && body.position.y < floorY && body.velocity.y < 0 {
                    // Back above the floor by what it sank under it, with what is left of its speed.
                    body.position.y = floorY + (floorY - body.position.y) * restitution
                    body.velocity.y = -body.velocity.y * restitution
                    body.velocity.x *= 0.8
                    body.spin *= 0.6
                    body.bounced = true
                }
                bodies[i] = body
            }
        }
        age += dt
    }
}

/// One mote's path from the burst into the collection jar.
public struct MotePath: Sendable, Equatable {
    /// Scene pt.
    public var start: SIMD2<Double>
    /// The Bézier control point, scene pt: the path bows toward it.
    public var control: SIMD2<Double>
    /// Scene pt.
    public var end: SIMD2<Double>
    /// Seconds after the burst at which the mote sets off.
    public var delay: Double
    /// Seconds from setting off to arriving.
    public var duration: Double

    public init(start: SIMD2<Double>, control: SIMD2<Double>, end: SIMD2<Double>, delay: Double, duration: Double) {
        self.start = start
        self.control = control
        self.end = end
        self.delay = delay
        self.duration = duration
    }

    /// Where the mote is (scene pt) t seconds after the burst: a quadratic Bézier with smoothstep easing. `start`
    /// before `delay`, `end` after delay + duration.
    public func point(at t: Double) -> SIMD2<Double> {
        if !(t > delay) { return start }
        if !(duration > 0) || t >= delay + duration { return end }
        let u = (t - delay) / duration
        let s = u * u * (3.0 - 2.0 * u)
        let r = 1.0 - s
        let first = start * (r * r)
        let middle = control * (2.0 * r * s)
        let last = end * (s * s)
        return first + middle + last
    }

    /// 3...5 motes from `origin` to `jar` (scene pt). Each bows out to a random side of the straight line, by
    /// 0.2…0.45 of its length (at least 40 pt of length is assumed). Delays 0…0.12 s, durations 0.55…0.8 s.
    public static func toJar(from origin: SIMD2<Double>, jar: SIMD2<Double>, rng: inout FeelRandom) -> [MotePath] {
        let count = rng.int(in: 3...5)
        let line = jar - origin
        let length = FeelMath.length(line)
        var sideways = FeelPoint(1.0, 0.0)
        if length > 1e-9 { sideways = FeelPoint(-line.y / length, line.x / length) }
        var paths: [MotePath] = []
        paths.reserveCapacity(count)
        for _ in 0..<count {
            let side = rng.unit() < 0.5 ? -1.0 : 1.0
            let bow = side * rng.uniform(0.2, 0.45) * max(length, 40.0)
            let along = rng.uniform(0.3, 0.6)
            let control = origin + line * along + sideways * bow
            let delay = rng.uniform(0.0, 0.12)
            let duration = rng.uniform(0.55, 0.8)
            paths.append(MotePath(start: origin, control: control, end: jar, delay: delay, duration: duration))
        }
        return paths
    }
}
