import AVFoundation
import QuartzCore
import SwiftUI

/// A grade that just landed: its word on screen and its burst on the stage, at the object it judged.
struct WinkBeatStamp: Identifiable, Equatable {
    let id: Int
    let index: Int
    let grade: WinkBeatGrade
    let at: Vec2
    /// Track time it landed (s): the burst is drawn from it.
    let time: Double
}

/// What the eyes just did, for the HUD's corner chip.
enum WinkBeatEyesNote: Equatable {
    case open, blink, winkLeft, winkRight, longBlink, noFace
}

/// The numbers the HUD shows, pushed a few times a second, not every frame.
struct WinkBeatHud: Equatable {
    var score = 0
    var combo = 0
    var accuracy = 1.0
    var energy = 1.0
    /// Track time (s), for the clock and the progress bar.
    var elapsed = 0.0
    var eyes = WinkBeatEyesNote.open
}

/// The spinner's count in its middle.
struct WinkBeatSpin: Equatable {
    var index: Int
    var hops: Int
    var needed: Int
}

/// One play of Wink Beat (skills `gaze-wink-judging`, `avaudio-rhythm-sync`): the track on the music player, the
/// heard track time from `WinkBeatClock`, the eyes through `WinkBeatEyes` and `GazeLock` into `WinkBeatPlay`. The
/// stage and the HUD read it; the app feeds it the tracking frames (`sample`). In the Simulator smoke test
/// (`-SpantherAutoplay winkbeat`) `WinkBeatBot` plays instead of the eyes. Used on the main thread only, like
/// `AppModel`, which feeds it.
final class WinkBeatSession: ObservableObject {
    enum Phase: Equatable { case select, ready, playing, done }

    @Published private(set) var phase: Phase = .select
    @Published var difficulty: WinkBeatDifficulty = .normal
    @Published private(set) var hud = WinkBeatHud()
    @Published private(set) var stamps: [WinkBeatStamp] = []
    /// Circles and slider heads waiting for a wink: their eye marks are drawn over the stage.
    @Published private(set) var marks: [Int] = []
    @Published private(set) var spin: WinkBeatSpin?
    /// The spinner on screen, if one is: its count and hint are drawn over the stage.
    @Published private(set) var spinnerShown: Int?
    /// The music could not be decoded or the phone plays no sound: the play still runs on the planned clock.
    @Published private(set) var silent = false

    let map: WinkBeatMap?
    let byEye: Bool
    let bot: Bool
    private let measuredErrorPt: Double
    private let zoneFloorPt: Double

    /// Read by the stage every frame, so not published.
    private(set) var play: WinkBeatPlay?
    private(set) var lock = GazeLock()
    private(set) var field = WinkBeatField.reference
    private(set) var aim: Vec2?
    /// The last object of the chart ends here (track s).
    private(set) var endTime = 0.0
    private var eyes = WinkBeatEyes()
    private var clock = WinkBeatClock()
    private var music: AVAudioPCMBuffer?
    private var musicLoading = false
    private var startHost = 0.0
    private var readyHost = 0.0
    private var hadReading = false
    private var touchAim: Vec2?
    private var botPlayer: WinkBeatBot?
    private var botFrame = 0
    private var botBlinks = 0
    /// CI: the spinner line is printed once, so the screenshot step can wait for it instead of guessing the time.
    private var spinnerSignalled = false
    private var timer: Timer?
    private var stampCounter = 0
    private var lastHudPush = 0.0
    private var eyesNote = WinkBeatEyesNote.open
    private var eyesNoteUntil = 0.0

    /// The start wink: where the player looked (the start disc, pt) and when (host s). The app recentres the aim on it.
    var onStart: ((Vec2, Double) -> Void)?
    /// The music starts at this host time.
    var onBegin: ((Double, WinkBeatPlay) -> Void)?
    /// A wink played an object: its spot (pt) and the wink's host time. The app teaches the aim with it.
    var onPlayed: ((Vec2, Double) -> Void)?
    /// A final judgement or a slider head: index, spot, grade, offset (s), host time.
    var onJudged: ((Int, Vec2, WinkBeatGrade, Double?, Double) -> Void)?
    /// The play ended (host time).
    var onEnd: ((Double, WinkBeatPlay) -> Void)?

