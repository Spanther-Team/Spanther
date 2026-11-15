import CoreHaptics
import Foundation

/// The pop's haptics (architecture proposal, "Audio and haptics engine"): one CHHapticEngine with three prebuilt
/// advanced pattern players, steered by dynamic parameters instead of a new pattern per hit:
/// - charge: a faint continuous rumble while the gaze holds a stone, rising with the hold;
/// - crack: a sharp tick at the lock;
/// - thud: a soft heavy knock as the shards burst, 60 ms later.
/// Phones without haptics (and the Simulator) get nothing, silently. Called from the game loop on the main thread.
final class Haptics {
    static let shared = Haptics()

    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var charge: CHHapticAdvancedPatternPlayer?
    private var crack: CHHapticAdvancedPatternPlayer?
    private var thud: CHHapticAdvancedPatternPlayer?
    private var charging = false
    private var sentLevel = -1.0

    private init() {}

    /// Makes the engine and the players (at the start of a play), so nothing is built at the moment of a lock.
    func prepare() {
        guard supported, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            // After a reset (the app went to the background, a media server restart) the players are rebuilt.
            engine.resetHandler = { [weak self] in
                DispatchQueue.main.async { self?.rebuildPlayers() }
            }
            engine.stoppedHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.charging = false }
            }
            try engine.start()
            self.engine = engine
            rebuildPlayers()
        } catch {
            engine = nil
        }
    }

    private func rebuildPlayers() {
        guard let engine else { return }
        try? engine.start()
        charge = Self.player(engine, events: [
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15),
            ], relativeTime: 0, duration: 3),
        ])
        charge?.loopEnabled = true
        crack = Self.player(engine, events: [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
            ], relativeTime: 0),
        ])
        thud = Self.player(engine, events: [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
            ], relativeTime: 0.01, duration: 0.07),
        ])
        charging = false
    }

    private static func player(_ engine: CHHapticEngine, events: [CHHapticEvent]) -> CHHapticAdvancedPatternPlayer? {
        guard let pattern = try? CHHapticPattern(events: events, parameters: []) else { return nil }
        return try? engine.makeAdvancedPlayer(with: pattern)
    }

    /// The gaze landed on a stone it can burn: the rumble starts faint.
    func chargeBegan() {
        guard let charge, !charging else { return }
        charging = true
        sentLevel = -1
        try? engine?.start()
        setLevel(0.15)
        try? charge.start(atTime: CHHapticTimeImmediate)
    }

    /// The hold's progress 0...1: the rumble rises with it. Sent only when it changed enough to be felt.
    func chargeProgress(_ progress: Double) {
        guard charging else { return }
        setLevel(0.15 + 0.6 * max(0, min(1, progress)))
    }

    /// The gaze left (the cracks heal) or the stone locked.
    func chargeEnded() {
        guard charging else { return }
        charging = false
        try? charge?.stop(atTime: CHHapticTimeImmediate)
    }

    /// The lock: a sharp crack now and the thud of the burst after the 60 ms squash.
    func lock(burstAfter squash: Double = 0.06) {
        chargeEnded()
        guard let engine else { return }
        try? crack?.start(atTime: CHHapticTimeImmediate)
        try? thud?.start(atTime: engine.currentTime + squash)
    }

    private func setLevel(_ level: Double) {
        guard let charge, abs(level - sentLevel) > 0.04 else { return }
        sentLevel = level
        try? charge.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(level),
                                                             relativeTime: 0)], atTime: CHHapticTimeImmediate)
    }
}
