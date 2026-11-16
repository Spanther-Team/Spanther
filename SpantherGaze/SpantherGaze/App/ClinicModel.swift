import CryptoKit
import Foundation
import LocalAuthentication

/// The clinic's records on this phone (GazeCore `ClinicStore`) for the screens (architecture proposal §1): the
/// children, who is playing now, and who holds the phone: the clinician (unlocked by Face ID or the device passcode)
/// adds children, starts courses, sees the charts and exports; a parent (by the parent PIN) sees the plain-words
/// summary; a child sees only the picker and the plays. Main thread.
final class ClinicModel: ObservableObject {
    /// Every child, archived ones too, by code.
    @Published private(set) var records: [ChildRecord] = []
    /// The child picked on «Кто играет?»; kept between launches.
    @Published var playingID: UUID? {
        didSet { UserDefaults.standard.set(playingID?.uuidString, forKey: "clinicPlaying") }
    }
    /// Who unlocked the clinic's screens; nil while a child holds the phone.
    @Published private(set) var role: Role?
    /// The phone has no passcode, so the clinician's screens could not be locked: they say so.
    @Published private(set) var unguarded = false
    /// The last thing that went wrong, said in a line on the screen that did it.
    @Published var problem: String?

    let store: ClinicStore?
    private static let pinKey = "clinicParentPin"

    init() {
        store = ClinicStore.defaultRoot.map { ClinicStore(root: $0) }
        playingID = UserDefaults.standard.string(forKey: "clinicPlaying").flatMap(UUID.init(uuidString:))
        reload()
    }

    func reload() {
        records = store?.records() ?? []
        if let id = playingID, !records.contains(where: { $0.id == id && !$0.child.archived }) { playingID = nil }
    }

    /// The children on the picker: not archived, by code.
    var active: [ChildRecord] { records.filter { !$0.child.archived } }
    var playing: ChildRecord? { records.first { $0.id == playingID } }
    func record(_ id: UUID) -> ChildRecord? { records.first { $0.id == id } }

    /// The plays an older build kept in sessions.json become children (one per code), once.
    func migrate(_ plays: [SessionSummary]) {
        guard let store else { return }
        if (try? store.migrateLegacy(plays)) ?? 0 > 0 { reload() }
    }

    // MARK: Roles

