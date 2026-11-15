import Foundation

// The pop's sound, made sample by sample: no recordings ship with the app. A lock sounds four layers together, a
// crack, the pop itself, a chime and a crumble, each panned to where the stone was and varied a little in pitch
// and level so no two hits are the same. Everything is made once, when a play starts (PopBank), never at the
// moment of the lock.

/// The peak each layer is scaled to (dB below full scale). Together they stay under about -10 dBFS at their
/// loudest moment; the limiter in the app catches the rare stack of two pops.
public enum PopMix {
    public static let crackDB = -18.0
    public static let popDB = -14.0
    public static let chimeDB = -21.0
    public static let crumbleDB = -24.0
    /// Offsets of the layers from the lock (s): the crack and the pop at once, the crumble just after, the chime
    /// once the burst has cleared.
    public static let crumbleDelaySec = 0.012
    public static let chimeDelaySec = 0.03

    public static func gain(_ db: Double) -> Double { pow(10, db / 20) }
}

/// Mono samples in -1...1 at the output's own rate. Every layer starts at zero and fades to zero, so nothing clicks.
public struct PopSynth: Sendable {
    /// A struck bar's modes (modal synthesis): free-bar ratios for crystal, a short block for wood.
    public enum Material: Sendable, Equatable {
        case crystal, wood
        public var ratios: [Double] { self == .crystal ? [1, 2.76, 5.40, 8.93] : [1, 4, 10] }
        public var amplitudes: [Double] { self == .crystal ? [1, 0.5, 0.28, 0.14] : [1, 0.35, 0.12] }
        /// The fundamental's decay (s, to 1/e); higher modes die sooner.
        public var decaySec: Double { self == .crystal ? 0.34 : 0.07 }
    }

    public let sampleRate: Double

    public init(sampleRate: Double) { self.sampleRate = max(8000, sampleRate) }

    private func samples(_ sec: Double) -> Int { max(1, Int((sec * sampleRate).rounded(.up))) }

