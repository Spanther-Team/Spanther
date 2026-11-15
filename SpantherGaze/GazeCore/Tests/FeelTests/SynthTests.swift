import XCTest
@testable import Feel

final class SynthTests: XCTestCase {
    private let rates = [48000.0, 44100.0]

    /// Finite, within −1...1, the stated length (±1 sample), and no click: the first and the last 0.5 ms stay
    /// below 2% of the peak.
    private func checkBuffer(_ x: [Float], seconds: Double, sampleRate: Double, _ name: String) {
        let expected = Int((seconds * sampleRate).rounded())
        XCTAssertLessThanOrEqual(abs(x.count - expected), 1, name)
        var finite = true
        for v in x {
            if !v.isFinite { finite = false }
        }
        XCTAssertTrue(finite, name)
        let peak = PopSynth.peak(x)
        XCTAssertGreaterThan(peak, 0.1, name)
        XCTAssertLessThanOrEqual(peak, 1.0, name)
        let edge = Int(0.0005 * sampleRate)
        XCTAssertGreaterThan(x.count, 2 * edge, name)
        if x.count <= 2 * edge { return }
        var loudest: Float = 0
        for i in 0..<edge {
            loudest = max(loudest, abs(x[i]))
            loudest = max(loudest, abs(x[x.count - 1 - i]))
        }
        XCTAssertLessThan(loudest, 0.02 * peak, name)
    }

    func testEveryLayerIsFiniteTheRightLengthAndClickFree() {
        for rate in rates {
            for seed in 0..<12 {
                var rng = FeelRandom(seed: UInt64(seed))
                let pitch = rng.uniform(0.92, 1.08)
                let name = "rate \(rate) seed \(seed)"
                checkBuffer(PopSynth.charge(sampleRate: rate, pitch: pitch, rng: &rng), seconds: 0.18,
                            sampleRate: rate, "charge " + name)
                checkBuffer(PopSynth.crack(sampleRate: rate, pitch: pitch, rng: &rng), seconds: 0.08,
                            sampleRate: rate, "crack " + name)
                checkBuffer(PopSynth.pop(sampleRate: rate, pitch: pitch, rng: &rng), seconds: 0.1,
                            sampleRate: rate, "pop " + name)
                checkBuffer(PopSynth.crumble(sampleRate: rate, pitch: pitch, rng: &rng), seconds: 0.18,
                            sampleRate: rate, "crumble " + name)
                for material in ChimeMaterial.allCases {
                    let note = ChimeLadder.frequencies[seed % ChimeLadder.frequencies.count]
                    checkBuffer(PopSynth.chime(material, frequency: note, sampleRate: rate, rng: &rng),
                                seconds: material.duration, sampleRate: rate, "chime \(material.rawValue) " + name)
                }
            }
        }
    }

    func testModalIsTheSumOfDecayingSines() {
        let rate = 48000.0
        let frequencies = [440.0, 1210.0]
        let amplitudes = [1.0, 0.4]
        let decays = [0.05, 0.02]
        let phases = [0.3, 1.1]
        let x = PopSynth.modal(frequencies: frequencies, amplitudes: amplitudes, decays: decays, phases: phases,
                               duration: 0.1, sampleRate: rate)
        XCTAssertEqual(x.count, 4800)
        for i in stride(from: 0, to: x.count, by: 37) {
            let t = Double(i) / rate
            var want = 0.0
            for k in 0..<2 {
                let angle = 2.0 * Double.pi * frequencies[k] * t + phases[k]
                want += amplitudes[k] * exp(-t / decays[k]) * sin(angle)
            }
            XCTAssertEqual(Double(x[i]), want, accuracy: 1e-5)
        }
        // A partial above half the sample rate is left out, not folded back.
        let high = PopSynth.modal(frequencies: [30000.0], amplitudes: [1.0], decays: [0.1], phases: [1.0],
                                  duration: 0.01, sampleRate: rate)
        XCTAssertEqual(PopSynth.peak(high), 0.0)
    }

    /// The times (s) at which the signal changes side, with a dead band of ±`band` so small wiggles near zero do
    /// not count.
    private func sideChanges(_ x: [Float], band: Float, sampleRate: Double) -> [Double] {
        var times: [Double] = []
        var side = 0
        for i in 0..<x.count {
            var now = side
            if x[i] > band { now = 1 }
            if x[i] < -band { now = -1 }
            if now != side {
                if side != 0 { times.append(Double(i) / sampleRate) }
                side = now
            }
        }
        return times
    }

