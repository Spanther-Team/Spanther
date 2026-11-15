import Foundation

// The clinic's records: children known by a code, their courses of 25 to 30 sessions, and each session's probe and
// plays. Nothing is rewritten: every child has an append-only log of events (ClinicStore), and the state the screens
// show is folded from it, so every number on a chart traces back to the line that recorded it. No face data and no
// names are kept: a child is a code and an emblem.

/// Who made a change: the clinician (unlocked by Face ID or the passcode) or a parent (by the parent PIN).
public enum Role: String, Codable, Sendable { case clinician, parent }

/// A child in the specialist's care.
public struct Child: Codable, Sendable, Equatable, Identifiable {
    /// The emblems a child finds their tile by, before they can read their code.
    public static let emblemCount = 12

    public var id: UUID
    /// The code the specialist gives instead of a name, such as «А-017».
    public var code: String
    /// The emblem tile, 0..<emblemCount.
    public var emblem: Int
    public var birthYear: Int?
    public var created: Date
    /// Hidden from the picker; the log and the charts stay.
    public var archived: Bool
    /// What the tile says under the emblem, such as «Лиса»: a word the child picked, never a real name. Nil in logs
    /// written before it existed.
    public var nickname: String?

    public init(id: UUID = UUID(), code: String, emblem: Int, birthYear: Int? = nil, created: Date,
                archived: Bool = false, nickname: String? = nil) {
        self.id = id
        self.code = code
        self.emblem = emblem
        self.birthYear = birthYear
        self.created = created
        self.archived = archived
        self.nickname = nickname
    }

    /// The tile's caption: the nickname when there is one, otherwise the code.
    public var tileName: String {
        let name = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? code : name
    }
}

/// Another procedure the child has in the same weeks, shown as a mark on the course chart.
public struct Procedure: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case neurofeedback, tms, laser, other }

    public var id: UUID
    public var kind: Kind
    public var date: Date
    /// The clinic's own name for it, such as «BrainsWay» or «Excellent Brain».
    public var label: String?

    public init(id: UUID = UUID(), kind: Kind, date: Date, label: String? = nil) {
        self.id = id
        self.kind = kind
        self.date = date
        self.label = label
    }
}

/// A planned course of sessions, measured with one frozen probe from the first session to the last.
public struct Course: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var plannedSessions: Int
    /// The probe protocol every session of this course runs. A newer build keeps running this version for the
    /// course, so session 1 and session 30 stay comparable.
    public var probeVersion: Int
    public var started: Date
    public var closed: Date?
    public var procedures: [Procedure]
    /// Where the course's sessions run: at the clinic or at home between visits. Nil in logs written before it
    /// existed, which `runsAt` reads as the clinic.
    public var place: Session.Place?

    public init(id: UUID = UUID(), title: String, plannedSessions: Int, probeVersion: Int, started: Date,
                closed: Date? = nil, procedures: [Procedure] = [], place: Session.Place? = .clinic) {
        self.id = id
        self.title = title
        self.plannedSessions = plannedSessions
        self.probeVersion = probeVersion
        self.started = started
        self.closed = closed
        self.procedures = procedures
        self.place = place
    }

    /// Where the course runs, the clinic when the log does not say.
    public var runsAt: Session.Place { place ?? .clinic }
}

/// What the phone saw while a session ran, so an odd session can be explained instead of argued about.
public struct Conditions: Codable, Sendable, Equatable {
    /// Mean error on the check screen of the calibration before the session (cm).
    public var calibrationErrorCm: Double?
    /// Median distance from the eyes to the screen (cm).
    public var distanceCm: Double?
    /// Median tracking frames per second.
    public var trackingFps: Double?
    /// The worst thermal state seen: nominal, fair, serious or critical.
    public var thermal: String?
    public var lowPower: Bool?
    public var night: Bool?
    /// Battery used during the session, 0...1.
    public var batteryUsed: Double?
    public var appVersion: String?
    /// The model identifier, such as iPhone14,5.
    public var device: String?
    /// Median ARKit light estimate on the face (lumen; about 1000 in a lit room, under 120 is dark).
    public var lightLm: Double?

