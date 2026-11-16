import Foundation

/// A gaze model that keeps its aim when the phone is tilted or the head nods.
///
/// The first model (`RidgeModel` on the rays' hits on the screen) is fitted at one grip. ARKit sees only a part of
/// how far the eyes turn inside the head (about a half across and a third up and down on the iPhone 13), and the
/// calibration makes up for it by scaling the hits. But a hit is the head's own direction plus the eyes' turn, so
/// the scaling blows the head's part up as well: in the session of 2026-11-16 one degree of nod moved the aim
/// 85 pt down the screen, and the phone drifted 14 degrees in a minute.
///
/// Here the calibration is fitted inside the head instead: from the eyes' measured direction in face space to the
/// direction they must really have, to see each dot from where the eyes were. A frame is then answered by
/// geometry: the corrected direction, turned by the head's rotation, cast from between the eyes onto the screen's
/// plane. The head's place and turn come from ARKit's face anchor, which the depth camera measures well, so a new
/// grip, a nod or another distance needs no new calibration.
///
/// The map is linear in the two angles and reads ARKit's ray only. Squares bend it wrongly once a new grip takes
/// the eyes outside the calibrated angles, and Vision's pupil offsets are measured against the eye's corners in
/// the image, which follow the camera's view of the head and not the head itself.
public struct HeadGazeModel: Sendable {
    /// The eyes' measured angles inside the head -> their real ones (`Transforms.headAngles`, radians).
    public var angles: RidgeModel
    public var screen: ScreenGeometry

    /// The corrected angles follow the measured ones this far past the calibrated range (as a share of it): a new
    /// grip moves the eyes well outside it, and the linear map still holds there.
    public static let clampMargin = 20.0
    /// The calibration dots span this share of the screen, from `dotsFrom` of its width and height.
    static let dotsFrom = 0.1
    static let dotsSpan = 0.8

    public init(angles: RidgeModel, screen: ScreenGeometry) {
        self.angles = angles
        self.screen = screen
    }

    /// The direction inside the head (angles, radians) in which eyes at `head` see the screen point `target`.
    public static func requiredAngles(target: Vec2, head: HeadFrameGaze, screen: ScreenGeometry) -> Vec2? {
        let p = screen.cameraPlane(fromScreen: target)
        return Transforms.headAngles(head.toFace(Vec3(p.x, p.y, 0) - head.origin))
    }

    static func vector(_ h: HeadFrameGaze) -> [Double] { [h.lookAngles.x, h.lookAngles.y] }

    /// Fits the model on calibration frames: each with the dot looked at (screen pt). Nil when most frames have no
    /// head-frame gaze (features rebuilt from an old CSV) or the fit fails.
    public static func fit(samples: [(target: Vec2, features: GazeFeatures)], screen: ScreenGeometry,
                           lambda: Double = 0.01) -> HeadGazeModel? {
        var X: [[Double]] = [], Y: [Vec2] = []
        for s in samples {
            guard let h = s.features.head, let a = requiredAngles(target: s.target, head: h, screen: screen) else { continue }
            X.append(vector(h))
            Y.append(a)
        }
        guard X.count >= 9, 2 * X.count >= samples.count,
              let m = RidgeModel.fit(features: X, targets: Y, lambda: lambda, featureSet: "head") else { return nil }
        return HeadGazeModel(angles: m, screen: screen)
    }

    /// Where the player looks (screen pt). Nil when the frame has no head-frame gaze or the corrected ray does
    /// not meet the screen's plane.
    public func predict(_ f: GazeFeatures) -> Vec2? {
        guard let h = f.head else { return nil }
        let a = angles.predict(Self.vector(h), clampMargin: Self.clampMargin)
        guard a.x.isFinite, a.y.isFinite, abs(a.x) < 1.4, abs(a.y) < 1.4,
              let hit = Transforms.intersectScreenPlane(origin: h.origin, direction: h.toCamera(Transforms.headDirection(a)))
        else { return nil }
        return screen.screen(fromCameraPlane: hit)
    }