    /// The crack: a burst of noise a few milliseconds long rung through four high resonators whose frequencies are
    /// not a harmonic row, so it sounds like stone giving way, not like a note.
    public func crack(pitch: Double = 1, burstSec: Double = 0.005, decaySec: Double = 0.035,
                      peakDB: Double = PopMix.crackDB, noise: inout FeelRandom) -> [Float] {
        let fs = sampleRate
        let burst = samples(burstSec)
        let total = burst + samples(5 * decaySec)
        var excitation = [Double](repeating: 0, count: total)
        for i in 0..<burst {
            excitation[i] = noise.uniform(-1, 1) * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(burst)))
        }
        let ratios = [1.0, 1.47, 2.09, 2.83], gains = [1.0, 0.8, 0.6, 0.45], decays = [1.0, 0.8, 0.65, 0.5]
        var out = [Double](repeating: 0, count: total)
        for k in ratios.indices {
            let f = 2600 * pitch * ratios[k]
            guard f < 0.45 * fs else { continue }
            // A two-pole resonator: a pole pair at the mode's frequency, as near the unit circle as its decay asks.
            let r = exp(-1 / (decaySec * decays[k] * fs))
            let a1 = 2 * r * cos(2 * Double.pi * f / fs), a2 = -r * r
            let g = gains[k] * (1 - r * r)
            var y1 = 0.0, y2 = 0.0
            for i in 0..<total {
                let y = a1 * y1 + a2 * y2 + g * excitation[i]
                out[i] += y
                y2 = y1
                y1 = y
            }
        }
        return Self.finish(&out, peakDB: peakDB, fadeSec: 0.003, sampleRate: fs)
    }

    /// The pop: a sine that falls from about 400 to 150 Hz in 30 ms (the body), with a puff of soft noise on top.
    public func pop(pitch: Double = 1, startHz: Double = 400, endHz: Double = 150, sweepSec: Double = 0.03,
                    decaySec: Double = 0.024, puff: Double = 0.35, peakDB: Double = PopMix.popDB,
                    noise: inout FeelRandom) -> [Float] {
        let fs = sampleRate
        let attack = 0.0015
        let total = samples(attack + 6 * decaySec)
        let f0 = startHz * pitch, f1 = endHz * pitch
        let smooth = 1 - exp(-2 * Double.pi * 1400 * pitch / fs)
        var out = [Double](repeating: 0, count: total)
        var phase = 0.0, air = 0.0
        for i in 0..<total {
            let t = Double(i) / fs
            let rise = t < attack ? 0.5 - 0.5 * cos(Double.pi * t / attack) : 1
            // An exponential glide, so the fall sounds even; the phase is summed, never sin(2π f(t) t).
            let f = f0 * pow(f1 / f0, min(t, sweepSec) / sweepSec)
            let body = sin(phase) * rise * exp(-t / decaySec)
            phase += 2 * Double.pi * f / fs
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            air += smooth * (noise.uniform(-1, 1) - air)
            out[i] = body + air * puff * rise * exp(-t / 0.012)
        }
        return Self.finish(&out, peakDB: peakDB, fadeSec: 0.004, sampleRate: fs)
    }

    /// A chime at `hz`: decaying sines at the material's mode ratios. Each mode is a phasor turned and shrunk a
    /// little every sample, so the sound costs one complex multiply per mode per sample.
    public func chime(_ hz: Double, material: Material = .crystal, peakDB: Double = PopMix.chimeDB) -> [Float] {
        let fs = sampleRate
        let tau = material.decaySec
        let total = samples(3.6 * tau)
        var out = [Double](repeating: 0, count: total)
        for (k, ratio) in material.ratios.enumerated() {
            let f = hz * ratio
            guard f < 0.45 * fs else { continue }
            let step = 2 * Double.pi * f / fs
            let r = exp(-1 / (tau / ratio.squareRoot() * fs))
            let cr = r * cos(step), sr = r * sin(step)
            var re = material.amplitudes[k], im = 0.0
            for i in 0..<total {
                out[i] += im
                let next = re * cr - im * sr
                im = re * sr + im * cr
                re = next
            }
        }
        let attack = samples(0.0006)
        for i in 0..<min(attack, total) { out[i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(attack)) }
        return Self.finish(&out, peakDB: peakDB, fadeSec: 0.25 * tau, sampleRate: fs)
    }

    /// The crumble: tiny clicks at random moments, many at first and fewer and fewer, like grit settling after
    /// the break. The moments are a Poisson stream whose rate falls away as exp(-t / fadeSec), drawn by rescaling
    /// time; `clicks` gives them (s), for the haptic grains and for the tests.
    public func crumble(pitch: Double = 1, startRate: Double = 380, fadeSec: Double = 0.05, lengthSec: Double = 0.2,
                        peakDB: Double = PopMix.crumbleDB, noise: inout FeelRandom) -> (samples: [Float], clicks: [Double]) {
        let fs = sampleRate
        let total = samples(lengthSec + 0.01)
        var out = [Double](repeating: 0, count: total)
        // The expected number of clicks in `lengthSec`: the integral of the rate.
        let all = startRate * fadeSec
        let budget = all * (1 - exp(-lengthSec / fadeSec))
        var clicks: [Double] = []
        var s = 0.0
        while true {
            s -= log(1 - noise.unit())
            guard s < budget else { break }
            clicks.append(-fadeSec * log(1 - s / all))
        }
        for t in clicks {
            let start = Int(t * fs)
            let f = noise.uniform(1800, 5500) * pitch
            let decay = noise.uniform(0.0006, 0.0015)
            let level = noise.uniform(0.5, 1) * exp(-t / (2 * fadeSec)) * (noise.unit() < 0.5 ? -1 : 1)
            let step = 2 * Double.pi * f / fs
            let r = exp(-1 / (decay * fs))
            let cr = r * cos(step), sr = r * sin(step)
            var re = level, im = 0.0
            for i in 0..<min(max(0, total - start), samples(6 * decay)) {
                out[start + i] += im
                let next = re * cr - im * sr
                im = re * sr + im * cr
                re = next
            }
        }
        return (Self.finish(&out, peakDB: peakDB, fadeSec: 0.005, sampleRate: fs), clicks)
    }

    /// Fades the end to zero (half a cosine), scales the peak to `peakDB` and turns the samples into Float.
    static func finish(_ x: inout [Double], peakDB: Double, fadeSec: Double, sampleRate fs: Double) -> [Float] {
        let n = x.count
        let fade = min(n, max(1, Int(fadeSec * fs)))
        for i in 0..<fade { x[n - 1 - i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)) }
        var peak = 0.0
        for v in x { peak = max(peak, abs(v)) }
        let g = peak > 0 ? PopMix.gain(peakDB) / peak : 0
        return x.map { Float($0 * g) }
    }
}

