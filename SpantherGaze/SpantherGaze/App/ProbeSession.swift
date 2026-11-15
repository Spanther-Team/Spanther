import AVFoundation
import Foundation
import QuartzCore
import UIKit

/// One run of the frozen 90-second probe (architecture proposal §1 and §2): a form drawn from a fresh seed
/// (`ProbePlan`), laid out in degrees of visual angle at the measured eye distance (`FieldMapping`), and scored frame
/// by frame (`ProbeRun`). Host time in (CACurrentMediaTime, the clock ARKit's frames share), field degrees inside,
/// screen pt for the drawing. Main thread.
final class ProbeSession: ObservableObject {
    enum Phase: Equatable { case running, done }

    @Published private(set) var phase: Phase = .running

    let plan: ProbePlan
    let mapping: FieldMapping
    let childID: UUID
    /// Host time of probe time 0.
    let startHost: Double
    let start = Date()
    private(set) var run: ProbeRun
    /// Host times at which each target was held or ran out: the screen pops or fades it.
    private(set) var held: [Int: Double] = [:]
    private(set) var expired: [Int: Double] = [:]
    /// Host times at which each distractor appeared.
    private(set) var distractorShown: [Int: Double] = [:]

    // What the phone saw while the probe ran, for the session's conditions.
    private var distances: [Double] = []
    private var fpsSeen: [Double] = []
    private var lights: [Double] = []
    private var thermal = ProcessInfo.ThermalState.nominal
    private var lowPower = false
    private let batteryStart: Float
    private let feedback = ProbeFeedback()

    /// `radiusDeg`: the zone round a target for this calibration (ProbeProtocol.hitRadiusDeg).
    init(plan: ProbePlan, mapping: FieldMapping, radiusDeg: Double, childID: UUID, now: Double) {
        self.plan = plan
        self.mapping = mapping
        self.childID = childID
        startHost = now + 0.6
        let half = mapping.screenHalfDeg
        run = ProbeRun(plan: plan, radiusDeg: radiusDeg, screenHalfWidthDeg: half.x, screenHalfHeightDeg: half.y)
        UIDeviceBattery.enable()
        batteryStart = UIDeviceBattery.level
    }

    /// Probe time at a host time (s; negative before the start).
    func time(host: Double) -> Double { host - startHost }

    /// One tracking frame: the gaze (screen pt, nil when the eyes were not seen) and what the camera saw.
    func sample(host: Double, gaze: Vec2?, distanceCm: Double?, fps: Double, light: Double?) {
        guard phase == .running else { return }
        let t = time(host: host)
        guard t >= 0 else { return }
        if let d = distanceCm { distances.append(d) }
        if fps > 0 { fpsSeen.append(fps) }
        if let l = light { lights.append(l) }
        for event in run.add(t: t, gaze: gaze.map { mapping.field(fromScreen: $0) }) {
            switch event {
            case .targetHeld(let i):
                held[i] = host
                feedback.held()
            case .targetExpired(let i):
                expired[i] = host
            case .distractorAppeared(let i):
                distractorShown[i] = host
            case .targetAppeared, .distractorGone:
                break
            }
        }
    }

    /// Moves the phase on with the clock; returns true on the call that ends the probe. The device state is read
    /// here, a few times a second.
    func tick(host: Double) -> Bool {
        guard phase == .running else { return false }
        let p = ProcessInfo.processInfo
        if p.thermalState.rawValue > thermal.rawValue { thermal = p.thermalState }
        lowPower = lowPower || p.isLowPowerModeEnabled
        // The run ends on its own clock; a phone that stops sending frames still ends it a second later.
        guard run.finished || time(host: host) > plan.rules.durationSec + 1 else { return false }
        phase = .done
        return true
    }

    /// Where the target, the gliding target and the distractor are at a host time (screen pt), for the drawing.
    func targetPosition(_ i: Int) -> Vec2 { mapping.screen(fromField: plan.targets[i].position) }
    func distractorPosition(_ i: Int) -> Vec2 { mapping.screen(fromField: plan.distractors[i].position) }
    func gliderPosition(host: Double) -> Vec2? { plan.pursuitPosition(at: time(host: host)).map { mapping.screen(fromField: $0) } }

    /// What the phone saw: the calibration's check error, the median distance, frame rate and light, the worst heat.
    func conditions(calibrationErrorCm: Double?, night: Bool) -> Conditions {
        let battery = UIDeviceBattery.level
        let used = batteryStart >= 0 && battery >= 0 ? Double(max(0, batteryStart - battery)) : nil
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String).map { v in
            "\(v) (\(info?["CFBundleVersion"] as? String ?? "?"))"
        }
        return Conditions(calibrationErrorCm: calibrationErrorCm, distanceCm: CourseStats.median(distances),
                          trackingFps: CourseStats.median(fpsSeen), thermal: FaceTracker.describe(thermal),
                          lowPower: lowPower, night: night, batteryUsed: used, appVersion: version,
                          device: Self.deviceModel, lightLm: CourseStats.median(lights))
    }

    /// The model identifier, such as iPhone14,5.
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The probe's one fixed, versioned feedback set (architecture proposal, "Audio and haptics engine"): a short wood
/// chime on D5, the same every time and never varied, so a new sound pack can never move a clinical number. Version 1
/// goes with probe protocol version 1.
final class ProbeFeedback {
    static let version = 1
    private let sound = SoundEngine.shared
    private let chime: AVAudioPCMBuffer?

    init() {
        var rng = FeelRandom(seed: 1)
        var samples = PopSynth.chime(.wood, frequency: 587.33, sampleRate: SoundEngine.sampleRate, rng: &rng)
        PopSynth.normalize(&samples, toDBFS: -12)
        chime = sound.buffer(samples)
        sound.hold("probe", true)
    }

    deinit { sound.hold("probe", false) }

    func held() {
        guard let chime else { return }
        let sound = self.sound
        sound.queue.async { sound.play(chime, pan: 0, volume: 0.7) }
    }
}

/// The battery level for the session's conditions (UIDevice, wrapped so the session reads like the rest).
enum UIDeviceBattery {
    static func enable() { UIDevice.current.isBatteryMonitoringEnabled = true }
    /// 0...1, or −1 where the phone does not say (the Simulator).
    static var level: Float { UIDevice.current.batteryLevel }
}
