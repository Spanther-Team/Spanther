import ARKit
import AVFoundation
import QuartzCore
import os

/// One ARKit frame turned into GazeCore types, plus timing for the debug overlay.
struct TrackingSample {
    var timestamp: Double
    /// nil when no face is tracked this frame.
    var features: GazeFeatures?
    /// ARKit eyeBlinkLeft / eyeBlinkRight blend shapes, 0 open ... 1 closed. nil when no face.
    var blink: (left: Double, right: Double)?
    var processingMs: Double
    var fps: Double
    /// The light ARKit estimates around the face (lumens, about 1000 in a lit room). nil when no face.
    var light: Double? = nil
}

/// The camera format ARKit runs and the device state that can lower its frame rate, for the debug overlay and
/// the session CSV (`tracking` rows). The first iPhone 13 session ran at 30 fps although `start()` asks for 60,
/// and nothing in its CSV said why.
struct TrackingInfo: Equatable {
    /// The format the session runs, width x height @ fps, for example "1280x720@60".
    var format = "-"
    /// Every face tracking format the device offers, in ARKit's order (best quality first).
    var offered = "-"
    /// ProcessInfo thermal state: nominal, fair, serious or critical.
    var thermal = "-"
    var lowPower = false
    /// How the screen is held (ScreenOrientation), which the gaze transforms use.
    var screen = "-"
    /// The image orientation Vision runs with, for example "downMirrored"; "turned" when the tracker turned it 180°
    /// because Vision found no face with the expected one.
    var vision = "-"
    /// Night vision is on: slowest frame rate, brighter exposure, no Vision pupils.
    var night = false
}

/// ARKit face tracking adapter (the `Tracking` module in CLAUDE.md). All ARKit work runs on `queue`;
/// samples are delivered to the main thread through `onSample`.
///
/// The tracking loop (architecture proposal, "Tracking loop"): the delegate runs on its own serial queue and copies
/// out only what it needs, so the ARFrame is let go when the callback returns; for the pupils it copies the face's
/// square into a buffer of its own (FaceCropper) and leaves it in a latest-only mailbox: when Vision is busy the older
/// crop is dropped, never queued. Signposts mark each stage for Instruments.
final class FaceTracker: NSObject, ARSessionDelegate {
    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    var onSample: ((TrackingSample) -> Void)?
    /// Called on the main thread when tracking starts and whenever the thermal state or Low Power Mode changes.
    var onInfo: ((TrackingInfo) -> Void)?
    /// Main thread only.
    private(set) var info = TrackingInfo()
    var pupilDetector: PupilDetector? = VisionPupilDetector()

    private let session = ARSession()
    private let queue = DispatchQueue(label: "spanther.tracking", qos: .userInteractive)
    private let visionQueue = DispatchQueue(label: "spanther.pupils", qos: .userInitiated)
    private let lock = NSLock()
    private var latestPupils: (value: PupilOffsets, time: Double)?
    private var visionBusy = false
    /// Guarded by `lock`. The newest face crop waiting for Vision; a newer one replaces it.
    private var mailbox: (buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, time: Double)?
    /// Tracking queue only.
    private let cropper = FaceCropper()
    private let signposter = OSSignposter(subsystem: "com.spanther.SpantherGaze", category: "tracking")
    /// Guarded by `lock`. Set on the main thread in `start`, read on `queue`.
    private var orientation = ScreenOrientation.landscapeRight
    /// Guarded by `lock`. Night vision: no Vision pupils (they are not found in the dark).
    private var nightVision = false
    /// Guarded by `lock`. The landscape image orientations are not yet checked on a phone, so Vision's results are
    /// counted in windows of 30 requests (about 1 s): almost no face in a window turns the image 180°, a mostly
    /// successful window keeps the orientation for good.
    private var visionTurned = false
    private var visionTrusted = false
    private var visionAttempts = 0
    private var visionHits = 0
    private var frameCount = 0
    private var fpsWindowStart = 0.0
    private var fpsFrames = 0
    private var fps = 0.0

