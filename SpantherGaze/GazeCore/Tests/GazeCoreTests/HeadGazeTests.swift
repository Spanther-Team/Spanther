import XCTest
@testable import GazeCore

/// The head-frame gaze model on a simulated player: a head in front of an iPhone 13 held in landscape, eyes that
/// really look at a dot on the screen, and an ARKit that sees only a part of how far they turn. The model is
/// calibrated at one grip and asked at others: after a nod, a tilt of the phone, nearer, further and to the side.
final class HeadGazeTests: XCTestCase {
    private struct Noise {
        var state: UInt64
        private mutating func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }

        /// Mean 0, standard deviation 1.
        mutating func next() -> Double { (unit() + unit() + unit() - 1.5) * 2 }
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    /// The simulated phone and player.
    private struct Rig {
        /// The real phone: 60.4 pt per cm, and a camera 9 mm away from where the model takes it to be.
        let truth = ScreenGeometry(size: Vec2(844, 390), ptPerMetre: 6040, orientation: .landscapeRight)
        let cameraShift = Vec2(0.004, 0.008)
        /// What the app assumes.
        let assumed = ScreenGeometry(size: Vec2(844, 390), ptPerMetre: 6000, orientation: .landscapeRight)
        /// ARKit sees this share of the eyes' turn inside the head, about an offset (radians), as on the iPhone 13.
        let share = Vec2(0.5, 0.35)
        let offset = Vec2(0.03, -0.02)
        /// Scatter of the measured angles (radians).
        var jitter = 0.0
        let leftEye = Vec3(0.032, 0.025, 0.02), rightEye = Vec3(-0.032, 0.025, 0.02)

        /// A screen point (screen pt) in the phone's own camera space.
        func onPhone(_ t: Vec2) -> Vec3 {
            let p = truth.cameraPlane(fromScreen: t) + cameraShift
            return Vec3(p.x, p.y, 0)
        }

        /// world <- face for a head at `position` (metres, in the first grip's camera space), turned by `pitch` and
        /// `yaw` (radians).
        func head(position: Vec3, pitch: Double, yaw: Double) -> Mat4 {
            Mat4.translation(position) * Mat4.rotationY(yaw) * Mat4.rotationX(pitch)
        }

        /// world <- camera for a phone tilted by `tilt` (radians) about the screen's long axis through its centre.
        func phone(tilt: Double) -> Mat4 {
            let c = onPhone(Vec2(422, 195))
            return Mat4.translation(c) * Mat4.rotationX(tilt) * Mat4.translation(c * -1)
        }

        /// One tracked frame of the player looking at `target` (screen pt).
        func frame(target: Vec2, face: Mat4, camera: Mat4 = .identity, noise: inout Noise) -> FaceFrame {
            let world = camera.point(onPhone(target))
            let toFace = face.rigidInverse
            func eye(_ centre: Vec3) -> (Mat4, Vec3) {
                // Where the eye really points inside the head, and what ARKit makes of it.
                let real = Transforms.headAngles(toFace.direction(world - face.point(centre)).normalized) ?? .zero
                let seen = Vec2(share.x * (real.x - offset.x) + jitter * noise.next(),
                                share.y * (real.y - offset.y) + jitter * noise.next())
                let z = Transforms.headDirection(seen)
                let x = HeadGazeTests.cross(Vec3(0, 1, 0), z).normalized
                let y = HeadGazeTests.cross(z, x)
                return (Mat4(columns: [x.x, x.y, x.z, 0], [y.x, y.y, y.z, 0], [z.x, z.y, z.z, 0],
                             [centre.x, centre.y, centre.z, 1]), z)
            }
            let (l, lz) = eye(leftEye), (r, rz) = eye(rightEye)
            let lookAt = (leftEye + rightEye) * 0.5 + (lz + rz).normalized * 0.45
            return FaceFrame(timestamp: 0, faceTransform: face, leftEyeTransform: l, rightEyeTransform: r,
                             lookAtPoint: lookAt, cameraTransform: camera, orientation: .landscapeRight)
        }
    }

