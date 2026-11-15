import Foundation

/// The clinic's logs on the phone: Application Support/clinic/<child id>/log.jsonl, one JSON event per line, only
/// ever appended and flushed to disk at once. Written when a session ends or a profile changes, never during play.
/// The logs leave the phone only through the export buttons (CLAUDE.md rule 5).
public final class ClinicStore {
    public enum StoreError: Error, Equatable {
        case emptyCode
        case duplicateCode(String)
        case unknownChild(UUID)
        case cannotCreate(String)
    }

    public let root: URL
    private var cache: [UUID: ChildRecord] = [:]
    private var loaded = false
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        // A stray NaN must not cost a child's session: it is kept as text instead of failing the write.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    }

    /// Application Support/clinic; nil only where the system has no such folder.
    public static var defaultRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("clinic", isDirectory: true)
    }

    public func logURL(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("log.jsonl")
    }

    /// Every child, archived ones too, by code.
    public func records() -> [ChildRecord] {
        loadIfNeeded()
        return cache.values.sorted {
            $0.child.code.compare($1.child.code, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
    }

    public func record(_ id: UUID) -> ChildRecord? {
        loadIfNeeded()
        return cache[id]
    }

    /// Reads one child's log from disk, counting the lines it cannot read instead of stopping at them.
    public func read(_ id: UUID) -> ChildRecord? {
        guard let data = try? Data(contentsOf: logURL(id)) else { return nil }
        var events: [ClinicEvent] = []
        var unread = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let event = try? decoder.decode(ClinicEvent.self, from: Data(line)) {
                events.append(event)
            } else {
                unread += 1
            }
        }
        return ChildRecord.fold(events, unreadLines: unread)
    }

    /// Forgets what was read and reads every log again.
    public func reload() {
        loaded = false
        cache = [:]
        loadIfNeeded()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), let record = read(id) else { continue }
            cache[id] = record
        }
    }

    /// Starts a child's log. The code must differ from those of the children not archived, ignoring case.
    @discardableResult
    public func createChild(code: String, emblem: Int, birthYear: Int? = nil, by role: Role,
                            at date: Date = Date()) throws -> ChildRecord {
        let code = try checkedCode(code, except: nil)
        let n = Child.emblemCount
        let child = Child(code: code, emblem: ((emblem % n) + n) % n, birthYear: birthYear, created: date)
        try write(ClinicEvent(seq: 1, at: date, by: role, change: .childCreated(child: child)), to: child.id)
        return try refreshed(child.id)
    }

    /// Adds one line to a child's log and returns the child's state with it.
    @discardableResult
    public func append(_ change: ClinicEvent.Change, child id: UUID, by role: Role,
                       at date: Date = Date()) throws -> ChildRecord {
        loadIfNeeded()
        guard let current = cache[id] else { throw StoreError.unknownChild(id) }
        var change = change
        if case .childUpdated(var updated) = change {
            updated.id = id
            if !updated.archived { updated.code = try checkedCode(updated.code, except: id) }
            change = .childUpdated(child: updated)
        }
        try write(ClinicEvent(seq: current.lastSeq + 1, at: date, by: role, change: change), to: id)
        return try refreshed(id)
    }

    /// Moves the plays an older build kept in sessions.json into the logs, once: a marker file in the clinic folder
    /// remembers it ran. The old file stays where it was. Returns the number of children made.
    @discardableResult
    public func migrateLegacy(_ plays: [SessionSummary], at date: Date = Date()) throws -> Int {
        let marker = root.appendingPathComponent(".legacy-migrated")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return 0 }
        loadIfNeeded()
        let children = ClinicMigration.children(fromLegacy: plays, at: date)
        for (child, sessions) in children {
            try write(ClinicEvent(seq: 1, at: date, by: .clinician, change: .childCreated(child: child)), to: child.id)
            for (i, session) in sessions.enumerated() {
                try write(ClinicEvent(seq: i + 2, at: date, by: .clinician, change: .sessionRecorded(session: session)),
                          to: child.id)
            }
            _ = try refreshed(child.id)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: marker.path, contents: Data()) else {
            throw StoreError.cannotCreate(marker.path)
        }
        return children.count
    }

    private func checkedCode(_ raw: String, except id: UUID?) throws -> String {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw StoreError.emptyCode }
        loadIfNeeded()
        let taken = cache.values.contains {
            $0.id != id && !$0.child.archived && $0.child.code.caseInsensitiveCompare(code) == .orderedSame
        }
        if taken { throw StoreError.duplicateCode(code) }
        return code
    }

    private func refreshed(_ id: UUID) throws -> ChildRecord {
        guard let record = read(id) else { throw StoreError.unknownChild(id) }
        cache[id] = record
        return record
    }

    /// Appends one line and flushes it. A line torn by a crash is closed first, so it stays one unreadable line
    /// instead of swallowing the new one.
    private func write(_ event: ClinicEvent, to id: UUID) throws {
        let url = logURL(id)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path), !fm.createFile(atPath: url.path, contents: nil) {
            throw StoreError.cannotCreate(url.path)
        }
        var line = try encoder.encode(event)
        line.append(0x0A)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { line = Data([0x0A]) + line }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }
}
