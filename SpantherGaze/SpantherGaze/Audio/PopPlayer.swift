import AVFoundation
import QuartzCore

/// The sound of a stone breaking: Feel's four layers (crack, pop, chime, crumble), rendered once into a PopBank at
/// the output's own rate and mixed for each lock into one of a few pooled voices. It has its own AVAudioEngine and
/// queue, like AmbientPlayer: the pad pauses its engine while it is silent, and the pops need theirs running the
/// whole time the game is on screen. Nothing here runs on the main thread, and nothing is allocated at a lock:
/// every voice keeps its own buffer, written only while its node is stopped.
final class PopPlayer {
    private struct Voice {
        let node: AVAudioPlayerNode
        let buffer: AVAudioPCMBuffer
        /// When the sound in the buffer is over (CACurrentMediaTime), so a free voice can be told from a busy one.
        var busyUntil = 0.0
    }

    /// Locks come at most a few a second and the longest sound (the chime) lasts 1.3 s.
    static let voiceCount = 8

    private let queue = DispatchQueue(label: "spanther.pop", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var bank: PopBank?
    private var voices: [Voice] = []
    private var ladder = ChimeLadder(steps: PopBank.dMajorPentatonic.count)
    private var lastVariant = -1
    private var rng = SystemRandomNumberGenerator()
    /// A new set of variants each launch, so two plays never sound quite alike.
    private let seed = UInt64.random(in: 0...UInt64.max)
    private var active = false
    private var observers: [NSObjectProtocol] = []
    private var configObserver: NSObjectProtocol?
    private var state = "off"
    private var rate = 0.0
    private var played = 0

    init() {
        // A call or an alarm stops the engine; when it is over the pops come back if the game is still on.
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.queue.async { self?.start() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine?.stop()
    }

    /// The game screen opened (true) or closed (false). The first opening builds the engine and the bank. Any thread.
    func setActive(_ on: Bool) {
        queue.async { [weak self] in self?.apply(on) }
    }

    /// A stone broke. `size`: 0 for the smallest class to 1 for the largest (smaller stones crack higher and a
    /// little softer); `pan`: -1 at the left edge to 1 at the right. Any thread.
    func lock(size: Double, pan: Double) {
        let now = CACurrentMediaTime()
        queue.async { [weak self] in self?.play(size: size, pan: pan, at: now) }
    }

    /// A meteor got through: the next lock rings the bottom of the ladder again.
    func breakRow() {
        queue.async { [weak self] in self?.ladder.breakRow() }
    }

    private func apply(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            if engine == nil { build() }
            start()
        } else {
            for i in voices.indices {
                voices[i].node.stop()
                voices[i].busyUntil = 0
            }
            engine?.pause()
        }
    }

    private func start() {
        guard active, let engine, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
            state = "on"
        } catch {
            state = "failed"
        }
    }

    /// The engine: `voiceCount` mono player nodes into the main mixer, which pans them, at the output's rate.
    private func build() {
        let session = AVAudioSession.sharedInstance()
        // Playback, like the music and the rhythm tracks, so it sounds with the ring switch off; mixed with the
        // player's own music if any is playing.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        let engine = AVAudioEngine()
        // Without an output (a Simulator on a machine with no sound card) connecting a node would raise an
        // exception Swift cannot catch, so the format is checked first.
        let out = engine.outputNode.outputFormat(forBus: 0)
        guard out.sampleRate >= 8000, out.channelCount > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: out.sampleRate, channels: 1) else {
            state = "no output"
            return
        }
        if bank?.sampleRate != out.sampleRate { bank = PopBank.make(sampleRate: out.sampleRate, seed: seed) }
        guard let bank else { return }
        ladder = ChimeLadder(steps: max(1, bank.chimes.count))
        var voices: [Voice] = []
        for _ in 0..<Self.voiceCount {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(bank.lockCapacity))
            else { continue }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: mono)
            voices.append(Voice(node: node, buffer: buffer))
        }
        engine.prepare()
        // When the output changes (headphones, a speaker) the engine stops by itself: build a new one.
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.engine?.stop()
                self.engine = nil
                self.voices = []
                if self.active {
                    self.build()
                    self.start()
                }
            }
        }
        self.engine = engine
        self.voices = voices
        rate = out.sampleRate
    }

    private func play(size: Double, pan: Double, at time: Double) {
        guard active, let engine, engine.isRunning, let bank, !voices.isEmpty else { return }
        let s = min(1, max(0, size))
        // The noisy layers: a variant near the stone's size on the pitch scale, never the same one twice running.
        let order = bank.variantsByPitch
        let centre = Int((s * Double(order.count - 1)).rounded())
        var pick = min(order.count - 1, max(0, centre + Int.random(in: -1...1, using: &rng)))
        if order[pick] == lastVariant { pick = pick == 0 ? min(order.count - 1, 1) : pick - 1 }
        let variant = order[pick]
        lastVariant = variant
        let step = ladder.lock(at: time)
        // A free voice, or else the one that will be done soonest.
        let now = CACurrentMediaTime()
        guard let i = voices.indices.first(where: { voices[$0].busyUntil <= now })
                ?? voices.indices.min(by: { voices[$0].busyUntil < voices[$1].busyUntil }) else { return }
        let voice = voices[i]
        // Stopped, the node lets go of the buffer, so it can be written again.
        voice.node.stop()
        guard let data = voice.buffer.floatChannelData?[0] else { return }
        let n = bank.renderLock(variant: variant, step: step, gain: Float(0.8 + 0.2 * s),
                                into: UnsafeMutableBufferPointer(start: data, count: Int(voice.buffer.frameCapacity)))
        guard n > 0 else { return }
        voice.buffer.frameLength = AVAudioFrameCount(n)
        // Panned only part of the way: a stone at the edge is heard from that side, not from one speaker alone.
        voice.node.pan = Float(min(1, max(-1, pan)) * 0.6)
        voice.node.scheduleBuffer(voice.buffer, at: nil, options: [], completionHandler: nil)
        voice.node.play()
        voices[i].busyUntil = now + Double(n) / bank.sampleRate + 0.05
        played += 1
    }

    /// One line for the debug file of the Simulator run: whether the engine ran and how many locks it sounded.
    func debugLine() -> String {
        queue.sync { String(format: "pops %@, %.0f Hz, %ld locks, %ld voices", state, rate, played, voices.count) }
    }
}