    private let size = Vec2(844, 390)
    /// The calibration's grip: 27 cm away, the head tipped back 22 degrees, as in the session of 2026-11-16.
    private let home = Vec3(0.03, 0.0, -0.27)
    private let homePitch = -0.38

    private func features(_ rig: Rig, _ target: Vec2, face: Mat4, camera: Mat4 = .identity, noise: inout Noise) -> GazeFeatures {
        GazeFeatures.make(rig.frame(target: target, face: face, camera: camera, noise: &noise))!
    }

    /// Both models, calibrated on the nine dots at the home grip. The head turns a little toward each dot.
    private func calibrate(_ rig: Rig, noise: inout Noise) -> (head: HeadGazeModel, screen: RidgeModel) {
        var samples: [(target: Vec2, features: GazeFeatures)] = []
        for dot in CalibrationLayout.calibration {
            let t = CalibrationLayout.point(dot, in: size)
            let face = rig.head(position: home, pitch: homePitch + 0.04 * (dot.y - 0.5), yaw: 0.06 * (dot.x - 0.5))
            for _ in 0..<30 { samples.append((t, features(rig, t, face: face, noise: &noise))) }
        }
        let head = HeadGazeModel.fit(samples: samples, screen: rig.assumed)!
        let screen = RidgeModel.fit(features: samples.map { $0.features.vector(.eyes) }, targets: samples.map { $0.target },
                                    lambda: 0.01, featureSet: GazeFeatures.FeatureSet.eyes.rawValue)!
        return (head, screen)
    }

    /// Mean miss (screen pt) of a model on the 13 check dots at a grip.
    private func miss(_ model: GazeModel, _ rig: Rig, face: Mat4, camera: Mat4 = .identity, noise: inout Noise) -> Double {
        var sum = 0.0
        for dot in CalibrationLayout.validation {
            let t = CalibrationLayout.point(dot, in: size)
            let p = model.predict(features(rig, t, face: face, camera: camera, noise: &noise))
            sum += p?.distance(to: t) ?? 10_000
        }
        return sum / Double(CalibrationLayout.validation.count)
    }

