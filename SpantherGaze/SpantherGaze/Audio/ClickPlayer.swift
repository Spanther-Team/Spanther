import AVFoundation
import QuartzCore

/// Short metronome clicks for the wink test, played by the app's one engine (SoundEngine) and started on the host
/// clock, so each one is heard on its beat. The click is synthesised here (a 35 ms tone with a fast decay), so the app
/// ships no sound files.
final class ClickPlayer {
    private let sound = SoundEngine.shared
    private let normal: AVAudioPCMBuffer?
    private let accent: AVAudioPCMBuffer?
    /// Seconds the audio route adds before a sound is heard: about 0.01 on the speaker, 0.15-0.25 on Bluetooth.
    /// Clicks start this much earlier, and the session CSV records it (`audio_latency_s`).
    private(set) var outputLatency = 0.0

    init() {
        let session = AVAudioSession.sharedInstance()
        // Playback, so the clicks sound with the ring/silent switch off; mixing, so other audio is not stopped.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        outputLatency = session.outputLatency
        sound.hold("clicks", true)
        normal = sound.buffer(Self.click(frequency: 1200))
        accent = sound.buffer(Self.click(frequency: 2000))
    }

    deinit {
        sound.hold("clicks", false)
    }

    /// Plays a click heard at `hostTime` (the CACurrentMediaTime clock, which ARKit frame timestamps share).
    /// `pan`: -1 left ... 1 right. The count-in uses the higher `accent` click.
    func play(at hostTime: Double, pan: Float = 0, accent useAccent: Bool = false) {
        guard let buffer = useAccent ? accent : normal else { return }
        let start = hostTime - outputLatency
        let sound = self.sound
        sound.queue.async { sound.play(buffer, at: start, pan: pan, volume: 0.8) }
    }

    func stop() { sound.stopVoices() }

    /// Mono samples at the engine's rate: a sine at `frequency` with a 1 ms attack and an exponential decay.
    static func click(frequency: Double, duration: Double = 0.035) -> [Float] {
        let rate = SoundEngine.sampleRate
        let n = Int(rate * duration)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let envelope = exp(-t * 90) * min(1, t / 0.001)
            out[i] = Float(sin(2 * Double.pi * frequency * t) * envelope)
        }
        return out
    }
}