    public init(calibrationErrorCm: Double? = nil, distanceCm: Double? = nil, trackingFps: Double? = nil,
                thermal: String? = nil, lowPower: Bool? = nil, night: Bool? = nil, batteryUsed: Double? = nil,
                appVersion: String? = nil, device: String? = nil, lightLm: Double? = nil) {
        self.calibrationErrorCm = calibrationErrorCm
        self.distanceCm = distanceCm
        self.trackingFps = trackingFps
        self.thermal = thermal
        self.lowPower = lowPower
        self.night = night
        self.batteryUsed = batteryUsed
        self.appVersion = appVersion
        self.device = device
        self.lightLm = lightLm
    }
}

/// The frozen probe's outcome. The version, the generator version and the seed rebuild exactly what the child saw.
public struct ProbeResult: Codable, Sendable, Equatable {
    public var version: Int
    public var generatorVersion: Int
    /// Below 2^53, so any JSON reader (a spreadsheet, a script) keeps it exact.
    public var seed: UInt64
    /// The quality gate before the probe passed (calibration error, distance). A session that failed it is kept,
    /// but its numbers stay off the chart.
    public var qualityPassed: Bool
    /// The probe ran to its end.
    public var completed: Bool
    /// The probe's numbers by name (ProbeMetric). Names a newer build adds are kept as they are.
    public var metrics: [String: Double]
    /// The form's fingerprint (ProbePlan.fingerprint): a later build that rebuilds the form from the seed can
    /// check it got the same one.
    public var fingerprint: UInt64?

    public init(version: Int, generatorVersion: Int, seed: UInt64, qualityPassed: Bool, completed: Bool,
                metrics: [String: Double], fingerprint: UInt64? = nil) {
        self.version = version
        self.generatorVersion = generatorVersion
        self.seed = seed
        self.qualityPassed = qualityPassed
        self.completed = completed
        self.metrics = metrics.filter { $0.value.isFinite }
        self.fingerprint = fingerprint
    }
}

/// One visit: the frozen probe first, then the game part. The plays are the summaries the report already keeps.
public struct Session: Codable, Sendable, Equatable, Identifiable {
    public enum Place: String, Codable, Sendable { case clinic, home }

    public var id: UUID
    public var courseID: UUID?
    /// 1 for the first session of its course; nil outside a course.
    public var number: Int?
    public var start: Date
    public var durationSec: Double
    public var place: Place
    public var conditions: Conditions
    public var probe: ProbeResult?
    public var plays: [SessionSummary]
    /// The clinician's tags, such as «после ТМС» or «сонный».
    public var tags: [String]
    public var note: String?
    /// The session's raw CSV (every tracked frame), a file name in the child's folder next to its log. It leaves
    /// the phone only through the export.
    public var csvFile: String?

    public init(id: UUID = UUID(), courseID: UUID?, number: Int?, start: Date, durationSec: Double,
                place: Place = .clinic, conditions: Conditions = Conditions(), probe: ProbeResult? = nil,
                plays: [SessionSummary] = [], tags: [String] = [], note: String? = nil, csvFile: String? = nil) {
        self.id = id
        self.courseID = courseID
        self.number = number
        self.start = start
        self.durationSec = durationSec
        self.place = place
        self.conditions = conditions
        self.probe = probe
        self.plays = plays
        self.tags = tags
        self.note = note
        self.csvFile = csvFile
    }

    /// The session counts on the course chart: its probe ran to the end and passed the quality gate.
    public var onChart: Bool { probe.map { $0.completed && $0.qualityPassed } ?? false }
}

/// One line of a child's log. Lines are only ever added: a mistake is voided by a new line, never erased.
public struct ClinicEvent: Codable, Sendable, Equatable {
    public enum Change: Codable, Sendable, Equatable {
        case childCreated(child: Child)
        /// The whole profile as it is now (code, emblem, birth year, archived); the id never changes.
        case childUpdated(child: Child)
        case courseStarted(course: Course)
        case courseClosed(courseID: UUID)
        case procedureMarked(courseID: UUID, procedure: Procedure)
        case sessionRecorded(session: Session)
        /// A session recorded by mistake (the wrong child, a test run): kept in the log, left off the charts.
        case sessionVoided(sessionID: UUID, reason: String)
        case sessionTagged(sessionID: UUID, tags: [String], note: String?)
    }

    /// 1, 2, 3... in the order the lines were written.
    public var seq: Int
    public var at: Date
    public var by: Role
    public var change: Change

    public init(seq: Int, at: Date, by: Role, change: Change) {
        self.seq = seq
        self.at = at
        self.by = by
        self.change = change
    }
}