    /// The mean zero-crossing frequency (Hz) of the half periods whose middle lies in from...to (s).
    private func crossingFrequency(_ times: [Double], from: Double, to: Double) -> Double? {
        var sum = 0.0
        var count = 0
        if times.count < 2 { return nil }
        for i in 1..<times.count {
            let middle = (times[i - 1] + times[i]) * 0.5
            if middle < from || middle > to { continue }
            sum += 0.5 / (times[i] - times[i - 1])
            count += 1
        }
        if count == 0 { return nil }
        return sum / Double(count)
    }

    func testPopSweepsFromFourHundredToOneHundredFiftyHertz() throws {
        let rate = 48000.0
        for seed in 0..<10 {
            var rng = FeelRandom(seed: UInt64(seed))
            let x = PopSynth.pop(sampleRate: rate, pitch: 1.0, rng: &rng)
            let times = sideChanges(x, band: 0.1 * PopSynth.peak(x), sampleRate: rate)
            let lead = PopSynth.leadIn
            let early = try XCTUnwrap(crossingFrequency(times, from: lead, to: lead + 0.005), "seed \(seed)")
            let late = try XCTUnwrap(crossingFrequency(times, from: lead + 0.025, to: lead + 0.030), "seed \(seed)")
            XCTAssertGreaterThan(early, 400.0 * 0.8, "seed \(seed)")
            XCTAssertLessThan(early, 400.0 * 1.2, "seed \(seed)")
            XCTAssertGreaterThan(late, 150.0 * 0.8, "seed \(seed)")
            XCTAssertLessThan(late, 150.0 * 1.2, "seed \(seed)")
        }
        // Pitch scales the whole sweep.
        var rng = FeelRandom(seed: 1)
        let high = PopSynth.pop(sampleRate: rate, pitch: 1.5, rng: &rng)
        let times = sideChanges(high, band: 0.1 * PopSynth.peak(high), sampleRate: rate)
        let late = try XCTUnwrap(crossingFrequency(times, from: PopSynth.leadIn + 0.025, to: PopSynth.leadIn + 0.030))
        XCTAssertEqual(late, 225.0, accuracy: 225.0 * 0.2)
    }

    func testChimePartials() {
        let rate = 48000.0
        let note = ChimeLadder.frequencies[0]
        for material in ChimeMaterial.allCases {
            let ratios = material.ratios
            XCTAssertEqual(ratios.count, material.decays.count)
            for seed in 0..<5 {
                var rng = FeelRandom(seed: UInt64(seed))
                let x = PopSynth.chime(material, frequency: note, sampleRate: rate, rng: &rng)
                for k in 0..<ratios.count {
                    let at = FeelCheck.goertzel(x, frequency: note * ratios[k], sampleRate: rate)
                    if k > 0 {
                        let between = note * (ratios[k - 1] + ratios[k]) * 0.5
                        let off = FeelCheck.goertzel(x, frequency: between, sampleRate: rate)
                        XCTAssertGreaterThan(at, 20.0 * off, "\(material.rawValue) partial \(k) seed \(seed)")
                    }
                    if k + 1 < ratios.count {
                        let between = note * (ratios[k] + ratios[k + 1]) * 0.5
                        let off = FeelCheck.goertzel(x, frequency: between, sampleRate: rate)
                        XCTAssertGreaterThan(at, 20.0 * off, "\(material.rawValue) partial \(k) seed \(seed)")
                    }
                }
            }
        }
        XCTAssertEqual(ChimeMaterial.crystal.ratios, [1.0, 2.76, 5.40, 8.93])
        XCTAssertEqual(ChimeMaterial.wood.ratios, [1.0, 4.0, 10.0])
        XCTAssertEqual(ChimeMaterial.crystal.duration, 0.7)
        XCTAssertEqual(ChimeMaterial.wood.duration, 0.25)
    }

    /// Seconds until the signal has fallen for good to 40 dB under its peak.
    private func fallTime(_ x: [Float], sampleRate: Double) -> Double {
        let quiet = 0.01 * PopSynth.peak(x)
        var last = 0
        for i in 0..<x.count {
            if abs(x[i]) > quiet { last = i }
        }
        return Double(last) / sampleRate
    }

