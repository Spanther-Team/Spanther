import Foundation

// The 30-day plan (Aziz, 2026-11-28): one short training a day, 7 to 10 minutes, that alternates the modes, raises the
// density of targets slowly, and once a week runs the same short control check so the player sees growth in numbers.
// After two weeks of play the focus by time of day shows when attention is higher: morning, day or evening. It is
// attention training: no word here or on its screens promises treatment or a diagnosis.

/// A mode the plan sends the player to.
public enum PlanMode: String, Codable, Sendable, CaseIterable {
    case moles, fishing, meteors, circles
}

/// One block of a plan day: a mode at a level for about `seconds`.
public struct PlanBlock: Equatable, Codable, Sendable {
    public var mode: PlanMode
    /// 1...10 for the arcades and the meteors; for the circles (Wink Beat) 1 is Easy and 2 Normal.
    public var level: Int
    /// The round's length (s): the arcades play this long; the meteors' level and the song keep their own.
    public var seconds: Double
    /// Part of the weekly control check: the same level and length every week.
    public var control: Bool

    public init(mode: PlanMode, level: Int, seconds: Double, control: Bool = false) {
        self.mode = mode
        self.level = level
        self.seconds = seconds
        self.control = control
    }
}

/// What the plan gives on one of its days.
public struct PlanDay: Equatable, Sendable {
    public var number: Int
    public var blocks: [PlanBlock]
    public var isControl: Bool { blocks.contains { $0.control } }
    /// About how long the day takes (min), with the 3-2-1s and the moves between blocks.
    public var minutes: Int { Int(((blocks.reduce(0) { $0 + $1.seconds } + Double(blocks.count) * 15) / 60).rounded()) }
}

/// How one block went.
public struct PlanBlockResult: Equatable, Codable, Sendable {
    public var mode: PlanMode
    public var level: Int
    public var control: Bool
    /// 0...1: targets caught of those there were.
    public var accuracy: Double
    /// Moles: mean time to the blink (s); fishing: mean look until the catch (s); nil elsewhere.
    public var reactionSec: Double?

    public init(mode: PlanMode, level: Int, control: Bool, accuracy: Double, reactionSec: Double? = nil) {
        self.mode = mode
        self.level = level
        self.control = control
        self.accuracy = min(1, max(0, accuracy))
        self.reactionSec = reactionSec
    }

    /// The focus index of the block, 0...100: the share of targets caught.
    public var focus: Int { Int((accuracy * 100).rounded()) }
}

/// A finished plan day.
public struct PlanDayRecord: Equatable, Codable, Sendable {
    public var number: Int
    /// When it ended.
    public var date: Date
    public var blocks: [PlanBlockResult]

    public init(number: Int, date: Date, blocks: [PlanBlockResult]) {
        self.number = number
        self.date = date
        self.blocks = blocks
    }

    /// The day's focus index: the mean of its blocks'.
    public var focus: Int {
        guard !blocks.isEmpty else { return 0 }
        return Int((Double(blocks.reduce(0) { $0 + $1.focus }) / Double(blocks.count)).rounded())
    }
}

/// One play's focus with when it was, for the focus by time of day. Every play counts, in the plan or not.
public struct FocusEntry: Equatable, Codable, Sendable {
    public var date: Date
    public var mode: PlanMode
    public var focus: Int

    public init(date: Date, mode: PlanMode, focus: Int) {
        self.date = date
        self.mode = mode
        self.focus = min(100, max(0, focus))
    }
}

/// Everything the plan keeps for a player (saved as JSON in their progress, so it goes with the account).
public struct PlanState: Equatable, Codable, Sendable {
    public var days: [PlanDayRecord] = []
    public var entries: [FocusEntry] = []

    public init(days: [PlanDayRecord] = [], entries: [FocusEntry] = []) {
        self.days = days
        self.entries = entries
    }

    /// The most focus entries kept: about two months of daily play.
    public static let maxEntries = 400