    init(map: WinkBeatMap?, byEye: Bool, bot: Bool, measuredErrorPt: Double, zoneFloorPt: Double) {
        self.map = map
        self.byEye = byEye
        self.bot = bot
        self.measuredErrorPt = measuredErrorPt
        self.zoneFloorPt = zoneFloorPt
        loadMusic()
    }

    /// The bundled track decoded into memory, off the main thread.
    private func loadMusic() {
        guard let map, music == nil, !musicLoading else { return }
        let name = (map.audio as NSString).deletingPathExtension, ext = (map.audio as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            silent = true
            return
        }
        musicLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let buffer = SoundEngine.musicBuffer(contentsOf: url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.music = buffer
                self.musicLoading = false
                if buffer == nil { self.silent = true }
            }
        }
    }

    /// Objects in the chart of a difficulty, for the select screen.
    func count(_ d: WinkBeatDifficulty) -> Int { map?.chart(d).count ?? 0 }

    // MARK: - Phases

    /// The player chose a difficulty: the chart is laid out on a screen this size (pt) and the start disc shows.
    func prepare(screen: CGSize) {
        guard let map else { return }
        field = WinkBeatField(width: Double(max(screen.width, 100)), height: Double(max(screen.height, 100)))
        let p = WinkBeatPlay(map: map, difficulty: difficulty, field: field, measuredErrorPt: measuredErrorPt,
                             zoneFloorPt: zoneFloorPt)
        play = p
        endTime = p.objects.map(\.endTime).max() ?? map.durationSec
        eyes = WinkBeatEyes()
        lock = GazeLock()
        stamps = []
        marks = []
        spin = nil
        spinnerShown = nil
        spinnerSignalled = false
        hud = WinkBeatHud()
        aim = nil
        readyHost = CACurrentMediaTime()
        phase = .ready
        startTimer()
    }

    /// The start disc in the middle of the screen (pt).
    var startPoint: Vec2 { Vec2(field.width / 2, field.height / 2) }

    private func begin(host: Double) {
        guard phase == .ready, let play else { return }
        onStart?(startPoint, host)
        let audio = AVAudioSession.sharedInstance()
        clock = WinkBeatClock(outputLatency: audio.outputLatency, ioBuffer: audio.ioBufferDuration,
                              userOffset: WinkBeatOffsets.seconds(for: .current))
        hadReading = false
        startHost = CACurrentMediaTime() + 0.6
        SoundEngine.shared.hold("music", true)
        if let music { SoundEngine.shared.playMusic(music, startHost: startHost) } else { silent = true }
        botPlayer = bot ? WinkBeatBot(play: play) : nil
        botFrame = 0
        lock = GazeLock()
        phase = .playing
        onBegin?(startHost, play)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.phase == .playing, self.music != nil else { return }
            if !SoundEngine.shared.isRunning, !self.bot { self.silent = true }
        }
    }

    private func finish() {
        guard phase == .playing, let play else { return }
        stopSound()
        timer?.invalidate()
        timer = nil
        pushHud(force: true)
        marks = []
        spin = nil
        spinnerShown = nil
        phase = .done
        onEnd?(CACurrentMediaTime(), play)
        if bot {
            // For the Simulator smoke test's check.
            let acc = (play.accuracy * 1000).rounded() / 10
            print("WINKBEAT_RESULT \(acc) \(play.rank.label) \(play.score) maxCombo=\(play.maxCombo) "
                  + "misses=\(play.count(.miss)) blinks=\(botBlinks)")
            fflush(stdout)
        }
    }

    /// Back to the difficulty choice, after the results or from play.
    func toSelect() {
        stopSound()
        timer?.invalidate()
        timer = nil
        play = nil
        stamps = []
        marks = []
        spin = nil
        spinnerShown = nil
        phase = .select
    }

    /// The screen is left.
    func leave() {
        stopSound()
        timer?.invalidate()
        timer = nil
    }

    private func stopSound() {
        SoundEngine.shared.stopMusic()
        SoundEngine.shared.hold("music", false)
    }

    // MARK: - Time

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The heard track time at `host` for drawing (no hold, no new reading), nil before play.
    func drawTime(host: Double) -> Double? {
        guard phase == .playing else { return nil }
        return clock.trackTime(host: host)
    }

    private func heardTime(host: Double) -> Double? {
        var reading = SoundEngine.shared.musicReading()
        if reading != nil { hadReading = true }
        // Before the first render, or with no sound at all, time runs from the planned start.
        if reading == nil, !hadReading { reading = .init(renderedSec: 0, host: startHost) }
        return clock.heard(reading: reading, hostNow: host)
    }

    private func tick() {
        let host = CACurrentMediaTime()
        switch phase {
        case .ready:
            // The bot starts once the start disc has been on screen for the screenshot.
            if bot, host > readyHost + 3.0 { begin(host: host) }
        case .playing:
            guard let t = heardTime(host: host) else { return }
            if let b = botPlayer {
                let f = b.frame(at: t, index: botFrame)
                botFrame += 1
                feedEyes(host: host, aim: f.aim, left: f.left, right: f.right)
            } else if !byEye {
                aim = touchAim
                if let play { _ = lock.update(aim: aim, time: host, targets: play.lockTargets(at: t)) }
            }
            let events = play?.frame(time: t, aim: aim) ?? []
            apply(events, host: host, t: t)
            // Only when one is old: every write to a published value redraws the HUD.
            if stamps.contains(where: { t - $0.time > 0.8 || $0.time - t > 1 }) {
                stamps.removeAll { t - $0.time > 0.8 || $0.time - t > 1 }
            }
            if let play {
                let waiting = play.lockTargets(at: t).map(\.id)
                if waiting != marks { marks = waiting }
                if let s = spin, play.results[s.index] != nil { spin = nil }
                let shown = play.visible(at: t).first { play.objects[$0].kind == .spinner }
                if shown != spinnerShown { spinnerShown = shown }
                // A CI screenshot lands about 3 s after this line and the spinner lasts under 3 s, so it goes early.
                if bot, !spinnerSignalled, let first = play.objects.first(where: { $0.kind == .spinner }),
                   t >= first.time - 2.5 {
                    spinnerSignalled = true
                    print("WINKBEAT_SPINNER \(String(format: "%.2f", t))")
                    fflush(stdout)
                }
            }
            pushHud(force: false, t: t, host: host)
            if play?.failed == true || t > endTime + 1.2 { finish() }
        case .select, .done:
            break
        }
    }

    private func pushHud(force: Bool, t: Double? = nil, host: Double = CACurrentMediaTime()) {
        guard force || host - lastHudPush >= 1.0 / 15 else { return }
        lastHudPush = host
        guard let play else { return }
        var h = hud
        h.score = play.score
        h.combo = play.combo
        h.accuracy = play.accuracy
        h.energy = play.energy
        if let t { h.elapsed = max(0, t) }
        h.eyes = host < eyesNoteUntil ? eyesNote : (aim == nil && byEye ? .noFace : .open)
        if h != hud { hud = h }
    }

    // MARK: - Input

    /// One tracking frame (eye mode): host time, the calibrated aim (pt), the lids (0 open ... 1 closed), nil
    /// when no face is seen.
    func sample(host: Double, aim raw: Vec2?, lids: (left: Double, right: Double)?) {
        guard byEye, !bot, phase == .ready || phase == .playing else { return }
        guard let lids else {
            eyes.faceLost()
            aim = nil
            return
        }
        feedEyes(host: host, aim: raw, left: lids.left, right: lids.right)
    }

    private func feedEyes(host: Double, aim raw: Vec2?, left: Double, right: Double) {
        let r = eyes.update(time: host, aim: raw, left: left, right: right)
        aim = r.aim
        switch phase {
        case .ready:
            for c in r.closures {
                switch c {
                case let .wink(_, onset, _): begin(host: onset)
                case let .longBlink(onset, _) where difficulty.acceptsLongBlink: begin(host: onset)
                default: break
                }
            }
        case .playing:
            guard let play, let t = clock.trackTime(host: host) else { return }
            let locked = lock.update(aim: r.aim, time: host, targets: play.lockTargets(at: t))
            for c in r.closures {
                note(c, host: host)
                guard var j = c.forJudge, let onsetTrack = clock.trackTime(host: j.time) else { continue }
                let onsetHost = j.time
                j.time = onsetTrack
                let events = self.play?.closure(j, prefer: locked) ?? []
                apply(events, host: onsetHost, t: t)
            }
        case .select, .done:
            break
        }
    }

    private func note(_ c: WinkBeatEyes.Closure, host: Double) {
        switch c {
        case let .wink(side, _, _): eyesNote = side == .left ? .winkLeft : .winkRight
        case .longBlink: eyesNote = .longBlink
        case .blink:
            eyesNote = .blink
            botBlinks += 1
        }
        eyesNoteUntil = host + 0.9
        pushHud(force: true)
    }

    /// A finger on the screen (touch mode, and the start disc in every mode): host time (`UITouch.timestamp`) and
    /// the spot (pt).
    func touchBegan(host: Double, at p: Vec2) {
        switch phase {
        case .ready:
            begin(host: host)
        case .playing:
            guard !byEye, let play, let t = clock.trackTime(host: host) else { return }
            touchAim = p
            aim = p
            // The finger plays the object under it, with the eye that object asks for.
            let under = play.lockTargets(at: t)
                .filter { $0.position.distance(to: p) <= $0.reach }
                .min { abs(play.expected($0.id) - t) < abs(play.expected($1.id) - t) }
            let side = under.flatMap { WinkSide(rawValue: play.objects[$0.id].side.rawValue) } ?? .left
            let events = self.play?.closure(WinkBeatClosure(side: side, time: t, aim: p), prefer: under?.id) ?? []
            apply(events, host: host, t: t)
        case .select, .done:
            break
        }
    }

    func touchMoved(to p: Vec2) { if !byEye { touchAim = p } }
    func touchEnded() { touchAim = nil }

    // MARK: - Events

    private func apply(_ events: [WinkBeatEvent], host: Double, t: Double) {
        guard let play else { return }
        for e in events {
            switch e {
            case let .judged(i, g, offset):
                let o = play.objects[i]
                let at = o.kind == .slider ? WinkBeatPlay.tail(of: o, field: field) : play.positions[i]
                addStamp(i, g, at: at, t: t)
                onJudged?(i, at, g, offset, host)
                if o.kind == .circle, offset != nil { onPlayed?(play.positions[i], host) }
            case let .head(i, g, offset):
                if g != .miss { addStamp(i, g, at: play.positions[i], t: t) }
                onJudged?(i, play.positions[i], g, offset, host)
                if offset != nil { onPlayed?(play.positions[i], host) }
            case let .spinnerHop(i, _, hops, needed):
                spin = WinkBeatSpin(index: i, hops: hops, needed: needed)
            case .sliderTick, .rejected:
                break
            case .failed:
                finish()
            }
        }
        if !events.isEmpty { pushHud(force: true, t: t, host: host) }
    }

    private func addStamp(_ i: Int, _ g: WinkBeatGrade, at: Vec2, t: Double) {
        stampCounter += 1
        stamps.append(WinkBeatStamp(id: stampCounter, index: i, grade: g, at: at, time: t))
        if stamps.count > 8 { stamps.removeFirst(stamps.count - 8) }
    }
}