    func testCrystalRingsLongerThanWood() {
        let rate = 48000.0
        for seed in 0..<5 {
            var rng = FeelRandom(seed: UInt64(seed))
            let crystal = PopSynth.chime(.crystal, frequency: 587.33, sampleRate: rate, rng: &rng)
            let wood = PopSynth.chime(.wood, frequency: 587.33, sampleRate: rate, rng: &rng)
            XCTAssertGreaterThan(fallTime(crystal, sampleRate: rate), 2.0 * fallTime(wood, sampleRate: rate))
        }
        XCTAssertGreaterThan(ChimeMaterial.crystal.decays[0], 3.0 * ChimeMaterial.wood.decays[0])
        // Higher partials die sooner.
        for material in ChimeMaterial.allCases {
            let decays = material.decays
            for k in 1..<decays.count { XCTAssertLessThan(decays[k], decays[k - 1]) }
        }
    }

    func testCrumbleThinsOut() {
        let rate = 48000.0
        let window = Int(0.05 * rate)
        for seed in 0..<20 {
            var rng = FeelRandom(seed: UInt64(seed))
            let x = PopSynth.crumble(sampleRate: rate, pitch: 1.0, rng: &rng)
            var first = 0.0
            var last = 0.0
            for i in 0..<window {
                first += Double(x[i]) * Double(x[i])
                last += Double(x[x.count - 1 - i]) * Double(x[x.count - 1 - i])
            }
            XCTAssertGreaterThan(first, last, "seed \(seed)")
            XCTAssertGreaterThan(first, 0.0, "seed \(seed)")
        }
    }

    func testCrackIsBrightAndShort() {
        let rate = 48000.0
        for seed in 0..<10 {
            var rng = FeelRandom(seed: UInt64(seed))
            let x = PopSynth.crack(sampleRate: rate, pitch: 1.0, rng: &rng)
            // Most of the energy is in the first 30 ms.
            var early = 0.0
            var all = 0.0
            for i in 0..<x.count {
                let e = Double(x[i]) * Double(x[i])
                all += e
                if i < Int(0.03 * rate) { early += e }
            }
            XCTAssertGreaterThan(early, 0.9 * all, "seed \(seed)")
            // More sign changes than a 2 kHz tone would make: the resonators sit at 2.5–7 kHz.
            var changes = 0
            let from = Int(0.001 * rate)
            let to = Int(0.011 * rate)
            for i in (from + 1)..<to {
                if (x[i] > 0) != (x[i - 1] > 0) { changes += 1 }
            }
            XCTAssertGreaterThan(changes, 40, "seed \(seed)")
        }
    }

    func testChargeRises() {
        let rate = 48000.0
        var rng = FeelRandom(seed: 6)
        let x = PopSynth.charge(sampleRate: rate, pitch: 1.0, rng: &rng)
        // Louder in the third quarter than in the first: a swell.
        var first = 0.0
        var third = 0.0
        let quarter = x.count / 4
        for i in 0..<quarter {
            first += Double(x[i]) * Double(x[i])
            third += Double(x[2 * quarter + i]) * Double(x[2 * quarter + i])
        }
        XCTAssertGreaterThan(third, 4.0 * first)
        // And higher at the end than at the start: about 300 Hz, then about 420 Hz.
        let low = FeelCheck.goertzel(Array(x[0..<(x.count / 3)]), frequency: 310.0, sampleRate: rate)
        let lowWrong = FeelCheck.goertzel(Array(x[0..<(x.count / 3)]), frequency: 415.0, sampleRate: rate)
        let high = FeelCheck.goertzel(Array(x[(2 * x.count / 3)..<x.count]), frequency: 415.0, sampleRate: rate)
        let highWrong = FeelCheck.goertzel(Array(x[(2 * x.count / 3)..<x.count]), frequency: 310.0, sampleRate: rate)
        XCTAssertGreaterThan(low, lowWrong)
        XCTAssertGreaterThan(high, highWrong)
    }