/// Every sound a play's pops need, made once on a background queue when the play starts (about 3.5 MB at 48 kHz).
public struct PopBank: Sendable {
    public enum Layer: Int, CaseIterable, Sendable { case crack, pop, chime, crumble }

    /// The D major pentatonic the ambient pad plays in, from D4 up two octaves: D4 E4 F#4 A4 B4 D5 E5 F#5 A5 B5.
    public static let dMajorPentatonic: [Double] = [293.66, 329.63, 369.99, 440.00, 493.88, 587.33, 659.26, 739.99,
                                                    880.00, 987.77]

    public let sampleRate: Double
    public let cracks: [[Float]]
    public let pops: [[Float]]
    public let crumbles: [[Float]]
    /// One chime per step of the ladder. The chimes keep the music's pitch: only the noisy layers vary.
    public let chimes: [[Float]]
    public let ladderHz: [Double]
    /// The pitch factor of each variant of the noisy layers, in their order.
    public let pitches: [Double]

    /// `variants` of each noisy layer, their pitches spread evenly over ±`pitchSpread` and shuffled. `fixed`: one
    /// variant of each at the plain pitch, the same whatever the seed: the probe's feedback, which must not
    /// change from one session to the next.
    public static func make(sampleRate: Double, seed: UInt64, variants: Int = 12, pitchSpread: Double = 0.08,
                            ladderHz: [Double] = dMajorPentatonic, fixed: Bool = false) -> PopBank {
        let synth = PopSynth(sampleRate: sampleRate)
        let seed = fixed ? 0 : seed
        var spread = FeelRandom.stream(seed, 0x5049_5443)
        var pitches: [Double] = [1]
        if !fixed {
            let v = max(1, variants)
            pitches = []
            for k in 0..<v {
                let u: Double = (Double(k) + spread.unit()) / Double(v)
                pitches.append(1 + pitchSpread * (2 * u - 1))
            }
            for i in stride(from: pitches.count - 1, to: 0, by: -1) { pitches.swapAt(i, spread.index(i + 1)) }
        }
        var noise = FeelRandom.stream(seed, 0x4E4F_4953)
        let cracks = pitches.map { synth.crack(pitch: $0, noise: &noise) }
        let pops = pitches.map { synth.pop(pitch: $0, noise: &noise) }
        let crumbles = pitches.map { synth.crumble(pitch: $0, noise: &noise).samples }
        return PopBank(sampleRate: synth.sampleRate, cracks: cracks, pops: pops, crumbles: crumbles,
                       chimes: ladderHz.map { synth.chime($0) }, ladderHz: ladderHz, pitches: pitches)
    }

    public func variants(of layer: Layer) -> [[Float]] {
        switch layer {
        case .crack: return cracks
        case .pop: return pops
        case .chime: return chimes
        case .crumble: return crumbles
        }
    }

    public var sampleCount: Int { Layer.allCases.reduce(0) { sum, l in sum + variants(of: l).reduce(0) { $0 + $1.count } } }
    public var byteCount: Int { sampleCount * MemoryLayout<Float>.size }
}

/// Which chime a lock rings: each lock in a row climbs one step of the ladder, and a break in the row (a meteor
/// that reached Earth, or a pause longer than `breakSec`) starts it at the bottom again.
public struct ChimeLadder: Sendable, Equatable {
    public let steps: Int
    public let breakSec: Double
    public private(set) var step = -1
    private var lastLock = -Double.infinity

    public init(steps: Int, breakSec: Double = 4) {
        self.steps = max(1, steps)
        self.breakSec = breakSec
    }

    /// The step to ring for a lock at `time` (s): 0 for the first of a row, then up to the top, which repeats.
    public mutating func lock(at time: Double) -> Int {
        step = time - lastLock > breakSec ? 0 : min(steps - 1, step + 1)
        lastLock = time
        return step
    }

    public mutating func breakRow() {
        step = -1
        lastLock = -.infinity
    }
}
