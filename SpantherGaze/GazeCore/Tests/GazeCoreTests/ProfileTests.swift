import XCTest
@testable import GazeCore

final class ProfileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let screen = Vec2(844, 390)

    // MARK: The book

    func testNamesAreTrimmedJoinedAndCut() {
        XCTAssertEqual(ProfileBook.clean(name: "  Азиз \n  Каратай "), "Азиз Каратай")
        XCTAssertNil(ProfileBook.clean(name: "   \n "))
        XCTAssertEqual(ProfileBook.clean(name: String(repeating: "я", count: 40))?.count, ProfileBook.maxNameLength)
    }

    func testTheFirstLaunchGetsOneActivePlayer() {
        var book = ProfileBook()
        XCTAssertTrue(book.ensureOne(defaultName: "Игрок 1", now: now))
        XCTAssertEqual(book.visible.map(\.name), ["Игрок 1"])
        XCTAssertEqual(book.active?.name, "Игрок 1")
        XCTAssertFalse(book.ensureOne(defaultName: "Игрок 1", now: now), "a second launch changes nothing")
    }

    func testANewPlayerTakesAFreeColourAndPlays() throws {
        var book = ProfileBook()
        book.ensureOne(defaultName: "Игрок 1", now: now)
        let mira = try XCTUnwrap(book.add(name: "Мира", now: now))
        XCTAssertEqual(book.active?.id, mira.id)
        XCTAssertNotEqual(mira.avatar, book.visible.first?.avatar)
        XCTAssertNil(book.add(name: "  ", now: now))
    }

    func testDeletingKeepsATombstoneAndNeverTheLastOne() throws {
        var book = ProfileBook()
        book.ensureOne(defaultName: "Игрок 1", now: now)
        let first = try XCTUnwrap(book.active)
        let mira = try XCTUnwrap(book.add(name: "Мира", now: now))
        let later = now.addingTimeInterval(60)
        XCTAssertTrue(book.remove(mira.id, now: later))
        XCTAssertEqual(book.visible.map(\.id), [first.id])
        XCTAssertEqual(book.active?.id, first.id, "the oldest left plays")
        XCTAssertEqual(book.profiles.first { $0.id == mira.id }?.deletedAt, later, "kept for the sync")
        XCTAssertNil(book.profile(mira.id))
        XCTAssertFalse(book.activate(mira.id))
        XCTAssertFalse(book.remove(first.id, now: later), "the last player stays")
    }

    func testEditsAndProgressMoveUpdatedAt() throws {
        var book = ProfileBook()
        book.ensureOne(defaultName: "Игрок 1", now: now)
        let id = try XCTUnwrap(book.activeID)
        let later = now.addingTimeInterval(30)
        XCTAssertTrue(book.edit(id, name: "Азиз", avatar: 99, birthYear: .some(2004), now: later))
        XCTAssertEqual(book.active?.name, "Азиз")
        XCTAssertEqual(book.active?.avatar, ProfileBook.avatarCount - 1)
        XCTAssertEqual(book.active?.birthYear, 2004)
        XCTAssertEqual(book.active?.updatedAt, later)
        XCTAssertFalse(book.edit(id, name: " ", now: later))
        let latest = later.addingTimeInterval(30)
        book.setProgress("winkbeat.hardOpen", "1", now: latest)
        XCTAssertEqual(book.progress("winkbeat.hardOpen"), "1")
        XCTAssertEqual(book.active?.updatedAt, latest)
        book.setProgress("winkbeat.hardOpen", "1", now: latest.addingTimeInterval(9))
        XCTAssertEqual(book.active?.updatedAt, latest, "the same value is no change")
    }

    // MARK: The store

    func testBookAndCalibrationComeBackFromTheirFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        XCTAssertEqual(store.loadBook(), ProfileBook(), "no file: an empty book")
        var book = ProfileBook()
        book.ensureOne(defaultName: "Игрок 1", now: now)
        try store.save(book)
        XCTAssertEqual(store.loadBook(), book)
        let id = try XCTUnwrap(book.activeID)
        try store.save(ProfileCalibration(profileID: id, stored: try kept()))
        let back = try XCTUnwrap(store.loadCalibration(id))
        XCTAssertEqual(back.stored.model?.name, "head")
        XCTAssertEqual(back.pipeline, GazeFeatures.pipelineVersion)
        XCTAssertNil(store.loadCalibration(UUID()))
        store.removeCalibration(id)
        XCTAssertNil(store.loadCalibration(id))
    }

    // MARK: When a kept calibration plays again

    private func kept(madeAt: Date? = nil, night: Bool = false) throws -> StoredCalibration {
        var X: [[Double]] = [], Y: [Vec2] = []
        for i in 0..<5 {
            for j in 0..<5 {
                let a = Double(i) / 4, b = Double(j) / 4
                X.append([a, b])
                Y.append(Vec2(100 + 600 * a, 50 + 300 * b))
            }
        }
        let fit = try XCTUnwrap(RidgeModel.fit(features: X, targets: Y, lambda: 0.001, featureSet: "head"))
        let head = HeadGazeModel(angles: fit, screen: ScreenGeometry(size: screen, ptPerMetre: 6000, orientation: .landscapeRight))
        let report = AccuracyReport(meanErrorPt: 31, jitterPt: 9, meanErrorCm: 0.52, jitterCm: 0.15, meanErrorDeg: 1.0,
                                    jitterDeg: 0.3, targets: 13)
        return StoredCalibration(model: .head(head), head: head, screenFit: nil, headMissPt: 31, screenMissPt: nil,
                                 report: report, reference: HeadPose(pitch: 0.1, yaw: 0), distanceM: 0.29, childID: nil,
                                 madeAt: madeAt ?? now, night: night, screenPt: screen, build: "1.0.4 (10)")
    }

    func testAKeptCalibrationGoesWithThePlayerForAWeekAndAcrossBuilds() throws {
        let c = ProfileCalibration(profileID: UUID(), stored: try kept())
        let sixDays = now.addingTimeInterval(6 * 24 * 3600)
        XCTAssertEqual(CalibrationPolicy.verdict(c, night: false, screenPt: Vec2(390, 844), now: sixDays), .use,
                       "either way round, another build")
        XCTAssertEqual(CalibrationPolicy.verdict(c, night: false, screenPt: screen, now: now.addingTimeInterval(8 * 24 * 3600)),
                       .recalibrate(.old))
        XCTAssertEqual(CalibrationPolicy.verdict(c, night: false, screenPt: screen, now: now.addingTimeInterval(-3600)),
                       .recalibrate(.old), "a clock moved back")
        XCTAssertEqual(CalibrationPolicy.verdict(c, night: true, screenPt: screen, now: now), .recalibrate(.nightVision))
        XCTAssertEqual(CalibrationPolicy.verdict(c, night: false, screenPt: Vec2(1024, 768), now: now),
                       .recalibrate(.otherScreen))
        XCTAssertEqual(CalibrationPolicy.verdict(c, night: false, screenPt: screen, pipeline: 2, now: now),
                       .recalibrate(.newTracking))
        var poor = c
        poor.poor = .poorAccuracy
        XCTAssertEqual(CalibrationPolicy.verdict(poor, night: false, screenPt: screen, now: now), .recalibrate(.poorAccuracy))
        poor.poor = .otherGrip
        XCTAssertEqual(CalibrationPolicy.verdict(poor, night: false, screenPt: screen, now: now), .recalibrate(.otherGrip))
    }

    // MARK: Health in play

    func testMissesLikeAzizsKeepTheCalibrationAndWideOnesDoNot() {
        var good = CalibrationHealth(calibrationDistanceM: 0.29)
        // His label misses, 2026-11-26 (pt at about 60 pt per cm): median 37 pt, the widest 76.
        for pt in [37.0, 56, 21, 76, 30, 44, 12, 40, 61, 25, 35, 50, 48, 19] { good.label(missCm: pt / 60) }
        XCTAssertNil(good.verdict)
        XCTAssertEqual(good.medianMissCm ?? 0, 0.7, accuracy: 0.1)

        var poor = CalibrationHealth(calibrationDistanceM: 0.29)
        for cm in [2.4, 1.2, 3.0, 2.2, 1.9, 2.6, 0.8] { poor.label(missCm: cm) }
        XCTAssertNil(poor.verdict, "not before 8 looks")
        poor.label(missCm: 2.1)
        XCTAssertEqual(poor.verdict, .poorAccuracy)
        for _ in 0..<20 { poor.label(missCm: 0.3) }
        XCTAssertEqual(poor.verdict, .poorAccuracy, "it stays until a new calibration")
    }

    func testTwentySecondsAtAnotherDistanceIsAnotherGrip() {
        var h = CalibrationHealth(calibrationDistanceM: 0.30)
        var t = 0.0
        // 15 s at 42 cm, a pause of 5 s (face lost), 4 s back at 30 cm.
        while t < 15 { h.frame(distanceM: 0.42, time: t); t += 1.0 / 60 }
        t += 5
        let back = t + 4
        while t < back { h.frame(distanceM: 0.30, time: t); t += 1.0 / 60 }
        XCTAssertNil(h.verdict)
        let far = t + 21
        while t < far { h.frame(distanceM: 0.18, time: t); t += 1.0 / 60 }
        XCTAssertEqual(h.verdict, .otherGrip)
    }
}
