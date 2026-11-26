import Foundation

// Players on this phone and the calibration each one keeps (Aziz, 2026-11-26: "к каждому профилю привязана
// калибровка"). Local first: profiles work with no account and no network; the backend's `profiles` table
// (backend/supabase) has the same fields, and `updatedAt` / `deletedAt` let a later sync merge copies. A
// calibration never leaves the phone. The clinic keeps its own children (`ClinicStore`) and their 12-hour rule.

/// A player on this phone (meteors, Wink Beat, pursuit).
public struct PlayerProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Which of the app's avatar colours (0 ..< `ProfileBook.avatarCount`).
    public var avatar: Int
    public var birthYear: Int?
    /// What the games remember for this player (Wink Beat's last difficulty, Hard opened), by key. A sync merges
    /// it key by key.
    public var progress: [String: String]
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when the player was deleted: kept until the sync has told the backend.
    public var deletedAt: Date?

    public init(id: UUID = UUID(), name: String, avatar: Int, birthYear: Int? = nil, progress: [String: String] = [:],
                createdAt: Date, updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.birthYear = birthYear
        self.progress = progress
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}

/// Every profile on the phone and the one playing now.
public struct ProfileBook: Codable, Equatable, Sendable {
    public static let maxNameLength = 24
    public static let avatarCount = 8

    public private(set) var profiles: [PlayerProfile] = []
    public private(set) var activeID: UUID?

    public init() {}

    /// The profiles not deleted, oldest first.
    public var visible: [PlayerProfile] { profiles.filter { $0.deletedAt == nil } }
    public var active: PlayerProfile? { activeID.flatMap(profile) }

    public func profile(_ id: UUID) -> PlayerProfile? { profiles.first { $0.id == id && $0.deletedAt == nil } }

    /// A name as kept: trimmed, inner runs of white space made one space, at most `maxNameLength` characters;
    /// nil when nothing is left.
    public static func clean(name: String) -> String? {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }

    /// The first launch gets a profile to play as, active; a book whose active one is gone activates the oldest.
    /// True when anything changed.
    @discardableResult
    public mutating func ensureOne(defaultName: String, now: Date) -> Bool {
        if visible.isEmpty {
            return add(name: defaultName, now: now) != nil
        }
        if active == nil {
            activeID = visible.first?.id
            return true
        }
        return false
    }

    /// A new player, active at once (they took the phone to set it up). Nil for an empty name.
    @discardableResult
    public mutating func add(name: String, avatar: Int? = nil, birthYear: Int? = nil, now: Date) -> PlayerProfile? {
        guard let clean = Self.clean(name: name) else { return nil }
        let used = Set(visible.map(\.avatar))
        let pick = avatar.map { min(max($0, 0), Self.avatarCount - 1) }
            ?? (0..<Self.avatarCount).first { !used.contains($0) } ?? visible.count % Self.avatarCount
        let p = PlayerProfile(name: clean, avatar: pick, birthYear: birthYear, createdAt: now)
        profiles.append(p)
        activeID = p.id
        return p
    }

    /// Renames a player or changes their colour or birth year. False when there is no such player or the name is
    /// empty.
    @discardableResult
    public mutating func edit(_ id: UUID, name: String? = nil, avatar: Int? = nil, birthYear: Int?? = nil,
                              now: Date) -> Bool {
        guard let i = profiles.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        var p = profiles[i]
        if let name {
            guard let clean = Self.clean(name: name) else { return false }
            p.name = clean
        }
        if let avatar { p.avatar = min(max(avatar, 0), Self.avatarCount - 1) }
        if let birthYear { p.birthYear = birthYear }
        guard p != profiles[i] else { return true }
        p.updatedAt = now
        profiles[i] = p
        return true
    }

    @discardableResult
    public mutating func activate(_ id: UUID) -> Bool {
        guard profile(id) != nil else { return false }
        activeID = id
        return true
    }

