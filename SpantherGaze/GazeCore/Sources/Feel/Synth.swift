import Foundation

// The sound of the pop, made here from numbers so the app ships no sound file for it. Five short layers: the
// charge (a swell while the gaze holds), the crack, the pop itself, a chime that climbs a five-note scale with each
// lock in a row, and a crumble of small clicks as the shards fall. Each is a mono Float buffer in −1...1.
// Where a layer is modal it is y(t) = Σ a_k e^(−t/τ_k) sin(2π f_k t + φ_k).
//
// No buffer clicks: every one starts and ends at zero. The sharp layers (crack, pop, chime, crumble) begin with
// `PopSynth.leadIn` seconds of silence, far too short to hear as a delay, so their first sample is quiet and their
// attack can still be fast.

/// What the chime sounds like it is made of.
public enum ChimeMaterial: String, Sendable, CaseIterable {
    case crystal, wood

    /// Each partial's frequency as a multiple of the note's: a free bar for crystal, a struck block for wood.
    public var ratios: [Double] {
        switch self {
        case .crystal: return [1.0, 2.76, 5.40, 8.93]
        case .wood: return [1.0, 4.0, 10.0]
        }
    }

    /// τ per partial, seconds (the time to fall by e). Crystal rings on, higher partials shorter; wood is short.
    public var decays: [Double] {
        switch self {
        case .crystal: return [0.35, 0.22, 0.12, 0.07]
        case .wood: return [0.06, 0.035, 0.02]
        }
    }

    /// The buffer's length, seconds.
    public var duration: Double {
        switch self {
        case .crystal: return 0.7
        case .wood: return 0.25
        }
    }
}

public enum PopSynth {
    /// Seconds of silence at the start of the sharp layers.
    static let leadIn = 0.00075
    /// The pop's sweep reaches its low pitch after this many seconds and stays there.
    static let popSweepSec = 0.026
    /// Each layer leaves its generator with this peak; the sound bank sets the playing level.
    static let rawPeak = 0.9

    static func leadSamples(_ sampleRate: Double) -> Int {
        return max(0, Int((leadIn * sampleRate).rounded(.up)))
    }

    static func sampleCount(_ duration: Double, _ sampleRate: Double) -> Int {
        return max(0, Int((duration * sampleRate).rounded()))
    }

