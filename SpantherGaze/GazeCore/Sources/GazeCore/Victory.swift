import Foundation

/// A play's rank on the victory screen (sunlit redesign, part 4). Nobody gets less than B: the screen rewards the
/// play, it does not grade the child.
public enum VictoryRank: String, Codable, Sendable, CaseIterable {
    case s = "S", a = "A", b = "B"

    /// Stars the rank adds to the observatory.
    public var stars: Int {
        switch self {
        case .s: return 3
        case .a: return 2
        case .b: return 1
        }
    }

    /// The rank from the play's main share (0...1, see `SessionSummary.victoryShare`) and its best run of locks.
    public static func of(share: Double?, bestStreak: Int) -> VictoryRank {
        let x = share.flatMap { $0.isFinite ? $0 : nil } ?? 0
        if x >= 0.9 || (x >= 0.8 && bestStreak >= 15) { return .s }
        if x >= 0.65 || bestStreak >= 10 { return .a }
        return .b
    }
}

/// What the plays build, kept per child: stars from every rank open the Steppe Observatory's landmarks one by one
/// and bring the panther cub its gifts.
public struct Observatory: Codable, Equatable, Sendable {
    public private(set) var stars: Int

    public init(stars: Int = 0) {
        self.stars = max(0, stars)
    }

    /// The stars at which each landmark opens, in order.
    public static let landmarkCosts = [1, 4, 8, 13, 19, 26, 34, 43]
    /// The stars at which the cub gets each gift, in order.
    public static let giftCosts = [3, 10, 21, 36]

    public var landmarks: Int { Observatory.landmarkCosts.filter { $0 <= stars }.count }
    public var gifts: Int { Observatory.giftCosts.filter { $0 <= stars }.count }
    /// The stars the next landmark needs in all, nil once every landmark is open.
    public var nextLandmarkCost: Int? { Observatory.landmarkCosts.first { $0 > stars } }

    public mutating func add(_ rank: VictoryRank) {
        stars += rank.stars
    }
}

/// One play's victory: its rank and the observatory before and after the stars it brought.
public struct VictoryAward: Equatable, Sendable {
    public let rank: VictoryRank
    public let share: Double?
    public let bestStreak: Int
    public let before: Observatory
    public let after: Observatory

    public init(share: Double?, bestStreak: Int, observatory: Observatory) {
        rank = VictoryRank.of(share: share, bestStreak: bestStreak)
        self.share = share.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.bestStreak = max(0, bestStreak)
        before = observatory
        var after = observatory
        after.add(rank)
        self.after = after
    }

    /// Indices of the landmarks this play opened.
    public var newLandmarks: Range<Int> { before.landmarks..<after.landmarks }
    /// Indices of the cub's gifts this play brought.
    public var newGifts: Range<Int> { before.gifts..<after.gifts }
}

extension SessionSummary {
    /// The share a play's rank is read from: meteors burned out of those that left the play, the rhythm game's
    /// accuracy, the warm-up's time near the dot.
    public var victoryShare: Double? {
        switch game {
        case .meteors: return burnedShare ?? holdShare
        case .rhythm: return accuracy
        case .pursuit: return holdShare
        }
    }
}