    /// True when the gaze lands further outside the calibration dots' rectangle than `margin` times its size (or
    /// nowhere on the screen's plane): a glance away. The same rule as `RidgeModel.outOfRange`, asked of the place
    /// on the screen instead of the features, since the eyes' angles for the screen's edge change with the grip.
    public func outOfRange(_ f: GazeFeatures, margin: Double) -> Bool {
        guard let p = predict(f) else { return true }
        let lo = Self.dotsFrom - margin * Self.dotsSpan, hi = Self.dotsFrom + Self.dotsSpan + margin * Self.dotsSpan
        return p.x < lo * screen.size.x || p.x > hi * screen.size.x || p.y < lo * screen.size.y || p.y > hi * screen.size.y
    }

    /// How much of the eyes' real turn ARKit measured, across and up-down: 1 over the fitted gains. For the
    /// session CSV; a value near zero or below it means the calibration found no signal on that axis.
    public var measuredShare: Vec2 {
        func share(_ w: [Double], _ j: Int) -> Double {
            let gain = w[j + 1] / angles.scale[j]
            return abs(gain) > 1e-9 ? 1 / gain : 0
        }
        return Vec2(share(angles.wx, 0), share(angles.wy, 1))
    }
}

/// The calibrated model the app plays with: the first one, on the rays' hits on the screen, or the head-frame one.
public enum GazeModel: Sendable {
    case screen(RidgeModel)
    case head(HeadGazeModel)

    /// "screen" or "head", for the session CSV and the debug overlay.
    public var name: String {
        switch self {
        case .screen: return "screen"
        case .head: return "head"
        }
    }

    private static func vector(_ m: RidgeModel, _ f: GazeFeatures) -> [Double] {
        f.vector(GazeFeatures.FeatureSet(rawValue: m.featureSet) ?? .eyes)
    }

    /// Where the player looks (screen pt), before any correction or smoothing. Nil when the frame cannot be answered.
    public func predict(_ f: GazeFeatures) -> Vec2? {
        switch self {
        case .screen(let m): return m.predict(Self.vector(m, f))
        case .head(let m): return m.predict(f)
        }
    }

    /// This frame's answer to "do the eyes point well off the screen?", for `RidgeModel.AwayGate`.
    public func looksOut(_ f: GazeFeatures, margin: Double = RidgeModel.lookingAwayMargin) -> Bool {
        switch self {
        case .screen(let m): return m.outOfRange(Self.vector(m, f), features: 0..<2, margin: margin)
        case .head(let m): return m.outOfRange(f, margin: margin)
        }
    }

    /// The model's mean miss on the check dots (screen pt): per dot the mean distance of its frames' predictions,
    /// then the mean over the dots. Frames it cannot answer are left out; nil when it answers none.
    public func checkError(_ dots: [(target: Vec2, features: [GazeFeatures])]) -> Double? {
        var sum = 0.0, n = 0
        for d in dots {
            let misses = d.features.compactMap { predict($0)?.distance(to: d.target) }.filter { $0.isFinite }
            guard !misses.isEmpty else { continue }
            sum += misses.reduce(0, +) / Double(misses.count)
            n += 1
        }
        return n > 0 ? sum / Double(n) : nil
    }

    /// Which model plays after the check dots. The head-frame model is the one that survives a new grip, so it
    /// plays unless it misses the check dots clearly more than the first model does at the calibration's own grip
    /// (`tolerance` times its miss), which would mean its fit went wrong. Returns both misses for the session CSV.
    public static func choose(head: HeadGazeModel?, screen: RidgeModel?,
                              check: [(target: Vec2, features: [GazeFeatures])],
                              tolerance: Double = 1.25) -> (model: GazeModel?, headMiss: Double?, screenMiss: Double?) {
        let h = head.map { GazeModel.head($0) }, s = screen.map { GazeModel.screen($0) }
        let hm = h?.checkError(check), sm = s?.checkError(check)
        guard let h else { return (s, hm, sm) }
        guard let s else { return (h, hm, sm) }
        // No check dots: nothing speaks against the head-frame model.
        guard let hm else { return (sm == nil ? h : s, hm, sm) }
        guard let sm else { return (h, hm, sm) }
        return (hm <= tolerance * sm ? h : s, hm, sm)
    }
}