    /// Deletes a player: kept as a tombstone for the sync, gone from the list. The last one cannot go. When it was
    /// playing, the oldest left plays.
    @discardableResult
    public mutating func remove(_ id: UUID, now: Date) -> Bool {
        guard visible.count > 1, let i = profiles.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            return false
        }
        profiles[i].deletedAt = now
        profiles[i].updatedAt = now
        if activeID == id { activeID = visible.first?.id }
        return true
    }

    public func progress(_ key: String, of id: UUID? = nil) -> String? {
        (id.flatMap(profile) ?? active)?.progress[key]
    }

    /// Sets (nil: clears) one thing a game remembers for the active player, or for `id`.
    public mutating func setProgress(_ key: String, _ value: String?, of id: UUID? = nil, now: Date) {
        guard let target = id ?? activeID,
              let i = profiles.firstIndex(where: { $0.id == target && $0.deletedAt == nil }),
              profiles[i].progress[key] != value else { return }
        profiles[i].progress[key] = value
        profiles[i].updatedAt = now
    }
}

extension GazeFeatures {
    /// The version of what the tracker measures and how (`GazeFeatures`, the face tracker, the pupil detector, the
    /// filters before the model). A profile's kept calibration plays again only on the same version, across app
    /// updates: bump it with any change that would move where a fitted model aims.
    public static let pipelineVersion = 1
}

/// A profile's calibration kept on this phone, and whether play found it poor.
public struct ProfileCalibration: Codable, Sendable {
    public var profileID: UUID
    public var stored: StoredCalibration
    /// `GazeFeatures.pipelineVersion` when it was made.
    public var pipeline: Int
    /// Play found it no longer fits (`CalibrationHealth`): the next eye mode calibrates again.
    public var poor: CalibrationHealth.Reason?

    public init(profileID: UUID, stored: StoredCalibration, pipeline: Int = GazeFeatures.pipelineVersion,
                poor: CalibrationHealth.Reason? = nil) {
        self.profileID = profileID
        self.stored = stored
        self.pipeline = pipeline
        self.poor = poor
    }
}

/// When a profile's kept calibration plays again. It goes with the player from launch to launch and across app
/// updates until it is `maxAgeSec` old, play has found it poor, or the screen, night vision or the tracker changed.
public enum CalibrationPolicy {
    /// One week (Aziz: recalibrate "когда прошло достаточно много времени"; the aim adapter keeps up with small
    /// changes in between).
    public static let maxAgeSec: Double = 7 * 24 * 3600

    public enum Reason: String, Codable, Equatable, Sendable {
        case old, otherScreen, nightVision, newTracking, poorAccuracy, otherGrip, noModel
    }

    public enum Verdict: Equatable, Sendable {
        case use
        case recalibrate(Reason)
    }

    public static func verdict(_ c: ProfileCalibration, night: Bool, screenPt: Vec2,
                               pipeline: Int = GazeFeatures.pipelineVersion, now: Date) -> Verdict {
        if let poor = c.poor { return .recalibrate(poor == .otherGrip ? .otherGrip : .poorAccuracy) }
        guard c.stored.model != nil else { return .recalibrate(.noModel) }
        guard c.pipeline == pipeline else { return .recalibrate(.newTracking) }
        guard c.stored.night == night else { return .recalibrate(.nightVision) }
        guard c.stored.sameScreen(screenPt) else { return .recalibrate(.otherScreen) }
        // A clock moved back by more than a minute is not trusted either.
        let age = now.timeIntervalSince(c.stored.madeAt)
        guard age > -60, age < maxAgeSec else { return .recalibrate(.old) }
        return .use
    }
}