    /// Σ a_k e^(−t/τ_k) sin(2π f_k t + φ_k) over `duration` seconds. Frequencies in Hz, decays (τ) in seconds,
    /// phases in rad (a missing phase is 0). Partials at or above half the sample rate are left out. Not shaped and
    /// not limited: the first sample is Σ a_k sin(φ_k).
    public static func modal(frequencies: [Double], amplitudes: [Double], decays: [Double], phases: [Double],
                             duration: Double, sampleRate: Double) -> [Float] {
        let n = sampleCount(duration, sampleRate)
        var sum = [Double](repeating: 0.0, count: n)
        let partials = min(frequencies.count, min(amplitudes.count, decays.count))
        for k in 0..<partials {
            let f = frequencies[k]
            if !(f > 0) || f >= 0.5 * sampleRate { continue }
            let phase = k < phases.count ? phases[k] : 0.0
            let turn = 2.0 * Double.pi * f / sampleRate
            let fade = decays[k] > 0 ? exp(-1.0 / (decays[k] * sampleRate)) : 0.0
            // A decaying phasor, turned once per sample: no sin or exp inside the loop.
            let stepRe = fade * cos(turn)
            let stepIm = fade * sin(turn)
            var re = amplitudes[k] * cos(phase)
            var im = amplitudes[k] * sin(phase)
            for i in 0..<n {
                sum[i] += im
                let nextRe = re * stepRe - im * stepIm
                im = re * stepIm + im * stepRe
                re = nextRe
            }
        }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = Float(sum[i]) }
        return out
    }

    /// Charge: a soft rising swell, 0.18 s, gliding from 300 to 420 Hz × pitch with a little second harmonic.
    /// Raised-cosine attack over the first 72% and release over the rest: no click at either end.
    public static func charge(sampleRate: Double, pitch: Double, rng: inout FeelRandom) -> [Float] {
        let n = sampleCount(0.18, sampleRate)
        let overtone = rng.uniform(0.12, 0.25)
        var phase = rng.uniform(0.0, 2.0 * Double.pi)
        let f0 = 300.0 * pitch
        let f1 = 420.0 * pitch
        let peakAt = 0.72
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let u = Double(i) / Double(max(1, n - 1))
            let glide = u * u * (3.0 - 2.0 * u)
            let f = f0 + (f1 - f0) * glide
            var env = 0.0
            if u < peakAt {
                env = 0.5 - 0.5 * cos(Double.pi * u / peakAt)
            } else {
                env = 0.5 + 0.5 * cos(Double.pi * (u - peakAt) / (1.0 - peakAt))
            }
            let tone = sin(phase) + overtone * sin(2.0 * phase)
            out[i] = Float(env * tone)
            phase += 2.0 * Double.pi * f / sampleRate
        }
        fit(&out)
        return out
    }

    /// Crack: a 3–8 ms noise burst through 3–4 high inharmonic resonators (two-pole resonant filters, one in each
    /// slice of 2.5–7 kHz × pitch, kept under 0.45 × sample rate), each ringing out in 20–60 ms. 0.08 s in all.
    public static func crack(sampleRate: Double, pitch: Double, rng: inout FeelRandom) -> [Float] {
        let n = sampleCount(0.08, sampleRate)
        let lead = leadSamples(sampleRate)
        let burst = max(2, Int((rng.uniform(0.003, 0.008) * sampleRate).rounded()))
        var excite = [Double](repeating: 0.0, count: n)
        for i in 0..<burst {
            let u = Double(i) / Double(burst)
            let noise = rng.uniform(-1.0, 1.0)
            let at = lead + i
            if at < n { excite[at] = noise * (1.0 - u) * (1.0 - u) }
        }
        let count = rng.int(in: 3...4)
        var sum = [Double](repeating: 0.0, count: n)
        for k in 0..<count {
            let low = 2500.0 + 4500.0 * Double(k) / Double(count)
            let high = 2500.0 + 4500.0 * Double(k + 1) / Double(count)
            let f = min(rng.uniform(low, high) * pitch, 0.45 * sampleRate)
            // The time to fall 60 dB is 6.908 τ.
            let tau = rng.uniform(0.02, 0.06) / 6.908
            let level = rng.uniform(0.5, 1.0)
            let r = exp(-1.0 / (tau * sampleRate))
            let a1 = 2.0 * r * cos(2.0 * Double.pi * f / sampleRate)
            let a2 = -r * r
            var y1 = 0.0
            var y2 = 0.0
            for i in 0..<n {
                let y = excite[i] + a1 * y1 + a2 * y2
                y2 = y1
                y1 = y
                sum[i] += level * y
            }
        }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = Float(sum[i]) }
        shape(&out, sampleRate: sampleRate, lead: lead, attack: 0.0003, release: 0.012)
        fit(&out)
        return out
    }

    /// Pop: a sine sweeping exponentially from 400 to 150 Hz × pitch (there after `popSweepSec`, 26 ms, then
    /// steady) and dying away with τ = 30 ms, plus a quiet puff of low-passed noise over the first few ms. 0.1 s.
    public static func pop(sampleRate: Double, pitch: Double, rng: inout FeelRandom) -> [Float] {
        let n = sampleCount(0.1, sampleRate)
        let lead = leadSamples(sampleRate)
        let f0 = 400.0 * pitch
        let f1 = 150.0 * pitch
        let sweep = popSweepSec
        let k = log(f1 / f0)
        let puff = rng.uniform(0.09, 0.15)
        let cut = 1.0 - exp(-2.0 * Double.pi * 900.0 / sampleRate)
        // The phase at the end of the sweep: 2π ∫ f0 e^(k t / sweep) dt from 0 to sweep.
        let sweptPhase = 2.0 * Double.pi * f0 * sweep / k * (f1 / f0 - 1.0)
        var low1 = 0.0
        var low2 = 0.0
        var out = [Float](repeating: 0, count: n)
        var i = lead
        while i < n {
            let t = Double(i - lead) / sampleRate
            var phase = 0.0
            if t < sweep {
                phase = 2.0 * Double.pi * f0 * sweep / k * (exp(k * t / sweep) - 1.0)
            } else {
                phase = sweptPhase + 2.0 * Double.pi * f1 * (t - sweep)
            }
            let body = exp(-t / 0.03) * sin(phase)
            let noise = rng.uniform(-1.0, 1.0)
            low1 += cut * (noise - low1)
            low2 += cut * (low1 - low2)
            let air = puff * exp(-t / 0.006) * low2
            out[i] = Float(body + air)
            i += 1
        }
        shape(&out, sampleRate: sampleRate, lead: lead, attack: 0.001, release: 0.012)
        fit(&out)
        return out
    }

    /// Chime: modal synthesis of the material's partials over `frequency` (Hz). Phases random, amplitudes halving
    /// with each partial (each also varied by up to 15%). 2 ms attack, and a fade over the last 40 ms (crystal) or
    /// 20 ms (wood) so the ring ends at zero.
    public static func chime(_ material: ChimeMaterial, frequency: Double, sampleRate: Double,
                             rng: inout FeelRandom) -> [Float] {
        let ratios = material.ratios
        var frequencies: [Double] = []
        var amplitudes: [Double] = []
        var phases: [Double] = []
        for k in 0..<ratios.count {
            frequencies.append(frequency * ratios[k])
            amplitudes.append(pow(0.5, Double(k)) * rng.uniform(0.85, 1.0))
            phases.append(rng.uniform(0.0, 2.0 * Double.pi))
        }
        let n = sampleCount(material.duration, sampleRate)
        let lead = min(n, leadSamples(sampleRate))
        let ring = modal(frequencies: frequencies, amplitudes: amplitudes, decays: material.decays, phases: phases,
                         duration: Double(n - lead) / sampleRate, sampleRate: sampleRate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<ring.count {
            if lead + i < n { out[lead + i] = ring[i] }
        }
        let release = material == .crystal ? 0.04 : 0.02
        shape(&out, sampleRate: sampleRate, lead: lead, attack: 0.002, release: release)
        fit(&out)
        return out
    }

    /// Crumble: short clicks (one Hann-windowed sine cycle each, 0.3–1 ms ÷ pitch, so band-limited and with no DC)
    /// at Poisson times whose rate fades in a straight line from 400/s to 0 over 150 ms, growing quieter as they
    /// thin out. The first click is always there. 0.18 s.
    public static func crumble(sampleRate: Double, pitch: Double, rng: inout FeelRandom) -> [Float] {
        let n = sampleCount(0.18, sampleRate)
        let lead = leadSamples(sampleRate)
        let fadeSec = 0.15
        let rate = 400.0
        let speed = max(pitch, 0.1)
        var sum = [Double](repeating: 0.0, count: n)
        var t = 0.0
        var first = true
        while t < fadeSec {
            // Thinning: times come at the full rate and each is kept with the share of the rate left at its time.
            var keep = first
            if !first {
                keep = rng.unit() < 1.0 - t / fadeSec
            }
            first = false
            if keep {
                let seconds = rng.uniform(0.0003, 0.001) / speed
                let level = rng.uniform(0.35, 1.0) * (1.0 - 0.6 * t / fadeSec)
                let flip = rng.unit() < 0.5 ? -1.0 : 1.0
                let count = max(4, Int((seconds * sampleRate).rounded()))
                let start = lead + Int((t * sampleRate).rounded())
                for i in 0..<count {
                    let at = start + i
                    if at >= n { break }
                    let u = (Double(i) + 0.5) / Double(count)
                    let window = 0.5 - 0.5 * cos(2.0 * Double.pi * u)
                    sum[at] += flip * level * window * sin(2.0 * Double.pi * u)
                }
            }
            t += -log(1.0 - rng.unit()) / rate
        }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = Float(sum[i]) }
        shape(&out, sampleRate: sampleRate, lead: lead, attack: 0.0002, release: 0.01)
        fit(&out)
        return out
    }

    /// The largest absolute sample. 0 for an empty buffer.
    public static func peak(_ x: [Float]) -> Float {
        var top: Float = 0
        for v in x {
            let size = abs(v)
            if size > top { top = size }
        }
        return top
    }

    /// Scales so the peak sits at `db` dBFS (e.g. −12). Silent input stays silent.
    public static func normalize(_ x: inout [Float], toDBFS db: Double) {
        let top = peak(x)
        if !(top > 0) || !top.isFinite { return }
        let gain = Float(pow(10.0, db / 20.0) / Double(top))
        for i in 0..<x.count { x[i] *= gain }
    }

    /// Smooth limiter, ceiling × tanh(x / ceiling): |out| never exceeds `ceiling`, small signals pass almost
    /// unchanged (0.1 × ceiling loses a third of a percent). A ceiling of 0 or less gives silence.
    public static func softLimit(_ x: inout [Float], ceiling: Float) {
        if !(ceiling > 0) {
            for i in 0..<x.count { x[i] = 0 }
            return
        }
        let top = Double(ceiling)
        for i in 0..<x.count {
            let limited = Float(top * tanh(Double(x[i]) / top))
            x[i] = min(ceiling, max(-ceiling, limited))
        }
    }

    /// Silence up to sample `lead`, a raised-cosine fade in over `attack` seconds from there, and a raised-cosine
    /// fade out over the last `release` seconds, down to exactly 0 at the last sample.
    static func shape(_ x: inout [Float], sampleRate: Double, lead: Int, attack: Double, release: Double) {
        let n = x.count
        if n == 0 { return }
        let silent = min(n, max(0, lead))
        for i in 0..<silent { x[i] = 0 }
        let rise = max(1, Int((attack * sampleRate).rounded()))
        for i in 0..<rise {
            let at = silent + i
            if at >= n { break }
            let gain = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(rise))
            x[at] *= Float(gain)
        }
        let fall = max(1, Int((release * sampleRate).rounded()))
        for i in 0..<fall {
            let at = n - 1 - i
            if at < 0 { break }
            let gain = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fall))
            x[at] *= Float(gain)
        }
    }

    /// Scales so the peak is `rawPeak`. Silence stays silent.
    private static func fit(_ x: inout [Float]) {
        let top = peak(x)
        if !(top > 0) || !top.isFinite { return }
        let gain = Float(rawPeak / Double(top))
        for i in 0..<x.count { x[i] *= gain }
    }
}

