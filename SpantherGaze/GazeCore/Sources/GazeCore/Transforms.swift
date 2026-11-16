import Foundation

// All coordinate conversions live here (CLAUDE.md rule 2). Spaces used:
//  face   – ARFaceAnchor local space, metres. +z points out of the face towards the camera.
//  world  – ARKit world space, metres.
//  camera – ARCamera local space, metres, in SENSOR orientation (landscape): +x along the sensor's long side,
//           +y up in landscape, -z looking out of the camera. The screen is (approximately) the camera's z = 0 plane.
//  screen – SwiftUI/UIKit points, origin top-left, y down, in the orientation the app runs (`ScreenOrientation`).
//           Since 2026-11-05 that is landscape with the front camera on the left.

/// How the phone is held while the app runs. GazeCore does not import UIKit, so the app maps
/// UIInterfaceOrientation onto this.
public enum ScreenOrientation: String, Sendable, CaseIterable {
    /// Front camera at the top.
    case portrait
    /// Front camera on the left (UIInterfaceOrientation.landscapeRight). The app's only orientation.
    case landscapeRight
    /// Front camera on the right (UIInterfaceOrientation.landscapeLeft).
    case landscapeLeft
}

/// One tracked frame, already converted from ARKit/simd types by the Tracking adapter.
public struct FaceFrame: Sendable {
    public var timestamp: Double
    /// world <- face
    public var faceTransform: Mat4
    /// face <- left eye / face <- right eye. Each eye's +z axis is its gaze direction.
    public var leftEyeTransform: Mat4
    public var rightEyeTransform: Mat4
    /// face space
    public var lookAtPoint: Vec3
    /// world <- camera
    public var cameraTransform: Mat4
    /// How the phone was held, for the camera-plane -> screen axes step.
    public var orientation: ScreenOrientation
    /// Pupil centres from an image detector (Vision or MediaPipe), already expressed as offsets
    /// inside each eye opening. nil when the detector had no fresh result.
    public var pupils: PupilOffsets?

    public init(timestamp: Double, faceTransform: Mat4, leftEyeTransform: Mat4, rightEyeTransform: Mat4,
                lookAtPoint: Vec3, cameraTransform: Mat4, orientation: ScreenOrientation, pupils: PupilOffsets? = nil) {
        self.timestamp = timestamp; self.faceTransform = faceTransform
        self.leftEyeTransform = leftEyeTransform; self.rightEyeTransform = rightEyeTransform
        self.lookAtPoint = lookAtPoint; self.cameraTransform = cameraTransform; self.orientation = orientation
        self.pupils = pupils
    }
}

/// Pupil position inside the eye opening: u along the eye (corner to corner), v across it,
/// both divided by eye width. Image space, so the detector's orientation must be right. With the image stood
/// upright for the player (`Transforms.frontCameraImageOrientation`), u runs along the screen's x and v along its y
/// in every orientation, because the face is upright to the screen.
public struct PupilOffsets: Sendable, Equatable {
    public var leftU: Double, leftV: Double, rightU: Double, rightV: Double
    public init(leftU: Double, leftV: Double, rightU: Double, rightV: Double) {
        self.leftU = leftU; self.leftV = leftV; self.rightU = rightU; self.rightV = rightV
    }
}

public enum Transforms {
    /// face -> camera
    public static func faceToCamera(_ f: FaceFrame) -> Mat4 { f.cameraTransform.rigidInverse * f.faceTransform }

    /// Eye centre in camera space, from face <- eye.
    public static func eyeOrigin(_ eye: Mat4, faceToCamera: Mat4) -> Vec3 { faceToCamera.point(eye.translation) }

    /// Intersection of a ray with the camera's z = 0 plane (≈ the screen). Camera space in, camera-plane metres out.
    /// Returns nil when the ray runs parallel to the screen or points away from it.
    public static func intersectScreenPlane(origin: Vec3, direction: Vec3) -> Vec2? {
        guard abs(direction.z) > 1e-9 else { return nil }
        let t = -origin.z / direction.z
        guard t > 0 else { return nil }
        let p = origin + direction * t
        return Vec2(p.x, p.y)
    }

    /// Camera-plane metres (sensor axes) -> screen axes in metres: x right and y down as the player sees the screen,
    /// origin at the camera. Camera +x runs from the front camera toward the bottom of the phone, camera +y is to the
    /// right of it in portrait. Checked on the iPhone 13 (second session, portrait calibration, 2026-11-04): the hit's
    /// camera y followed the dots' screen x (r = 0.92) and camera x their screen y (r = 0.99). Turning the phone turns
    /// the screen axes with it. Before 2026-11-05 portrait features were logged as (-y, -x); the ridge model fits
    /// either sign, so old session CSVs replay the same.
    public static func cameraPlaneToScreen(_ p: Vec2, _ o: ScreenOrientation) -> Vec2 {
        switch o {
        case .portrait: return Vec2(p.y, p.x)
        case .landscapeRight: return Vec2(p.x, -p.y)
        case .landscapeLeft: return Vec2(-p.x, p.y)
        }
    }