/// Watches a calibration in play and says when it no longer fits the player. Two signs, either one is enough:
/// - the moments the game knew where the player looked (a hit, a destroyed meteor, the start disc): the median of
///   the last `window` misses of the raw aim (before the aim adapter) is over `poorMissCm`. In Aziz's CSVs of
///   2026-11-07 and 2026-11-26 the median was 0.6 to 1.1 cm;
/// - the face has stayed more than `gripChange` nearer or farther than at calibration for `gripSec` of tracked
///   frames: the model is aiming from a grip it never saw.
/// Once a sign is seen the verdict stays until a new calibration (a new `CalibrationHealth`).
public struct CalibrationHealth: Sendable {
    public struct Config: Equatable, Sendable {
        public var window = 12
        public var minLabels = 8
        public var poorMissCm = 1.8
        public var gripChange = 0.35
        public var gripSec = 20.0
        public init() {}
    }

    public enum Reason: String, Codable, Equatable, Sendable { case poorAccuracy, otherGrip }

    public let config: Config
    /// The face's distance at calibration (m); 0 or less turns the grip sign off.
    public let calibrationDistanceM: Double
    public private(set) var verdict: Reason?
    private var misses: [Double] = []
    private var offGrip: Double = 0
    private var lastFrame: Double?

    public init(calibrationDistanceM: Double, config: Config = Config()) {
        self.calibrationDistanceM = calibrationDistanceM
        self.config = config
    }

    /// The median of the misses kept (cm), once there are `minLabels` of them.
    public var medianMissCm: Double? {
        guard misses.count >= config.minLabels else { return nil }
        let s = misses.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// A moment the game knew where the player looked: how far the raw aim was from it (cm).
    public mutating func label(missCm: Double) {
        guard missCm.isFinite, missCm >= 0 else { return }
        misses.append(missCm)
        if misses.count > config.window { misses.removeFirst(misses.count - config.window) }
        if verdict == nil, let m = medianMissCm, m > config.poorMissCm { verdict = .poorAccuracy }
    }

    /// A tracked frame at `time` (s) with the face `distanceM` from the screen. Time off the grip adds up across
    /// frames; a gap of more than half a second (face lost, app paused) adds nothing.
    public mutating func frame(distanceM: Double, time: Double) {
        defer { lastFrame = time }
        guard calibrationDistanceM > 0, distanceM > 0 else { return }
        let dt = lastFrame.map { time - $0 } ?? 0
        let ratio = distanceM / calibrationDistanceM
        if abs(ratio - 1) > config.gripChange {
            if dt > 0, dt < 0.5 { offGrip += dt }
        } else {
            offGrip = max(0, offGrip - max(0, min(dt, 0.5)))
        }
        if verdict == nil, offGrip >= config.gripSec { verdict = .otherGrip }
    }
}

/// Profiles and their calibrations in one folder on this phone: profiles.json, and calibration-<profile id>.json
/// for each player who has one. Plain files, written atomically.
public struct ProfileStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// Application Support/profiles.
    public static var defaultRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("profiles", isDirectory: true)
    }

    private var bookURL: URL { root.appendingPathComponent("profiles.json") }
    private func calibrationURL(_ id: UUID) -> URL { root.appendingPathComponent("calibration-\(id.uuidString).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The book on file; empty when there is none or it cannot be read.
    public func loadBook() -> ProfileBook {
        guard let data = try? Data(contentsOf: bookURL),
              let book = try? Self.decoder.decode(ProfileBook.self, from: data) else { return ProfileBook() }
        return book
    }

    public func save(_ book: ProfileBook) throws {
        try write(Self.encoder.encode(book), to: bookURL)
    }

    public func loadCalibration(_ id: UUID) -> ProfileCalibration? {
        guard let data = try? Data(contentsOf: calibrationURL(id)),
              let c = try? Self.decoder.decode(ProfileCalibration.self, from: data), c.profileID == id else { return nil }
        return c
    }

    public func save(_ c: ProfileCalibration) throws {
        try write(Self.encoder.encode(c), to: calibrationURL(c.profileID))
    }

    public func removeCalibration(_ id: UUID) {
        try? FileManager.default.removeItem(at: calibrationURL(id))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