/// A child's state as the screens show it, folded from the log.
public struct ChildRecord: Sendable, Equatable, Identifiable {
    public var child: Child
    /// In the order they were started.
    public var courses: [Course]
    /// Recorded sessions that were not voided, oldest first.
    public var sessions: [Session]
    /// Voided sessions, kept for the audit trail, with the reason in `voidReasons`.
    public var voided: [Session]
    public var voidReasons: [UUID: String]
    public var lastSeq: Int
    /// Lines the fold could not read: a torn last line after a crash, or an event from a newer build.
    public var unreadLines: Int

    public var id: UUID { child.id }

    /// The course sessions are added to now: the newest one not closed.
    public var openCourse: Course? { courses.last { $0.closed == nil } }

    public func sessions(of courseID: UUID) -> [Session] { sessions.filter { $0.courseID == courseID } }

    /// The number the next session of a course gets: one more than the highest number kept on its chart.
    public func nextNumber(in courseID: UUID) -> Int {
        (sessions(of: courseID).compactMap(\.number).max() ?? 0) + 1
    }

    /// Folds a log in the order it was written. Nil when the log does not start the child (no `childCreated`).
    public static func fold(_ events: [ClinicEvent], unreadLines: Int = 0) -> ChildRecord? {
        var record: ChildRecord?
        for event in events {
            if case .childCreated(let child) = event.change {
                if record == nil {
                    record = ChildRecord(child: child, courses: [], sessions: [], voided: [], voidReasons: [:],
                                         lastSeq: event.seq, unreadLines: unreadLines)
                }
                continue
            }
            guard var r = record else { continue }
            r.apply(event)
            r.lastSeq = max(r.lastSeq, event.seq)
            record = r
        }
        record?.sessions.sort { $0.start < $1.start }
        return record
    }

    private mutating func apply(_ event: ClinicEvent) {
        switch event.change {
        case .childCreated:
            break
        case .childUpdated(let updated):
            if updated.id == child.id { child = updated }
        case .courseStarted(let course):
            if !courses.contains(where: { $0.id == course.id }) { courses.append(course) }
        case .courseClosed(let id):
            if let i = courses.firstIndex(where: { $0.id == id }), courses[i].closed == nil { courses[i].closed = event.at }
        case .procedureMarked(let id, let procedure):
            if let i = courses.firstIndex(where: { $0.id == id }) {
                courses[i].procedures.append(procedure)
                courses[i].procedures.sort { $0.date < $1.date }
            }
        case .sessionRecorded(let session):
            if !sessions.contains(where: { $0.id == session.id }) && !voided.contains(where: { $0.id == session.id }) {
                sessions.append(session)
            }
        case .sessionVoided(let id, let reason):
            if let i = sessions.firstIndex(where: { $0.id == id }) {
                voided.append(sessions.remove(at: i))
                voidReasons[id] = reason
            }
        case .sessionTagged(let id, let tags, let note):
            if let i = sessions.firstIndex(where: { $0.id == id }) {
                sessions[i].tags = tags
                sessions[i].note = note
            }
        }
    }
}

/// The plays an older build kept in sessions.json, moved into the clinic's logs once.
public enum ClinicMigration {
    /// The code given to plays that were saved without one, so none of them is lost.
    public static let noCode = "Без кода"

    /// One child per code, oldest play first; each play becomes a session outside any course, so the old history
    /// shows up without passing for a probe.
    public static func children(fromLegacy plays: [SessionSummary], at date: Date) -> [(child: Child, sessions: [Session])] {
        var order: [String] = []
        var byCode: [String: [SessionSummary]] = [:]
        for play in plays.sorted(by: { $0.start < $1.start }) {
            let trimmed = play.childCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = trimmed.isEmpty ? noCode : trimmed
            if byCode[code] == nil { order.append(code) }
            byCode[code, default: []].append(play)
        }
        return order.enumerated().map { index, code in
            let plays = byCode[code] ?? []
            let child = Child(code: code, emblem: index % Child.emblemCount, created: plays.first?.start ?? date)
            let sessions = plays.map { play in
                Session(courseID: nil, number: nil, start: play.start, durationSec: play.durationSec,
                        conditions: Conditions(calibrationErrorCm: play.calibrationErrorCm), plays: [play])
            }
            return (child, sessions)
        }
    }
}
