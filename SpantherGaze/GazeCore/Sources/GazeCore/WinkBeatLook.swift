import Foundation

/// How Wink Beat's play layer moves (skill `metal-anime-stage`, section 2): every value is a function of track
/// time, never of frame counts or timers, so the picture stays on the music after a stutter. Plain Swift so the
/// shapes can be tested; the Metal stage only draws what these return.
public enum WinkBeatLook {
    /// How far an object's approach has come at track time `t`: 0 when it appears (`lead` before its time),
    /// 1 on its beat, clamped.
    public static func approach(_ t: Double, objectTime: Double, lead: Double) -> Double {
        guard lead > 0 else { return 1 }
        return min(1, max(0, (t - (objectTime - lead)) / lead))
    }

    /// The approach ring's radius over the hit circle's: 3 when the object appears, 1 on its beat.
    public static func ringScale(_ progress: Double) -> Double { 1 + 2 * (1 - progress) }

    /// An object fades in over the first quarter of its approach.
    public static func fadeIn(_ progress: Double) -> Double { min(1, max(0, progress / 0.25)) }

    /// The beat pulse: 1 on each beat of the track, falling to 0 over the first 35% of the beat, 0 before the
    /// first beat.
    public static func beatPulse(_ t: Double, firstBeat: Double, beatSec: Double) -> Double {
        guard beatSec > 0, t >= firstBeat else { return 0 }
        let phase = ((t - firstBeat) / beatSec).truncatingRemainder(dividingBy: 1)
        return max(0, 1 - phase / 0.35)
    }

    /// How long a hit's shockwave and shards last (s).
    public static let burstSec = 0.4

    /// A hit's shockwave at `age` seconds after the hit: its radius over the hit circle's (1 to 1.9, easing out)
    /// and its opacity. Nil once it is over or before it starts.
    public static func shockwave(age: Double) -> (scale: Double, alpha: Double)? {
        guard age >= 0, age < burstSec else { return nil }
        let k = age / burstSec
        let ease = 1 - (1 - k) * (1 - k)
        return (1 + 0.9 * ease, 1 - k)
    }

    /// Shard `k` of the hit on object `index` at `age` seconds: its offset from the circle's centre (in hit circle
    /// radii) and its size (0...1). The same object always throws the same shards. Nil once they are gone.
    public static func shard(index: Int, k: Int, age: Double) -> (offset: Vec2, size: Double)? {
        guard age >= 0, age < burstSec else { return nil }
        var rng = Rng(seed: UInt64(truncatingIfNeeded: index &* 7919 &+ k &* 104_729 &+ 17))
        let angle = rng.next() * 2 * Double.pi
        let reach = 1.25 + 1.0 * rng.next()
        let kAge = age / burstSec
        let travel = reach * (1 - (1 - kAge) * (1 - kAge))
        return (Vec2(cos(angle), sin(angle)) * travel, (1 - kAge) * (0.6 + 0.4 * rng.next()))
    }

    /// The spinner's petals that have been passed, for drawing: `hops` of `needed` in either direction, as how
    /// many petals of the 8 around the ring to show as done (0...petals).
    public static func petalsDone(hops: Int, needed: Int, petals: Int) -> Int {
        guard needed > 0 else { return petals }
        return min(petals, max(0, Int((Double(abs(hops)) / Double(needed) * Double(petals)).rounded(.down))))
    }
}