/// Which chime note the next lock plays: one step up the scale with every lock in a row.
public struct ChimeLadder: Sendable, Equatable {
    /// D major pentatonic from D5 (the ambient pad's key): D5 E5 F#5 A5 B5 D6 E6 F#6, in Hz.
    public static let frequencies: [Double] = [587.33, 659.26, 739.99, 880.00, 987.77, 1174.66, 1318.51, 1479.98]

    /// The index the last `next()` returned, −1 before the first.
    public private(set) var step: Int

    public init() {
        step = -1
    }

    /// The next note's index: one higher on each consecutive lock, staying on the top note once there.
    public mutating func next() -> Int {
        step = min(step + 1, ChimeLadder.frequencies.count - 1)
        return step
    }

    /// A miss, a slip or a pause: the next lock starts from the bottom again.
    public mutating func reset() {
        step = -1
    }
}

public enum SoundLayer: String, Sendable, CaseIterable {
    case charge, crack, pop, chime, crumble
}

/// Every sound of the pop, made once at session start: many variants of each layer, so no two pops sound alike.
public struct SoundBank: Sendable {
    /// Hz.
    public let sampleRate: Double
    /// How many variants each chime note has.
    public let chimePerStep: Int
    let buffers: [SoundLayer: [[Float]]]

    /// The peak of every buffer before its level factor, dBFS.
    static let levelDB = -12.0
    /// A chime's pitch is varied by at most this share (0.4%, about 7 cents), so the scale stays in tune with the
    /// ambient pad. The other layers have no key and are varied over the full 0.92...1.08.
    static let chimeDetune = 0.004

