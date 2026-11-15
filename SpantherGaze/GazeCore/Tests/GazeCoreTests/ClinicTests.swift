import XCTest
@testable import GazeCore

final class ClinicTests: XCTestCase {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clinic-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func play(_ code: String, _ t: TimeInterval) -> SessionSummary {
        var s = SessionSummary(id: "p\(t)", childCode: code, game: .meteors, start: Date(timeIntervalSince1970: t),
                               durationSec: 60, byEye: true, calibrationErrorCm: 1.2)
        s.meteors = 10
        s.burned = 7
        return s
    }

    func testStoreOnlyAddsLinesAndRebuildsTheSameState() throws {
        let root = tempRoot()
        let store = ClinicStore(root: root)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let kid = try store.createChild(code: "А-017", emblem: 3, birthYear: 2018, by: .clinician, at: t0)
        let course = Course(title: "Курс 1", plannedSessions: 30, probeVersion: 1, started: t0)
        try store.append(.courseStarted(course: course), child: kid.id, by: .clinician, at: t0)
        let probe = ProbeResult(version: 1, generatorVersion: 1, seed: 42, qualityPassed: true, completed: true,
                                metrics: ["holdShare": 0.8, "broken": .nan])
        let first = Session(courseID: course.id, number: 1, start: t0.addingTimeInterval(60), durationSec: 600,
                            conditions: Conditions(trackingFps: .nan), probe: probe,
                            plays: [play("А-017", 1_800_000_100)])
        try store.append(.sessionRecorded(session: first), child: kid.id, by: .clinician)
        let url = store.logURL(kid.id)
        let before = try Data(contentsOf: url)

        let second = Session(courseID: course.id, number: 2, start: t0.addingTimeInterval(86_400), durationSec: 600)
        try store.append(.sessionRecorded(session: second), child: kid.id, by: .clinician)
        try store.append(.sessionVoided(sessionID: second.id, reason: "тестовый запуск"), child: kid.id, by: .clinician)
        try store.append(.sessionTagged(sessionID: first.id, tags: ["после ТМС"], note: "устал\nк концу"),
                         child: kid.id, by: .parent)
        try store.append(.procedureMarked(courseID: course.id, procedure: Procedure(kind: .tms, date: t0, label: "BrainsWay")),
                         child: kid.id, by: .clinician)
        try store.append(.courseClosed(courseID: course.id), child: kid.id, by: .clinician, at: t0.addingTimeInterval(90_000))

        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.prefix(before.count), before, "earlier lines are never touched")
        XCTAssertEqual(after.split(separator: 0x0A).count, 8, "one line per event, even with a newline in a note")

        let reread = try XCTUnwrap(ClinicStore(root: root).record(kid.id))
        XCTAssertEqual(reread.child, store.record(kid.id)?.child)
        XCTAssertEqual(reread.child.code, "А-017")
        XCTAssertEqual(reread.sessions.map(\.id), [first.id])
        XCTAssertEqual(reread.voided.map(\.id), [second.id])
        XCTAssertEqual(reread.voidReasons[second.id], "тестовый запуск")
        XCTAssertEqual(reread.sessions[0].tags, ["после ТМС"])
        XCTAssertEqual(reread.sessions[0].note, "устал\nк концу")
        XCTAssertEqual(reread.sessions[0].probe?.metrics, ["holdShare": 0.8])
        XCTAssertTrue(reread.sessions[0].conditions.trackingFps?.isNaN ?? false, "a NaN is kept, not a lost session")
        XCTAssertEqual(reread.sessions[0].plays.first?.burned, 7)
        XCTAssertEqual(reread.courses.first?.procedures.first?.label, "BrainsWay")
        XCTAssertEqual(reread.courses.first?.closed, t0.addingTimeInterval(90_000))
        XCTAssertNil(reread.openCourse)
        XCTAssertEqual(reread.nextNumber(in: course.id), 2, "a voided session leaves its number free")
        XCTAssertEqual(reread.lastSeq, 8)
        XCTAssertEqual(reread.unreadLines, 0)
    }

    func testTornLastLineIsSkippedAndTheNextLineStartsClean() throws {
        let root = tempRoot()
        let store = ClinicStore(root: root)
        let kid = try store.createChild(code: "B-2", emblem: 0, by: .clinician)
        let handle = try FileHandle(forWritingTo: store.logURL(kid.id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\":2,\"at\":".utf8))
        try handle.close()

        let torn = ClinicStore(root: root)
        XCTAssertEqual(torn.record(kid.id)?.unreadLines, 1)
        let course = Course(title: "Курс 1", plannedSessions: 25, probeVersion: 1, started: Date())
        let after = try torn.append(.courseStarted(course: course), child: kid.id, by: .clinician)
        XCTAssertEqual(after.courses.map(\.id), [course.id])
        XCTAssertEqual(after.unreadLines, 1)
        XCTAssertEqual(after.lastSeq, 2)
    }

    func testCodesAreRequiredAndUniqueAmongActiveChildren() throws {
        let store = ClinicStore(root: tempRoot())
        let a = try store.createChild(code: " A-1 ", emblem: 13, by: .clinician)
        XCTAssertEqual(a.child.code, "A-1")
        XCTAssertEqual(a.child.emblem, 1)
        XCTAssertThrowsError(try store.createChild(code: "a-1", emblem: 0, by: .clinician)) {
            XCTAssertEqual($0 as? ClinicStore.StoreError, .duplicateCode("a-1"))
        }
        XCTAssertThrowsError(try store.createChild(code: "  ", emblem: 0, by: .clinician)) {
            XCTAssertEqual($0 as? ClinicStore.StoreError, .emptyCode)
        }
        var archived = a.child
        archived.archived = true
        try store.append(.childUpdated(child: archived), child: a.id, by: .clinician)
        XCTAssertNoThrow(try store.createChild(code: "A-1", emblem: 2, by: .clinician), "an archived code can be reused")
        XCTAssertEqual(store.records().count, 2)
    }

    func testLegacyPlaysMoveOnceIntoOneChildPerCode() throws {
        let root = tempRoot()
        let store = ClinicStore(root: root)
        let plays = [play("K-1", 300), play("", 100), play("K-1", 200), play(" K-2", 400)]
        XCTAssertEqual(try store.migrateLegacy(plays), 3)
        let records = ClinicStore(root: root).records()
        XCTAssertEqual(Set(records.map(\.child.code)), ["K-1", "K-2", ClinicMigration.noCode])
        let k1 = try XCTUnwrap(records.first { $0.child.code == "K-1" })
        XCTAssertEqual(k1.sessions.map(\.start.timeIntervalSince1970), [200, 300])
        XCTAssertNil(k1.sessions.first?.courseID)
        XCTAssertNil(k1.sessions.first?.probe, "old plays never pass for a probe")
        XCTAssertEqual(k1.sessions.first?.conditions.calibrationErrorCm, 1.2)
        XCTAssertEqual(try store.migrateLegacy(plays), 0, "runs once")
    }
}
