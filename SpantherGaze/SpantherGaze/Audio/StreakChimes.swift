import AVFoundation
import QuartzCore

/// A streak milestone's chime (sunlit redesign, part 3): a short arpeggio up the pentatonic scale of the pop's
/// chime ladder (D major from D5), crystal bars synthesised once in the background and played on the app's one
/// engine. A higher tier plays more and higher notes. Until the notes are ready a milestone is silent.
final class StreakChimes {
    static let shared = StreakChimes()

    private let sound = SoundEngine.shared
    private let synthQueue = DispatchQueue(label: "spanther.streak-synth", qos: .utility)
    /// One buffer per step of ChimeLadder.frequencies. Read and written on the sound queue only.
    private var notes: [AVAudioPCMBuffer] = []
    // Main thread only.
    private var asked = false
    private var release: DispatchWorkItem?

    private init() {}

    /// Synthesises the notes in the background, once. Main thread.
    func prepare() {
        guard !asked else { return }
        asked = true
        let sound = self.sound
        synthQueue.async { [weak self] in
            var rng = FeelRandom(seed: 0x5EED_C41E_0000_0005)
            let made = ChimeLadder.frequencies.compactMap { f in
                sound.buffer(PopSynth.chime(.crystal, frequency: f, sampleRate: SoundEngine.sampleRate, rng: &rng))
            }
            sound.queue.async { self?.notes = made }
        }
    }

    /// The steps of the scale a tier plays, low to high.
    static func arpeggio(_ tier: Int) -> [Int] {
        switch tier {
        case 0: return [0, 2, 4]
        case 1: return [0, 2, 4, 5]
        case 2: return [1, 3, 5, 6]
        default: return [2, 4, 5, 6, 7]
        }
    }

    /// Plays a milestone's arpeggio, 85 ms between notes, spread a little from left to right. Main thread.
    func play(tier: Int) {
        prepare()
        // The engine runs while the notes ring and pauses by itself after.
        sound.hold("streak", true)
        release?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sound.hold("streak", false) }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        let steps = Self.arpeggio(tier)
        // Through the synthesis queue, so a chime asked for while the notes are still being made waits for them.
        let sound = self.sound
        synthQueue.async { sound.queue.async { [weak self] in
            guard let self, !self.notes.isEmpty else { return }
            let start = CACurrentMediaTime() + 0.03
            let mid = Double(steps.count - 1) / 2
            for (k, step) in steps.enumerated() where step < self.notes.count {
                let pan = Float((Double(k) - mid) * 0.15)
                self.sound.play(self.notes[step], at: start + 0.085 * Double(k), pan: pan, volume: 0.6)
            }
        } }
    }
}
