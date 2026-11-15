import Foundation

/// The pop's touch, as plain numbers. The app turns them into Core Haptics patterns once, when a play starts, and
/// afterwards only starts the players and turns their intensity, so nothing is built at the moment of the lock.
/// The lock's taps fall on the same moments as the sound's layers (PopMix).
public enum PopHaptics {
    public struct Event: Sendable, Equatable {
        /// From the start of the pattern (s).
        public let time: Double
        /// 0 for a tap (a transient event); above 0, a hum that long (a continuous event).
        public let duration: Double
        /// 0...1 each.
        public let intensity: Double
        public let sharpness: Double

        public init(time: Double, duration: Double = 0, intensity: Double, sharpness: Double) {
            self.time = time
            self.duration = duration
            self.intensity = intensity
            self.sharpness = sharpness
        }
    }

    /// A point of a curve that scales a pattern's intensity over time (0...1).
    public struct CurvePoint: Sendable, Equatable {
        public let time: Double
        public let value: Double
    }

    /// While the gaze holds a stone: a faint, low hum that grows toward the lock. It lasts `holdSec`; the app stops
    /// it early when the look breaks.
    public static func charge(holdSec: Double) -> (events: [Event], intensity: [CurvePoint]) {
        let length = max(0.05, holdSec)
        return ([Event(time: 0, duration: length, intensity: 1, sharpness: 0.12)],
                [CurvePoint(time: 0, value: 0.1), CurvePoint(time: length * 0.6, value: 0.25),
                 CurvePoint(time: length, value: 0.45)])
    }

    /// The lock: a sharp tick with the crack, a soft heavy thud with the pop, and three grains that thin out with
    /// the crumble. The app scales it by the stone's size (0.6 small ... 1 large).
    public static let lock: [Event] = [
        Event(time: 0, intensity: 0.55, sharpness: 0.95),
        Event(time: 0.004, intensity: 0.9, sharpness: 0.22),
        Event(time: PopMix.crumbleDelaySec + 0.018, intensity: 0.26, sharpness: 0.6),
        Event(time: PopMix.crumbleDelaySec + 0.04, intensity: 0.2, sharpness: 0.6),
        Event(time: PopMix.crumbleDelaySec + 0.075, intensity: 0.14, sharpness: 0.55),
    ]
}
