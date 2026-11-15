import XCTest
@testable import GazeCore

final class CourseStatsTests: XCTestCase {
    private func points(_ ys: [Double], _ xs: [Double]? = nil) -> [(x: Double, y: Double)] {
        ys.enumerated().map { (x: xs?[$0.offset] ?? Double($0.offset + 1), y: $0.element) }
    }

    func testPlainSummaries() throws {
        XCTAssertNil(CourseStats.mean([]))
        XCTAssertNil(CourseStats.sd([4]))
        XCTAssertNil(CourseStats.median([]))
        XCTAssertEqual(try XCTUnwrap(CourseStats.mean([2, 4, 4, 4, 5, 5, 7, 9])), 5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(CourseStats.sd([2, 4, 4, 4, 5, 5, 7, 9])), (32.0 / 7).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(CourseStats.median([4, 1, 3, 2])), 2.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(CourseStats.median([7])), 7, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(CourseStats.quantile([4, 1, 3, 2], 0.25)), 1.75, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(CourseStats.quantile([4, 1, 3, 2], 0.75)), 3.25, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(CourseStats.quantile([4, 1, 3, 2], -1)), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(CourseStats.quantile([4, 1, 3, 2], 2)), 4, accuracy: 1e-12)
    }

    /// One wild session must not bend the trend: the line through y = 2x + 1 stays that line.
    func testTheTrendIgnoresOneOddSession() throws {
        var ys = (1...10).map { 2.0 * Double($0) + 1 }
        ys[4] = 40
        let trend = try XCTUnwrap(CourseStats.theilSen(points(ys)))
        XCTAssertEqual(trend.slope, 2, accuracy: 1e-12)
        XCTAssertEqual(trend.intercept, 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(trend.slopeLow), 2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(trend.slopeHigh), 2, accuracy: 1e-12)
        XCTAssertEqual(trend.pivotX, 5.5, accuracy: 1e-12)
        XCTAssertEqual(trend.count, 10)
        XCTAssertTrue(trend.isClear)
        XCTAssertEqual(trend.value(at: 30), 61, accuracy: 1e-9)
    }