    /// Screen axes in metres (origin at the camera, x right and y down as the player sees the screen) -> camera-plane
    /// metres (sensor axes): the inverse of `cameraPlaneToScreen`.
    public static func screenToCameraPlane(_ p: Vec2, _ o: ScreenOrientation) -> Vec2 {
        switch o {
        case .portrait: return Vec2(p.y, p.x)
        case .landscapeRight: return Vec2(p.x, -p.y)
        case .landscapeLeft: return Vec2(-p.x, p.y)
        }
    }

    /// A direction in face space -> its two angles inside the head (radians): x the turn about the face's vertical
    /// axis (positive toward face +x), y the lift toward face +y. Straight out of the face (+z) is (0, 0). Nil for
    /// a direction that does not point out of the face.
    public static func headAngles(_ d: Vec3) -> Vec2? {
        guard d.z > 1e-9, d.x.isFinite, d.y.isFinite, d.z.isFinite else { return nil }
        return Vec2(atan2(d.x, d.z), atan2(d.y, (d.x * d.x + d.z * d.z).squareRoot()))
    }

    /// The inverse of `headAngles`: a unit direction in face space.
    public static func headDirection(_ a: Vec2) -> Vec3 {
        Vec3(sin(a.x) * cos(a.y), sin(a.y), cos(a.x) * cos(a.y))
    }

    /// Rhythm mode: a note's place in the play area (0...1 from the left edge to the right one and from the top edge
    /// to the bottom one, as the player sees the screen) -> screen pt, for a screen `size` pt across and down.
    public static func playAreaToScreen(x: Double, y: Double, size: Vec2) -> Vec2 { Vec2(x * size.x, y * size.y) }

    /// EXIF orientation (the raw value of CGImagePropertyOrientation) that stands ARKit's front-camera image upright
    /// for a player facing the screen held this way (CLAUDE.md rule 3). Portrait is 5 (leftMirrored): with it Vision
    /// found pupils on 99-100% of frames on the iPhone 13. The landscape values come from Apple's Vision face tracking
    /// sample for the front camera, which uses leftMirrored for portrait as well: camera on the left 4 (downMirrored),
    /// camera on the right 2 (upMirrored). Not yet checked on a phone, so FaceTracker turns the image 180° when
    /// Vision finds no face with it.
    public static func frontCameraImageOrientation(_ o: ScreenOrientation) -> UInt32 {
        switch o {
        case .portrait: return 5
        case .landscapeRight: return 4
        case .landscapeLeft: return 2
        }
    }

    /// The EXIF orientation of the same image turned 180°.
    public static func rotated180(exif: UInt32) -> UInt32 {
        switch exif {
        case 1: return 3
        case 3: return 1
        case 2: return 4
        case 4: return 2
        case 5: return 7
        case 7: return 5
        case 6: return 8
        case 8: return 6
        default: return exif
        }
    }

    /// Head yaw, pitch, roll (radians) and distance (metres) of the face as seen from the camera.
    public static func headPose(_ f: FaceFrame) -> (yaw: Double, pitch: Double, roll: Double, distance: Double) {
        let m = faceToCamera(f)
        let z = m.zAxis.normalized, x = m.xAxis.normalized
        let yaw = atan2(z.x, z.z)
        let pitch = asin(max(-1, min(1, -z.y)))
        let roll = atan2(x.y, x.x)
        return (yaw, pitch, roll, m.translation.length)
    }
}

/// The eyes as the head carries them: where they are and how the head is turned (camera space), and which way they
/// point inside the head (face space angles, `Transforms.headAngles`), as ARKit measures it. A tilt of the phone or
/// a nod changes the first part and leaves the second alone, which is what lets `HeadGazeModel` keep its aim.
public struct HeadFrameGaze: Sendable, Equatable {
    /// Midpoint between the eyes' centres (camera space, metres).
    public var origin: Vec3
    /// The face's own axes in camera space (the rotation part of camera <- face).
    public var faceX: Vec3
    public var faceY: Vec3
    public var faceZ: Vec3
    /// Mean of both eyes' directions toward `lookAtPoint`, inside the head (radians).
    public var lookAngles: Vec2

    public init(origin: Vec3, faceX: Vec3, faceY: Vec3, faceZ: Vec3, lookAngles: Vec2) {
        self.origin = origin; self.faceX = faceX; self.faceY = faceY; self.faceZ = faceZ
        self.lookAngles = lookAngles
    }

