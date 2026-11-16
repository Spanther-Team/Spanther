import AVFoundation
import Foundation
import QuartzCore
import UIKit

enum Route: Equatable {
    case menu
    case calibration
    case check
    case result
    case game
    /// Measures one-eye winks, the input of the rhythm mode.
    case winkTest
    /// Rhythm mode: notes land on the beat of a track; look at each one and wink as it lands.
    case rhythm
    /// The 60-second warm-up: one target glides across the screen and the eyes follow it.
    case pursuit
    /// The clinic: «Кто играет?», and behind Face ID the profiles, courses, charts and export.
    case clinic
    /// The frozen 90-second probe at the start of a session.
    case probe
}

enum ControlMode { case eyes, touch }

/// The session's one calibration (`AppModel.calibration`): the fitted gaze models, how well the one that plays hit
/// the check dots, the grip it was made at, and whose it is.
struct SessionCalibration {
    /// The model that plays, and the other fit, whose aim is logged next to it.
    let model: GazeModel
    let shadow: GazeModel?
    let head: HeadGazeModel?
    let screen: RidgeModel?
    /// Both models' mean miss on the check dots (screen pt).
    let headMissPt: Double?
    let screenMissPt: Double?
    /// The check dots' accuracy of the model that plays.
    let report: AccuracyReport
    /// The mean head pose and distance (m) of the calibration's frames: the aim adapter measures tilt from them.
    let reference: HeadPose?
    let distanceM: Double
    /// The child picked on «Кто играет?» when it was made (nil: nobody was picked), and when.
    let childID: UUID?
    let madeAt: Date
}

/// Live tracking numbers for the debug overlay, refreshed about 10 times a second.
final class TrackingStatus: ObservableObject {
    @Published var fps = 0.0
    @Published var processingMs = 0.0
    @Published var faceFound = false
    @Published var features: GazeFeatures?
    @Published var gaze: Vec2?
    @Published var blink: (left: Double, right: Double)?
    /// Each eye's current open level, which the blink thresholds ride on.
    @Published var blinkBase: (left: Double, right: Double) = (0, 0)
    @Published var gazeFrozen = false
    /// Blinks counted toward the next reload (0...2).
    @Published var pendingBlinks = 0
    @Published var reloadBlinksNeeded = 3
    @Published var blinksTotal = 0
    /// Camera format, formats offered, thermal state and Low Power Mode.
    @Published var tracking = TrackingInfo()
    /// Wink test: the last closure the wink detector reported, and the level at which each eye counts as closed.
    @Published var lastWink: WinkEvent?
    @Published var winkCloseLevel: (left: Double, right: Double) = (0.6, 0.6)
    /// Aim adapter: the correction it adds now (screen pt), the labels it learned and the ones it left out.
    @Published var aimCorrection = Vec2.zero
    @Published var aimLabels = 0
    @Published var aimRejected = 0
    /// The light ARKit estimates around the face (lumens), for the "too dark" hint and the debug overlay.
    @Published var light: Double?
}

