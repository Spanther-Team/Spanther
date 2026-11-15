import Foundation

// The arithmetic behind the course chart: a trend that one odd session cannot bend, the measurement's own error,
// and whether a change is larger than that error. Nothing here judges a child; it only says how far a number moved
// and whether the probe can tell that move from its own noise.

public enum CourseStats {
    // MARK: Plain summaries

    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var sum = 0.0
        for v in values { sum += v }
        return sum / Double(values.count)
    }

    /// Standard deviation with n - 1 below the line; nil for fewer than two values.
    public static func sd(_ values: [Double]) -> Double? {
        guard values.count >= 2, let m = mean(values) else { return nil }
        var ss = 0.0
        for v in values { ss += (v - m) * (v - m) }
        return (ss / Double(values.count - 1)).squareRoot()
    }

    public static func median(_ values: [Double]) -> Double? { quantile(values, 0.5) }

    /// The value below which the share `p` (0...1) of the values lie, interpolating between neighbours.
    public static func quantile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return orderStatistic(sorted, min(1, max(0, p)) * Double(sorted.count - 1))
    }

    /// The value at a position between two neighbours of a sorted list (0 is the first).
    static func orderStatistic(_ sorted: [Double], _ position: Double) -> Double {
        let low = min(sorted.count - 1, max(0, Int(position.rounded(.down))))
        let high = min(sorted.count - 1, low + 1)
        return sorted[low] + (position - Double(low)) * (sorted[high] - sorted[low])
    }

    // MARK: Trend

    /// A Theil-Sen line: its slope is the median of the slopes between every two points, so a single odd session
    /// moves it little. `slopeLow...slopeHigh` is Sen's interval for the slope.
    public struct Trend: Equatable, Sendable {
        /// Change of the value per unit of x (per session).
        public let slope: Double
        public let intercept: Double
        /// Nil with too few points for an interval (fewer than five at 90%).
        public let slopeLow: Double?
        public let slopeHigh: Double?
        /// The median x: lines for the interval's two slopes are drawn through the trend at this point.
        public let pivotX: Double
        public let count: Int

        public func value(at x: Double) -> Double { intercept + slope * x }

        /// The range between the interval's two lines at x; nil without an interval.
        public func band(at x: Double) -> ClosedRange<Double>? {
            guard let low = slopeLow, let high = slopeHigh else { return nil }
            let centre = value(at: pivotX)
            let a = centre + low * (x - pivotX), b = centre + high * (x - pivotX)
            return min(a, b)...max(a, b)
        }

        /// The interval lies wholly above or below zero: the trend is more than the scatter around it.
        public var isClear: Bool {
            guard let low = slopeLow, let high = slopeHigh else { return false }
            return low > 0 || high < 0
        }
    }

    /// The trend through the points; nil for fewer than four. `z`: the normal quantile of the interval, 1.645 for
    /// 90% (the default) or 1.96 for 95%.
    public static func theilSen(_ points: [(x: Double, y: Double)], z: Double = 1.6448536269514722) -> Trend? {
        let pts = points.filter { $0.x.isFinite && $0.y.isFinite }
        let n = pts.count
        guard n >= 4 else { return nil }
        var slopes: [Double] = []
        slopes.reserveCapacity(n * (n - 1) / 2)
        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                let dx = pts[j].x - pts[i].x
                if dx != 0 { slopes.append((pts[j].y - pts[i].y) / dx) }
            }
        }
        guard slopes.count >= 3 else { return nil }
        slopes.sort()
        let slope = orderStatistic(slopes, Double(slopes.count - 1) / 2)
        guard let intercept = median(pts.map { $0.y - slope * $0.x }), let pivotX = median(pts.map { $0.x }) else {
            return nil
        }
        // Sen (1968): the interval's ends are order statistics of the slopes, placed by the variance of Kendall's S
        // (reduced for equal values of y and of x).
        var variance = Double(n * (n - 1) * (2 * n + 5)) / 18
        var tiesY: [Double: Int] = [:], tiesX: [Double: Int] = [:]
        for p in pts {
            tiesY[p.y, default: 0] += 1
            tiesX[p.x, default: 0] += 1
        }
        for c in Array(tiesY.values) + Array(tiesX.values) where c > 1 {
            variance -= Double(c * (c - 1) * (2 * c + 5)) / 18
        }
        var low: Double?
        var high: Double?
        if variance > 0 {
            let c = z * variance.squareRoot()
            let count = Double(slopes.count)
            let lowPosition = (count - c) / 2 - 1, highPosition = (count + c) / 2
            if lowPosition >= 0, highPosition <= count - 1 {
                low = orderStatistic(slopes, lowPosition)
                high = orderStatistic(slopes, highPosition)
            }
        }
        return Trend(slope: slope, intercept: intercept, slopeLow: low, slopeHigh: high, pivotX: pivotX, count: n)
    }

    // MARK: Measurement error

    /// The standard error of measurement from repeats: each group holds one child's sessions under the same
    /// conditions (the baseline sessions), and the spread inside the groups, pooled, is how much the number moves
    /// when the child has not changed. Nil without a group of two or more, or when nothing varies.
    public static func pooledWithinSD(_ groups: [[Double]]) -> (sd: Double, degreesOfFreedom: Int)? {
        var ss = 0.0, df = 0
        for group in groups {
            let values = group.filter { $0.isFinite }
            guard values.count >= 2, let m = mean(values) else { continue }
            for v in values { ss += (v - m) * (v - m) }
            df += values.count - 1
        }
        guard df > 0, ss > 0 else { return nil }
        return ((ss / Double(df)).squareRoot(), df)
    }

    /// The standard error of measurement from a reliability study: SD * sqrt(1 - ICC).
    public static func sem(sd: Double, icc: Double) -> Double { sd * max(0, 1 - icc).squareRoot() }

    /// The minimal detectable change: the smallest difference between the mean of `recentCount` sessions and the
    /// mean of `baselineCount` sessions that the measurement's error would not produce by itself, 95 times in 100.
    /// With one session on each side this is the usual MDC95 = 1.96 * sqrt(2) * SEM.
    public static func mdc(sem: Double, baselineCount: Int = 1, recentCount: Int = 1, z: Double = 1.959963984540054) -> Double {
        z * sem * (1 / Double(max(1, baselineCount)) + 1 / Double(max(1, recentCount))).squareRoot()
    }

    // MARK: Change over a course

    public enum Verdict: String, Sendable {
        /// Larger than the measurement's error, in the good direction or the bad one.
        case better, worse
        /// Larger than the error, for a number with no good direction.
        case changed
        /// Within the measurement's error.
        case same
        /// The measurement's error is not known yet.
        case unknown
    }

    public struct Change: Equatable, Sendable {
        /// Mean of the baseline sessions and of the latest sessions.
        public let baseline: Double
        public let recent: Double
        public let delta: Double
        public let baselineCount: Int
        public let recentCount: Int
        /// The minimal detectable change for these two means; nil while the error is not known.
        public let mdc: Double?
        public let verdict: Verdict
        /// The change in units of the minimal detectable change (1: just detectable).
        public var inMDC: Double? { mdc.flatMap { $0 > 0 ? delta / $0 : nil } }
    }

    /// The latest sessions against the first ones. `values`: one number per session in order, sessions that failed
    /// the quality check already left out. Nil until there is at least one session after the baseline.
    public static func change(_ values: [Double], better: ProbeMetric.Better, sem: Double?, baselineCount: Int = 3,
                              recentCount: Int = 3, z: Double = 1.959963984540054) -> Change? {
        let v = values.filter { $0.isFinite }
        let k = max(1, baselineCount)
        guard v.count > k else { return nil }
        let m = min(max(1, recentCount), v.count - k)
        guard let base = mean(Array(v.prefix(k))), let recent = mean(Array(v.suffix(m))) else { return nil }
        let delta = recent - base
        guard let sem, sem.isFinite, sem > 0 else {
            return Change(baseline: base, recent: recent, delta: delta, baselineCount: k, recentCount: m, mdc: nil,
                          verdict: .unknown)
        }
        let limit = mdc(sem: sem, baselineCount: k, recentCount: m, z: z)
        var verdict = Verdict.same
        if abs(delta) > limit {
            switch better {
            case .higher: verdict = delta > 0 ? .better : .worse
            case .lower: verdict = delta < 0 ? .better : .worse
            case .neither: verdict = .changed
            }
        }
        return Change(baseline: base, recent: recent, delta: delta, baselineCount: k, recentCount: m, mdc: limit,
                      verdict: verdict)
    }

    /// The band around the baseline on the chart: one later session falls inside it 95 times in 100 when the child
    /// has not changed. Wider than the SEM alone, because the baseline's own mean is uncertain too.
    public static func baselineBand(_ values: [Double], sem: Double, baselineCount: Int = 3,
                                    z: Double = 1.959963984540054) -> ClosedRange<Double>? {
        let v = values.filter { $0.isFinite }
        let k = min(max(1, baselineCount), v.count)
        guard k >= 1, sem.isFinite, sem >= 0, let base = mean(Array(v.prefix(k))) else { return nil }
        let half = z * sem * (1 + 1 / Double(k)).squareRoot()
        return (base - half)...(base + half)
    }
}