    /// Face ID or the device passcode opens the clinician's screens. A phone without a passcode cannot guard them:
    /// they open, and the clinic screen asks for a passcode to be set.
    func unlockClinician(done: @escaping (Bool) -> Void = { _ in }) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            unguarded = true
            role = .clinician
            done(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("Открыть профили, графики и выгрузку")) { [weak self] ok, _ in
            DispatchQueue.main.async {
                if ok {
                    self?.unguarded = false
                    self?.role = .clinician
                }
                done(ok)
            }
        }
    }

    var hasParentPin: Bool { UserDefaults.standard.string(forKey: Self.pinKey) != nil }

    /// The clinician sets the PIN that guards the reports at home (4 to 8 digits).
    func setParentPin(_ pin: String) -> Bool {
        guard role == .clinician, Self.validPin(pin) else { return false }
        UserDefaults.standard.set(Self.hash(pin), forKey: Self.pinKey)
        return true
    }

    func unlockParent(pin: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: Self.pinKey), Self.hash(pin) == stored else { return false }
        role = .parent
        return true
    }

    /// Back to the child's view.
    func lock() { role = nil }

    static func validPin(_ pin: String) -> Bool { (4...8).contains(pin.count) && pin.allSatisfy(\.isNumber) }

    private static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data("spanther-parent-pin:\(pin)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Changes (each one a new line in the child's log)

    @discardableResult
    func addChild(code: String, emblem: Int, nickname: String?, birthYear: Int?) -> ChildRecord? {
        guard role == .clinician, let store else { return nil }
        do {
            let r = try store.createChild(code: code, emblem: emblem, birthYear: birthYear, nickname: nickname, by: .clinician)
            reload()
            playingID = r.id
            problem = nil
            return r
        } catch ClinicStore.StoreError.emptyCode {
            problem = L("Нужен код ребёнка")
        } catch ClinicStore.StoreError.duplicateCode(let c) {
            problem = L("Код {0} уже есть", c)
        } catch {
            problem = L("Не получилось сохранить")
        }
        return nil
    }

    func startCourse(child id: UUID, title: String, planned: Int, place: Session.Place) {
        let course = Course(title: title, plannedSessions: max(1, planned), probeVersion: ProbeProtocol.latest.version,
                            started: Date(), place: place)
        apply(.courseStarted(course: course), child: id)
    }

    func closeCourse(child id: UUID, course: UUID) { apply(.courseClosed(courseID: course), child: id) }

    func markProcedure(child id: UUID, course: UUID, kind: Procedure.Kind, date: Date, label: String?) {
        let text = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        apply(.procedureMarked(courseID: course, procedure: Procedure(kind: kind, date: date,
                                                                      label: (text?.isEmpty ?? true) ? nil : text)), child: id)
    }

    func voidSession(child id: UUID, session: UUID, reason: String) {
        apply(.sessionVoided(sessionID: session, reason: reason), child: id)
    }

    func tagSession(child id: UUID, session: UUID, tags: [String], note: String?) {
        apply(.sessionTagged(sessionID: session, tags: tags, note: note), child: id)
    }

    func archive(child id: UUID) {
        guard var c = record(id)?.child else { return }
        c.archived = true
        apply(.childUpdated(child: c), child: id)
        if playingID == id { playingID = nil }
    }

    /// A finished visit: its raw CSV is copied next to the child's log first, so the log line can name it.
    func recordSession(_ session: Session, child id: UUID, csv: URL?) {
        guard let store else { return }
        var s = session
        if let csv, FileManager.default.fileExists(atPath: csv.path) {
            let stamp = Self.fileStamp.string(from: session.start)
            s.csvFile = try? store.storeFile(from: csv, child: id, name: "session-\(stamp).csv")
        }
        let by: Role = role ?? (session.place == .home ? .parent : .clinician)
        do {
            try store.append(.sessionRecorded(session: s), child: id, by: by)
            reload()
        } catch {
            problem = L("Занятие не сохранилось")
        }
    }

    private func apply(_ change: ClinicEvent.Change, child id: UUID) {
        guard let store else { return }
        do {
            try store.append(change, child: id, by: role ?? .clinician)
            reload()
            problem = nil
        } catch ClinicStore.StoreError.duplicateCode(let c) {
            problem = L("Код {0} уже есть", c)
        } catch {
            problem = L("Не получилось сохранить")
        }
    }

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    #if DEBUG
    /// The Simulator smoke test (`-SpantherAutoplay probe`): a made-up child «CI-1» with a course of 30, made once.
    func makeBotChild() -> UUID? {
        if let r = active.first(where: { $0.child.code == "CI-1" }) { return r.id }
        let was = role
        role = .clinician
        defer { role = was }
        guard let r = addChild(code: "CI-1", emblem: 3, nickname: "Бот", birthYear: 2018) else { return nil }
        startCourse(child: r.id, title: "Курс CI", planned: 30, place: .clinic)
        return r.id
    }
    #endif

    // MARK: The probe's forms

    /// The zone orders of the forms these sessions showed, so a new session gets another one. Rebuilt from the seeds
    /// in the log (the form is frozen per seed and generator version). Takes a while for a long course: any thread.
    static func signatures(of sessions: [Session]) -> Set<String> {
        var seen: Set<String> = []
        for s in sessions {
            guard let p = s.probe, let rules = ProbeProtocol.version(p.version), p.generatorVersion == rules.generatorVersion,
                  let plan = ProbePlan.make(seed: p.seed, rules: rules) else { continue }
            seen.insert(plan.zoneSignature)
        }
        return seen
    }
}