/// App state shared by all screens. Main thread only.
final class AppModel: ObservableObject {
    @Published var route: Route = .menu {
        didSet {
            lookedAtMeteor = nil
            applyBrightness()
            if oldValue == .game, route != .game {
                gamePaused = false
                finishMeteorPlay()
            }
            if route == .game, oldValue != .game { beginMeteorPlay() }
            if oldValue == .pursuit, route != .pursuit { dropPursuit() }
            if oldValue == .probe, route != .probe { dropProbe() }
            updateAmbient()
        }
    }
    @Published var mode: ControlMode = .eyes
    /// «Мелкие цели»: every target and its hit zone 30% smaller (balance.json `targetScale`), in both games.
    /// On unless switched off; kept between launches.
    @Published var smallTargets = UserDefaults.standard.object(forKey: "smallTargets") as? Bool ?? true {
        didSet { UserDefaults.standard.set(smallTargets, forKey: "smallTargets") }
    }
    /// «Красные знаки»: the meteor game sends in red signs the player must not look at.
    @Published var decoysOn = UserDefaults.standard.object(forKey: "decoys") as? Bool ?? true {
        didSet { UserDefaults.standard.set(decoysOn, forKey: "decoys") }
    }
    /// The calm music of the meteor game; the speaker button in the game switches it too.
    @Published var musicOn = UserDefaults.standard.object(forKey: "music") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(musicOn, forKey: "music")
            updateAmbient()
        }
    }
    /// The meteor game is on its pause plate (GameView sets it): the music fades out until play goes on.
    var gamePaused = false {
        didSet { if gamePaused != oldValue { updateAmbient() } }
    }
    private let ambient = AmbientPlayer()

    /// The scale of every target and hit zone now: balance.json's with «Мелкие цели», 1 without.
    var targetScale: Double { smallTargets ? balance.smallTargetScale : 1 }
    /// With small targets no hit zone gets smaller than this (screen pt): 1.25 times what the calibration missed
    /// by on its check screen. 0 by finger and with regular targets.
    var zoneFloorPt: Double {
        balance.zoneFloor(measuredErrorPt: mode == .eyes ? report?.meanErrorPt : nil, scale: targetScale)
    }

    /// The music plays while the meteor game is on screen, in front, not paused and not muted.
    private func updateAmbient() {
        ambient.setPlaying(route == .game && musicOn && active && !gamePaused)
    }
    @Published var report: AccuracyReport?
    @Published var showDebug = false
    @Published var usePupils = true
    /// Adds the aim adapter's correction to the gaze. Off: the adapter still learns and the CSV still shows its
    /// correction, but the aim is the calibrated model's alone, for comparing the two on the phone.
    @Published var adaptAim = true
    /// Night vision: for playing in a dark room. ARKit's face tracking needs some light (Apple says it does not
    /// work in total darkness), and there the only light on the face is the screen's. So the screen goes to full
    /// brightness on the play screens, the camera runs at its slowest frame rate for a longer exposure, and the
    /// gaze model drops the Vision pupils, which are not found in the dark. Switching it asks for a new
    /// calibration, since the model is fitted on the features it plays with. Kept between launches.
    @Published var nightVision = UserDefaults.standard.bool(forKey: "nightVision") {
        didSet {
            guard nightVision != oldValue else { return }
            UserDefaults.standard.set(nightVision, forKey: "nightVision")
            dropCalibration()
            if FaceTracker.isSupported { tracker.setNightVision(nightVision) }
            logTracking()
            applyBrightness()
        }
    }
    /// Host time the app started, when the garden begins to grow.
    let launchTime = CACurrentMediaTime()
    /// The app is in front (scene phase active).
    private var active = true
    /// The screen brightness before night vision raised it, to give back on the menu or in the background.
    private var savedBrightness: CGFloat?
    /// Where the calibration's result leads (`continueAfterCalibration`): the menu after the session's first
    /// calibration and after «Перекалибровать», otherwise the mode or screen that asked for it.
    private(set) var afterCalibration: Route = .menu

    let status = TrackingStatus()
    let tracker = FaceTracker()
    /// The clinic's children, courses and sessions (GazeCore ClinicStore), and who holds the phone.
    let clinic = ClinicModel()
    let balance: BalanceConfig
    private(set) var logger = SessionLogger()

    /// Current gaze for the game (screen pt). Not @Published: read every frame by the scene.
    private(set) var gaze: GazeInput = .lost
    /// The gaze point is the one kept from before an eyelid moved (a blink), not a fresh look. A red sign's look
    /// does not count such frames.
    private(set) var gazeHeld = false
    /// The calibrated gaze model that plays (GazeCore `GazeModel`): the head-frame one, or the first one on the rays'
    /// screen hits when the check dots speak against the head-frame fit.
    private(set) var model: GazeModel?
    /// The other fitted model. It does not play; its aim goes into the session CSV next to the playing one's, so
    /// one session on the phone compares the two.
    private var shadowModel: GazeModel?
    /// Both fits of the last calibration. Its check dots choose which one plays.
    private var fitted: (head: HeadGazeModel?, screen: RidgeModel?) = (nil, nil)
    /// Both models' mean miss on the check dots (screen pt), for the session CSV.
    private var modelCheck: (headMissPt: Double?, screenMissPt: Double?) = (nil, nil)
    /// The session's one calibration, once its check dots are done. Every mode plays on it: the meteors, the rhythm
    /// mode, the warm-up and the clinic's probe. It is made right after the start screen (`openSession`), or comes
    /// back from an earlier launch within 12 hours (`restoreKeptCalibration`), and is made again
    /// only when the player asks («Перекалибровать» on the menu, «Калибровка» in the meteors' pause) or another
    /// child takes the phone; night vision drops it, since the model then reads other features. The fields above
    /// are what the frames are read with now: this one's, or a new calibration's while it is being made.
    @Published private(set) var calibration: SessionCalibration?
    /// While a new calibration is being made: what the aim had learned on the session's calibration, and its CSV,
    /// so that leaving the new one before its end brings both back.
    private var stash: (adapter: GazeAdapter?, logger: SessionLogger)?
    /// The grip of the calibration being fitted: the mean head pose and distance (m) of its frames.
    private var grip: (reference: HeadPose?, distanceM: Double) = (nil, 0.28)
    private var filter = OneEuroFilter2D()
    /// The probe's gaze (screen pt): the model's own prediction, filtered on its own, without the aim correction the
    /// games teach and with no point held over a blink or a stray frame. Nil when there is no fresh look this frame.
    private(set) var probeGaze: Vec2?
    private var probeFilter = OneEuroFilter2D()
    /// Single frames past the calibrated range while the eyes sweep after a moving target are not a glance away.
    private var awayGate = RidgeModel.AwayGate()
    private var lastStatusPush = 0.0
    private var blinkDetector = BlinkDetector(EnergyConfig())
    private var winkDetector = WinkDetector()
    /// Closures the wink detector reported since the current wink test run started (tracking clock).
    private(set) var winks: [WinkEvent] = []
    /// Time of the last 3-blink reload not yet taken by the game.
    private var pendingReloadTime: Double?
    private var lastSampleTime = 0.0

    /// Keeps the calibrated aim on target when the phone is held at another tilt (GazeAdapter). Made at each
    /// calibration, warmed on the check dots, then taught by the meteors being burned and the rhythm notes winked.
    private(set) var adapter: GazeAdapter?
    /// The model's raw predictions (screen pt, before the correction) of the last 0.6 s with open eyes, with the
    /// head pose: where the player looked just before an eye closure or a tap.
    private var recentRaw: [(time: Double, raw: Vec2, pose: HeadPose)] = []
    /// What the adapter adds to the prediction right now (screen pt).
    private(set) var aimCorrection = Vec2.zero
    /// The meteor the game takes as looked at (screen pt), set by the scene on each frame of an eye game.
    var lookedAtMeteor: Vec2?
    /// A meteor being looked at teaches the adapter a little on every frame: 20 frames weigh as much as one note.
    static let meteorLabelWeight = 1.0 / 20
    private var checkPoses: [HeadPose] = []
    /// Warm-up: tells from the model's own aim whether the eyes follow the dot, which then teaches the adapter.
    private var followGate = FollowGate()

    /// Rhythm mode: the tracks in the bundle (tracks.json) and the play in progress.
    let rhythmTracks: [RhythmTrack]
    @Published private(set) var rhythm: RhythmSession?
    /// The report of the rhythm play that just ended, for its results screen.
    @Published private(set) var rhythmSummary: SessionSummary?
    private var rhythmTimer: Timer?

    /// Points per centimetre. Current iPhones are about 60 pt/cm (163 pt per inch on 2x, ~153 on 3x Pro).
    let ptPerCm = 60.0
    var featureSet: GazeFeatures.FeatureSet { usePupils && !nightVision ? .eyesAndPupils : .eyes }

    // Collection during calibration / check
    private var collecting: (target: Vec2, kind: String)?
    private var collectedFeatures: [GazeFeatures] = []
    private var collectedGaze: [Vec2] = []
    private var calibrationSet: [(target: Vec2, features: [GazeFeatures])] = []
    private var checkSet: [(target: Vec2, predictions: [Vec2])] = []
    /// The check dots' frames, on which both fitted models are compared.
    private var checkFeatures: [(target: Vec2, features: [GazeFeatures])] = []
    private var distances: [Double] = []

    init() {
        guard let url = Bundle.main.url(forResource: "balance", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let cfg = try? BalanceConfig.load(from: data) else {
            fatalError("balance.json is missing or invalid")
        }
        balance = cfg
        rhythmTracks = Bundle.main.url(forResource: "tracks", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? RhythmTrack.load(from: $0) } ?? []
        blinkDetector = BlinkDetector(cfg.energy ?? EnergyConfig())
        status.reloadBlinksNeeded = (cfg.energy ?? EnergyConfig()).reloadBlinks
        if !FaceTracker.isSupported { mode = .touch }
        if let bot = autoplay {
            // CI smoke test in the Simulator: skip the menu and let the bot play.
            if bot == "wink" {
                route = .winkTest
                startWinkBot()
            } else if bot == "rhythm" {
                mode = .eyes
                route = .rhythm
            } else if bot == "pursuit" {
                mode = .eyes
                route = .pursuit
            } else if bot == "probe" {
                // The clinic's flow for the Simulator: a made-up child with a course, then the probe played by the bot.
                mode = .eyes
                #if DEBUG
                if let id = clinic.makeBotChild() { pick(child: id) }
                #endif
                route = .probe
            } else {
                mode = bot == "eyes" ? .eyes : .touch
                route = .game
            }
        }
        #if DEBUG
        if let demo = demoReport {
            // Made-up plays for the CI screenshots of the report, in memory only: nothing goes into the history file.
            sessions = Self.demoSessions()
            childCode = "К-07"
            if demo == "summary" { lastSummary = sessions.last { $0.game == .meteors && $0.childCode == "К-07" } }
        }
        #endif
        tracker.onSample = { [weak self] s in self?.handle(s) }
        tracker.onInfo = { [weak self] info in
            self?.status.tracking = info
            self?.logTracking()
        }
        // The plays an older build kept in sessions.json become the clinic's first children, once.
        #if DEBUG
        if demoReport == nil, autoplay == nil { clinic.migrate(sessions) }
        #else
        clinic.migrate(sessions)
        #endif
        // A child picked on «Кто играет?» plays under their code, so the plays and the sessions agree.
        if let c = clinic.playing { childCode = c.child.code }
    }

    /// The child picked on «Кто играет?»: the plays from now on are saved under their code.
    /// Another child takes the phone: the last child's calibration and aim learning do not fit their eyes, and their
    /// frames must not go into this child's CSV. So the calibration is dropped and the new child's own one starts
    /// at once, with a new CSV; its result leads back here.
    func pick(child id: UUID) {
        let changed = clinic.playingID != id
        clinic.playingID = id
        if let c = clinic.record(id) { childCode = c.child.code }
        guard changed else { return }
        dropCalibration()
        gaze = .lost
        if eyeTrackingSupported, autoplay == nil {
            beginCalibration(then: route == .clinic ? .clinic : .menu)
        } else {
            logger = SessionLogger()
            logTracking()
        }
    }

    /// Forgets the session's calibration and everything learned on it: another child, or night vision switched.
    /// The next eye mode calibrates first, and the next launch does not bring the old one back.
    private func dropCalibration() {
        calibration = nil
        stash = nil
        report = nil
        clearLive()
        UserDefaults.standard.removeObject(forKey: Self.keptCalibrationKey)
    }

    /// Plays on a calibration made before: its models, check, grip and report, with a fresh aim adapter.
    private func adopt(_ c: SessionCalibration) {
        fitted = (c.head, c.screen)
        modelCheck = (c.headMissPt, c.screenMissPt)
        grip = (c.reference, c.distanceM)
        report = c.report
        play(c.model)
    }

    // MARK: the calibration kept between launches

    /// Where the session's calibration is kept between launches (`StoredCalibration`, as JSON).
    private static let keptCalibrationKey = "keptCalibration"

    /// The app's version and build, e.g. "1.0.3 (7)": a calibration kept by another build is not used.
    private static let build: String = {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }()

    /// The window's size (screen pt): every eye mode fills it, the calibration's dots included.
    private var windowSize: Vec2? {
        guard let s = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let b = s.coordinateSpace.bounds.size
        return Vec2(Double(b.width), Double(b.height))
    }

    /// Keeps the session's new calibration on this phone, so that the next launch within 12 hours plays on it.
    private func keepCalibration(_ c: SessionCalibration) {
        guard let w = windowSize else { return }
        let kept = StoredCalibration(model: c.model, head: c.head, screenFit: c.screen, headMissPt: c.headMissPt,
                                     screenMissPt: c.screenMissPt, report: c.report, reference: c.reference,
                                     distanceM: c.distanceM, childID: c.childID, madeAt: c.madeAt, night: nightVision,
                                     screenPt: w, build: Self.build)
        guard let data = try? JSONEncoder().encode(kept) else { return }
        UserDefaults.standard.set(data, forKey: Self.keptCalibrationKey)
    }

    /// iOS ends an app it has sent to the background whenever it wants the memory, so coming back to the game is
    /// often a new launch. The calibration kept from an earlier launch plays again when it is the same child's, with
    /// the same night vision, on this screen and build, and less than 12 hours old. The aim adapter starts afresh and
    /// learns again in play; the new session CSV says which model plays. False: there is none that fits.
    private func restoreKeptCalibration() -> Bool {
        guard let w = windowSize, let data = UserDefaults.standard.data(forKey: Self.keptCalibrationKey),
              let kept = try? JSONDecoder().decode(StoredCalibration.self, from: data),
              kept.fits(child: clinic.playingID, night: nightVision, screenPt: w, build: Self.build, now: Date()),
              let m = kept.model else { return false }
        let c = SessionCalibration(model: m, shadow: kept.shadow, head: kept.head, screen: kept.screenFit,
                                   headMissPt: kept.headMissPt, screenMissPt: kept.screenMissPt, report: kept.report,
                                   reference: kept.reference, distanceM: kept.distanceM, childID: kept.childID,
                                   madeAt: kept.madeAt)
        adopt(c)
        calibration = c
        logModel()
        return true
    }

    /// Clears the models the frames are read with: a new calibration is being made, or there is none.
    private func clearLive() {
        model = nil
        shadowModel = nil
        fitted = (nil, nil)
        modelCheck = (nil, nil)
        adapter = nil
        aimCorrection = .zero
        recentRaw = []
        resetGazeFilters()
    }

    /// Sets the model that plays and the one that only shadows it, with a fresh aim adapter for the playing one.
    private func play(_ m: GazeModel?) {
        model = m
        switch m {
        case .some(.head): shadowModel = fitted.screen.map { GazeModel.screen($0) }
        case .some(.screen): shadowModel = fitted.head.map { GazeModel.head($0) }
        case .none: shadowModel = nil
        }
        aimCorrection = .zero
        recentRaw = []
        resetGazeFilters()
        // The adapter's tilt terms are measured from the grip the model was fitted at.
        var config = GazeAdapterConfig()
        // The head-frame model turns its aim with the head by geometry, so no follow of the head is assumed for it:
        // the adapter starts from no correction and adds only what the labels show.
        if case .some(.head) = m {
            config.followPitch = 0
            config.followYaw = 0
        }
        adapter = m == nil ? nil : grip.reference.map { GazeAdapter(reference: $0, distanceM: grip.distanceM, config: config) }
    }

    /// Starts the aim filters and the looking-away gate afresh.
    private func resetGazeFilters() {
        filter.reset()
        probeFilter.reset()
        awayGate.reset()
        probeGaze = nil
    }

    /// Writes the camera format and device state into the current session CSV.
    private func logTracking() {
        let i = tracker.info
        logger.tracking(format: i.format, offered: i.offered, thermal: i.thermal, lowPower: i.lowPower,
                        screen: i.screen, vision: i.vision, night: i.night, time: CACurrentMediaTime())
        logModel()
    }

    /// Writes which gaze model plays, and how both did on the check dots, into the current session CSV. A session
    /// started after the calibration (a wink test, another child's file) says so too.
    private func logModel() {
        guard let m = model else { return }
        logger.model(time: CACurrentMediaTime(), name: m.name, headMissPt: modelCheck.headMissPt,
                     screenMissPt: modelCheck.screenMissPt)
    }

    /// Night vision lights the face with the screen: full brightness on every screen but the menu, while the app
    /// is in front. The player's own brightness comes back on the menu and when the app leaves the screen.
    private func applyBrightness() {
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.screen else { return }
        if nightVision && active && route != .menu {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            screen.brightness = 1
        } else if let b = savedBrightness {
            screen.brightness = b
            savedBrightness = nil
        }
    }

    func scenePhaseChanged(active: Bool) {
        self.active = active
        applyBrightness()
        updateAmbient()
        // A warm-up that was interrupted is not a minute of following: it ends without a result. Nor is a probe.
        if !active, route == .pursuit { route = .menu }
        if !active, route == .probe, probe?.phase != .done { route = .clinic }
        guard var p = meteorPlay else { return }
        let now = CACurrentMediaTime()
        if active {
            if p.since == nil { p.since = now }
        } else if let since = p.since {
            p.shownSec += now - since
            p.since = nil
        }
        meteorPlay = p
        // iOS may end an app in the background without a word, so the play so far goes into the history now.
        if !active { saveMeteorPlay() }
    }

    var eyeTrackingSupported: Bool { FaceTracker.isSupported }

    /// The rhythm mode plays by eye where face tracking works, and for the Simulator bot, which aims by itself.
    var rhythmByEye: Bool { eyeTrackingSupported || autoplay == "rhythm" }

    /// The only way the app's screen is held (Info.plist: UIInterfaceOrientationLandscapeRight, front camera on the
    /// left). Gaze calibration does not survive turning the phone half a turn, because the camera moves to the other
    /// side of the screen, so the app does not offer the other landscape side.
    static let screenOrientation = ScreenOrientation.landscapeRight

    func startTracking() {
        if FaceTracker.isSupported { tracker.start(orientation: Self.screenOrientation, night: nightVision) }
    }

    private func handle(_ s: TrackingSample) {
        lastSampleTime = s.timestamp
        // The warm-up's dot and its minute wait while the camera does not see the face.
        if route == .pursuit, mode == .eyes, let p = pursuit { p.face(found: s.features != nil, host: s.timestamp) }
        // This frame's aim of the playing model before the correction and the filter, and the other model's aim
        // (screen pt), for the session CSV.
        var rawAim: Vec2?, altAim: Vec2?
        var blink = BlinkUpdate(freezeGaze: false, eyesClosed: false, blinkEnded: nil, reload: false)
        if s.features != nil, let b = s.blink {
            blink = blinkDetector.update(time: s.timestamp, left: b.left, right: b.right)
            if let dur = blink.blinkEnded {
                status.blinksTotal += 1
                if route == .game { logger.event(kind: "blink", time: s.timestamp, blinkSec: dur) }
            }
            if blink.reload { pendingReloadTime = s.timestamp }
        } else {
            blinkDetector.faceLost()
        }

        if route == .winkTest || route == .rhythm {
            if s.features != nil, let b = s.blink {
                if let e = winkDetector.update(time: s.timestamp, left: b.left, right: b.right) {
                    logger.wink(e)
                    if route == .winkTest {
                        winks.append(e)
                        status.lastWink = e
                    } else {
                        // The gaze is still held from before the lid moved (the blink detector froze it), so this
                        // is where the player aimed.
                        rhythmClosure(e)
                    }
                }
            } else {
                winkDetector.faceLost()
            }
        }

        gazeHeld = s.features != nil && blink.freezeGaze
        probeGaze = nil
        if s.features != nil, blink.freezeGaze {
            // Eyelid closing: the pupils drift down and the prediction dips, so keep the last gaze point
            // (screen pt) and do not feed the filter. Eyes shut longer than a blink count as tracking lost.
            let maxBlink = (balance.energy ?? EnergyConfig()).blink.maxClosedSec
            if model == nil {
                gaze = .notLooking
            } else if blinkDetector.closedFor(at: s.timestamp) > maxBlink {
                gaze = .lost
            } else if case .point = gaze {
                // hold
            } else {
                gaze = .lost
            }
        } else if let f = s.features {
            if let m = model {
                let raw = m.predict(f)
                let out = raw == nil || m.looksOut(f)
                rawAim = raw
                altAim = shadowModel?.predict(f)
                if awayGate.looksAway(out: out, t: s.timestamp) {
                    // The eyes have pointed well off the screen for a while (a glance away). Hide the aim instead
                    // of extrapolating, and start the filters afresh so the aim does not swing back in from far away.
                    filter.reset()
                    probeFilter.reset()
                    gaze = .notLooking
                } else if out {
                    // One stray frame past the range while the eyes sweep after a moving target: the aim keeps its
                    // last point, like over a blink, and the filters are not fed the outlier.
                    if case .point = gaze { gazeHeld = true } else { gaze = .notLooking }
                } else if let raw {
                    let pose = HeadPose(f)
                    recentRaw.append((s.timestamp, raw, pose))
                    if let i = recentRaw.firstIndex(where: { $0.time >= s.timestamp - 0.6 }), i > 0 {
                        recentRaw.removeFirst(i)
                    }
                    if route == .game, mode == .eyes, let target = lookedAtMeteor {
                        adapter?.learn(raw: raw, target: target, pose: pose, time: s.timestamp, weight: Self.meteorLabelWeight)
                    }
                    if route == .pursuit, mode == .eyes, let p = pursuit, p.phase == .running, !p.waitingForFace {
                        // The warm-up's dot teaches the aim the way a meteor being burned does, but only while the
                        // model's own aim travels with the dot: resting eyes or a glance elsewhere teach nothing.
                        let target = p.target(host: s.timestamp)
                        if followGate.add(t: s.timestamp, aim: raw, target: target),
                           adapter?.learn(raw: raw, target: target, pose: pose, time: s.timestamp,
                                          weight: Self.meteorLabelWeight) == true {
                            p.taught += 1
                        }
                    }
                    aimCorrection = adaptAim ? (adapter?.correction(pose: pose) ?? .zero) : .zero
                    gaze = .point(filter.filter(raw + aimCorrection, t: s.timestamp))
                    probeGaze = probeFilter.filter(raw, t: s.timestamp)
                }
            } else {
                gaze = .notLooking
            }
            if let c = collecting {
                // Frames inside a blink are skipped above, so they never reach the calibration set.
                collectedFeatures.append(f)
                if case .point(let p) = gaze { collectedGaze.append(p) }
                distances.append(f.distance)
                logger.sample(kind: c.kind, time: s.timestamp, target: c.target, gaze: gazePoint, f: f, blink: s.blink, hold: false,
                              processingMs: s.processingMs, light: s.light, raw: rawAim, alt: altAim)
            }
        } else {
            gaze = .lost
        }
        if route == .game, mode == .eyes, let f = s.features {
            logger.sample(kind: "frame", time: s.timestamp, target: lookedAtMeteor, gaze: gazePoint, f: f,
                          blink: s.blink, hold: blink.freezeGaze, processingMs: s.processingMs,
                          correction: adapter == nil ? nil : aimCorrection, light: s.light, raw: rawAim, alt: altAim)
        }
        if route == .rhythm, let f = s.features {
            logger.sample(kind: "rhythm_frame", time: s.timestamp, target: nil, gaze: gazePoint, f: f,
                          blink: s.blink, hold: blink.freezeGaze, processingMs: s.processingMs,
                          correction: adapter == nil ? nil : aimCorrection, locked: rhythm?.lock.locked, light: s.light, raw: rawAim, alt: altAim)
        }
        if route == .winkTest, let f = s.features {
            logger.sample(kind: "wink_frame", time: s.timestamp, target: nil, gaze: gazePoint, f: f,
                          blink: s.blink, hold: false, processingMs: s.processingMs, light: s.light, raw: rawAim, alt: altAim)
        }
        if let f = s.features {
            // The eyes' distance to the screen (cm), smoothed: the probe lays its field out at it.
            let d = f.distance * 100
            faceDistanceCm = faceDistanceCm.map { $0 + (d - $0) * 0.1 } ?? d
        }
        if route == .probe, let p = probe, p.phase == .running {
            // Every tracked frame of the probe, with the target it shows, into the session's CSV.
            let host = s.timestamp
            p.sample(host: host, gaze: probeGazePoint, distanceCm: s.features.map { $0.distance * 100 }, fps: s.fps, light: s.light)
            if let f = s.features {
                let t = p.time(host: host)
                let target = p.gliderPosition(host: host) ?? p.plan.scheduledTarget(at: t).map { p.targetPosition($0.index) }
                logger.sample(kind: "probe_frame", time: host, target: target, gaze: probeGazePoint, f: f, blink: s.blink,
                              hold: blink.freezeGaze, processingMs: s.processingMs, light: s.light, raw: rawAim, alt: altAim)
            }
        }
        if route == .pursuit, mode == .eyes, let p = pursuit, p.phase == .running {
            // Every tracked frame of the warm-up: the distance from the gaze to the target (screen pt). A frame
            // with no face, or with the eyes away from the screen, counts as off the target.
            let target = p.sample(host: s.timestamp, gaze: gazePoint)
            if let f = s.features {
                logger.sample(kind: "pursuit_frame", time: s.timestamp, target: target ?? p.target(host: s.timestamp),
                              gaze: gazePoint, f: f, blink: s.blink, hold: blink.freezeGaze, processingMs: s.processingMs,
                              correction: adapter == nil ? nil : aimCorrection, light: s.light, raw: rawAim, alt: altAim)
            }
        }
        // The wink test draws the eyelids live, so it gets the numbers 30 times a second.
        if s.timestamp - lastStatusPush > (route == .winkTest ? 1.0 / 30 : 0.1) {
            lastStatusPush = s.timestamp
            status.fps = s.fps
            status.processingMs = s.processingMs
            status.faceFound = s.features != nil
            status.features = s.features
            status.light = s.light
            status.gaze = gazePoint
            status.blink = s.blink
            status.blinkBase = blinkDetector.openLevel()
            status.gazeFrozen = blink.freezeGaze
            status.pendingBlinks = blinkDetector.pendingBlinks(at: s.timestamp)
            if route == .winkTest { status.winkCloseLevel = winkDetector.closeLevel() }
            if showDebug {
                status.aimCorrection = aimCorrection
                status.aimLabels = adapter?.learned ?? 0
                status.aimRejected = adapter?.rejected ?? 0
            }
        }
    }

    /// The game takes a 3-blink reload once. A reload older than half a second is dropped, so blinks made
    /// on a menu or while paused do not fire later.
    func consumeBlinkReload() -> Bool {
        guard let t = pendingReloadTime else { return false }
        pendingReloadTime = nil
        return lastSampleTime - t < 0.5
    }

    /// Blinks counted so far toward the next reload, for the HUD.
    var pendingBlinks: Int { blinkDetector.pendingBlinks(at: lastSampleTime) }

    func logGameEvent(kind: String, energy: Int, level: Int) {
        logger.event(kind: kind, time: CACurrentMediaTime(), energy: energy, level: level)
    }

    var gazePoint: Vec2? {
        #if DEBUG
        if let a = botAim { return a }
        #endif
        if case .point(let p) = gaze { return p }
        return nil
    }

    /// What the probe scores (screen pt): `probeGaze`, or the bot's aim in a test run.
    var probeGazePoint: Vec2? {
        #if DEBUG
        if let a = botAim { return a }
        #endif
        return probeGaze
    }

    // MARK: wink test

    /// Opens the wink test with a fresh session CSV, so «Экспорт CSV» sends just the test.
    func beginWinkTest() {
        logger = SessionLogger()
        logTracking()
        winkDetector = WinkDetector()
        winks = []
        status.lastWink = nil
        route = .winkTest
    }

    /// A run starts: its first click sounds at `time`. Closures from before it are dropped.
    func startWinkRun(plan: WinkTestPlan, time: Double, audioLatency: Double) {
        winks = []
        status.lastWink = nil
        logger.winkTest(time: time, periodSec: plan.periodSec, audioLatency: audioLatency)
        if autoplay == "wink" { winkBot = WinkBot(plan: plan, start: time) }
    }

    /// Simulator smoke test (`-SpantherAutoplay wink`): a scripted player's eyelids go through `handle` 60 times a
    /// second, as if ARKit had sent them, with a face that looks straight at the screen.
    private var winkBot: WinkBot?
    private var botTimer: Timer?

    private func startWinkBot() {
        let face = GazeFeatures(lookAtHit: .zero, eyeAxisHit: .zero, yaw: 0, pitch: 0, roll: 0, distance: 0.35, pupils: nil)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = CACurrentMediaTime()
            let lids = self.winkBot?.lids(at: t) ?? (left: 0.1, right: 0.1)
            self.handle(TrackingSample(timestamp: t, features: face, blink: lids, processingMs: 0.5, fps: 60))
        }
        RunLoop.main.add(timer, forMode: .common)
        botTimer = timer
    }

    func logWinkCue(side: WinkSide, time: Double) { logger.cue(side: side, time: time) }

    // MARK: rhythm mode

    /// Opens the rhythm mode's track list.
    func openRhythm() {
        rhythm?.stop()
        rhythm = nil
        route = .rhythm
    }

    /// Lays a track out for play on a screen this size (pt) and shows its start star.
    func prepareRhythm(track: RhythmTrack, level: RhythmLevel, screen: Vec2) {
        rhythm?.stop()
        winkDetector = WinkDetector()
        rhythmSummary = nil
        rhythm = RhythmSession(track: track, level: level, screen: screen,
                               measuredErrorPt: mode == .eyes ? report?.meanErrorPt : 0,
                               latencySec: RhythmRecords.latencySec, targetScale: targetScale, zoneFloorPt: zoneFloorPt)
        startRhythmTimer()
    }

    /// Back to the track list, from play or from the results.
    func leaveRhythmPlay() {
        rhythm?.stop()
        rhythm = nil
        rhythmTimer?.invalidate()
        rhythmTimer = nil
        #if DEBUG
        botAim = nil
        #endif
    }

    /// The start star was winked at or touched at `host`: the aim is recentred on it and the music starts.
    private func startRhythm(at host: Double) {
        guard let s = rhythm, s.phase == .ready else { return }
        if mode == .eyes { learnLabel(target: s.startPoint, before: host, source: "start") }
        guard s.begin(host: CACurrentMediaTime()), let start = s.startHost else { return }
        logger.rhythmStart(time: start, track: s.track.id, level: s.level.rawValue, beatSec: s.track.beatSec,
                           audioLatency: s.outputLatency, latency: s.judge.latencySec, notes: s.notes.count)
    }

    /// An eye closure from the wink detector, while the rhythm mode is open.
    private func rhythmClosure(_ e: WinkEvent) {
        guard let s = rhythm else { return }
        switch s.phase {
        case .ready:
            // A wink starts the track. An ordinary blink does not: everyone blinks while reading the screen.
            if e.side != .both { startRhythm(at: e.onset) }
        case .playing:
            // The gaze is still held from before the lid moved, so the lock is where the player aimed.
            let aim = gazePoint
            s.updateLock(aim: aim, host: CACurrentMediaTime())
            let rejectedBefore = s.judge.lastRejected
            if let hit = s.closure(side: e.side, host: e.onset, aim: aim) {
                record(hit, in: s, host: e.onset, side: e.side.rawValue, aim: aim, locked: s.lock.locked)
            } else if let r = s.judge.lastRejected, r != rejectedBefore {
                logger.rhythmReject(time: e.onset, index: r.index, reason: r.reason.rawValue, side: e.side.rawValue,
                                    distance: r.distanceSec)
            }
        case .done:
            break
        }
    }

    /// A finger on the rhythm screen: it starts the track on the start star, and plays the notes in touch mode.
    func rhythmTouch(at p: Vec2) {
        guard let s = rhythm else { return }
        let now = CACurrentMediaTime()
        switch s.phase {
        case .ready:
            if mode == .touch || p.distance(to: s.startPoint) < 100 { startRhythm(at: now) }
        case .playing:
            guard mode == .touch, let hit = s.tap(at: p, host: now) else { return }
            record(hit, in: s, host: now, side: p.x < s.screen.x / 2 ? "left" : "right", aim: p, locked: nil)
        case .done:
            break
        }
    }

    private func record(_ hit: RhythmJudge.Hit, in s: RhythmSession, host: Double, side: String, aim: Vec2?, locked: Int?) {
        let target = s.points[hit.index]
        logger.rhythmNote(hit: true, time: host, index: hit.index, target: target, judgement: hit.judgement.rawValue,
                          offset: hit.offsetSec, aimDistance: aim.map { $0.distance(to: target) }, side: side, locked: locked)
        // The closure landed in this note's window, so the note is where the player meant to look.
        if mode == .eyes { learnLabel(target: target, before: host, source: "rhythm") }
    }

    private func startRhythmTimer() {
        rhythmTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.rhythmTick() }
        RunLoop.main.add(t, forMode: .common)
        rhythmTimer = t
    }

    private func rhythmTick() {
        guard let s = rhythm, route == .rhythm else {
            rhythmTimer?.invalidate()
            rhythmTimer = nil
            return
        }
        let now = CACurrentMediaTime()
        #if DEBUG
        rhythmBotStep(s, now)
        #endif
        // The aim is not drawn: the note (or the start star) it is locked on lights up instead.
        s.updateLock(aim: mode == .eyes ? gazePoint : nil, host: now)
        guard s.phase == .playing else { return }
        for d in s.takeStartedDistractions(host: now) {
            let at: Vec2?
            switch d.kind {
            case .firefly, .seed: at = d.position(at: d.start)
            case .bloom, .swing: at = s.garden.lianaPoints(d.index, time: now).last
            case .surge: at = s.garden.path(tree: d.index, to: d.tip, time: now).last
            }
            logger.distraction(time: now, kind: d.kind.rawValue, at: at)
        }
        for i in s.tick(host: now) {
            logger.rhythmNote(hit: false, time: now, index: i, target: s.points[i], judgement: Judgement.miss.rawValue,
                              offset: nil, aimDistance: nil, side: nil)
        }
        if s.phase == .done {
            rhythmTimer?.invalidate()
            rhythmTimer = nil
            if s.judge.count(.perfect) + s.judge.count(.good) + s.judge.count(.ok) >= 5 {
                RhythmRecords.latencySec = s.judge.latencySec
            }
            s.isNewBest = RhythmRecords.save(s.track, s.level, score: s.judge.score, stars: s.judge.stars)
            logger.rhythmEnd(time: now, score: s.judge.score, accuracy: s.judge.accuracy, latency: s.judge.latencySec)
            let played = now - (s.startHost ?? now)
            let summary = SessionSummary.rhythm(id: UUID().uuidString, childCode: currentChildCode,
                                                start: Date().addingTimeInterval(-played), durationSec: played,
                                                byEye: mode == .eyes,
                                                calibrationErrorCm: mode == .eyes ? report?.meanErrorCm : nil,
                                                track: s.track.title, level: s.level, judge: s.judge,
                                                targetScale: s.targetScale)
            keep(summary)
            rhythmSummary = summary
        }
    }

    /// Teaches the aim adapter that the player looked at `target` (screen pt) just before `host`, an eye closure
    /// or a tap: the raw predictions of the 0.3 s before it with open eyes (median per axis) and the pose then.
    @discardableResult
    private func learnLabel(target: Vec2, before host: Double, source: String) -> Bool {
        let frames = recentRaw.filter { $0.time <= host && $0.time >= host - 0.3 }
        guard adapter != nil, frames.count >= 3 else { return false }
        let raw = Vec2(Self.median(frames.map { $0.raw.x }), Self.median(frames.map { $0.raw.y }))
        let pose = HeadPose(pitch: Self.median(frames.map { $0.pose.pitch }), yaw: Self.median(frames.map { $0.pose.yaw }))
        let ok = adapter?.learn(raw: raw, target: target, pose: pose, time: host) ?? false
        logger.label(time: host, source: source, target: target, raw: raw, pitch: pose.pitch, yaw: pose.yaw,
                     accepted: ok, correction: adapter?.correction(pose: pose) ?? .zero)
        return ok
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The wink test's mean delay from the click to the eye closing seeds the rhythm judge's delay.
    func rememberWinkDelay(_ stats: WinkStats) {
        let hits = stats.left.hits + stats.right.hits
        guard hits >= 10 else { return }
        let mean = (stats.left.meanOffsetMs * Double(stats.left.hits) + stats.right.meanOffsetMs * Double(stats.right.hits)) / Double(hits)
        RhythmRecords.latencySec = mean / 1000
    }

    #if DEBUG
    /// Simulator smoke test (`-SpantherAutoplay rhythm`): looks a little off each note's centre and winks the asked
    /// eye about 0.1 s after the beat, misses every eleventh note and, on hard, winks the wrong eye now and then.
    private(set) var botAim: Vec2?
    private var botPlayed = Set<Int>()
    private var botReadySince: Double?

    private func rhythmBotStep(_ s: RhythmSession, _ now: Double) {
        guard autoplay == "rhythm" else { return }
        switch s.phase {
        case .ready:
            botAim = s.startPoint + Vec2(10, -6)
            botPlayed = []
            if botReadySince == nil { botReadySince = now }
            if now - (botReadySince ?? now) > 6 {
                botReadySince = nil
                rhythmClosure(WinkEvent(side: .left, onset: now - 0.02, decided: now, otherPeak: 0.2))
            }
        case .playing:
            let t = s.trackTime(host: now)
            if let i = s.nextOpen(after: t) {
                botAim = s.points[i] + Vec2(Double(i % 5) * 6 - 12, Double(i % 3) * 8 - 8)
            }
            for (i, n) in s.notes.enumerated() where !botPlayed.contains(i) {
                let late = 0.1 + Double((i * 37) % 13 - 6) * 0.01
                guard t >= n.time + late else { break }
                botPlayed.insert(i)
                if i % 11 == 7 { continue }
                var side: WinkSide = n.side == .right ? .right : n.side == .left ? .left : (i % 2 == 0 ? .left : .right)
                if s.level == .hard, i % 17 == 9 { side = side == .left ? .right : .left }
                rhythmClosure(WinkEvent(side: side, onset: now, decided: now + 0.03, otherPeak: 0.2))
            }
        case .done:
            botAim = nil
        }
    }
    #endif

    // MARK: warm-up

    /// The warm-up in progress (made by its screen, which knows its size).
    @Published private(set) var pursuit: PursuitSession?
    /// Touch mode: where the finger is on the warm-up screen (screen pt), nil when it is up.
    var pursuitTouch: Vec2?
    private var pursuitTimer: Timer?

    /// Opens the warm-up by eye (calibrating first when there is no calibration yet) or by finger.
    func openPursuit(byEye: Bool) {
        mode = byEye ? .eyes : .touch
        if byEye, model == nil {
            beginCalibration(then: .pursuit)
            return
        }
        route = .pursuit
    }

    /// The warm-up screen is up on a screen this size (pt): the target rests for three seconds, then moves.
    func beginPursuit(screen: Vec2) {
        guard route == .pursuit, pursuit == nil else { return }
        let now = CACurrentMediaTime()
        let p = PursuitSession(screen: screen, byEye: mode == .eyes, measuredErrorPt: report?.meanErrorPt,
                               targetScale: targetScale, now: now)
        pursuit = p
        playFX = p.fx
        pursuitTouch = nil
        followGate.reset()
        logger.pursuitStart(time: p.startHost, radiusPt: p.radiusPt, durationSec: p.plan.durationSec)
        pursuitTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.pursuitTick() }
        RunLoop.main.add(t, forMode: .common)
        pursuitTimer = t
    }

    private func pursuitTick() {
        guard let p = pursuit, route == .pursuit else {
            pursuitTimer?.invalidate()
            pursuitTimer = nil
            return
        }
        let now = CACurrentMediaTime()
        #if DEBUG
        let bot = autoplay == "pursuit"
        if bot { pursuitBotStep(p, now) }
        #else
        let bot = false
        #endif
        // By eye the frames are counted as the tracking delivers them (`handle`); by finger and for the bot, here.
        if mode == .touch || bot, p.phase == .running {
            p.sample(host: now, gaze: mode == .touch ? pursuitTouch : gazePoint)
        }
        guard p.tick(host: now) else { return }
        // No frame at all (the camera never delivered one): there is nothing to report.
        guard !p.tally.isEmpty else {
            route = .menu
            return
        }
        let summary = SessionSummary.pursuit(id: UUID().uuidString, childCode: currentChildCode,
                                             start: Date().addingTimeInterval(-p.plan.durationSec),
                                             durationSec: p.plan.durationSec, byEye: p.byEye,
                                             calibrationErrorCm: p.byEye ? report?.meanErrorCm : nil,
                                             tally: p.tally, ptPerCm: ptPerCm)
        logger.pursuitEnd(time: now, onTarget: p.tally.all.share, meanDistancePt: p.tally.meanDistancePt,
                          taught: p.byEye ? p.taught : nil)
        keep(summary)
        route = .menu
        lastSummary = summary
    }

    /// The warm-up screen closed: an unfinished warm-up leaves no result.
    private func dropPursuit() {
        pursuitTimer?.invalidate()
        pursuitTimer = nil
        pursuit = nil
        pursuitTouch = nil
        #if DEBUG
        botAim = nil
        #endif
    }

    #if DEBUG
    /// Simulator smoke test (`-SpantherAutoplay pursuit`): follows the target a little late and a little off, has no
    /// gaze for three seconds of the horizontal part and stares into a corner for three seconds of the eight.
    private func pursuitBotStep(_ p: PursuitSession, _ now: Double) {
        let t = p.time(host: now)
        if t >= 12, t < 15 {
            botAim = nil
        } else if t >= 44, t < 47 {
            botAim = Vec2(40, 40)
        } else {
            botAim = p.target(host: now - 0.12) + Vec2(18, -12)
        }
    }
    #endif

    // MARK: probe

    /// The probe in progress (made by its screen, which knows its size).
    @Published private(set) var probe: ProbeSession?
    /// The last probe's outcome, for its summary card: the session as recorded and why it stays off the chart.
    @Published private(set) var probeOutcome: (session: Session, issues: [ProbeQuality.Issue])?
    @Published private(set) var probePreparing = false
    private var probeTimer: Timer?
    /// The eyes' distance to the screen (cm), smoothed over the last frames; nil before the first face.
    private(set) var faceDistanceCm: Double?

    /// Starts a session's probe for the child picked on «Кто играет?», calibrating first when there is no
    /// calibration yet. The probe is by eye only: it measures the gaze.
    func openProbe() {
        guard clinic.playing != nil, eyeTrackingSupported || autoplay == "probe" else { return }
        mode = .eyes
        probeOutcome = nil
        // The probe measures this child's gaze, so it runs on this child's own calibration only.
        if autoplay != "probe", model == nil || calibration?.childID != clinic.playingID {
            beginCalibration(then: .probe)
            return
        }
        route = .probe
    }

    /// The probe screen is up on a screen this size (pt): the form is drawn from a fresh seed off the main thread
    /// (one whose zone order this child has not seen), laid out at the eyes' distance, and the probe starts.
    func beginProbe(screen: Vec2) {
        guard route == .probe, probe == nil, !probePreparing else { return }
        guard let child = clinic.playing else {
            route = .clinic
            return
        }
        probePreparing = true
        let rules = child.openCourse.flatMap { ProbeProtocol.version($0.probeVersion) } ?? .latest
        let past = child.sessions + child.voided
        let seed = UInt64.random(in: 0...ProbePlan.seedMask)
        let mapping = FieldMapping(size: screen, ptPerCm: ptPerCm, distanceCm: faceDistanceCm ?? 30,
                                   fieldHalfWidthDeg: rules.fieldHalfWidthDeg, fieldHalfHeightDeg: rules.fieldHalfHeightDeg)
        let radius = rules.hitRadiusDeg(calibrationErrorDeg: report?.meanErrorDeg)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = ProbePlan.fresh(from: seed, avoiding: ClinicModel.signatures(of: past), rules: rules)
            DispatchQueue.main.async {
                guard let self else { return }
                self.probePreparing = false
                guard self.route == .probe, let plan else {
                    if self.route == .probe { self.route = .clinic }
                    return
                }
                let p = ProbeSession(plan: plan, mapping: mapping, radiusDeg: radius, childID: child.id,
                                     now: CACurrentMediaTime())
                self.probe = p
                self.logger.event(kind: "probe_start", time: p.startHost)
                self.probeTimer?.invalidate()
                let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.probeTick() }
                RunLoop.main.add(t, forMode: .common)
                self.probeTimer = t
            }
        }
    }

    private func probeTick() {
        guard let p = probe, route == .probe else {
            probeTimer?.invalidate()
            probeTimer = nil
            return
        }
        let now = CACurrentMediaTime()
        #if DEBUG
        if autoplay == "probe" {
            // The Simulator has no face: the bot looks at what the probe shows, a reaction late, and samples itself.
            let t = p.time(host: now - 0.3)
            botAim = p.gliderPosition(host: now - 0.12) ?? p.plan.scheduledTarget(at: t).map { p.targetPosition($0.index) }
            p.sample(host: now, gaze: botAim, distanceCm: 32, fps: 60, light: 800)
        }
        #endif
        guard p.tick(host: now) else { return }
        finishProbe(p)
    }

    /// The probe has run its time: the quality gate, the result, and the session written to the child's log with the
    /// raw CSV next to it. A session that fails the gate is kept, marked, and left off the trend.
    private func finishProbe(_ p: ProbeSession) {
        probeTimer?.invalidate()
        probeTimer = nil
        let record = clinic.record(p.childID)
        let conditions = p.conditions(calibrationErrorCm: report?.meanErrorCm, night: nightVision)
        let metrics = p.run.metrics()
        let issues = ProbeQuality.issues(conditions: conditions, metrics: metrics, completed: p.run.finished,
                                         maxErrorCm: ProbeQuality.maxErrorCm(sessionStart: p.start, birthYear: record?.child.birthYear))
        let result = p.run.result(qualityPassed: issues.isEmpty)
        let course = record?.openCourse
        let number = course.flatMap { c in record?.nextNumber(in: c.id) }
        let session = Session(courseID: course?.id, number: number, start: p.start, durationSec: p.plan.rules.durationSec,
                              place: course?.runsAt ?? .clinic, conditions: conditions, probe: result)
        logger.event(kind: "probe_end", time: CACurrentMediaTime())
        clinic.recordSession(session, child: p.childID, csv: logger.url)
        probeOutcome = (session, issues)
        #if DEBUG
        botAim = nil
        #endif
    }

    /// The probe screen closed: an unfinished probe leaves no session.
    private func dropProbe() {
        probeTimer?.invalidate()
        probeTimer = nil
        probe = nil
        probePreparing = false
    }

    // MARK: calibration

    /// The start screen has let the player in: on an iPhone that tracks faces, the session's one calibration comes
    /// first, and every mode plays on it. The same child's calibration from a launch less than 12 hours ago is that one
    /// (`restoreKeptCalibration`). The CI bots and the report screenshots go without.
    func openSession() {
        guard eyeTrackingSupported, model == nil, route == .menu, autoplay == nil else { return }
        #if DEBUG
        guard demoReport == nil else { return }
        #endif
        if restoreKeptCalibration() { return }
        beginCalibration(then: .menu)
    }

    /// «Играть глазами» on the meteors: on the session's calibration, or after one when there is none yet.
    func playMeteorsByEye() {
        mode = .eyes
        if model == nil {
            beginCalibration(then: .game)
        } else {
            route = .game
        }
    }

    /// Starts a calibration; its result then leads to `next` (`continueAfterCalibration`). The session's calibration
    /// stays in force until the new one has passed its check dots: leaving before that brings it back.
    func beginCalibration(then next: Route) {
        afterCalibration = next
        stash = calibration == nil ? nil : (adapter, logger)
        clearLive()
        calibrationSet = []
        checkSet = []
        checkFeatures = []
        checkPoses = []
        distances = []
        report = nil
        logger = SessionLogger()
        logTracking()
        route = .calibration
    }

    func beginCollecting(target: Vec2, kind: String) {
        collecting = (target, kind)
        collectedFeatures = []
        collectedGaze = []
    }

    /// Drops the dot being collected (calibration cancelled).
    func cancelCollecting() {
        collecting = nil
        collectedFeatures = []
        collectedGaze = []
    }

    /// The calibration was left before its end («Назад», «Отмена», or a fit that failed): the session's calibration
    /// plays on, with what the aim had learned on it and its CSV. Without one, the eye modes will ask again.
    func cancelCalibration() {
        cancelCollecting()
        if let c = calibration {
            adopt(c)
            if let s = stash {
                adapter = s.adapter
                logger = s.logger
            }
        } else {
            clearLive()
            report = nil
        }
        stash = nil
        route = afterCalibration == .probe || afterCalibration == .clinic ? .clinic : .menu
    }

    /// The calibration's result moves on, to where the calibration was asked for.
    func continueAfterCalibration() {
        switch afterCalibration {
        case .rhythm: openRhythm()
        case .pursuit: openPursuit(byEye: true)
        case .probe: openProbe()
        case .game:
            mode = .eyes
            route = .game
        case .clinic: route = .clinic
        default: route = .menu
        }
    }

    /// Ends collection for one dot. Returns false when too few frames had a face (the dot is repeated).
    @discardableResult
    func endCollecting(minSamples: Int = 20) -> Bool {
        guard let c = collecting else { return false }
        collecting = nil
        guard collectedFeatures.count >= minSamples else { return false }
        if c.kind == "calibration" {
            calibrationSet.append((c.target, collectedFeatures))
        } else {
            checkSet.append((c.target, collectedGaze))
            checkFeatures.append((c.target, collectedFeatures))
            checkPoses.append(HeadPose.mean(collectedFeatures) ?? HeadPose(pitch: 0, yaw: 0))
        }
        return true
    }

    /// Fits both gaze models on the 9 calibration dots, then moves to the check screen. `screen`: the size of the
    /// screen the dots were shown on (screen pt). The head-frame model plays the check when it could be fitted.
    func finishCalibration(screen: Vec2) {
        var X: [[Double]] = [], Y: [Vec2] = []
        var samples: [(target: Vec2, features: GazeFeatures)] = []
        for (t, fs) in calibrationSet {
            for f in fs {
                X.append(f.vector(featureSet))
                Y.append(t)
                samples.append((t, f))
            }
        }
        let first = RidgeModel.fit(features: X, targets: Y, lambda: 0.01, featureSet: featureSet.rawValue)
        let calibrated = samples.map { $0.features }
        grip = (HeadPose.mean(calibrated),
                calibrated.isEmpty ? 0.28 : calibrated.map(\.distance).reduce(0, +) / Double(calibrated.count))
        let geometry = ScreenGeometry(size: screen, ptPerMetre: ptPerCm * 100, orientation: Self.screenOrientation)
        fitted = (HeadGazeModel.fit(samples: samples, screen: geometry), first)
        modelCheck = (nil, nil)
        if let head = fitted.head {
            play(GazeModel.head(head))
        } else {
            play(first.map { GazeModel.screen($0) })
        }
        if model == nil {
            // Nothing could be fitted: the session's calibration, if any, stays.
            cancelCalibration()
        } else {
            route = .check
        }
    }

    func finishCheck() {
        // The check dots choose the model: the head-frame one plays on, unless it misses them clearly more than the
        // first model does at this grip.
        let pick = GazeModel.choose(head: fitted.head, screen: fitted.screen, check: checkFeatures)
        modelCheck = (pick.headMiss, pick.screenMiss)
        if let chosen = pick.model, chosen.name != model?.name {
            play(chosen)
            // The other model played the check, so the report is made of the chosen model's own aim on the same
            // frames (before the filter).
            checkSet = checkFeatures.map { d in
                (target: d.target, predictions: d.features.compactMap { chosen.predict($0) })
            }
        }
        logModel()
        let distCm = distances.isEmpty ? 30 : distances.reduce(0, +) / Double(distances.count) * 100
        report = Metrics.report(samples: checkSet, ptPerCm: ptPerCm, viewingDistanceCm: distCm)
        // The report above is the model's own accuracy. Then the check dots warm the adapter up: they say where the
        // player looked at the calibration grip, which takes out a steady offset before the game starts.
        let now = CACurrentMediaTime()
        for (i, c) in checkSet.enumerated() where i < checkPoses.count && !c.predictions.isEmpty {
            let mean = c.predictions.reduce(Vec2.zero, +) * (1 / Double(c.predictions.count))
            let ok = adapter?.learn(raw: mean, target: c.target, pose: checkPoses[i], time: now) ?? false
            logger.label(time: now, source: "check", target: c.target, raw: mean, pitch: checkPoses[i].pitch,
                         yaw: checkPoses[i].yaw, accepted: ok, correction: adapter?.correction(pose: checkPoses[i]) ?? .zero)
        }
        // The session's calibration from now on, for every mode.
        if let m = model, let r = report {
            let c = SessionCalibration(model: m, shadow: shadowModel, head: fitted.head, screen: fitted.screen,
                                       headMissPt: modelCheck.headMissPt, screenMissPt: modelCheck.screenMissPt,
                                       report: r, reference: grip.reference, distanceM: grip.distanceM,
                                       childID: clinic.playingID, madeAt: Date())
            calibration = c
            keepCalibration(c)
        }
        stash = nil
        route = .result
    }

    /// Hit-zone margin E for the game.
    var hitMarginPt: Double {
        switch mode {
        case .touch: return balance.hitMarginPt.min
        case .eyes: return balance.hitMargin(measuredErrorPt: report?.meanErrorPt ?? balance.hitMarginPt.max)
        }
    }

    /// Debug builds only: launch argument `-SpantherAutoplay eyes|touch` starts a game played by a bot that
    /// looks at (or touches) the lowest meteor and reloads after running dry. Used by the Simulator smoke test
    /// in CI, where there is no face tracking.
    #if DEBUG
    let autoplay: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SpantherAutoplay"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    #else
    let autoplay: String? = nil
    #endif

    var logURL: URL { logger.url }

    func log(_ r: AsteroidRecord) {
        logger.asteroid(r, time: CACurrentMediaTime())
        // The CI bot opens the game in `init`, where setting `route` starts no play: its play starts here.
        if meteorPlay == nil, route == .game { beginMeteorPlay() }
        meteorPlay?.tally.add(r)
    }

    /// A red sign left the play at `position` (screen pt): looked at (an error) or passed by.
    func log(_ r: DecoyRecord, at position: Vec2) {
        logger.decoy(r, at: position, time: CACurrentMediaTime())
        if meteorPlay == nil, route == .game { beginMeteorPlay() }
        meteorPlay?.tally.add(r)
    }

    // MARK: session report

    /// The code the specialist gave the child instead of a name; every play is saved under it. Kept between launches.
    @Published var childCode = UserDefaults.standard.string(forKey: "childCode") ?? "" {
        didSet { UserDefaults.standard.set(childCode, forKey: "childCode") }
    }
    var currentChildCode: String { childCode.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Every play saved on this phone (SessionStore), in the order they ended.
    @Published private(set) var sessions: [SessionSummary] = SessionStore.load()
    /// The meteor play that just ended, for the menu to show once.
    @Published var lastSummary: SessionSummary?

    /// The meteor play on screen: one per visit to the game screen, with what it was set up with.
    private struct MeteorPlay {
        let id = UUID().uuidString
        let start = Date()
        let childCode: String
        let byEye: Bool
        let calibrationErrorCm: Double?
        /// The scale the targets and hit zones have in this play.
        let targetScale: Double
        var tally = MeteorTally()
        /// Seconds on screen with the app in front, before `since`: the host time it last came to the front.
        var shownSec = 0.0
        var since: Double?
    }
    private var meteorPlay: MeteorPlay?

    private func beginMeteorPlay() {
        meteorPlay = MeteorPlay(childCode: currentChildCode, byEye: mode == .eyes,
                                calibrationErrorCm: mode == .eyes ? report?.meanErrorCm : nil,
                                targetScale: targetScale, since: active ? CACurrentMediaTime() : nil)
        logger.game(time: CACurrentMediaTime(), targetScale: targetScale, zoneFloorPt: zoneFloorPt, decoys: decoysOn)
        // The CI bot's game opens in `init`, where `route` runs no observer: its music starts here.
        updateAmbient()
    }

    /// Writes the meteor play so far into the history, under its id, so that a later save replaces it.
    @discardableResult
    private func saveMeteorPlay() -> SessionSummary? {
        guard let p = meteorPlay, !p.tally.isEmpty else { return nil }
        let shown = p.shownSec + (p.since.map { CACurrentMediaTime() - $0 } ?? 0)
        let s = p.tally.summary(id: p.id, childCode: p.childCode, start: p.start, durationSec: shown, byEye: p.byEye,
                                calibrationErrorCm: p.calibrationErrorCm, targetScale: p.targetScale)
        keep(s)
        return s
    }

    /// The game screen closed: the play goes into the history, and back on the menu its summary shows.
    private func finishMeteorPlay() {
        let s = saveMeteorPlay()
        meteorPlay = nil
        if route == .menu { lastSummary = s }
        #if DEBUG
        // The Simulator run reads this to see that the music's engine started and made sound.
        if autoplay != nil {
            try? ambient.debugLine().write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ambient.txt"),
                                           atomically: true, encoding: .utf8)
        }
        #endif
    }

    /// The streak of the play now or the last one (meteors, warm-up), for the victory screen's best run. The
    /// rhythm game keeps its own (the judge's best combo).
    var playFX: StreakFX?
    /// Each play's victory by the play's id, so a victory screen shown twice adds its stars once.
    private var awards: [String: VictoryAward] = [:]

    /// The victory of a play: its rank, and the stars it adds to the child's observatory (saved at once).
    func victory(for s: SessionSummary) -> VictoryAward {
        if let a = awards[s.id] { return a }
        let best = s.maxCombo ?? playFX?.best ?? 0
        let a = VictoryAward(share: s.victoryShare, bestStreak: best, observatory: ObservatoryStore.load(child: s.childCode))
        ObservatoryStore.save(a.after, child: s.childCode)
        awards[s.id] = a
        return a
    }

    /// Adds a play to the history, or replaces the one with its id, and writes the history to the phone.
    private func keep(_ s: SessionSummary) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        SessionStore.save(sessions)
    }

    /// Deletes the plays of one child (every play when the code is empty) from the phone.
    func deleteSessions(of code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions.removeAll { c.isEmpty || $0.childCode == c }
        SessionStore.save(sessions)
        ObservatoryStore.reset(child: c)
    }

    /// Debug builds only: launch argument `-SpantherDemoReport summary|history` fills the history with made-up plays
    /// of two children and opens the report on the menu, for the CI screenshots. Nothing of it is saved.
    #if DEBUG
    let demoReport: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SpantherDemoReport"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    private static func demoSessions() -> [SessionSummary] {
        let now = Date(), day = 86_400.0
        var out: [SessionSummary] = []
        let meteors = [(14, 24, 1.12, 0.8, 2), (16, 25, 1.05, 0.7, 2), (17, 24, 0.98, 0.6, 3), (19, 26, 0.93, 0.6, 3),
                       (21, 27, 0.86, 0.5, 4)]
        for (k, m) in meteors.enumerated() {
            var s = SessionSummary(id: "demo-m\(k)", childCode: "К-07", game: .meteors,
                                   start: now.addingTimeInterval(-Double(4 - k) * day - 900), durationSec: 240 + 15 * Double(k),
                                   byEye: true, calibrationErrorCm: [1.3, 1.2, 1.4, 1.1, 1.2][k])
            s.burned = m.0
            s.meteors = m.1
            s.meanFirstLookSec = m.2
            s.slipsPerMeteor = m.3
            s.maxLevel = m.4
            s.targetScale = 0.7
            s.holdShare = [0.52, 0.58, 0.61, 0.70, 0.74][k]
            s.decoys = [26, 27, 29, 30, 31][k]
            s.decoyErrors = [9, 7, 7, 5, 4][k]
            out.append(s)
        }
        for k in 0..<2 {
            var s = SessionSummary(id: "demo-p\(k)", childCode: "К-07", game: .pursuit,
                                   start: now.addingTimeInterval(-Double(4 - 4 * k) * day - 1300), durationSec: 60,
                                   byEye: true, calibrationErrorCm: [1.3, 1.2][k])
            s.holdShare = [0.71, 0.84][k]
            s.pursuitMeanCm = [1.9, 1.4][k]
            s.pursuitHorizontal = [0.80, 0.91][k]
            s.pursuitVertical = [0.74, 0.86][k]
            s.pursuitEight = [0.60, 0.76][k]
            s.pursuitLostShare = [0.06, 0.03][k]
            out.append(s)
        }
        for k in 0..<3 {
            var s = SessionSummary(id: "demo-r\(k)", childCode: "К-07", game: .rhythm,
                                   start: now.addingTimeInterval(-Double(4 - 2 * k) * day - 400), durationSec: 61,
                                   byEye: true, calibrationErrorCm: 1.2)
            s.track = "Орбита"
            s.rhythmLevel = RhythmLevel.normal.rawValue
            s.accuracy = 0.58 + 0.07 * Double(k)
            s.notes = 61
            s.hits = 41 + 4 * k
            s.perfect = 17 + 3 * k
            s.maxCombo = 9 + 3 * k
            s.extraWinks = 7 - 2 * k
            s.targetScale = 0.7
            s.holdShare = 0.78 + 0.05 * Double(k)
            s.timingDeviationMs = 64 - 9 * Double(k)
            s.timingOffsetMs = 118
            s.winkLeft = 0.80 + 0.04 * Double(k)
            s.winkRight = 0.66 + 0.07 * Double(k)
            out.append(s)
        }
        for k in 0..<2 {
            var s = SessionSummary(id: "demo-f\(k)", childCode: "К-12", game: .meteors,
                                   start: now.addingTimeInterval(-Double(3 - k) * day), durationSec: 180,
                                   byEye: false, calibrationErrorCm: nil)
            s.burned = 18 + k
            s.meteors = 22
            s.meanFirstLookSec = 1.3 - 0.1 * Double(k)
            s.slipsPerMeteor = 0.4
            s.maxLevel = 2
            s.targetScale = 0.7
            s.holdShare = 0.7
            s.decoys = 20
            s.decoyErrors = 2 - k
            out.append(s)
        }
        return out.sorted { $0.start < $1.start }
    }
    #endif
}
