import XCTest
@testable import Feel

final class PopSynthTests: XCTestCase {
    private let fs = 48_000.0
    private var synth: PopSynth { PopSynth(sampleRate: fs) }

    private func peak(_ x: [Float]) -> Double { Double(x.map { abs($0) }.max() ?? 0) }

    private func rms(_ x: [Float], _ from: Double, _ to: Double) -> Double {
        let a = max(0, Int(from * fs)), b = min(x.count, Int(to * fs))
        guard b > a else { return 0 }
        var s = 0.0
        for i in a..<b { s += Double(x[i]) * Double(x[i]) }
        return (s / Double(b - a)).squareRoot()
    }

    /// The power of one frequency over a stretch of the samples (Goertzel).
    private func power(_ x: [Float], _ hz: Double, _ from: Double = 0, _ to: Double = .infinity) -> Double {
        let a = max(0, Int(from * fs)), b = min(x.count, to.isFinite ? Int(to * fs) : x.count)
        let c = 2 * cos(2 * Double.pi * hz / fs)
        var s1 = 0.0, s2 = 0.0
        for i in a..<b {
            let s = Double(x[i]) + c * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - c * s1 * s2
    }

    /// Every layer: finite, at its peak level, starting and ending at zero, so nothing clicks.
    private func assertClean(_ x: [Float], peakDB: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(x.isEmpty, what, file: file, line: line)
        XCTAssertTrue(x.allSatisfy { $0.isFinite }, what, file: file, line: line)
        XCTAssertEqual(peak(x), PopMix.gain(peakDB), accuracy: 1e-6, what, file: file, line: line)
        XCTAssertLessThan(abs(Double(x[0])), 1e-3 * peak(x), what, file: file, line: line)
        XCTAssertEqual(Double(x[x.count - 1]), 0, accuracy: 1e-9, what, file: file, line: line)
        let tail = Array(x.suffix(Int(0.001 * fs)))
        XCTAssertLessThan(peak(tail), 0.05 * peak(x), what, file: file, line: line)
    }

    func testTheCrackIsAShortHighBurst() {
        var noise = FeelRandom(seed: 1)
        let x = synth.crack(noise: &noise)
        assertClean(x, peakDB: PopMix.crackDB, "crack")
        XCTAssertEqual(Double(x.count) / fs, 0.005 + 5 * 0.035, accuracy: 0.001)
        // Its energy sits in the resonators, kilohertz up, not in the low end.
        let high = power(x, 2600) + power(x, 3822)
        let low = power(x, 200) + power(x, 500)
        XCTAssertGreaterThan(high, 100 * low)
        // It is over almost at once. The slowest ring dies with a 35 ms time constant, which alone puts the last half
        // 27 dB (0.044) below the first 20 ms; the faster rings and the closing fade only take more away.
        XCTAssertLessThan(rms(x, 0.09, 0.18), 0.044 * rms(x, 0, 0.02))
        // A higher pitch moves the ring up.
        var again = FeelRandom(seed: 1)
        let up = synth.crack(pitch: 1.08, noise: &again)
        XCTAssertGreaterThan(power(up, 2600 * 1.08), power(up, 2600 / 1.08))
    }

    func testThePopFallsFrom400To150Hz() {
        var noise = FeelRandom(seed: 2)
        let x = synth.pop(puff: 0, noise: &noise)
        assertClean(x, peakDB: PopMix.popDB, "pop")
        // Upward zero crossings give the period of the sine as it falls.
        var ups: [Double] = []
        for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 {
            let t0 = Double(i - 1) / fs, a = Double(x[i - 1]), b = Double(x[i])
            ups.append(t0 + (-a / (b - a)) / fs)
        }
        XCTAssertGreaterThan(ups.count, 6)
        // Half way round the first cycle the glide has barely begun: about 400 Hz, a little less.
        let first = 1 / (ups[1] - ups[0])
        XCTAssertTrue((320...400).contains(first), "first cycle \(first) Hz")
        // After the sweep it holds 150 Hz.
        let late = ups.filter { $0 > 0.032 }
        XCTAssertGreaterThan(late.count, 2)
        XCTAssertEqual(1 / (late[1] - late[0]), 150, accuracy: 1.5)
        // With the puff, more air at the top.
        var again = FeelRandom(seed: 2)
        let airy = synth.pop(noise: &again)
        assertClean(airy, peakDB: PopMix.popDB, "pop with puff")
        XCTAssertGreaterThan(power(airy, 1200, 0, 0.02) / power(airy, 400, 0, 0.02),
                             power(x, 1200, 0, 0.02) / power(x, 400, 0, 0.02))
    }

    func testTheChimeRingsAtTheBarsModes() {
        let x = synth.chime(440)
        assertClean(x, peakDB: PopMix.chimeDB, "crystal")
        XCTAssertEqual(Double(x.count) / fs, 3.6 * 0.34, accuracy: 0.001)
        for ratio in [1, 2.76, 5.40, 8.93] {
            for off in [0.9, 1.12] {
                XCTAssertGreaterThan(power(x, 440 * ratio, 0, 0.2), 100 * power(x, 440 * ratio * off, 0, 0.2),
                                     "mode \(ratio)")
            }
        }
        // Long and sweet: still a good part of itself after a third of a second, and the high modes die first.
        XCTAssertGreaterThan(rms(x, 0.3, 0.4), 0.2 * rms(x, 0, 0.1))
        XCTAssertGreaterThan(power(x, 440, 0.3, 0.5) / power(x, 440 * 8.93, 0.3, 0.5),
                             power(x, 440, 0, 0.1) / power(x, 440 * 8.93, 0, 0.1))
        // Wood: its own modes, and short.
        let wood = synth.chime(440, material: .wood)
        assertClean(wood, peakDB: PopMix.chimeDB, "wood")
        XCTAssertLessThan(wood.count, x.count / 3)
        XCTAssertGreaterThan(power(wood, 1760, 0, 0.1), 100 * power(wood, 440 * 2.76, 0, 0.1))
        // A mode above the highest the rate can hold is left out instead of folding back.
        let shrill = PopSynth(sampleRate: 16_000).chime(1000)
        XCTAssertTrue(shrill.allSatisfy { $0.isFinite })
    }

    func testTheCrumbleThinsOut() {
        var counts = 0, early = 0, late = 0
        let runs = 200
        for seed in 0..<runs {
            var noise = FeelRandom(seed: UInt64(seed))
            let (x, clicks) = synth.crumble(noise: &noise)
            if seed == 0 { assertClean(x, peakDB: PopMix.crumbleDB, "crumble") }
            XCTAssertEqual(clicks, clicks.sorted())
            XCTAssertTrue(clicks.allSatisfy { $0 >= 0 && $0 < 0.2 })
            counts += clicks.count
            early += clicks.filter { $0 < 0.05 }.count
            late += clicks.filter { $0 >= 0.15 }.count
        }
        // The rate 380 e^(-t / 0.05) per second makes 380 * 0.05 * (1 - e^-4) = 18.65 clicks on average.
        XCTAssertEqual(Double(counts) / Double(runs), 380 * 0.05 * (1 - exp(-4)), accuracy: 0.6)
        // About 12 in the first 50 ms and 0.6 in the last: the stream thins as it should.
        XCTAssertEqual(Double(early) / Double(runs), 380 * 0.05 * (1 - exp(-1)), accuracy: 0.6)
        XCTAssertLessThan(Double(late) / Double(runs), 1.0)
    }

    func testTheBankHoldsEveryVariantAndFitsInMemory() {
        let bank = PopBank.make(sampleRate: fs, seed: 77)
        XCTAssertEqual(bank.cracks.count, 12)
        XCTAssertEqual(bank.pops.count, 12)
        XCTAssertEqual(bank.crumbles.count, 12)
        XCTAssertEqual(bank.chimes.count, 10)
        XCTAssertLessThan(bank.byteCount, 4_000_000)
        // The pitches cover ±8% evenly, in shuffled order, so no two hits sound alike.
        XCTAssertEqual(Set(bank.pitches).count, 12)
        XCTAssertTrue(bank.pitches.allSatisfy { (0.92...1.08).contains($0) })
        let sorted = bank.pitches.sorted()
        for k in 0..<12 { XCTAssertTrue((0.92 + Double(k) * 0.16 / 12...0.92 + Double(k + 1) * 0.16 / 12).contains(sorted[k])) }
        XCTAssertNotEqual(bank.pitches, sorted)
        XCTAssertNotEqual(bank.cracks[0], bank.cracks[1])
        // The chimes stay on the notes of the music.
        for (hz, chime) in zip(bank.ladderHz, bank.chimes) {
            let on = power(chime, hz, 0, 0.3)
            XCTAssertGreaterThan(on, 50 * power(chime, hz * 1.03, 0, 0.3))
            XCTAssertGreaterThan(on, 50 * power(chime, hz / 1.03, 0, 0.3))
        }
        XCTAssertEqual(bank.ladderHz, PopBank.dMajorPentatonic)
        XCTAssertEqual(bank.ladderHz, bank.ladderHz.sorted())
        // The same seed, the same sounds.
        let again = PopBank.make(sampleRate: fs, seed: 77)
        XCTAssertEqual(again.cracks, bank.cracks)
        XCTAssertEqual(again.crumbles, bank.crumbles)
        XCTAssertNotEqual(PopBank.make(sampleRate: fs, seed: 78, ladderHz: []).cracks, bank.cracks)
    }

    /// The probe's feedback must be the same in every session, whatever the session's seed.
    func testTheFixedBankIsTheSameForEverySeed() {
        let a = PopBank.make(sampleRate: fs, seed: 1, ladderHz: [440], fixed: true)
        let b = PopBank.make(sampleRate: fs, seed: 999, ladderHz: [440], fixed: true)
        XCTAssertEqual(a.pitches, [1])
        XCTAssertEqual(a.cracks, b.cracks)
        XCTAssertEqual(a.pops, b.pops)
        XCTAssertEqual(a.crumbles, b.crumbles)
        XCTAssertEqual(a.chimes, b.chimes)
        XCTAssertEqual(a.cracks.count, 1)
    }

    func testTheLadderClimbsWithEachLockInARow() {
        var ladder = ChimeLadder(steps: 4, breakSec: 3)
        XCTAssertEqual(ladder.lock(at: 10), 0)
        XCTAssertEqual(ladder.lock(at: 11), 1)
        XCTAssertEqual(ladder.lock(at: 12.5), 2)
        XCTAssertEqual(ladder.lock(at: 13), 3)
        XCTAssertEqual(ladder.lock(at: 14), 3)
        // A long pause starts the row again, and so does a meteor that got through.
        XCTAssertEqual(ladder.lock(at: 17.5), 0)
        XCTAssertEqual(ladder.lock(at: 18), 1)
        ladder.breakRow()
        XCTAssertEqual(ladder.lock(at: 18.5), 0)
    }

    func testTheHapticsStayInRangeAndFollowTheSound() {
        let (events, curve) = PopHaptics.charge(holdSec: 0.8)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].duration, 0.8)
        XCTAssertEqual(curve.map(\.value), curve.map(\.value).sorted())
        XCTAssertEqual(curve.last?.time, 0.8)
        for e in events + PopHaptics.lock {
            XCTAssertTrue((0...1).contains(e.intensity))
            XCTAssertTrue((0...1).contains(e.sharpness))
            XCTAssertGreaterThanOrEqual(e.time, 0)
        }
        XCTAssertEqual(PopHaptics.lock.map(\.time), PopHaptics.lock.map(\.time).sorted())
        // The crack's tick is the sharpest; the grains come while the crumble still sounds.
        XCTAssertEqual(PopHaptics.lock.max { $0.sharpness < $1.sharpness }?.time, 0)
        for grain in PopHaptics.lock.dropFirst(2) {
            XCTAssertTrue((PopMix.crumbleDelaySec...PopMix.crumbleDelaySec + 0.15).contains(grain.time))
        }
    }
}