    /// camera space direction -> face space.
    public func toFace(_ v: Vec3) -> Vec3 { Vec3(v.dot(faceX), v.dot(faceY), v.dot(faceZ)) }
    /// face space direction -> camera space.
    public func toCamera(_ w: Vec3) -> Vec3 { faceX * w.x + faceY * w.y + faceZ * w.z }
}

/// Where the screen lies against the front camera, for turning a screen point into a place in camera space and
/// back. The camera is taken to sit on the middle of the screen's edge it is nearest to; on an iPhone it is within
/// about a centimetre of that. A calibration absorbs that offset at its own distance, and what is left when the
/// distance changes is the offset times the change's share (a millimetre or two).
public struct ScreenGeometry: Sendable, Equatable {
    /// Screen size (screen pt), in the orientation the app runs.
    public var size: Vec2
    public var ptPerMetre: Double
    public var orientation: ScreenOrientation

    public init(size: Vec2, ptPerMetre: Double, orientation: ScreenOrientation) {
        self.size = size; self.ptPerMetre = ptPerMetre; self.orientation = orientation
    }

    /// The front camera's place on the screen (screen pt).
    public var cameraPt: Vec2 {
        switch orientation {
        case .portrait: return Vec2(size.x / 2, 0)
        case .landscapeRight: return Vec2(0, size.y / 2)
        case .landscapeLeft: return Vec2(size.x, size.y / 2)
        }
    }

    /// Screen pt -> camera-plane metres (the camera's z = 0 plane, sensor axes).
    public func cameraPlane(fromScreen p: Vec2) -> Vec2 {
        Transforms.screenToCameraPlane((p - cameraPt) * (1 / ptPerMetre), orientation)
    }

    /// Camera-plane metres -> screen pt.
    public func screen(fromCameraPlane p: Vec2) -> Vec2 {
        Transforms.cameraPlaneToScreen(p, orientation) * ptPerMetre + cameraPt
    }
}

/// Gaze features handed to the calibration model. Two ray sources are kept side by side so the
/// baseline (lookAtPoint) and the eye-transform ray can be compared on the same recordings (rule 7).
public struct GazeFeatures: Sendable {
    /// Average of both eyes' ray through `lookAtPoint`, hitting the screen plane (screen axes, metres from the camera).
    public var lookAtHit: Vec2
    /// Average of both eyes' own +z axis ray, hitting the screen plane (screen axes, metres from the camera).
    public var eyeAxisHit: Vec2
    public var yaw: Double, pitch: Double, roll: Double, distance: Double
    public var pupils: PupilOffsets?
    /// Eye centres in camera space (metres): ARKit eye transforms moved through face → world → camera.
    /// Not used by the model; shown in the debug overlay for the stage-0 check.
    public var leftEyeCamera: Vec3 = .zero
    public var rightEyeCamera: Vec3 = .zero
    /// The same frame as `HeadGazeModel` reads it. Nil when the eyes do not point out of the face, and in features
    /// rebuilt from an old session CSV, which did not log it.
    public var head: HeadFrameGaze?

    public init(lookAtHit: Vec2, eyeAxisHit: Vec2, yaw: Double, pitch: Double, roll: Double, distance: Double,
                pupils: PupilOffsets?, leftEyeCamera: Vec3 = .zero, rightEyeCamera: Vec3 = .zero) {
        self.lookAtHit = lookAtHit; self.eyeAxisHit = eyeAxisHit
        self.yaw = yaw; self.pitch = pitch; self.roll = roll; self.distance = distance; self.pupils = pupils
        self.leftEyeCamera = leftEyeCamera; self.rightEyeCamera = rightEyeCamera
    }

    public enum FeatureSet: String, CaseIterable, Sendable {
        /// Baseline from CLAUDE.md stage 1: the lookAtPoint ray's hit on the screen.
        case lookAt
        /// lookAtPoint + eye axes.
        case eyes
        /// Everything above plus pupil offsets from the image detector (stage 2 direction).
        case eyesAndPupils
    }

