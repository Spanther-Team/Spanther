import XCTest
@testable import GazeCore

final class StoredCalibrationTests: XCTestCase {
    private let screen = Vec2(852, 393)
    private let child = UUID()
    private let made = Date(timeIntervalSince1970: 1_800_000_000)

    /// A ridge fit on a plain linear map, so a prediction says whether the weights came back.
    private func ridge(_ set: String) throws -> RidgeModel {
        var X: [[Double]] = [], Y: [Vec2] = []
        for i in 0..<5 {
            for j in 0..<5 {
                let a = Double(i) / 4, b = Double(j) / 4
                X.append([a, b])
                Y.append(Vec2(100 + 600 * a, 50 + 300 * b))
            }
        }
        return try XCTUnwrap(RidgeModel.fit(features: X, targets: Y, lambda: 0.001, featureSet: set))
    }

    private func kept(plays head: Bool = true) throws -> StoredCalibration {
        let geometry = ScreenGeometry(size: screen, ptPerMetre: 6000, orientation: .landscapeRight)
        let headModel = HeadGazeModel(angles: try ridge("head"), screen: geometry)
        let first = try ridge("eyes")
        let report = AccuracyReport(meanErrorPt: 31, jitterPt: 9, meanErrorCm: 0.52, jitterCm: 0.15, meanErrorDeg: 1.0,
                                    jitterDeg: 0.3, targets: 13)
        return StoredCalibration(model: head ? .head(headModel) : .screen(first), head: headModel, screenFit: first,
                                 headMissPt: 31, screenMissPt: 44, report: report,
                                 reference: HeadPose(pitch: 0.1, yaw: -0.05), distanceM: 0.29, childID: child,
                                 madeAt: made, night: false, screenPt: screen, build: "1.0.3 (7)")
    }

    func testComesBackWholeThroughJSON() throws {
        let k = try kept()
        let back = try JSONDecoder().decode(StoredCalibration.self, from: JSONEncoder().encode(k))
        XCTAssertEqual(back.model?.name, "head")
        XCTAssertEqual(back.shadow?.name, "screen")
        XCTAssertEqual(back.head?.screen, k.head?.screen)
        XCTAssertEqual(back.report, k.report)
        XCTAssertEqual(back.reference, HeadPose(pitch: 0.1, yaw: -0.05))
        XCTAssertEqual(back.distanceM, 0.29)
        XCTAssertEqual(back.childID, child)
        XCTAssertEqual(back.madeAt, made)
        // The weights came back: the first model aims where it aimed before.
        let p = try XCTUnwrap(back.screenFit).predict([0.5, 0.5])
        XCTAssertEqual(p.x, 400, accuracy: 1)
        XCTAssertEqual(p.y, 200, accuracy: 1)
        XCTAssertEqual(back.head?.angles.wx ?? [], k.headAngles?.wx ?? [])
    }

    func testTheScreenModelCanBeTheOneThatPlays() throws {
        let k = try kept(plays: false)
        XCTAssertEqual(k.model?.name, "screen")
        XCTAssertEqual(k.shadow?.name, "head")
    }

    func testPlaysOnlyForTheSameChildDayNightBuildAndScreen() throws {
        let k = try kept()
        let soon = made.addingTimeInterval(3600)
        XCTAssertTrue(k.fits(child: child, night: false, screenPt: screen, build: "1.0.3 (7)", now: soon))
        // The same screen given the other way round, and a fraction of a point off.
        XCTAssertTrue(k.fits(child: child, night: false, screenPt: Vec2(393.4, 852), build: "1.0.3 (7)", now: soon))
        XCTAssertFalse(k.fits(child: UUID(), night: false, screenPt: screen, build: "1.0.3 (7)", now: soon))
        XCTAssertFalse(k.fits(child: nil, night: false, screenPt: screen, build: "1.0.3 (7)", now: soon))
        XCTAssertFalse(k.fits(child: child, night: true, screenPt: screen, build: "1.0.3 (7)", now: soon))
        XCTAssertFalse(k.fits(child: child, night: false, screenPt: screen, build: "1.0.4 (8)", now: soon))
        XCTAssertFalse(k.fits(child: child, night: false, screenPt: Vec2(844, 390), build: "1.0.3 (7)", now: soon))
        // Twelve hours, and a clock that went back.
        let late = made.addingTimeInterval(StoredCalibration.maxAgeSec + 1)
        XCTAssertFalse(k.fits(child: child, night: false, screenPt: screen, build: "1.0.3 (7)", now: late))
        XCTAssertFalse(k.fits(child: child, night: false, screenPt: screen, build: "1.0.3 (7)",
                              now: made.addingTimeInterval(-3600)))
    }

    func testNoChildPickedFitsNoChildPicked() throws {
        var k = try kept()
        k.childID = nil
        XCTAssertTrue(k.fits(child: nil, night: false, screenPt: screen, build: "1.0.3 (7)", now: made))
    }

    func testAPlayingModelThatDidNotComeBackDoesNotPlay() throws {
        var k = try kept()
        k.headOrientation = "sideways"
        XCTAssertNil(k.head)
        XCTAssertNil(k.model)
        XCTAssertFalse(k.fits(child: child, night: false, screenPt: screen, build: "1.0.3 (7)", now: made))
    }
}
