import XCTest
@testable import GazeCore

/// The music clock and the sync check (skill `avaudio-rhythm-sync`): a fake audio clock with route delays, jitter
/// and jumps, and taps from a player who hears the clicks late.
final class WinkBeatSyncTests: XCTestCase {
    func testClockIsNilUntilTheFirstReading() {
        var c = WinkBeatClock(outputLatency: 0.01, ioBuffer: 0.005)
        XCTAssertNil(c.heard(reading: nil, hostNow: 5))
        XCTAssertNil(c.trackTime(host: 5))
    }

    func testClockSubtractsTheRouteAndExtrapolatesBetweenRenders() {
        var c = WinkBeatClock(outputLatency: 0.01, ioBuffer: 0.005, userOffset: 0.02)
        let r = WinkBeatClock.Reading(renderedSec: 1.0, host: 100)
        XCTAssertEqual(c.heard(reading: r, hostNow: 100)!, 0.965, accuracy: 1e-9)
        // No new reading: host time carries it on.
        XCTAssertEqual(c.heard(reading: nil, hostNow: 100.5)!, 1.465, accuracy: 1e-9)
        XCTAssertEqual(c.trackTime(host: 100.25)!, 1.215, accuracy: 1e-9)
    }

    func testClockHoldsSmallStepsBackAndTakesBigOnes() {
        var c = WinkBeatClock()
        XCTAssertEqual(c.heard(reading: .init(renderedSec: 2.0, host: 10), hostNow: 10)!, 2.0, accuracy: 1e-9)
        // A render that reads 10 ms behind: held, never back.
        XCTAssertEqual(c.heard(reading: .init(renderedSec: 1.99, host: 10), hostNow: 10)!, 2.0, accuracy: 1e-9)
        XCTAssertEqual(c.heard(reading: nil, hostNow: 10.02)!, 2.01, accuracy: 1e-9)
        // 0.5 s back (a seek): taken at once.
        XCTAssertEqual(c.heard(reading: .init(renderedSec: 1.5, host: 10.02), hostNow: 10.02)!, 1.5, accuracy: 1e-9)
        // Forward jumps are always taken.
        XCTAssertEqual(c.heard(reading: .init(renderedSec: 3.0, host: 10.03), hostNow: 10.03)!, 3.0, accuracy: 1e-9)
        c.reset()
        XCTAssertNil(c.heard(reading: nil, hostNow: 11))
    }

    func testClockFollowsARouteChangeOfLatency() {
        var c = WinkBeatClock(outputLatency: 0.01)
        _ = c.heard(reading: .init(renderedSec: 5, host: 50), hostNow: 50)
        // AirPods: 0.2 s more delay. The heard time steps back by 0.19 s, more than the hold allows, so it is taken.
        c.outputLatency = 0.2
        XCTAssertEqual(c.heard(reading: nil, hostNow: 50)!, 4.8, accuracy: 1e-9)
    }

    func testClicksAreOnTheBeat() {
        let s = WinkBeatSync(bpm: 100, count: 16, leadIn: 1.0)
        XCTAssertEqual(s.clicks.count, 16)
        XCTAssertEqual(s.beatSec, 0.6, accuracy: 1e-12)
        XCTAssertEqual(s.clicks[0], 1.0, accuracy: 1e-12)
        XCTAssertEqual(s.clicks[15], 10.0, accuracy: 1e-9)
        XCTAssertEqual(s.endSec, 10.3, accuracy: 1e-9)
        XCTAssertNil(s.click(atOrBefore: 0.9))
        XCTAssertEqual(s.click(atOrBefore: 1.0), 0)
        XCTAssertEqual(s.click(atOrBefore: 1.59), 0)
        XCTAssertEqual(s.click(atOrBefore: 1.61), 1)
        XCTAssertEqual(s.click(atOrBefore: 99), 15)
    }