    /// Every layer's variants, each normalized to −12 dBFS and then given a level factor in 0.88...1.0.
    /// charge: 8 variants; crack, pop, crumble: `variantsPerLayer`, each with its pitch varied by a factor in
    /// 0.92...1.08; chime: ChimeLadder.frequencies.count × chimePerStep, laid out step-major
    /// (index = step × chimePerStep + k), each within `chimeDetune` of its note. The same seed gives the same bank.
    public static func make(sampleRate: Double, seed: UInt64, variantsPerLayer: Int = 48, chimePerStep: Int = 4,
                            material: ChimeMaterial = .crystal) -> SoundBank {
        var rng = FeelRandom(seed: seed)
        let variants = max(0, variantsPerLayer)
        let perStep = max(0, chimePerStep)

        var charges: [[Float]] = []
        for _ in 0..<8 {
            let pitch = rng.uniform(0.92, 1.08)
            var buffer = PopSynth.charge(sampleRate: sampleRate, pitch: pitch, rng: &rng)
            level(&buffer, rng: &rng)
            charges.append(buffer)
        }
        var cracks: [[Float]] = []
        for _ in 0..<variants {
            let pitch = rng.uniform(0.92, 1.08)
            var buffer = PopSynth.crack(sampleRate: sampleRate, pitch: pitch, rng: &rng)
            level(&buffer, rng: &rng)
            cracks.append(buffer)
        }
        var pops: [[Float]] = []
        for _ in 0..<variants {
            let pitch = rng.uniform(0.92, 1.08)
            var buffer = PopSynth.pop(sampleRate: sampleRate, pitch: pitch, rng: &rng)
            level(&buffer, rng: &rng)
            pops.append(buffer)
        }
        var chimes: [[Float]] = []
        for step in 0..<ChimeLadder.frequencies.count {
            for _ in 0..<perStep {
                let pitch = rng.uniform(1.0 - chimeDetune, 1.0 + chimeDetune)
                var buffer = PopSynth.chime(material, frequency: ChimeLadder.frequencies[step] * pitch,
                                            sampleRate: sampleRate, rng: &rng)
                level(&buffer, rng: &rng)
                chimes.append(buffer)
            }
        }
        var crumbles: [[Float]] = []
        for _ in 0..<variants {
            let pitch = rng.uniform(0.92, 1.08)
            var buffer = PopSynth.crumble(sampleRate: sampleRate, pitch: pitch, rng: &rng)
            level(&buffer, rng: &rng)
            crumbles.append(buffer)
        }

        var buffers: [SoundLayer: [[Float]]] = [:]
        buffers[SoundLayer.charge] = charges
        buffers[SoundLayer.crack] = cracks
        buffers[SoundLayer.pop] = pops
        buffers[SoundLayer.chime] = chimes
        buffers[SoundLayer.crumble] = crumbles
        return SoundBank(sampleRate: sampleRate, chimePerStep: perStep, buffers: buffers)
    }

