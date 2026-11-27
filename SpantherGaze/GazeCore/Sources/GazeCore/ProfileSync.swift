import Foundation

// Players, progress and plays between this phone and the signed-in account (backend/README.md).
// The phone works without the network: a sync takes the account's copies in, merges them with the same rules the
// database uses, sends what the account lacks, then sends the plays waiting on the phone. Calibrations never leave.

// MARK: Rows as the database keeps them

/// A player as the database's profiles table keeps it. Times in whole seconds, so a copy from the phone and the
/// same copy back from the database are equal.
public struct ProfileRow: Codable, Equatable, Sendable {
    /// The columns the app reads.
    public static let columns = "id,name,avatar,birth_year,progress,created_at,updated_at,deleted_at"

    public var id: UUID
    public var name: String
    public var avatar: Int
    public var birthYear: Int?
    public var progress: [String: String]
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    /// The phone's player, fitted to the database's checks.
    public init(_ p: PlayerProfile) {
        id = p.id
        var n = p.name
        while n.unicodeScalars.count > 64 { n.removeLast() }
        name = n.isEmpty ? "?" : n
        avatar = min(max(p.avatar, 0), 15)
        birthYear = p.birthYear.flatMap { (1900...2100).contains($0) ? $0 : nil }
        progress = p.progress
        createdAt = BackendDate.whole(p.createdAt)
        updatedAt = BackendDate.whole(p.updatedAt)
        deletedAt = p.deletedAt.map(BackendDate.whole)
    }

    public var profile: PlayerProfile {
        PlayerProfile(id: id, name: name, avatar: avatar, birthYear: birthYear, progress: progress,
                      createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, avatar, birthYear = "birth_year", progress, createdAt = "created_at",
             updatedAt = "updated_at", deletedAt = "deleted_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatar = try c.decodeIfPresent(Int.self, forKey: .avatar) ?? 0
        birthYear = try c.decodeIfPresent(Int.self, forKey: .birthYear)
        // A value someone typed into the database by hand as a number or a flag still reads.
        progress = (try c.decodeIfPresent([String: LooseString].self, forKey: .progress) ?? [:])
            .compactMapValues(\.value)
        createdAt = try Self.date(c, .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try Self.date(c, .updatedAt) ?? createdAt
        deletedAt = try Self.date(c, .deletedAt)
    }

    /// Every key, nulls too: one request's rows must all have the same keys.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(avatar, forKey: .avatar)
        try c.encode(birthYear, forKey: .birthYear)
        try c.encode(progress, forKey: .progress)
        try c.encode(BackendDate.string(createdAt), forKey: .createdAt)
        try c.encode(BackendDate.string(updatedAt), forKey: .updatedAt)
        try c.encode(deletedAt.map(BackendDate.string), forKey: .deletedAt)
    }

    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date? {
        try c.decodeIfPresent(String.self, forKey: key).flatMap(BackendDate.date)
    }
}

/// One play's result as the database's plays table keeps it: added once, never changed.
public struct PlayRow: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var profileID: UUID
    /// meteors, rhythm, pursuit, winkbeat.
    public var game: String
    public var difficulty: String?
    public var byEye: Bool
    public var startedAt: Date
    public var durationSec: Double
    public var score: Int?
    /// The share of targets hit, 0...1.
    public var accuracy: Double?
    public var hits: Int?
    public var misses: Int?
    /// "1.0.4 (10)".
    public var build: String?

    /// Fitted to the database's checks, so one odd number does not stop the rest from going.
    public init(id: UUID = UUID(), profileID: UUID, game: String, difficulty: String? = nil, byEye: Bool,
                startedAt: Date, durationSec: Double, score: Int? = nil, accuracy: Double? = nil, hits: Int? = nil,
                misses: Int? = nil, build: String? = nil) {
        self.id = id
        self.profileID = profileID
        let g = String(game.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(32))
        self.game = g.isEmpty ? "unknown" : g
        self.difficulty = difficulty.map { String($0.prefix(32)) }
        self.byEye = byEye
        self.startedAt = BackendDate.whole(startedAt)
        self.durationSec = durationSec.isFinite ? max(0, durationSec) : 0
        self.score = score
        self.accuracy = accuracy.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        self.hits = hits.map { max(0, $0) }
        self.misses = misses.map { max(0, $0) }
        self.build = build.map { String($0.prefix(40)) }
    }