/// Tells whether the eyes are following a moving target, from the aim alone: over the last `windowSec` the model's
/// own aim must have travelled the way the target did, and about as far, along the axis the target moved most.
/// Where the aim sits does not matter, so a calibration that is off by a steady amount still passes; an aim that
/// rests while the target moves, or wanders on its own, does not. This is the test of the "Pursuits" technique
/// (Vidal, Bulling, Gellersen 2013), used here to decide when the target may teach the aim.
///
/// The numbers come from the warm-up of 2026-11-16 (iPhone 13, 30 frames a second): with them 76% of the
/// horizontal sweep's frames and 54% of the vertical one's pass, the rest being the turning points and the moments
/// the eyes left the dot.
public struct FollowGate: Sendable {
    public var windowSec: Double
    /// The target must have travelled at least this far in the window (screen pt), or nothing can be told.
    public var minTravelPt: Double
    public var minCorrelation: Double
    /// The aim's travel per unit of the target's (the slope of one against the other) must lie in this range: a
    /// resting aim's wander can line up with the target by chance, but it does not go as far.
    public var gain: ClosedRange<Double>
    /// The window needs this many frames, spread over at least half of it.
    public var minFrames: Int
    private var frames: [(t: Double, aim: Vec2, target: Vec2)] = []

    public init(windowSec: Double = 1.2, minTravelPt: Double = 60, minCorrelation: Double = 0.6,
                gain: ClosedRange<Double> = 0.4...2.5, minFrames: Int = 8) {
        self.windowSec = windowSec
        self.minTravelPt = minTravelPt
        self.minCorrelation = minCorrelation
        self.gain = gain
        self.minFrames = minFrames
    }

    /// One frame: the model's uncorrected aim and the target (screen pt). Returns whether the eyes follow now.
    public mutating func add(t: Double, aim: Vec2, target: Vec2) -> Bool {
        // A gap in the frames (a blink, the face lost) starts the window again.
        if let last = frames.last, t - last.t > 0.25 || t < last.t { frames.removeAll() }
        frames.append((t, aim, target))
        if let i = frames.firstIndex(where: { t - $0.t <= windowSec }), i > 0 { frames.removeFirst(i) }
        guard frames.count >= minFrames, let first = frames.first, t - first.t >= windowSec / 2 else { return false }
        let xs = frames.map { $0.target.x }, ys = frames.map { $0.target.y }
        let travelX = (xs.max() ?? 0) - (xs.min() ?? 0), travelY = (ys.max() ?? 0) - (ys.min() ?? 0)
        let alongX = travelX >= travelY
        guard max(travelX, travelY) >= minTravelPt else { return false }
        let a = frames.map { alongX ? $0.target.x : $0.target.y }, b = frames.map { alongX ? $0.aim.x : $0.aim.y }
        let fit = Self.line(a, b)
        return fit.correlation >= minCorrelation && gain.contains(fit.slope)
    }

    public mutating func reset() { frames.removeAll() }

    /// How `b` goes with `a`: Pearson's correlation and the least-squares slope of b against a. Zeros when either
    /// does not vary.
    static func line(_ a: [Double], _ b: [Double]) -> (correlation: Double, slope: Double) {
        let n = Double(a.count)
        guard a.count == b.count, n > 1 else { return (0, 0) }
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<a.count {
            sab += (a[i] - ma) * (b[i] - mb)
            saa += (a[i] - ma) * (a[i] - ma)
            sbb += (b[i] - mb) * (b[i] - mb)
        }
        guard saa > 1e-9, sbb > 1e-9 else { return (0, 0) }
        return (sab / (saa * sbb).squareRoot(), sab / saa)
    }
}