    /// To −12 dBFS, then a level factor in 0.88...1.0.
    private static func level(_ x: inout [Float], rng: inout FeelRandom) {
        PopSynth.normalize(&x, toDBFS: levelDB)
        let factor = Float(rng.uniform(0.88, 1.0))
        for i in 0..<x.count { x[i] *= factor }
    }

    /// How many variants the layer has.
    public func count(_ layer: SoundLayer) -> Int {
        return buffers[layer]?.count ?? 0
    }

    /// One variant's samples. The index wraps (modulo the count, negative ones too); an empty layer gives [].
    public func variant(_ layer: SoundLayer, _ index: Int) -> [Float] {
        guard let all = buffers[layer], !all.isEmpty else { return [] }
        let n = all.count
        return all[((index % n) + n) % n]
    }

    /// The chime of a ladder step. The step is clamped to the ladder, the variant wraps.
    public func chime(step: Int, variant: Int) -> [Float] {
        if chimePerStep <= 0 { return [] }
        let top = ChimeLadder.frequencies.count - 1
        let s = min(top, max(0, step))
        let k = ((variant % chimePerStep) + chimePerStep) % chimePerStep
        return self.variant(SoundLayer.chime, s * chimePerStep + k)
    }

    /// 4 bytes per sample over all buffers.
    public var byteCount: Int {
        var samples = 0
        for (_, all) in buffers {
            for buffer in all { samples += buffer.count }
        }
        return samples * 4
    }
}

public enum StereoPlacement {
    /// Pan for AVAudioPlayerNode (−1 left … 1 right) from a scene x in 0...width (pt): the left edge gives
    /// −spread, the middle 0, the right edge +spread. An x outside 0...width is clamped to the nearer edge.
    public static func pan(x: Double, width: Double, spread: Double = 0.8) -> Float {
        if !(width > 0) { return 0 }
        let side = FeelMath.clamp(2.0 * x / width - 1.0, -1.0, 1.0)
        return Float(FeelMath.clamp(side * spread, -1.0, 1.0))
    }
}