    enum CodingKeys: String, CodingKey {
        case id, profileID = "profile_id", game, difficulty, byEye = "by_eye", startedAt = "started_at",
             durationSec = "duration_sec", score, accuracy, hits, misses, build
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        profileID = try c.decode(UUID.self, forKey: .profileID)
        game = try c.decode(String.self, forKey: .game)
        difficulty = try c.decodeIfPresent(String.self, forKey: .difficulty)
        byEye = try c.decode(Bool.self, forKey: .byEye)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt).flatMap(BackendDate.date)
            ?? Date(timeIntervalSince1970: 0)
        durationSec = try c.decode(Double.self, forKey: .durationSec)
        score = try c.decodeIfPresent(Int.self, forKey: .score)
        accuracy = try c.decodeIfPresent(Double.self, forKey: .accuracy)
        hits = try c.decodeIfPresent(Int.self, forKey: .hits)
        misses = try c.decodeIfPresent(Int.self, forKey: .misses)
        build = try c.decodeIfPresent(String.self, forKey: .build)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(profileID.uuidString.lowercased(), forKey: .profileID)
        try c.encode(game, forKey: .game)
        try c.encode(difficulty, forKey: .difficulty)
        try c.encode(byEye, forKey: .byEye)
        try c.encode(BackendDate.string(startedAt), forKey: .startedAt)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encode(score, forKey: .score)
        try c.encode(accuracy, forKey: .accuracy)
        try c.encode(hits, forKey: .hits)
        try c.encode(misses, forKey: .misses)
        try c.encode(build, forKey: .build)
    }
}

extension PlayRow {
    /// A play of meteors, the rhythm mode or the warm-up, from the session's summary. Nil when the summary's id is
    /// not a UUID.
    public init?(_ s: SessionSummary, profileID: UUID, build: String?) {
        guard let id = UUID(uuidString: s.id) else { return nil }
        var difficulty: String?
        var score: Int?
        var accuracy: Double?
        var hits: Int?
        var misses: Int?
        switch s.game {
        case .meteors:
            difficulty = s.maxLevel.map { "level-\($0)" }
            score = s.burned
            hits = s.burned
            if let all = s.meteors, let burned = s.burned {
                misses = all - burned
                accuracy = all > 0 ? Double(burned) / Double(all) : nil
            }
        case .rhythm:
            difficulty = s.rhythmLevel
            accuracy = s.accuracy
            hits = s.hits
            if let notes = s.notes, let h = s.hits { misses = notes - h }
        case .pursuit:
            break
        }
        self.init(id: id, profileID: profileID, game: s.game.rawValue, difficulty: difficulty, byEye: s.byEye,
                  startedAt: s.start, durationSec: s.durationSec, score: score, accuracy: accuracy, hits: hits,
                  misses: misses, build: build)
    }
}

/// A string, or a number or flag read as one; nil for anything else.
struct LooseString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = nil
        } else if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int.self) {
            value = String(i)
        } else if let d = try? c.decode(Double.self) {
            value = String(d)
        } else if let b = try? c.decode(Bool.self) {
            value = b ? "1" : "0"
        } else {
            value = nil
        }
    }
}

// MARK: What the phone remembers between syncs

/// Kept next to the players (sync.json).
public struct ProfileSyncState: Codable, Equatable, Sendable {
    /// The account this phone's players were last synced with; it stays after signing out.
    public var accountID: UUID?
    /// The players known to be in that account.
    public var synced: Set<UUID> = []

    public init(accountID: UUID? = nil, synced: Set<UUID> = []) {
        self.accountID = accountID
        self.synced = synced
    }
}