    /// Main thread. `orientation` is how the app's screen is held; it has to match Info.plist. `night`: night
    /// vision (see `setNightVision`).
    func start(orientation: ScreenOrientation, night: Bool = false) {
        guard Self.isSupported else { return }
        lock.lock()
        self.orientation = orientation
        nightVision = night
        if night { latestPupils = nil }
        let vision = visionDescriptionLocked
        lock.unlock()
        info.screen = orientation.rawValue
        info.vision = night ? "off (night)" : vision
        info.night = night
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        // The light estimate is logged on every frame, so a session played in the dark can be told apart.
        config.isLightEstimationEnabled = true
        // CLAUDE.md asks for 60 fps, and the architecture proposal for the smallest format that gives it: fewer
        // pixels for ARKit, and Vision only ever sees the face's square. Without a 60 fps format, the first of the
        // fastest. Night vision takes the first of the slowest instead (30 fps on the iPhone 13): a frame can then be
        // exposed twice as long, and in a dark room the light from the screen is all the camera gets. The light
        // estimate stays on in every mode: the session CSV, the calibration's "too dark" hint and the clinic's
        // quality gate read it.
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        func pixels(_ f: ARConfiguration.VideoFormat) -> CGFloat { f.imageResolution.width * f.imageResolution.height }
        let fast = formats.filter { $0.framesPerSecond >= 60 }
        let chosen = night ? formats.min(by: { $0.framesPerSecond < $1.framesPerSecond })
            : (fast.min(by: { pixels($0) < pixels($1) }) ?? formats.max(by: { $0.framesPerSecond < $1.framesPerSecond }))
        if let chosen { config.videoFormat = chosen }
        info.offered = formats.isEmpty ? "-" : formats.map { Self.describe($0) }.joined(separator: " ")
        info.format = Self.describe(config.videoFormat)
        let center = NotificationCenter.default
        center.removeObserver(self)
        center.addObserver(self, selector: #selector(deviceStateChanged),
                           name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(deviceStateChanged),
                           name: .NSProcessInfoPowerStateDidChange, object: nil)
        updateDeviceState()
        session.delegateQueue = queue
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        configureCamera(night: night)
    }

    /// Night vision on or off: the session restarts with the other frame rate. Main thread.
    func setNightVision(_ on: Bool) {
        lock.lock(); let o = orientation; lock.unlock()
        start(orientation: o, night: on)
    }

