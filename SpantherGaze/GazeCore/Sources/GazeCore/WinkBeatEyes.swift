import Foundation

// Wink Beat's eyes: turns each tracking frame (aim and lid closure) into a blink-safe aim and the closures that may
// play objects. Three rules keep blinks harmless:
// 1. Both eyes closing within the pair window is a blink (`WinkDetector`, 25 ms measured on the phone): never a hit.
// 2. A closure is judged with the aim from `preOnsetSec` before its onset. A wink squeezes the face and the tracked
//    gaze slides while the lid comes down; that slide never decides which object was played.
// 3. While any eye is closed, and `settleSec` after both open, the aim holds its last good point, so a blink in the
//    middle of a slider or spinner does not count as looking away.

public struct WinkBeatEyesConfig: Equatable, Sendable {
    public var wink = WinkConfig()
    /// Aim used for a closure: from this long before its onset (s).
    public var preOnsetSec = 0.1
    /// The aim stays held this long after both eyes are open again (s).
    public var settleSec = 0.1
    /// A two-eye closure this long is a deliberate long blink (s). Normal blinks close for about 0.1 to 0.2 s.
    /// To be set from a phone CSV.
    public var longBlinkSec = 0.3
    public init() {}
}

public struct WinkBeatEyes: Sendable {
    public enum Closure: Equatable, Sendable {
        /// One eye: may play an object. `aim` from before the onset.
        case wink(side: WinkSide, onset: Double, aim: Vec2?)
        /// Both eyes held closed for `longBlinkSec`: plays `any` objects on easy. Sent once the closure has lasted.
        case longBlink(onset: Double, aim: Vec2?)
        /// An ordinary blink, sent when the eyes open: never plays anything, kept for the session log.
        case blink(onset: Double, durationSec: Double)
    }

    public let config: WinkBeatEyesConfig
    public private(set) var detector: WinkDetector
    /// Aims seen while both eyes were open and settled (time, pt).
    private var history: [(time: Double, aim: Vec2)] = []
    private var heldUntil: Double?
    private var held: Vec2?
    private var blink: (onset: Double, aim: Vec2?, long: Bool)?

    public init(config: WinkBeatEyesConfig = WinkBeatEyesConfig()) {
        self.config = config
        detector = WinkDetector(config.wink)
    }

    /// Whether the aim is being held for a closure right now.
    public var holding: Bool { heldUntil != nil }

    /// One frame: `time` (s, the tracking clock or track time, the same for every call), the raw aim (pt, nil when
    /// there is none) and each eye's closure (0 open ... 1 closed). Returns the aim to use this frame and any
    /// closures that ended their decision on it.
    public mutating func update(time: Double, aim raw: Vec2?, left: Double, right: Double)
        -> (aim: Vec2?, closures: [Closure]) {
        let event = detector.update(time: time, left: left, right: right)
        let base = detector.openLevel(), cfg = config.wink
        let leftOpen = left < max(cfg.openThreshold, base.left + cfg.openRise)
        let rightOpen = right < max(cfg.openThreshold, base.right + cfg.openRise)
        history.removeAll { time - $0.time > 1.0 }

        if !(leftOpen && rightOpen) {
            if heldUntil == nil { held = aim(before: time - config.preOnsetSec) ?? held }
            heldUntil = time + config.settleSec
        } else if let until = heldUntil, time >= until {
            heldUntil = nil
        }
        var out: Vec2? = raw
        if heldUntil != nil {
            out = held
        } else if let r = raw {
            history.append((time, r))
            held = r
        }

        var closures: [Closure] = []
        if let e = event {
            if e.side == .both {
                blink = (e.onset, aim(before: e.onset - config.preOnsetSec), false)
            } else {
                closures.append(.wink(side: e.side, onset: e.onset, aim: aim(before: e.onset - config.preOnsetSec)))
            }
        }
        if let b = blink {
            if leftOpen || rightOpen {
                if !b.long { closures.append(.blink(onset: b.onset, durationSec: time - b.onset)) }
                blink = nil
            } else if !b.long, time - b.onset >= config.longBlinkSec {
                closures.append(.longBlink(onset: b.onset, aim: b.aim))
                blink?.long = true
            }
        }
        return (out, closures)
    }

    /// Face lost: forget the half-seen closure and the held aim.
    public mutating func faceLost() {
        detector.faceLost()
        history.removeAll()
        heldUntil = nil
        held = nil
        blink = nil
    }

    /// The last good aim at or before `t`, else the oldest one kept.
    private func aim(before t: Double) -> Vec2? {
        history.last { $0.time <= t }?.aim ?? history.first?.aim
    }
}

extension WinkBeatEyes.Closure {
    /// The closure as the judge takes it, or nil for an ordinary blink.
    public var forJudge: WinkBeatClosure? {
        switch self {
        case let .wink(side, onset, aim): return WinkBeatClosure(side: side, time: onset, aim: aim)
        case let .longBlink(onset, aim): return WinkBeatClosure(side: .both, time: onset, aim: aim)
        case .blink: return nil
        }
    }
}
