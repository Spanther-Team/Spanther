import AVFoundation
import QuartzCore

/// The pop's sound layers (architecture proposal, "Sound layers"): Feel's SoundBank, synthesised once at the start
/// of a play on a background queue (about 48 variants a layer), turned into engine buffers and played on the app's one
/// engine, panned by the stone's place and varied in level, so no two hits sound the same. Nothing is computed at the
/// moment of a lock. Until the bank is ready the pop is silent.
final class PopSounds {
    private let sound = SoundEngine.shared
    private let synthQueue = DispatchQueue(label: "spanther.pop-synth", qos: .utility)
    // Read and written on the sound queue only.
    private var layers: [SoundLayer: [AVAudioPCMBuffer]] = [:]
    private var chimes: [[AVAudioPCMBuffer]] = []
    private var ladder = ChimeLadder()
    private var rng: FeelRandom
    private var held = false
    private var synthesised = false

    init(seed: UInt64) {
        rng = FeelRandom(seed: seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    /// Keeps the engine running while the game screen is up (true), or lets it pause once the last sound has rung out.
    func hold(_ on: Bool) {
        guard on != held else { return }
        held = on
        sound.hold("game", on)
    }

    /// Holds the engine for the play and synthesises the bank in the background, once.
    func prepare(seed: UInt64) {
        hold(true)
        guard !synthesised else { return }
        synthesised = true
        let sound = self.sound
        synthQueue.async { [weak self] in
            let bank = SoundBank.make(sampleRate: SoundEngine.sampleRate, seed: seed)
            var made: [SoundLayer: [AVAudioPCMBuffer]] = [:]
            for layer in [SoundLayer.charge, .crack, .pop, .crumble] {
                made[layer] = (0..<bank.count(layer)).compactMap { sound.buffer(bank.variant(layer, $0)) }
            }
            let steps = ChimeLadder.frequencies.count
            let ladder: [[AVAudioPCMBuffer]] = (0..<steps).map { step in
                (0..<bank.chimePerStep).compactMap { sound.buffer(bank.chime(step: step, variant: $0)) }
            }
            sound.queue.async {
                self?.layers = made
                self?.chimes = ladder
            }
        }
    }

    /// The gaze landed on a stone it can burn: a soft rising tone from the stone's side.
    func charge(pan: Float) {
        sound.queue.async { [weak self] in
            guard let self, let b = self.pick(.charge) else { return }
            self.sound.play(b, pan: pan, volume: 0.55)
        }
    }

    /// The lock, layered on one timeline from `hostTime` (the CACurrentMediaTime clock): the crack at once, then the
    /// pop and the chime with the burst after the squash, and the crumble as the shards fly. The chime climbs the
    /// pentatonic ladder with each lock in a row.
    func lock(pan: Float, at hostTime: Double, squash: Double = 0.06) {
        sound.queue.async { [weak self] in
            guard let self else { return }
            let step = self.ladder.next()
            let level = Float(self.rng.uniform(0.9, 1.0))
            if let b = self.pick(.crack) { self.sound.play(b, at: hostTime, pan: pan, volume: level) }
            if let b = self.pick(.pop) { self.sound.play(b, at: hostTime + squash, pan: pan, volume: level) }
            if step >= 0, step < self.chimes.count, !self.chimes[step].isEmpty {
                let row = self.chimes[step]
                let b = row[self.rng.int(in: 0...(row.count - 1))]
                self.sound.play(b, at: hostTime + squash + 0.01, pan: pan * 0.6, volume: level * 0.8)
            }
            if let b = self.pick(.crumble) { self.sound.play(b, at: hostTime + squash + 0.03, pan: pan, volume: level * 0.7) }
        }
    }

    /// A stone reached Earth, the play paused or a level ended: the next lock starts the ladder from the bottom.
    func resetLadder() {
        sound.queue.async { [weak self] in self?.ladder.reset() }
    }

    private func pick(_ layer: SoundLayer) -> AVAudioPCMBuffer? {
        guard let list = layers[layer], !list.isEmpty else { return nil }
        return list[rng.int(in: 0...(list.count - 1))]
    }
}
