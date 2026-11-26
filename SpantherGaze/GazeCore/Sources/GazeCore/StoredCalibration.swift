import Foundation

/// The session's calibration, kept on the phone between launches (the app puts it in UserDefaults). iOS ends an app
/// it has sent to the background whenever it wants the memory, so coming back to the game is often a new launch;
/// the same child, the same day, plays on the calibration they already made instead of calibrating again.
/// Only fitted numbers are kept: the two models' weights, their misses on the check dots, the accuracy report and
/// the grip it was made at. No camera frame and nothing of the face itself.
public struct StoredCalibration: Codable, Sendable {
    /// A kept calibration plays for 12 hours: the day's sessions, not the next morning's.
    public static let maxAgeSec: Double = 12 * 3600

    /// The model that plays: "head" or "screen" (`GazeModel.name`).
    public var plays: String
    /// The head-frame model: its fit of the eye angles, and the screen it maps them onto
    /// (width and height in pt, pt per metre, the screen's orientation).
    public var headAngles: RidgeModel?
    public var headScreen: [Double]?
    public var headOrientation: String?
    /// The first model, fitted on the rays' hits on the screen.
    public var screenFit: RidgeModel?
    /// Both models' mean miss on the check dots (screen pt), and the check's report for the one that plays.
    public var headMissPt: Double?
    public var screenMissPt: Double?
    public var report: AccuracyReport
    /// The grip: the calibration frames' mean head pose (radians) and distance (m).
    public var referencePitch: Double?
    public var referenceYaw: Double?
    public var distanceM: Double
    /// Whose it is (nil: no child was picked) and when it was made; with night vision or not, on which screen
    /// (width and height in pt) and on which build of the app. Any of these different, and it does not play.
    public var childID: UUID?
    public var madeAt: Date
    public var night: Bool
    public var screenPt: [Double]
    public var build: String

    public init(model: GazeModel, head: HeadGazeModel?, screenFit: RidgeModel?, headMissPt: Double?,
                screenMissPt: Double?, report: AccuracyReport, reference: HeadPose?, distanceM: Double,
                childID: UUID?, madeAt: Date, night: Bool, screenPt: Vec2, build: String) {
        plays = model.name
        headAngles = head?.angles
        headScreen = head.map { [$0.screen.size.x, $0.screen.size.y, $0.screen.ptPerMetre] }
        headOrientation = head?.screen.orientation.rawValue
        self.screenFit = screenFit
        self.headMissPt = headMissPt
        self.screenMissPt = screenMissPt
        self.report = report
        referencePitch = reference?.pitch
        referenceYaw = reference?.yaw
        self.distanceM = distanceM
        self.childID = childID
        self.madeAt = madeAt
        self.night = night
        self.screenPt = [screenPt.x, screenPt.y]
        self.build = build
    }

    /// The head-frame model as it was fitted.
    public var head: HeadGazeModel? {
        guard let a = headAngles, let s = headScreen, s.count == 3,
              let o = headOrientation.flatMap(ScreenOrientation.init(rawValue:)) else { return nil }
        return HeadGazeModel(angles: a, screen: ScreenGeometry(size: Vec2(s[0], s[1]), ptPerMetre: s[2], orientation: o))
    }

    /// The model that plays, and the other one, whose aim goes into the session CSV next to it.
    public var model: GazeModel? {
        plays == "head" ? head.map { GazeModel.head($0) } : screenFit.map { GazeModel.screen($0) }
    }
    public var shadow: GazeModel? {
        plays == "head" ? screenFit.map { GazeModel.screen($0) } : head.map { GazeModel.head($0) }
    }

    public var reference: HeadPose? {
        guard let p = referencePitch, let y = referenceYaw else { return nil }
        return HeadPose(pitch: p, yaw: y)
    }

    /// True when this calibration may play now: the same child, night vision setting and build, the same screen
    /// (within a point, either way round), made less than `maxAgeSec` ago and not in the future (a clock moved back).
    public func fits(child: UUID?, night: Bool, screenPt: Vec2, build: String, now: Date) -> Bool {
        let age = now.timeIntervalSince(madeAt)
        guard childID == child, self.night == night, self.build == build, age > -60, age < Self.maxAgeSec,
              model != nil else { return false }
        return sameScreen(screenPt)
    }

    /// Made on a screen of this size (pt), within a point, either way round.
    public func sameScreen(_ screenPt: Vec2) -> Bool {
        guard self.screenPt.count == 2 else { return false }
        let kept = self.screenPt.sorted(), here = [screenPt.x, screenPt.y].sorted()
        return abs(kept[0] - here[0]) <= 1 && abs(kept[1] - here[1]) <= 1
    }
}
