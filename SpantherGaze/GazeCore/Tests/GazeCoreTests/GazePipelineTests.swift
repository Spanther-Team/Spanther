import XCTest
@testable import GazeCore

/// The live gaze pipeline under a moving target: the filter must follow without falling behind, and the
/// looking-away gate must not blank the aim on single frames that spike past the calibrated range.
final class GazePipelineTests: XCTestCase {
    /// Deterministic noise with mean 0 and a standard deviation of 1 (SplitMix64 under a sum of uniforms).
    private struct Noise {
        var state: UInt64
        private mutating func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }

        mutating func next() -> Double { (unit() + unit() + unit() - 1.5) * 2 }
    }

    /// The RMS distance from the filtered gaze to the true target, following `target` at `hz` for 10 s with
    /// 6 pt of measurement noise, the first second (the filter settling) left out.
    private func rms(_ filter: OneEuroFilter2D, hz: Double, seed: UInt64, target: (Double) -> Vec2) -> Double {
        var f = filter
        var noise = Noise(state: seed)
        var sum = 0.0
        var n = 0
        for i in 0...Int(10 * hz) {
            let t = Double(i) / hz
            let truth = target(t)
            let seen = Vec2(truth.x + 6 * noise.next(), truth.y + 6 * noise.next())
            let out = f.filter(seen, t: t)
            if t >= 1 {
                sum += out.distance(to: truth) * out.distance(to: truth)
                n += 1
            }
        }
        return (sum / Double(n)).squareRoot()
    }

    /// The warm-up's and the probe's glider at its fastest: about 500 pt/s across the screen.
    private func glide(_ t: Double) -> Vec2 { Vec2(200 * sin(2 * Double.pi * 0.4 * t), 0) }

    func testTheFilterFollowsAMovingTargetWithoutFallingBehind() {
        let tuned = rms(OneEuroFilter2D(), hz: 60, seed: 7, target: glide)
        let old = rms(OneEuroFilter2D(minCutoff: 1.0, beta: 0.007), hz: 60, seed: 7, target: glide)
        // The old tuning lagged well behind the glider (about 15 pt at full speed); the new one stays on it,
        // and what error is left is mostly the measurement noise coming through.
        XCTAssertGreaterThan(old, 9, "old error \(old)")
        XCTAssertLessThan(tuned, 6.5, "tuned error \(tuned)")
        XCTAssertLessThan(tuned, 0.7 * old)
        // The same at 30 frames a second: the lag must not come back on a throttled phone.
        let slow = rms(OneEuroFilter2D(), hz: 30, seed: 7, target: glide)
        XCTAssertLessThan(slow, 7.5, "30 fps error \(slow)")
    }

    func testTheFilterStillSmoothsAStillGaze() {
        let still: (Double) -> Vec2 = { _ in Vec2(0, 0) }
        let tuned = rms(OneEuroFilter2D(), hz: 60, seed: 9, target: still)
        let old = rms(OneEuroFilter2D(minCutoff: 1.0, beta: 0.007), hz: 60, seed: 9, target: still)
        // The raw noise is 8.5 pt RMS in 2D; resting gaze must stay much calmer than that. The faster following
        // costs about a point and a half of rest calm, far under any hit zone.
        XCTAssertLessThan(tuned, 4)
        XCTAssertLessThan(tuned, old + 1.6)
    }

    func testTheFilterForgetsOnReset() {
        var f = OneEuroFilter2D()
        _ = f.filter(Vec2(500, 500), t: 0)
        f.reset()
        let out = f.filter(Vec2(3, 4), t: 1)
        XCTAssertEqual(out.x, 3, accuracy: 1e-12)
        XCTAssertEqual(out.y, 4, accuracy: 1e-12)
    }

    func testTheAwayGateIgnoresSpikesAndCatchesRealGlances() {
        var gate = RidgeModel.AwayGate(graceSec: 0.15)
        let dt = 1.0 / 60
        // Following a moving target: every tenth frame spikes out of range for one frame. Never away.
        for i in 0..<120 {
            XCTAssertFalse(gate.looksAway(out: i % 10 == 0, t: Double(i) * dt), "frame \(i)")
        }
        // A real glance away: out stays set, and the gate turns after the grace, not before.
        let start = 2.0
        var away: [Double] = []
        for i in 0..<30 {
            let t = start + Double(i) * dt
            if gate.looksAway(out: true, t: t) { away.append(t) }
        }
        XCTAssertEqual(away.first ?? .infinity, start + 0.15, accuracy: dt)
        // The way back is instant, whatever came before.
        XCTAssertFalse(gate.looksAway(out: false, t: start + 1))
        XCTAssertFalse(gate.looksAway(out: true, t: start + 1 + dt))
    }

    func testABlinkDoesNotLowerThePursuitShareButALossDoes() throws {
        let plan = try XCTUnwrap(ProbePlan.make(seed: 0))
        let r = plan.rules
        func play(_ gaze: (Double) -> Vec2?) -> [String: Double] {
            var run = ProbeRun(plan: plan, radiusDeg: 3.5, screenHalfWidthDeg: 12, screenHalfHeightDeg: 5.5)
            for i in 0...Int((90.5 * 60).rounded()) {
                let t = Double(i) / 60
                _ = run.add(t: t, gaze: gaze(t))
            }
            return run.metrics()
        }
        func onGlider(_ t: Double) -> Vec2 { plan.pursuitPosition(at: t) ?? Vec2(0, 0) }
        // A child who blinks for 0.2 s every 4 s while following exactly scores like one who never blinks.
        let blinky = play { t in t.truncatingRemainder(dividingBy: 4) < 0.2 ? nil : onGlider(t) }
        XCTAssertEqual(try XCTUnwrap(blinky[ProbeMetric.pursuitOnShare.rawValue]), 1)
        // Losing the eyes for a second counts off the glider, the first blink's worth of it included.
        let lossFrom = r.pursuitScoredFromSec + 5.0
        let lossy = play { t in (lossFrom..<lossFrom + 1).contains(t) ? nil : onGlider(t) }
        let scored = r.pursuitScoredToSec - r.pursuitScoredFromSec
        XCTAssertEqual(try XCTUnwrap(lossy[ProbeMetric.pursuitOnShare.rawValue]), 1 - 1 / scored, accuracy: 0.01)
    }
}