    func testAnglesAndScreenPlacesGoThereAndBack() {
        for a in [Vec2(0, 0), Vec2(0.3, -0.2), Vec2(-0.5, 0.4)] {
            let back = Transforms.headAngles(Transforms.headDirection(a))!
            XCTAssertEqual(back.x, a.x, accuracy: 1e-12)
            XCTAssertEqual(back.y, a.y, accuracy: 1e-12)
        }
        XCTAssertNil(Transforms.headAngles(Vec3(0.1, 0.2, -1)))
        for o in ScreenOrientation.allCases {
            let p = Vec2(0.031, -0.012)
            let back = Transforms.cameraPlaneToScreen(Transforms.screenToCameraPlane(p, o), o)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-15)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-15)
            let g = ScreenGeometry(size: Vec2(844, 390), ptPerMetre: 6000, orientation: o)
            let q = g.screen(fromCameraPlane: g.cameraPlane(fromScreen: Vec2(100, 300)))
            XCTAssertEqual(q.x, 100, accuracy: 1e-9)
            XCTAssertEqual(q.y, 300, accuracy: 1e-9)
            // The camera is the origin of its own plane.
            let c = g.cameraPlane(fromScreen: g.cameraPt)
            XCTAssertEqual(c.length, 0, accuracy: 1e-15)
        }
        // Landscape with the camera on the left: a point to the right of it on the screen is along the sensor's
        // long side (camera +x), and a point lower on the screen is camera -y.
        let g = ScreenGeometry(size: Vec2(844, 390), ptPerMetre: 6000, orientation: .landscapeRight)
        let right = g.cameraPlane(fromScreen: Vec2(600, 195)), low = g.cameraPlane(fromScreen: Vec2(0, 315))
        XCTAssertEqual(right.x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(right.y, 0, accuracy: 1e-12)
        XCTAssertEqual(low.y, -0.02, accuracy: 1e-12)
    }

    func testTheRequiredAnglesPointAtTheDot() {
        var noise = Noise(state: 1)
        var rig = Rig()
        rig.jitter = 0
        let exact = ScreenGeometry(size: size, ptPerMetre: 6040, orientation: .landscapeRight)
        let face = rig.head(position: Vec3(0.02, 0.03, -0.3), pitch: -0.3, yaw: 0.1)
        for t in [Vec2(100, 60), Vec2(422, 195), Vec2(800, 350)] {
            let h = features(rig, t, face: face, noise: &noise).head!
            let a = HeadGazeModel.requiredAngles(target: t, head: h, screen: exact)!
            let hit = Transforms.intersectScreenPlane(origin: h.origin, direction: h.toCamera(Transforms.headDirection(a)))!
            let back = exact.screen(fromCameraPlane: hit)
            XCTAssertEqual(back.x, t.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, t.y, accuracy: 1e-6)
        }
    }

    func testTheHeadModelKeepsItsAimAtANewGripAndTheFirstModelDoesNot() {
        var noise = Noise(state: 3)
        let rig = Rig()
        let (h, s) = calibrate(rig, noise: &noise)
        let head = GazeModel.head(h), screen = GazeModel.screen(s)
        // ARKit's share of the eyes' turn comes back out of the fit.
        XCTAssertEqual(h.measuredShare.x, 0.5, accuracy: 0.03)
        XCTAssertEqual(h.measuredShare.y, 0.35, accuracy: 0.03)

        let atHome = rig.head(position: home, pitch: homePitch, yaw: 0)
        XCTAssertLessThan(miss(head, rig, face: atHome, noise: &noise), 6)
        // The first model also learned that the head turns toward each dot, so even a still head costs it a little.
        XCTAssertLessThan(miss(screen, rig, face: atHome, noise: &noise), 40)

        // A nod of 7 and of 14 degrees, the eyes staying on the dots: what the phone did in a minute of warm-up.
        for nod in [0.12, 0.24, -0.12] {
            let face = rig.head(position: home, pitch: homePitch + nod, yaw: 0)
            XCTAssertLessThan(miss(head, rig, face: face, noise: &noise), 8, "nod \(nod)")
        }
        let nodded = rig.head(position: home, pitch: homePitch + 0.24, yaw: 0)
        XCTAssertGreaterThan(miss(screen, rig, face: nodded, noise: &noise), 250)
        // A turn of the head, nearer and further, to the side, and all of it at once.
        let grips: [(String, Mat4)] = [
            ("turn", rig.head(position: home, pitch: homePitch, yaw: 0.2)),
            ("near", rig.head(position: Vec3(0.03, 0, -0.22), pitch: homePitch, yaw: 0)),
            ("far", rig.head(position: Vec3(0.03, 0, -0.36), pitch: homePitch, yaw: 0)),
            ("aside", rig.head(position: Vec3(0.07, -0.03, -0.27), pitch: homePitch, yaw: 0)),
            ("all", rig.head(position: Vec3(0.06, 0.02, -0.33), pitch: homePitch + 0.2, yaw: -0.15)),
        ]
        for (name, face) in grips {
            // What is left is the camera's real place and scale against the assumed ones, times the change.
            XCTAssertLessThan(miss(head, rig, face: face, noise: &noise), 20, name)
        }
        // The phone tilted in the hands by 10 degrees either way, the head where it was.
        for tilt in [0.17, -0.17] {
            XCTAssertLessThan(miss(head, rig, face: atHome, camera: rig.phone(tilt: tilt), noise: &noise), 8, "tilt \(tilt)")
        }
    }

    func testTheHeadModelUnderMeasurementNoise() {
        var noise = Noise(state: 5)
        var rig = Rig()
        // Half a degree of scatter on ARKit's angles.
        rig.jitter = 0.009
        let (h, _) = calibrate(rig, noise: &noise)
        let head = GazeModel.head(h)
        let nodded = rig.head(position: home, pitch: homePitch + 0.2, yaw: 0.1)
        // One frame's miss is the scatter blown up by the gain (about 1.5 degrees up and down at 27 cm), not more.
        var sum = 0.0
        for _ in 0..<20 { sum += miss(head, rig, face: nodded, noise: &noise) }
        XCTAssertLessThan(sum / 20, 60)
    }

    func testAGlanceFarOffTheScreenCountsAsAway() {
        var noise = Noise(state: 7)
        let rig = Rig()
        let (h, _) = calibrate(rig, noise: &noise)
        let model = GazeModel.head(h)
        let face = rig.head(position: home, pitch: homePitch + 0.15, yaw: 0)
        for dot in CalibrationLayout.validation {
            let t = CalibrationLayout.point(dot, in: size)
            XCTAssertFalse(model.looksOut(features(rig, t, face: face, noise: &noise)))
        }
        // The screen's own corners are not away; a place two screens to the side or a screen above is.
        XCTAssertFalse(model.looksOut(features(rig, Vec2(0, 0), face: face, noise: &noise)))
        XCTAssertFalse(model.looksOut(features(rig, Vec2(844, 390), face: face, noise: &noise)))
        XCTAssertTrue(model.looksOut(features(rig, Vec2(844 * 3, 195), face: face, noise: &noise)))
        XCTAssertTrue(model.looksOut(features(rig, Vec2(422, -390), face: face, noise: &noise)))
        // Features rebuilt from an old CSV carry no head-frame gaze: nothing to answer with.
        let old = GazeFeatures(lookAtHit: Vec2(0.05, -0.06), eyeAxisHit: Vec2(0.05, -0.06), yaw: 0, pitch: -0.4, roll: 0,
                               distance: 0.26, pupils: nil)
        XCTAssertNil(model.predict(old))
        XCTAssertTrue(model.looksOut(old))
    }

    func testTheHeadModelPlaysUnlessItChecksClearlyWorse() {
        var noise = Noise(state: 9)
        let rig = Rig()
        let (h, s) = calibrate(rig, noise: &noise)
        let atHome = rig.head(position: home, pitch: homePitch, yaw: 0)
        var check: [(target: Vec2, features: [GazeFeatures])] = []
        for dot in CalibrationLayout.validation {
            let t = CalibrationLayout.point(dot, in: size)
            check.append((t, (0..<10).map { _ in features(rig, t, face: atHome, noise: &noise) }))
        }
        let good = GazeModel.choose(head: h, screen: s, check: check)
        XCTAssertEqual(good.model?.name, "head")
        XCTAssertLessThan(good.headMiss ?? .infinity, 6)
        XCTAssertLessThan(good.screenMiss ?? .infinity, 40)
        // A head-frame fit that went wrong (here: its gains thrown away) loses to the first model.
        var broken = h
        broken.angles.wx = broken.angles.wx.map { _ in 0 }
        XCTAssertEqual(GazeModel.choose(head: broken, screen: s, check: check).model?.name, "screen")
        XCTAssertEqual(GazeModel.choose(head: nil, screen: s, check: check).model?.name, "screen")
        XCTAssertEqual(GazeModel.choose(head: h, screen: nil, check: check).model?.name, "head")
        XCTAssertEqual(GazeModel.choose(head: h, screen: s, check: []).model?.name, "head")
        XCTAssertNil(GazeModel.choose(head: nil, screen: nil, check: check).model)
    }

    // MARK: following a moving target

    /// The warm-up's dot on its horizontal sweep (screen pt).
    private func sweep(_ t: Double) -> Vec2 { Vec2(422 + 320 * sin(2 * Double.pi * t / 10), 195) }

    func testTheFollowGatePassesEyesThatFollowWhereverTheAimSits() {
        var gate = FollowGate()
        var noise = Noise(state: 11)
        var passed = 0, asked = 0
        for i in 0..<300 {
            let t = Double(i) / 30
            // The aim is 120 pt off and jitters by 12 pt, but it moves with the dot.
            let aim = sweep(t) + Vec2(90 + 12 * noise.next(), -80 + 12 * noise.next())
            let ok = gate.add(t: t, aim: aim, target: sweep(t))
            // Away from the sweep's turning points, where the dot hardly moves.
            if t > 1.5, abs(cos(2 * Double.pi * t / 10)) > 0.5 {
                asked += 1
                if ok { passed += 1 }
            }
        }
        XCTAssertGreaterThan(Double(passed) / Double(asked), 0.9)
    }

    func testTheFollowGateStopsAnAimThatDoesNotFollow() {
        var noise = Noise(state: 13)
        // Resting on one place while the dot moves, with the same jitter.
        var gate = FollowGate()
        var passed = 0
        for i in 0..<300 {
            let t = Double(i) / 30
            if gate.add(t: t, aim: Vec2(500 + 25 * noise.next(), 200 + 25 * noise.next()), target: sweep(t)) { passed += 1 }
        }
        XCTAssertLessThan(passed, 15)
        // Moving the other way.
        gate.reset()
        passed = 0
        for i in 0..<300 {
            let t = Double(i) / 30
            let dot = sweep(t)
            if gate.add(t: t, aim: Vec2(844 - dot.x, dot.y), target: dot) { passed += 1 }
        }
        XCTAssertEqual(passed, 0)
        // A dot that stands still tells nothing.
        gate.reset()
        for i in 0..<60 {
            XCTAssertFalse(gate.add(t: Double(i) / 30, aim: Vec2(422, 195), target: Vec2(422, 195)))
        }
    }

    func testTheFollowGateStartsAgainAfterAGap() {
        var gate = FollowGate()
        for i in 0..<60 { _ = gate.add(t: Double(i) / 30, aim: sweep(Double(i) / 30), target: sweep(Double(i) / 30)) }
        XCTAssertTrue(gate.add(t: 2.0, aim: sweep(2.0), target: sweep(2.0)))
        // Half a second without frames: the window is empty again and needs time to fill.
        XCTAssertFalse(gate.add(t: 2.6, aim: sweep(2.6), target: sweep(2.6)))
        XCTAssertFalse(gate.add(t: 2.7, aim: sweep(2.7), target: sweep(2.7)))
        for i in 0..<30 { _ = gate.add(t: 2.7 + Double(i + 1) / 30, aim: sweep(2.7 + Double(i + 1) / 30), target: sweep(2.7 + Double(i + 1) / 30)) }
        XCTAssertTrue(gate.add(t: 3.75, aim: sweep(3.75), target: sweep(3.75)))
    }

    // MARK: the warm-up's clock

    func testTheWarmUpClockStandsStillWhileHeld() {
        var clock = PursuitClock(startHost: 100)
        XCTAssertEqual(clock.time(host: 99), -1)
        XCTAssertEqual(clock.time(host: 110), 10)
        clock.hold(host: 110)
        XCTAssertTrue(clock.isHeld)
        XCTAssertEqual(clock.time(host: 117), 10)
        // A second hold while held changes nothing.
        clock.hold(host: 115)
        clock.resume(host: 121)
        XCTAssertFalse(clock.isHeld)
        XCTAssertEqual(clock.startHost, 111)
        XCTAssertEqual(clock.time(host: 121), 10)
        XCTAssertEqual(clock.time(host: 125), 14)
        // Resuming a clock that is not held changes nothing.
        clock.resume(host: 130)
        XCTAssertEqual(clock.time(host: 130), 19)
    }
}