    func testPeakAndNormalize() {
        XCTAssertEqual(PopSynth.peak([]), 0.0)
        XCTAssertEqual(PopSynth.peak([0.25, -0.75, 0.5]), 0.75)

        var x: [Float] = []
        for i in 0..<4800 {
            x.append(Float(0.5 * sin(2.0 * Double.pi * 440.0 * Double(i) / 48000.0)))
        }
        PopSynth.normalize(&x, toDBFS: -12.0)
        XCTAssertEqual(FeelCheck.peakDB(x), -12.0, accuracy: 0.01)
        PopSynth.normalize(&x, toDBFS: -3.0)
        XCTAssertEqual(FeelCheck.peakDB(x), -3.0, accuracy: 0.01)

        var silent = [Float](repeating: 0, count: 100)
        PopSynth.normalize(&silent, toDBFS: -12.0)
        XCTAssertEqual(silent, [Float](repeating: 0, count: 100))
        var empty: [Float] = []
        PopSynth.normalize(&empty, toDBFS: -12.0)
        XCTAssertTrue(empty.isEmpty)
    }

    func testSoftLimit() {
        let ceiling: Float = 0.5
        var x: [Float] = []
        for i in 0...2000 {
            x.append(Float(i - 1000) / 100.0)
        }
        let before = x
        PopSynth.softLimit(&x, ceiling: ceiling)
        for i in 0..<x.count {
            XCTAssertLessThanOrEqual(abs(x[i]), ceiling)
            // It keeps the sign and the order.
            XCTAssertEqual(x[i] > 0, before[i] > 0)
            if i > 0 { XCTAssertGreaterThanOrEqual(x[i], x[i - 1]) }
        }
        var small: [Float] = [0.1 * ceiling, -0.1 * ceiling, 0.02 * ceiling]
        let wanted = small
        PopSynth.softLimit(&small, ceiling: ceiling)
        for i in 0..<small.count {
            XCTAssertLessThan(abs(small[i] - wanted[i]), 0.01 * abs(wanted[i]))
        }
    }
}

final class ChimeLadderTests: XCTestCase {
    func testClimbsToTheTopAndStays() {
        var ladder = ChimeLadder()
        XCTAssertEqual(ladder.step, -1)
        let top = ChimeLadder.frequencies.count - 1
        for want in 0...top {
            let got = ladder.next()
            XCTAssertEqual(got, want)
            XCTAssertEqual(ladder.step, want)
        }
        for _ in 0..<5 {
            let got = ladder.next()
            XCTAssertEqual(got, top)
        }
        ladder.reset()
        XCTAssertEqual(ladder.step, -1)
        let again = ladder.next()
        XCTAssertEqual(again, 0)
    }

    func testFrequenciesAreDMajorPentatonicFromD5() {
        let f = ChimeLadder.frequencies
        XCTAssertEqual(f.count, 8)
        XCTAssertEqual(f[0], 587.33, accuracy: 0.01)
        for i in 1..<f.count { XCTAssertGreaterThan(f[i], f[i - 1]) }
        // D5 E5 F#5 A5 B5 D6 E6 F#6: semitones above D5.
        let semitones = [0.0, 2.0, 4.0, 7.0, 9.0, 12.0, 14.0, 16.0]
        for i in 0..<f.count {
            let tempered = 587.3295 * pow(2.0, semitones[i] / 12.0)
            XCTAssertEqual(f[i], tempered, accuracy: 0.02)
        }
    }
}

final class StereoPlacementTests: XCTestCase {
    func testPan() {
        XCTAssertEqual(StereoPlacement.pan(x: 0.0, width: 400.0), -0.8, accuracy: 1e-6)
        XCTAssertEqual(StereoPlacement.pan(x: 400.0, width: 400.0), 0.8, accuracy: 1e-6)
        XCTAssertEqual(StereoPlacement.pan(x: 200.0, width: 400.0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(StereoPlacement.pan(x: 300.0, width: 400.0), 0.4, accuracy: 1e-6)
        XCTAssertEqual(StereoPlacement.pan(x: -50.0, width: 400.0), -0.8, accuracy: 1e-6)
        XCTAssertEqual(StereoPlacement.pan(x: 9000.0, width: 400.0), 0.8, accuracy: 1e-6)
        XCTAssertEqual(StereoPlacement.pan(x: 400.0, width: 400.0, spread: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(StereoPlacement.pan(x: 400.0, width: 400.0, spread: 3.0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(StereoPlacement.pan(x: 10.0, width: 0.0), 0.0, accuracy: 1e-6)
    }
}