    public static func make(_ f: FaceFrame) -> GazeFeatures? {
        let f2c = Transforms.faceToCamera(f)
        let lo = Transforms.eyeOrigin(f.leftEyeTransform, faceToCamera: f2c)
        let ro = Transforms.eyeOrigin(f.rightEyeTransform, faceToCamera: f2c)
        let target = f2c.point(f.lookAtPoint)
        guard let l1 = Transforms.intersectScreenPlane(origin: lo, direction: target - lo),
              let r1 = Transforms.intersectScreenPlane(origin: ro, direction: target - ro) else { return nil }
        let ld = f2c.direction(f.leftEyeTransform.zAxis), rd = f2c.direction(f.rightEyeTransform.zAxis)
        let l2 = Transforms.intersectScreenPlane(origin: lo, direction: ld) ?? l1
        let r2 = Transforms.intersectScreenPlane(origin: ro, direction: rd) ?? r1
        let pose = Transforms.headPose(f)
        var out = GazeFeatures(
            lookAtHit: Transforms.cameraPlaneToScreen((l1 + r1) * 0.5, f.orientation),
            eyeAxisHit: Transforms.cameraPlaneToScreen((l2 + r2) * 0.5, f.orientation),
            yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll, distance: pose.distance, pupils: f.pupils,
            leftEyeCamera: lo, rightEyeCamera: ro)
        // The lookAtPoint ray inside the head: both eyes' directions averaged, in face space.
        let le = f.leftEyeTransform.translation, re = f.rightEyeTransform.translation
        let look = ((f.lookAtPoint - le).normalized + (f.lookAtPoint - re).normalized).normalized
        if let la = Transforms.headAngles(look) {
            out.head = HeadFrameGaze(origin: (lo + ro) * 0.5, faceX: f2c.xAxis.normalized, faceY: f2c.yAxis.normalized,
                                     faceZ: f2c.zAxis.normalized, lookAngles: la)
        }
        return out
    }

    /// Flat vector for the ridge model. The first two entries are always the lookAtPoint hit (screen axes, metres),
    /// which `RidgeModel.outOfRange` uses to spot a glance away from the screen. Quadratic terms on that ray let
    /// the model bend at the screen edges, where uncalibrated lookAtPoint error is largest.
    ///
    /// Head pose (yaw, pitch, roll, distance) is deliberately not a feature. The hits are computed in camera space,
    /// so they already move with the head and the phone. As separate features, the pose terms learned that the head
    /// turns a little toward each calibration dot, and when the phone moved during a game the aim moved with it
    /// (first iPhone session, 2026-11-04: the aim was over 1 cm off the screen 25% of the time in level 6).
    ///
    /// Missing pupils are NaN, not 0: the model treats NaN as "average", so a frame without a fresh pupil result
    /// does not make the aim jump.
    public func vector(_ set: FeatureSet) -> [Double] {
        let a = lookAtHit
        var v = [a.x, a.y, a.x * a.x, a.y * a.y, a.x * a.y]
        if set != .lookAt { v += [eyeAxisHit.x, eyeAxisHit.y] }
        if set == .eyesAndPupils {
            if let p = pupils {
                v += [(p.leftU + p.rightU) / 2, (p.leftV + p.rightV) / 2]
            } else {
                v += [.nan, .nan]
            }
        }
        return v
    }
}

/// The probe's field on this screen. Field deg: degrees of visual angle from the centre of the screen, x to the
/// right and y down as the player sees the screen. Screen pt: origin top-left, y down. The eyes are taken to be
/// `distanceCm` in front of the screen's centre, so a place `d` degrees to the side lies distance * tan(d) from it.
public struct FieldMapping: Sendable, Equatable {
    /// Screen size (screen pt).
    public let size: Vec2
    /// Screen points per centimetre on this phone.
    public let ptPerCm: Double
    /// From the eyes to the screen (cm).
    public let distanceCm: Double
    /// 1 when the whole field fits the screen at this distance; less when it had to shrink to fit (a small phone
    /// held far away). Below 1 a field degree is that much smaller than a true degree.
    public let fit: Double

    public init(size: Vec2, ptPerCm: Double, distanceCm: Double, fieldHalfWidthDeg: Double, fieldHalfHeightDeg: Double,
                marginPt: Double = 30) {
        self.size = size
        self.ptPerCm = max(1, ptPerCm)
        self.distanceCm = max(1, distanceCm)
        let reach = self.ptPerCm * self.distanceCm
        let needX = reach * tan(fieldHalfWidthDeg * Double.pi / 180)
        let needY = reach * tan(fieldHalfHeightDeg * Double.pi / 180)
        let roomX = max(1, size.x / 2 - marginPt), roomY = max(1, size.y / 2 - marginPt)
        fit = min(1, roomX / max(1e-9, needX), roomY / max(1e-9, needY))
    }

    /// Screen pt for one unit of tan(angle).
    private var scale: Double { ptPerCm * distanceCm * fit }

    /// Field deg -> screen pt.
    public func screen(fromField p: Vec2) -> Vec2 {
        Vec2(size.x / 2 + scale * tan(p.x * Double.pi / 180), size.y / 2 + scale * tan(p.y * Double.pi / 180))
    }

    /// Screen pt -> field deg.
    public func field(fromScreen p: Vec2) -> Vec2 {
        Vec2(atan((p.x - size.x / 2) / scale) * 180 / Double.pi, atan((p.y - size.y / 2) / scale) * 180 / Double.pi)
    }

    /// A length at the centre of the field: field deg -> screen pt.
    public func length(fromDeg d: Double) -> Double { scale * tan(d * Double.pi / 180) }

    /// The screen's half-width and half-height (field deg).
    public var screenHalfDeg: Vec2 { field(fromScreen: size) }
}
