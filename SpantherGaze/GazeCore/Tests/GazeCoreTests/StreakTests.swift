import XCTest
@testable import GazeCore

final class StreakTests: XCTestCase {
    func testMilestonesEveryFifthLockInARow() {
        var s = Streak()
        var hit: [Int] = []
        for _ in 0..<26 { if let m = s.lock() { hit.append(m) } }
        XCTAssertEqual(hit, [5, 10, 15, 20, 25])
        XCTAssertEqual(s.milestones, 5)
        XCTAssertEqual(s.best, 26)
    }

    func testAMissStartsTheCountAgainButKeepsTheBest() {
        var s = Streak()
        for _ in 0..<4 { s.lock() }
        XCTAssertEqual(s.breakRun(), 4)
        XCTAssertEqual(s.count, 0)
        XCTAssertNil(s.lock())
        for _ in 0..<3 { s.lock() }
        XCTAssertEqual(s.lock(), 5)
        XCTAssertEqual(s.best, 5)
    }

    func testTiers() {
        XCTAssertEqual([5, 10, 15, 20, 25, 50].map(Streak.tier), [0, 1, 2, 3, 3, 3])
        XCTAssertFalse(Streak.isMilestone(0))
        XCTAssertFalse(Streak.isMilestone(7))
        XCTAssertTrue(Streak.isMilestone(30))
    }

    func testFollowingAComboCountsItsLocksAndItsResets() {
        var s = Streak()
        XCTAssertEqual(s.follow(4), [])
        XCTAssertEqual(s.follow(11), [5, 10])
        // The combo fell to 0 (a miss) and came back to 1.
        XCTAssertEqual(s.follow(1), [])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.best, 11)
        XCTAssertEqual(s.follow(0), [])
        XCTAssertEqual(s.count, 0)
    }

    func testFollowingTheDotLocksEveryTwoSeconds() {
        var f = FollowStreak()
        var locks = 0
        var t = 0.0
        while t < 6.05 {
            if f.update(time: t, on: true) == .lock { locks += 1 }
            t += 1.0 / 60
        }
        XCTAssertEqual(locks, 3)
    }

    func testAShortSlipIsForgivenALongOneBreaks() {
        var f = FollowStreak()
        XCTAssertEqual(f.update(time: 0, on: true), .none)
        XCTAssertEqual(f.update(time: 1.0, on: false), .none)
        XCTAssertEqual(f.update(time: 1.3, on: false), .none)
        XCTAssertEqual(f.update(time: 1.35, on: true), .none)
        // The slip did not reset the clock: two seconds since the start.
        XCTAssertEqual(f.update(time: 2.0, on: true), .lock)
        XCTAssertEqual(f.update(time: 2.5, on: false), .none)
        XCTAssertEqual(f.update(time: 3.0, on: false), .broke)
        // Off the dot with no run going: nothing to break.
        XCTAssertEqual(f.update(time: 4.0, on: false), .none)
        XCTAssertEqual(f.update(time: 5.0, on: true), .none)
        XCTAssertEqual(f.update(time: 6.9, on: true), .none)
        XCTAssertEqual(f.update(time: 7.0, on: true), .lock)
    }
}