    public mutating func add(_ e: FocusEntry) {
        entries.append(e)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    public func json() -> String? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func from(json: String?) -> PlanState {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let s = json, let d = s.data(using: .utf8), let p = try? dec.decode(PlanState.self, from: d) else {
            return PlanState()
        }
        return p
    }
}

public enum DailyPlan {
    public static let length = 30
    /// Once a week, from the first day: the first check is the starting point the others are compared with.
    public static let controlDays: Set<Int> = [1, 8, 15, 22, 29]
    /// The control check: moles and fishing at level 3 for a minute each, the same every week.
    public static let controlLevel = 3
    public static let controlSec = 60.0

    /// The usual length of a block (s).
    public static func seconds(_ m: PlanMode) -> Double {
        switch m {
        case .moles: return 150
        case .fishing: return 120
        case .meteors: return 120
        case .circles: return 107
        }
    }

    /// The day the player is on and whether it was already played today. One plan day per calendar day.
    public static func today(_ s: PlanState, now: Date, calendar: Calendar = .current) -> (number: Int, doneToday: Bool) {
        guard let last = s.days.last else { return (1, false) }
        if calendar.isDate(last.date, inSameDayAs: now) { return (last.number, true) }
        return (min(length, last.number + 1), last.number >= length)
    }

    /// The modes in order: each day leaves one out and starts after it, so no day looks like the one before.
    static let rotation: [PlanMode] = [.moles, .fishing, .meteors, .circles]

    static func modes(day n: Int) -> [PlanMode] {
        let skip = (n - 1) % rotation.count
        return (1..<rotation.count).map { rotation[(skip + $0) % rotation.count] }
    }

    /// The level a mode plays at on day `n`: one level up every three days, held while the last play of the mode
    /// caught under 60%, one down under 40%.
    public static func level(_ m: PlanMode, day n: Int, history s: PlanState) -> Int {
        let last = s.days.reversed().lazy.flatMap { $0.blocks.reversed() }.first { $0.mode == m && !$0.control }
        if m == .circles {
            // Easy for the first two weeks, then Normal while the songs go well.
            guard n > 14 else { return 1 }
            if let l = last, l.accuracy < 0.6 { return 1 }
            return 2
        }
        let base = min(10, 1 + (n - 1) / 3)
        guard let l = last else { return base }
        if l.accuracy < 0.4 { return max(1, l.level - 1) }
        if l.accuracy < 0.6 { return min(base, l.level) }
        return base
    }

    /// The plan for day `n` (1...30). A control day starts with the check and then plays two of the usual blocks.
    public static func day(_ n: Int, history s: PlanState) -> PlanDay {
        let n = min(length, max(1, n))
        var blocks: [PlanBlock] = []
        var modes = modes(day: n)
        if controlDays.contains(n) {
            blocks.append(PlanBlock(mode: .moles, level: controlLevel, seconds: controlSec, control: true))
            blocks.append(PlanBlock(mode: .fishing, level: controlLevel, seconds: controlSec, control: true))
            modes = Array(modes.prefix(2))
        }
        for m in modes { blocks.append(PlanBlock(mode: m, level: level(m, day: n, history: s), seconds: seconds(m))) }
        return PlanDay(number: n, blocks: blocks)
    }

    /// The weekly control checks done so far.
    public static func controls(_ s: PlanState) -> [ControlCheck] {
        s.days.compactMap { d in
            let c = d.blocks.filter(\.control)
            guard !c.isEmpty else { return nil }
            let moles = c.first { $0.mode == .moles }, fish = c.first { $0.mode == .fishing }
            let focus = Int((Double(c.reduce(0) { $0 + $1.focus }) / Double(c.count)).rounded())
            return ControlCheck(day: d.number, date: d.date, focus: focus, molesReactionSec: moles?.reactionSec,
                                fishHoldSec: fish?.reactionSec)
        }
    }
}

/// One weekly control check.
public struct ControlCheck: Equatable, Sendable {
    public var day: Int
    public var date: Date
    /// The mean focus index of the check's two blocks.
    public var focus: Int
    public var molesReactionSec: Double?
    public var fishHoldSec: Double?
}

// MARK: - Focus by time of day

public enum DayBand: String, CaseIterable, Sendable {
    case morning, day, evening