    /// Night vision lets the camera's auto exposure aim one stop brighter and use low light boost where the camera
    /// has it (ARKit 6 hands out the capture device for this). Off puts both back.
    private func configureCamera(night: Bool) {
        guard let device = ARFaceTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = night }
            let bias: Float = night ? min(1, device.maxExposureTargetBias) : 0
            device.setExposureTargetBias(max(device.minExposureTargetBias, bias), completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            // The camera keeps ARKit's own exposure.
        }
    }

    func stop() { session.pause() }

    static func describe(_ f: ARConfiguration.VideoFormat) -> String {
        "\(Int(f.imageResolution.width))x\(Int(f.imageResolution.height))@\(f.framesPerSecond)"
    }

    /// Names of the EXIF orientations 1...8, as CGImagePropertyOrientation spells them.
    static func describeImageOrientation(_ raw: UInt32) -> String {
        let names = ["up", "upMirrored", "down", "downMirrored", "leftMirrored", "right", "rightMirrored", "left"]
        return (1...8).contains(raw) ? names[Int(raw) - 1] : "\(raw)"
    }

    /// Caller holds `lock`.
    private var visionOrientationLocked: UInt32 {
        let raw = Transforms.frontCameraImageOrientation(orientation)
        return visionTurned ? Transforms.rotated180(exif: raw) : raw
    }

    /// Caller holds `lock`.
    private var visionDescriptionLocked: String {
        Self.describeImageOrientation(visionOrientationLocked) + (visionTurned ? " turned" : "")
    }

    /// Caller holds `lock`. Returns true when this result turned the image orientation.
    private func recordVisionLocked(found: Bool) -> Bool {
        guard !visionTrusted else { return false }
        visionAttempts += 1
        if found { visionHits += 1 }
        guard visionAttempts >= 30 else { return false }
        defer { visionAttempts = 0; visionHits = 0 }
        if visionHits >= 20 { visionTrusted = true; return false }
        guard visionHits <= 3 else { return false }
        visionTurned.toggle()
        return true
    }

    static func describe(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// The notifications arrive on any thread.
    @objc private func deviceStateChanged() {
        DispatchQueue.main.async { [weak self] in self?.updateDeviceState() }
    }

    /// Main thread.
    private func updateDeviceState() {
        let p = ProcessInfo.processInfo
        info.thermal = Self.describe(p.thermalState)
        info.lowPower = p.isLowPowerModeEnabled
        onInfo?(info)
    }

    // MARK: ARSessionDelegate (runs on `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t0 = CACurrentMediaTime()
        let interval = signposter.beginInterval("frame")
        defer { signposter.endInterval("frame", interval) }
        fpsFrames += 1
        if t0 - fpsWindowStart >= 1 { fps = Double(fpsFrames) / (t0 - fpsWindowStart); fpsFrames = 0; fpsWindowStart = t0 }

        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else {
            deliver(TrackingSample(timestamp: frame.timestamp, features: nil, blink: nil, processingMs: 0, fps: fps))
            return
        }

        // Pupils: the face's square, copied out of the frame every second frame into the latest-only mailbox. Vision
        // takes the newest crop whenever it is free; a crop it had no time for is dropped. Not in night vision.
        frameCount += 1
        lock.lock()
        let night = nightVision
        let raw = visionOrientationLocked
        lock.unlock()
        if pupilDetector != nil, !night, frameCount % 2 == 0, let rect = FaceCropper.faceRect(frame: frame, face: face) {
            let cropState = signposter.beginInterval("crop")
            let crop = cropper.crop(frame.capturedImage, rect: rect)
            signposter.endInterval("crop", cropState)
            if let crop {
                // The sensor image is rotated and mirrored relative to the upright face; Transforms says how for the
                // way the phone is held (CLAUDE.md rule 3). A crop keeps the image's orientation.
                let imageOrientation = CGImagePropertyOrientation(rawValue: raw) ?? .leftMirrored
                lock.lock()
                mailbox = (crop, imageOrientation, frame.timestamp)
                let start = !visionBusy
                if start { visionBusy = true }
                lock.unlock()
                if start { visionQueue.async { [weak self] in self?.drainMailbox() } }
            }
        }
        // A pupil result stays usable for 0.3 s. With 0.1 s, the first iPhone session had pupils on only 54% of
        // calibration frames, because Vision runs on every second frame and a request can take longer than that.
        lock.lock()
        let pupils = latestPupils.flatMap { frame.timestamp - $0.time < 0.3 ? $0.value : nil }
        let orientation = self.orientation
        lock.unlock()

        let ff = FaceFrame(
            timestamp: frame.timestamp,
            faceTransform: Mat4(face.transform),
            leftEyeTransform: Mat4(face.leftEyeTransform),
            rightEyeTransform: Mat4(face.rightEyeTransform),
            lookAtPoint: Vec3(face.lookAtPoint),
            cameraTransform: Mat4(frame.camera.transform),
            orientation: orientation,
            pupils: pupils)
        let features = GazeFeatures.make(ff)
        let blink = (left: face.blendShapes[.eyeBlinkLeft]?.doubleValue ?? 0,
                     right: face.blendShapes[.eyeBlinkRight]?.doubleValue ?? 0)
        deliver(TrackingSample(timestamp: frame.timestamp, features: features, blink: blink,
                               processingMs: (CACurrentMediaTime() - t0) * 1000, fps: fps,
                               light: frame.lightEstimate.map { Double($0.ambientIntensity) }))
    }

    /// Vision's loop on `visionQueue`: takes the newest crop from the mailbox until it is empty, then stops.
    private func drainMailbox() {
        guard let detector = pupilDetector else {
            lock.lock(); visionBusy = false; mailbox = nil; lock.unlock()
            return
        }
        while true {
            lock.lock()
            guard let job = mailbox else {
                visionBusy = false
                lock.unlock()
                return
            }
            mailbox = nil
            lock.unlock()
            let state = signposter.beginInterval("vision")
            let p = detector.detect(job.buffer, orientation: job.orientation)
            signposter.endInterval("vision", state)
            lock.lock()
            if let p { latestPupils = (p, job.time) }
            let turned = recordVisionLocked(found: p != nil)
            let vision = visionDescriptionLocked
            // A crop made before the orientation turned would only fail again.
            if turned { mailbox = nil }
            lock.unlock()
            if turned {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.info.vision = vision
                    self.onInfo?(self.info)
                }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        deliver(TrackingSample(timestamp: CACurrentMediaTime(), features: nil, blink: nil, processingMs: 0, fps: 0))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        deliver(TrackingSample(timestamp: CACurrentMediaTime(), features: nil, blink: nil, processingMs: 0, fps: 0))
    }

    private func deliver(_ s: TrackingSample) {
        DispatchQueue.main.async { [weak self] in self?.onSample?(s) }
    }
}