    func testSteadyTapsGiveTheirMedianDelay() {
        var s = WinkBeatSync()
        var rng = Rng(seed: 7)
        // The warm-up taps are far off and must not count.
        s.tap(at: s.clicks[0] + 0.2)
        s.tap(at: s.clicks[1] - 0.15)
        for c in s.clicks.dropFirst(2) { s.tap(at: c + 0.035 + (rng.next() - 0.5) * 0.02) }
        XCTAssertEqual(s.counted.count, 14)
        guard case let .steady(offset) = s.result else { return XCTFail("\(s.result)") }
        XCTAssertEqual(offset, 0.035, accuracy: 0.006)
        XCTAssertEqual(WinkBeatSync.steppedMs(offset), 35)
    }

    func testSecondTapsAndStrayTapsDoNotCount() {
        var s = WinkBeatSync()
        XCTAssertEqual(s.tap(at: s.clicks[3] + 0.01), 3)
        XCTAssertNil(s.tap(at: s.clicks[3] + 0.05), "a second tap on the same click")
        XCTAssertNil(s.tap(at: s.clicks[4] + 0.29), "half a beat away belongs to no click")
        XCTAssertNil(s.tap(at: 0.2), "before the first click")
        XCTAssertNil(s.tap(at: s.endSec + 1))
        XCTAssertEqual(s.result, .tooFewTaps)
    }

    func testUnevenTapsAreFlagged() {
        var s = WinkBeatSync()
        for (i, c) in s.clicks.enumerated() { s.tap(at: c + (i % 2 == 0 ? 0.12 : -0.08)) }
        guard case .uneven = s.result else { return XCTFail("\(s.result)") }
    }

    func testOffsetIsClampedToTheAllowedRange() {
        var s = WinkBeatSync(bpm: 60)
        for c in s.clicks { s.tap(at: c + 0.42) }
        XCTAssertEqual(s.result, .steady(offset: WinkBeatSync.range.upperBound))
    }

    func testClickTrackTicksStartOnTheirSamples() {
        let s = WinkBeatSync(bpm: 100, count: 4, leadIn: 0.5)
        let rate = 48_000.0
        let x = s.samples(sampleRate: rate)
        XCTAssertEqual(x.count, Int(((s.endSec + 0.3) * rate).rounded(.up)))
        for c in s.clicks {
            let i = Int((c * rate).rounded())
            XCTAssertEqual(x[i - 1], 0, "silence just before a tick")
            let peak = x[i..<(i + 480)].map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.3)
        }
        let between = Int(((s.clicks[0] + s.clicks[1]) / 2 * rate).rounded())
        XCTAssertLessThan(abs(x[between]), 1e-4)
        XCTAssertLessThanOrEqual(x.map { abs($0) }.max() ?? 0, 0.61)
    }

    /// The whole loop with a fake audio device: the clicks come out 40 ms later than the route reports, a player taps
    /// on what they hear, and the measured offset puts the clock back on the sound.
    func testMeasuredOffsetCorrectsAnUnderreportedLatency() {
        let reported = 0.012, hidden = 0.040, io = 0.005
        var clock = WinkBeatClock(outputLatency: reported, ioBuffer: io)
        var sync = WinkBeatSync()
        let startHost = 1000.0
        // The device renders sample time = host - startHost (it starts at startHost); a click at track time c is
        // heard at host startHost + c + reported + io + hidden.
        var rng = Rng(seed: 3)
        for c in sync.clicks {
            let heardHost = startHost + c + reported + io + hidden
            let tapHost = heardHost + (rng.next() - 0.5) * 0.016
            let renderHost = tapHost - 0.004
            _ = clock.heard(reading: .init(renderedSec: renderHost - startHost, host: renderHost), hostNow: tapHost)
            sync.tap(at: clock.trackTime(host: tapHost)!)
        }
        guard case let .steady(offset) = sync.result else { return XCTFail("\(sync.result)") }
        XCTAssertEqual(offset, hidden, accuracy: 0.006)
        clock.userOffset = offset
        let c = sync.clicks[5]
        XCTAssertEqual(clock.trackTime(host: startHost + c + reported + io + hidden)!, c, accuracy: 0.006)
    }
}