    /// Morning 5:00 to 12:00, day 12:00 to 17:00, evening the rest (night play counts as evening).
    public static func of(hour h: Int) -> DayBand {
        switch h {
        case 5..<12: return .morning
        case 12..<17: return .day
        default: return .evening
        }
    }
}

/// When the player's focus is higher. Modes differ in how hard they are, so each play is compared with the mean of
/// its own mode, and a band's index is the overall mean plus its plays' mean difference.
public struct FocusByTime: Equatable, Sendable {
    public struct Band: Equatable, Sendable {
        public var band: DayBand
        /// Days with play in this band.
        public var days: Int
        /// The band's focus index (0...100), nil without play.
        public var focus: Int?
    }

    public var bands: [Band]
    /// Days from the first play to the last (both counted).
    public var spanDays: Int
    /// Enough play to say anything: two weeks, and three days of play in each of at least two bands.
    public var ready: Bool
    /// The band with the higher focus, when it leads the next one by at least `lead` points.
    public var best: DayBand?
    /// Days of the two weeks still to go.
    public var daysLeft: Int { max(0, Self.weeks2 - spanDays) }

    public static let weeks2 = 14
    public static let minDaysInBand = 3
    public static let lead = 5

    public init(_ entries: [FocusEntry], calendar: Calendar = .current) {
        guard let first = entries.map(\.date).min(), let last = entries.map(\.date).max() else {
            bands = DayBand.allCases.map { Band(band: $0, days: 0, focus: nil) }
            spanDays = 0
            ready = false
            best = nil
            return
        }
        let d0 = calendar.startOfDay(for: first), d1 = calendar.startOfDay(for: last)
        spanDays = (calendar.dateComponents([.day], from: d0, to: d1).day ?? 0) + 1
        var modeMean: [PlanMode: Double] = [:]
        for m in PlanMode.allCases {
            let f = entries.filter { $0.mode == m }.map { Double($0.focus) }
            if !f.isEmpty { modeMean[m] = f.reduce(0, +) / Double(f.count) }
        }
        let overall = Double(entries.reduce(0) { $0 + $1.focus }) / Double(entries.count)
        var out: [Band] = []
        for b in DayBand.allCases {
            let mine = entries.filter { DayBand.of(hour: calendar.component(.hour, from: $0.date)) == b }
            let days = Set(mine.map { calendar.startOfDay(for: $0.date) }).count
            var focus: Int?
            if !mine.isEmpty {
                let diff = mine.reduce(0.0) { $0 + Double($1.focus) - (modeMean[$1.mode] ?? overall) } / Double(mine.count)
                focus = Int(min(100, max(0, overall + diff)).rounded())
            }
            out.append(Band(band: b, days: days, focus: focus))
        }
        bands = out
        let counted = out.filter { $0.days >= Self.minDaysInBand && $0.focus != nil }
        ready = spanDays >= Self.weeks2 && counted.count >= 2
        let sorted = counted.sorted { ($0.focus ?? 0) > ($1.focus ?? 0) }
        if ready, sorted.count >= 2, (sorted[0].focus ?? 0) - (sorted[1].focus ?? 0) >= Self.lead {
            best = sorted[0].band
        } else {
            best = nil
        }
    }
}

// MARK: - The daily play limit

/// The soft daily limit Aziz chose (2026-11-28): after 20 minutes of play in a day the app suggests a rest, then
/// again every 5 minutes; play can go on. Counts play time on one calendar day.
public struct PlayTimeGuard: Equatable, Codable, Sendable {
    public static let firstSec = 20.0 * 60
    public static let everySec = 5.0 * 60

    /// The local day counted ("2026-11-28").
    public var day: String
    public var playedSec: Double
    /// When the next reminder is due (s of play today).
    public var nextSec: Double

    public init(day: String) {
        self.day = day
        playedSec = 0
        nextSec = Self.firstSec
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Adds `sec` of play on the day `key`; a new day starts from zero.
    public mutating func add(_ sec: Double, day key: String) {
        if key != day { self = PlayTimeGuard(day: key) }
        playedSec += max(0, sec)
    }

    public var due: Bool { playedSec >= nextSec }

    /// The reminder was shown: the next one comes 5 minutes of play later.
    public mutating func reminded() { nextSec = playedSec + Self.everySec }

    public var playedMinutes: Int { Int(playedSec / 60) }
}