    /// Values worked out apart from this code (and the slope and the interval checked against SciPy's theilslopes).
    func testTheTrendAndItsIntervalMatchTheReference() throws {
        let rising: [Double] = [52, 55, 51, 58, 60, 57, 63, 61, 66, 64, 70, 68]
        let ninety = try XCTUnwrap(CourseStats.theilSen(points(rising)))
        XCTAssertEqual(ninety.slope, 1.666666666667, accuracy: 1e-9)
        XCTAssertEqual(ninety.intercept, 50.666666666667, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ninety.slopeLow), 1.285806735062, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ninety.slopeHigh), 1.888683445895, accuracy: 1e-9)
        XCTAssertTrue(ninety.isClear)
        // A wider claim needs a wider interval.
        let ninetyFive = try XCTUnwrap(CourseStats.theilSen(points(rising), z: 1.959963984540054))
        XCTAssertEqual(try XCTUnwrap(ninetyFive.slopeLow), 1.137657665661, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ninetyFive.slopeHigh), 2.0, accuracy: 1e-9)

        // Equal values, and two sessions at the same x, narrow the variance the interval is placed by.
        let tied = try XCTUnwrap(CourseStats.theilSen(points([3, 3, 4, 4, 4, 6, 7], [1, 2, 2, 3, 4, 5, 6])))
        XCTAssertEqual(tied.slope, 0.775, accuracy: 1e-9)
        XCTAssertEqual(tied.intercept, 2.125, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tied.slopeLow), 0.295314081620, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tied.slopeHigh), 1.0, accuracy: 1e-9)
    }

    func testAFlatNoisyCourseHasNoClearTrend() throws {
        let trend = try XCTUnwrap(CourseStats.theilSen(points([5, 6, 4, 5.5, 4.5, 5.2, 4.8, 5.1, 4.9, 5.3])))
        XCTAssertEqual(trend.slope, 0.014285714286, accuracy: 1e-9)
        let low = try XCTUnwrap(trend.slopeLow), high = try XCTUnwrap(trend.slopeHigh)
        XCTAssertEqual(low, -0.142375282681, accuracy: 1e-9)
        XCTAssertEqual(high, 0.164633408715, accuracy: 1e-9)
        XCTAssertFalse(trend.isClear)

        // The band is a point at the pivot and opens with the distance from it.
        let centre = trend.value(at: trend.pivotX)
        let atPivot = try XCTUnwrap(trend.band(at: trend.pivotX))
        XCTAssertEqual(atPivot.lowerBound, centre, accuracy: 1e-12)
        XCTAssertEqual(atPivot.upperBound, centre, accuracy: 1e-12)
        let later = try XCTUnwrap(trend.band(at: trend.pivotX + 10))
        XCTAssertEqual(later.upperBound - later.lowerBound, 10 * (high - low), accuracy: 1e-9)
        XCTAssertEqual(later.upperBound, centre + 10 * high, accuracy: 1e-9)
        // Before the pivot the two lines swap places; the band stays the right way up.
        let earlier = try XCTUnwrap(trend.band(at: trend.pivotX - 4))
        XCTAssertEqual(earlier.lowerBound, centre - 4 * high, accuracy: 1e-9)
        XCTAssertEqual(earlier.upperBound, centre - 4 * low, accuracy: 1e-9)
    }

    func testTooFewSessionsGiveNoTrendOrNoInterval() throws {
        XCTAssertNil(CourseStats.theilSen(points([1, 3, 2])))
        // A value that is not a number is left out, not counted as a session.
        XCTAssertNil(CourseStats.theilSen(points([1, 3, .nan, 2])))
        // All at one x: no slope can be taken.
        XCTAssertNil(CourseStats.theilSen(points([1, 3, 2, 5], [2, 2, 2, 2])))

        let four = try XCTUnwrap(CourseStats.theilSen(points([1, 3, 2, 5])))
        XCTAssertEqual(four.slope, 1.166666666667, accuracy: 1e-9)
        XCTAssertEqual(four.intercept, 0.083333333333, accuracy: 1e-9)
        XCTAssertNil(four.slopeLow)
        XCTAssertNil(four.slopeHigh)
        XCTAssertNil(four.band(at: 3))
        XCTAssertFalse(four.isClear)

        let five = try XCTUnwrap(CourseStats.theilSen(points([1, 3, 2, 5, 6])))
        XCTAssertEqual(five.slope, 1.125, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(five.slopeLow), -0.036315109497, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(five.slopeHigh), 2.357543406331, accuracy: 1e-9)
        XCTAssertFalse(five.isClear)
    }

    func testMeasurementErrorFromRepeats() throws {
        let pooled = try XCTUnwrap(CourseStats.pooledWithinSD([[1, 3], [10, 14]]))
        XCTAssertEqual(pooled.sd, 5.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(pooled.degreesOfFreedom, 2)
        // A child with one session adds nothing; a value that is not a number is left out.
        let mixed = try XCTUnwrap(CourseStats.pooledWithinSD([[1, 3], [7], [10, .nan, 14], []]))
        XCTAssertEqual(mixed.sd, 5.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(mixed.degreesOfFreedom, 2)
        XCTAssertNil(CourseStats.pooledWithinSD([[4], [5]]))
        XCTAssertNil(CourseStats.pooledWithinSD([[4, 4, 4]]))

        XCTAssertEqual(CourseStats.sem(sd: 10, icc: 0.75), 5, accuracy: 1e-12)
        XCTAssertEqual(CourseStats.sem(sd: 10, icc: 1.2), 0, accuracy: 1e-12)
        XCTAssertEqual(CourseStats.mdc(sem: 1), 2.771807648699356, accuracy: 1e-12)
        XCTAssertEqual(CourseStats.mdc(sem: 1, baselineCount: 3, recentCount: 3), 1.6003038921184367, accuracy: 1e-12)
        XCTAssertEqual(CourseStats.mdc(sem: 2.5, baselineCount: 3, recentCount: 1), 2.5 * 2.2631714681523434, accuracy: 1e-12)
    }

    func testAChangeIsNamedOnlyWhenItIsLargerThanTheError() throws {
        let course: [Double] = [10, 10, 10, 12, 14, 16]
        let up = try XCTUnwrap(CourseStats.change(course, better: .higher, sem: 1))
        XCTAssertEqual(up.baseline, 10, accuracy: 1e-12)
        XCTAssertEqual(up.recent, 14, accuracy: 1e-12)
        XCTAssertEqual(up.delta, 4, accuracy: 1e-12)
        XCTAssertEqual(up.baselineCount, 3)
        XCTAssertEqual(up.recentCount, 3)
        XCTAssertEqual(try XCTUnwrap(up.mdc), 1.6003038921184367, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(up.inMDC), 4 / 1.6003038921184367, accuracy: 1e-9)
        XCTAssertEqual(up.verdict, .better)

        XCTAssertEqual(CourseStats.change(course, better: .lower, sem: 1)?.verdict, .worse)
        XCTAssertEqual(CourseStats.change(course, better: .neither, sem: 1)?.verdict, .changed)
        XCTAssertEqual(CourseStats.change(course.reversed(), better: .higher, sem: 1)?.verdict, .worse)
        XCTAssertEqual(CourseStats.change(course.reversed(), better: .lower, sem: 1)?.verdict, .better)
        // The same four points of change are nothing against an error of five.
        XCTAssertEqual(CourseStats.change(course, better: .higher, sem: 5)?.verdict, .same)

        // Until the error is known the change is shown without a verdict.
        let unknown = try XCTUnwrap(CourseStats.change(course, better: .higher, sem: nil))
        XCTAssertEqual(unknown.verdict, .unknown)
        XCTAssertNil(unknown.mdc)
        XCTAssertNil(unknown.inMDC)
        XCTAssertEqual(unknown.delta, 4, accuracy: 1e-12)
        XCTAssertEqual(CourseStats.change(course, better: .higher, sem: 0)?.verdict, .unknown)

        // Only the baseline so far: nothing to compare.
        XCTAssertNil(CourseStats.change([10, 11, 12], better: .higher, sem: 1))
        // One session after it: the baseline's three against that one, with the wider limit that goes with it.
        let first = try XCTUnwrap(CourseStats.change([10, 10, 10, 13], better: .higher, sem: 1))
        XCTAssertEqual(first.recentCount, 1)
        XCTAssertEqual(first.recent, 13, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(first.mdc), 2.2631714681523434, accuracy: 1e-12)
        XCTAssertEqual(first.verdict, .better)
        // The latest sessions never reach back into the baseline.
        let two = try XCTUnwrap(CourseStats.change([10, 10, 10, 13, 15], better: .higher, sem: 1))
        XCTAssertEqual(two.recentCount, 2)
        XCTAssertEqual(two.recent, 14, accuracy: 1e-12)
    }

    func testTheBaselineBand() throws {
        let band = try XCTUnwrap(CourseStats.baselineBand([10, 12, 14, 30], sem: 1))
        XCTAssertEqual(band.lowerBound, 12 - 2.2631714681523434, accuracy: 1e-12)
        XCTAssertEqual(band.upperBound, 12 + 2.2631714681523434, accuracy: 1e-12)
        // With one session so far the band stands on that session alone and is wider.
        let one = try XCTUnwrap(CourseStats.baselineBand([10], sem: 1))
        XCTAssertEqual(one.lowerBound, 10 - 2.771807648699356, accuracy: 1e-12)
        XCTAssertEqual(one.upperBound, 10 + 2.771807648699356, accuracy: 1e-12)
        XCTAssertNil(CourseStats.baselineBand([], sem: 1))
        XCTAssertNil(CourseStats.baselineBand([10, 12], sem: .nan))
    }
}
