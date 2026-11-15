import CoreHaptics

/// The pop's touch: Feel's PopHaptics patterns on one CHHapticEngine. While the gaze holds a stone, a soft low hum
/// grows toward the lock; the lock itself is a sharp tick, a heavy thud and three grains with the crumble. The
/// players are made once per play, one pair per meteor class with that class's strength (small stones are lighter
/// in the hand), so nothing is built at the moment of a lock. Its own queue; does nothing on a phone without the
/// Taptic Engine's Core Haptics, an iPad or the Simulator.
final class FeelHaptics {
    /// A meteor class: how long its hold takes and how strongly it is felt (0.6 for the smallest, 1 the largest).
    struct Kind: Equatable {
        var holdSec: Double
        var strength: Double
    }

    private let queue = DispatchQueue(label: "spanther.haptics", qos: .userInitiated)
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var running = false
    private var active = false
    private var kinds: [String: Kind] = [:]
    private var charges: [String: CHHapticAdvancedPatternPlayer] = [:]
    private var locks: [String: CHHapticPatternPlayer] = [:]
    private var charging: CHHapticAdvancedPatternPlayer?

    /// The classes of this play (from balance.json, scaled with «Мелкие цели»). Any thread.
    func prepare(_ kinds: [String: Kind]) {
        queue.async { [weak self] in
            guard let self, self.supported, kinds != self.kinds else { return }
            self.kinds = kinds
            self.makePlayers()
        }
    }

    /// The game screen opened or closed. Any thread.
    func setActive(_ on: Bool) {
        queue.async { [weak self] in
            guard let self, self.supported, on != self.active else { return }
            self.active = on
            if on {
                self.makeEngine()
                self.start()
                if self.charges.isEmpty { self.makePlayers() }
            } else {
                self.stopCharging()
                self.engine?.stop(completionHandler: nil)
                self.running = false
            }
        }
    }

    /// The gaze settled on a stone of class `kind` whose hold is `progress` (0...1) along a `dwellSec` hold: the
    /// hum starts where the hold is, at the pace of this stone's hold. Any thread.
    func startCharge(kind: String, progress: Double, dwellSec: Double) {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.stopCharging()
            self.start()
            guard self.running, let player = self.charges[kind], let k = self.kinds[kind], dwellSec > 0 else { return }
            player.playbackRate = Float(k.holdSec / dwellSec)
            do {
                try player.start(atTime: CHHapticTimeImmediate)
                if progress > 0.02 { try player.seek(toOffset: min(0.98, progress) * k.holdSec) }
                self.charging = player
            } catch {
                self.charging = nil
            }
        }
    }

    /// The look broke before the lock. Any thread.
    func stopCharge() {
        queue.async { [weak self] in self?.stopCharging() }
    }

    /// The lock of a stone of class `kind`. Any thread.
    func lock(kind: String) {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.stopCharging()
            self.start()
            guard self.running else { return }
            try? self.locks[kind]?.start(atTime: CHHapticTimeImmediate)
        }
    }

    private func stopCharging() {
        try? charging?.stop(atTime: CHHapticTimeImmediate)
        charging = nil
    }

    private func makeEngine() {
        guard engine == nil else { return }
        guard let engine = try? CHHapticEngine() else { return }
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        // Sent to the background or interrupted, the engine stops; the next touch starts it again.
        engine.stoppedHandler = { [weak self] _ in
            self?.queue.async {
                self?.running = false
                self?.charging = nil
            }
        }
        // After a reset of the haptic server the old players are gone: make them again on the restarted engine.
        engine.resetHandler = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.running = false
                self.charging = nil
                self.start()
                self.makePlayers()
            }
        }
        self.engine = engine
    }

    private func start() {
        guard active, !running, let engine else { return }
        do {
            try engine.start()
            running = true
        } catch {
            running = false
        }
    }

    private func makePlayers() {
        charges = [:]
        locks = [:]
        guard let engine else { return }
        for (name, k) in kinds {
            let (events, curve) = PopHaptics.charge(holdSec: k.holdSec)
            let rise = CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                                              controlPoints: curve.map {
                                                  CHHapticParameterCurve.ControlPoint(relativeTime: $0.time,
                                                                                      value: Float($0.value))
                                              },
                                              relativeTime: 0)
            if let pattern = try? CHHapticPattern(events: events.map { event($0, strength: k.strength) },
                                                  parameterCurves: [rise]),
               let player = try? engine.makeAdvancedPlayer(with: pattern) {
                charges[name] = player
            }
            if let pattern = try? CHHapticPattern(events: PopHaptics.lock.map { event($0, strength: k.strength) },
                                                  parameters: []),
               let player = try? engine.makePlayer(with: pattern) {
                locks[name] = player
            }
        }
    }

    private func event(_ e: PopHaptics.Event, strength: Double) -> CHHapticEvent {
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(min(1, max(0, e.intensity * strength)))),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(e.sharpness)),
        ]
        if e.duration > 0 {
            return CHHapticEvent(eventType: .hapticContinuous, parameters: parameters, relativeTime: e.time,
                                 duration: e.duration)
        }
        return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: e.time)
    }
}