/// Plays waiting to go to the account, kept on the phone (plays.json) until sent; the oldest give way past
/// `limit`. Plays of a player not in the signed-in account wait for that account.
public struct PlayQueue: Codable, Equatable, Sendable {
    public static let limit = 2000

    public private(set) var rows: [PlayRow] = []

    public init(rows: [PlayRow] = []) { self.rows = rows }

    /// A play not sent yet, or a newer copy of one waiting (the same id).
    public mutating func add(_ row: PlayRow) {
        if let i = rows.firstIndex(where: { $0.id == row.id }) {
            rows[i] = row
            return
        }
        rows.append(row)
        if rows.count > Self.limit { rows.removeFirst(rows.count - Self.limit) }
    }

    /// The plays of these players, oldest first.
    public func ready(for players: Set<UUID>) -> [PlayRow] { rows.filter { players.contains($0.profileID) } }

    public mutating func remove(_ ids: Set<UUID>) { rows.removeAll { ids.contains($0.id) } }

    /// The players who have plays waiting.
    public var players: Set<UUID> { Set(rows.map(\.profileID)) }
}

// MARK: The steps of a sync

public enum ProfileSync {
    /// Takes the account's players in, after the phone's own `book` was made ready for them:
    ///  * players of another account that was signed in here before leave the phone (they stay in their account);
    ///  * a fresh phone's untouched first player (never named, never played as) gives way when the account
    ///    already has players.
    /// Then the account's copies are merged in. Returns the players taken off the phone: their calibration goes.
    public static func takeIn(_ server: [PlayerProfile], account: UUID, book: inout ProfileBook,
                              state: inout ProfileSyncState, played: Set<UUID>) -> Set<UUID> {
        var gone = Set<UUID>()
        if state.accountID != account {
            if state.accountID != nil { gone = state.synced }
            state = ProfileSyncState(accountID: account)
        }
        let theirs = Set(server.map(\.id))
        if server.contains(where: { $0.deletedAt == nil }) {
            let mine = book.visible.filter { !gone.contains($0.id) }
            if mine.count == 1, let p = mine.first, !theirs.contains(p.id), !state.synced.contains(p.id),
               !played.contains(p.id), ProfileBook.isPlaceholder(p) {
                gone.insert(p.id)
            }
        }
        gone = gone.subtracting(theirs)
        book.drop(gone)
        book.merge(server)
        state.synced.formUnion(theirs)
        return gone
    }

    /// The players the account lacks or holds another copy of. A player deleted before it ever reached the
    /// account stays on the phone.
    public static func toSend(_ book: ProfileBook, server: [PlayerProfile]) -> [ProfileRow] {
        var theirs: [UUID: ProfileRow] = [:]
        for p in server { theirs[p.id] = ProfileRow(p) }
        return book.profiles.map(ProfileRow.init).filter { row in
            guard let copy = theirs[row.id] else { return row.deletedAt == nil }
            return copy != row
        }
    }

    public static func sent(_ rows: [ProfileRow], state: inout ProfileSyncState) {
        state.synced.formUnion(rows.map(\.id))
    }

    /// Sends rows all at once; when the server refuses the lot, one by one, so a row it refuses (a check, a rule)
    /// does not hold the others back. Returns the rows it took and the rows it refused; other failures throw.
    public static func send<Row: Sendable>(_ rows: [Row], _ push: ([Row]) async throws -> Void)
        async throws -> (sent: [Row], refused: [Row]) {
        guard !rows.isEmpty else { return ([], []) }
        do {
            try await push(rows)
            return (rows, [])
        } catch let e as BackendError where e.reason == .rejected && rows.count > 1 {
            var sent: [Row] = []
            var refused: [Row] = []
            for row in rows {
                do {
                    try await push([row])
                    sent.append(row)
                } catch let e as BackendError where e.reason == .rejected {
                    refused.append(row)
                }
            }
            return (sent, refused)
        }
    }
}
