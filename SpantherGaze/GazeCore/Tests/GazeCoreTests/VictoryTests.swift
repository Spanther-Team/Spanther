import XCTest
@testable import GazeCore

final class VictoryTests: XCTestCase {
    func testRanks() {
        XCTAssertEqual(VictoryRank.of(share: 0.92, bestStreak: 0), .s)
        XCTAssertEqual(VictoryRank.of(share: 0.82, bestStreak: 15), .s)
        XCTAssertEqual(VictoryRank.of(share: 0.82, bestStreak: 14), .a)
        XCTAssertEqual(VictoryRank.of(share: 0.4, bestStreak: 10), .a)
        XCTAssertEqual(VictoryRank.of(share: 0.4, bestStreak: 3), .b)
        // No share at all (or a broken one) is still a B.
        XCTAssertEqual(VictoryRank.of(share: nil, bestStreak: 0), .b)
        XCTAssertEqual(VictoryRank.of(share: .nan, bestStreak: 0), .b)
        XCTAssertEqual(VictoryRank.allCases.map(\.stars), [3, 2, 1])
    }

    func testLandmarksAndGiftsOpenWithStars() {
        var o = Observatory()
        XCTAssertEqual(o.landmarks, 0)
        XCTAssertEqual(o.nextLandmarkCost, 1)
        o.add(.b)
        XCTAssertEqual(o.landmarks, 1)
        XCTAssertEqual(o.gifts, 0)
        o.add(.a)
        XCTAssertEqual(o.stars, 3)
        XCTAssertEqual(o.gifts, 1)
        XCTAssertEqual(o.nextLandmarkCost, 4)
        let full = Observatory(stars: 100)
        XCTAssertEqual(full.landmarks, Observatory.landmarkCosts.count)
        XCTAssertEqual(full.gifts, Observatory.giftCosts.count)
        XCTAssertNil(full.nextLandmarkCost)
        XCTAssertEqual(Observatory(stars: -4).stars, 0)
    }

    func testAnAwardSaysWhatItOpened() {
        let a = VictoryAward(share: 0.95, bestStreak: 12, observatory: Observatory(stars: 2))
        XCTAssertEqual(a.rank, .s)
        XCTAssertEqual(a.after.stars, 5)
        XCTAssertEqual(a.newLandmarks, 1..<2)
        XCTAssertEqual(a.newGifts, 0..<1)
        let none = VictoryAward(share: 0.5, bestStreak: 0, observatory: Observatory(stars: 4))
        XCTAssertTrue(none.newLandmarks.isEmpty)
        XCTAssertTrue(none.newGifts.isEmpty)
    }

    func testObservatoryRoundTripsAsJSON() throws {
        let o = Observatory(stars: 17)
        let back = try JSONDecoder().decode(Observatory.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(back, o)
    }
}
