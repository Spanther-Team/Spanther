import Foundation

/// Locks in a row in one play (sunlit redesign, part 3). Every lock adds one; a miss or a look at a distractor ends
/// the run. Every fifth lock in a row (5, 10, 15, 20, 25 ...) is a milestone, celebrated on screen.
public struct Streak: Equatable, Sendable {
    /// Locks in the current run.
    public private(set) var count = 0
    /// The longest run of the play.
    public private(set) var best = 0
    /// Milestones reached in the play.
    public private(set) var milestones = 0

    public init() {}

    /// A lock. Returns the run's length when it is a milestone, nil otherwise.
    @discardableResult
    public mutating func lock() -> Int? {
        count += 1
        best = max(best, count)
        guard Streak.isMilestone(count) else { return nil }
        milestones += 1
        return count
    }

    /// A miss or a distractor: the run is over. Returns how long it was.
    @discardableResult
    public mutating func breakRun() -> Int {
        let was = count
        count = 0
        return was
    }

    /// Follows a count kept elsewhere (the rhythm judge's combo): a lower count first ends the run, then every lock up
    /// to `n` is counted. Returns the milestones passed on the way, in order.
    public mutating func follow(_ n: Int) -> [Int] {
        if n < count { breakRun() }
        var passed: [Int] = []
        while count < n {
            if let m = lock() { passed.append(m) }
        }
        return passed
    }

    public static func isMilestone(_ n: Int) -> Bool { n >= 5 && n % 5 == 0 }

    /// How big the celebration is: 0 for 5 in a row, 1 for 10, 2 for 15, 3 for 20 and every milestone after it.
    public static func tier(_ milestone: Int) -> Int { max(0, min(3, milestone / 5 - 1)) }
}

/// The warm-up has no targets to lock, so following the dot is counted in locks: every `holdSec` on the dot is one,
/// and being off it for longer than `graceSec` ends the run (a short slip or a blink is forgiven).
public struct FollowStreak: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case none, lock, broke
    }

    public var holdSec: Double
    public var graceSec: Double
    private var onSince: Double?
    private var offSince: Double?
    private var credited = 0

    public init(holdSec: Double = 2.0, graceSec: Double = 0.4) {
        self.holdSec = holdSec
        self.graceSec = graceSec
    }

    /// One frame at `t` (seconds): `on` is whether the gaze is on the dot.
    public mutating func update(time t: Double, on: Bool) -> Step {
        if on {
            offSince = nil
            guard let since = onSince else {
                onSince = t
                credited = 0
                return .none
            }
            let whole = Int((t - since) / holdSec)
            guard whole > credited else { return .none }
            credited = whole
            return .lock
        }
        guard onSince != nil else { return .none }
        guard let off = offSince else {
            offSince = t
            return .none
        }
        guard t - off > graceSec else { return .none }
        onSince = nil
        offSince = nil
        credited = 0
        return .broke
    }
}
