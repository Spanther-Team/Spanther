import XCTest
@testable import GazeCore

/// The play layer's motion as functions of track time (skill `metal-anime-stage`).
final class WinkBeatLookTests: XCTestCase {
    func testApproachRunsFromAppearingToTheBeat() {
        XCTAssertEqual(WinkBeatLook.approach(0.0, objectTime: 2.0, lead: 1.5), 0)
        XCTAssertEqual(WinkBeatLook.approach(0.5, objectTime: 2.0, lead: 1.5), 0)
        XCTAssertEqual(WinkBeatLook.approach(1.25, objectTime: 2.0, lead: 1.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WinkBeatLook.approach(2.0, objectTime: 2.0, lead: 1.5), 1)
        XCTAssertEqual(WinkBeatLook.approach(9.0, objectTime: 2.0, lead: 1.5), 1)
        XCTAssertEqual(WinkBeatLook.ringScale(0), 3)
        XCTAssertEqual(WinkBeatLook.ringScale(1), 1)
        XCTAssertEqual(WinkBeatLook.fadeIn(0.125), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WinkBeatLook.fadeIn(0.6), 1)
    }

    func testBeatPulseIsOnTheBeat() {
        let beat = 60.0 / 99
        XCTAssertEqual(WinkBeatLook.beatPulse(0.05, firstBeat: 0.091, beatSec: beat), 0)
        XCTAssertEqual(WinkBeatLook.beatPulse(0.091, firstBeat: 0.091, beatSec: beat), 1, accuracy: 1e-9)
        XCTAssertEqual(WinkBeatLook.beatPulse(0.091 + 10 * beat, firstBeat: 0.091, beatSec: beat), 1, accuracy: 1e-6)
        XCTAssertEqual(WinkBeatLook.beatPulse(0.091 + 0.5 * beat, firstBeat: 0.091, beatSec: beat), 0)
        XCTAssertEqual(WinkBeatLook.beatPulse(0.091 + 0.175 * beat, firstBeat: 0.091, beatSec: beat), 0.5, accuracy: 1e-9)
    }

    func testBurstGrowsFadesAndEnds() {
        XCTAssertNil(WinkBeatLook.shockwave(age: -0.01))
        XCTAssertEqual(WinkBeatLook.shockwave(age: 0)!.scale, 1)
        XCTAssertEqual(WinkBeatLook.shockwave(age: 0)!.alpha, 1)
        let mid = WinkBeatLook.shockwave(age: 0.2)!
        XCTAssertGreaterThan(mid.scale, 1.5)
        XCTAssertEqual(mid.alpha, 0.5, accuracy: 1e-12)
        XCTAssertNil(WinkBeatLook.shockwave(age: WinkBeatLook.burstSec))
    }

    func testShardsAreTheSameEachTimeAndFlyOut() {
        let a = WinkBeatLook.shard(index: 12, k: 3, age: 0.2)!
        let b = WinkBeatLook.shard(index: 12, k: 3, age: 0.2)!
        XCTAssertEqual(a.offset, b.offset)
        XCTAssertEqual(a.size, b.size)
        XCTAssertNotEqual(WinkBeatLook.shard(index: 12, k: 4, age: 0.2)!.offset, a.offset)
        XCTAssertEqual(WinkBeatLook.shard(index: 12, k: 3, age: 0)!.offset.length, 0, accuracy: 1e-12)
        let late = WinkBeatLook.shard(index: 12, k: 3, age: 0.39)!
        XCTAssertGreaterThan(late.offset.length, a.offset.length)
        XCTAssertLessThan(late.size, a.size)
        XCTAssertNil(WinkBeatLook.shard(index: 12, k: 3, age: 0.5))
    }

    func testPetalsDoneFollowTheHops() {
        XCTAssertEqual(WinkBeatLook.petalsDone(hops: 0, needed: 12, petals: 8), 0)
        XCTAssertEqual(WinkBeatLook.petalsDone(hops: 6, needed: 12, petals: 8), 4)
        XCTAssertEqual(WinkBeatLook.petalsDone(hops: -6, needed: 12, petals: 8), 4)
        XCTAssertEqual(WinkBeatLook.petalsDone(hops: 30, needed: 12, petals: 8), 8)
    }
}
