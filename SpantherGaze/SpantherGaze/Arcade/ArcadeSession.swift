import Foundation
import QuartzCore

/// The arcades (Aziz, 2026-11-27): «Кроты», bonk the mole by blinking at its hole (a rabbit and a hedgehog must be
/// left alone), and «Рыбалка», hold a fish with the eyes until it is caught, as a meteor is burnt.
enum ArcadeGame: String, CaseIterable {
    case moles, fishing

    var title: String { self == .moles ? L("Кроты") : L("Рыбалка") }
    static let levels = 10
}

/// Each player's best stars per level (the players' progress, like Wink Beat's). One star opens the next level.
enum ArcadeProgress {
    /// The players on this phone (AppModel sets it at launch); the phone's defaults before that.
    static weak var profiles: ProfilesModel?

    private static func key(_ g: ArcadeGame) -> String { "arcade.\(g.rawValue).stars" }

    static func stars(_ g: ArcadeGame) -> [Int] {
        let raw = profiles?.progress(key(g)) ?? UserDefaults.standard.string(forKey: key(g)) ?? ""
        var out = raw.split(separator: ",").map { Int($0) ?? 0 }
        while out.count < ArcadeGame.levels { out.append(0) }
        return Array(out.prefix(ArcadeGame.levels))
    }

    static func record(_ g: ArcadeGame, level: Int, got: Int) {
        var s = stars(g)
        guard level >= 1, level <= s.count, got > s[level - 1] else { return }
        s[level - 1] = got
        let v = s.map(String.init).joined(separator: ",")
        if let p = profiles { p.setProgress(key(g), v) } else { UserDefaults.standard.set(v, forKey: key(g)) }
    }

    static func open(_ g: ArcadeGame, level: Int, stars s: [Int]) -> Bool {
        level == 1 || (level >= 2 && level - 2 < s.count && s[level - 2] >= 1)
    }
}

/// What the play screen shows over the stage. Pushed at most 20 times a second.
struct ArcadeHud: Equatable {
    var score = 0
    var secondsLeft = 0
    var combo = 0
    var landed = 0
    var goal = 0
    /// The fish under the eyes: how far its hold has come (0...1), where it is and the ring's radius (pt).
    var reel: Double?
    var reelSpot: Vec2?
    var reelRadius = 40.0
}

/// A short word or number that rises from a spot on the screen (pt).
struct ArcadeStamp: Identifiable, Equatable {
    enum Tone: Equatable { case good, gold, bad, quiet }
    let id: Int
    let text: String
    let spot: Vec2
    let tone: Tone
    let host: Double
}

/// The end of a round, for the results and the account.
struct ArcadeOutcome: Equatable {
    var game: ArcadeGame
    var level: Int
    var stars: Int
    var score: Int
    /// 0...1: moles bonked of those that came up; fish hooked of those that bit.
    var accuracy: Double
    var hits: Int
    var misses: Int
    /// The results' detail lines.
    var lines: [String]
    var nextOpen: Bool
    /// Moles: mean time from a mole's start to the blink (s); fishing: mean look until the catch (s).
    var reactionSec: Double? = nil
}

/// One arcade play, shared by both games: the level choice, a 3-2-1, the round on a 60 Hz timer, the eyes through
/// `WinkBeatEyes` with every blink playing (a two-eye blink or a wink is the action, at its onset, with the aim
/// from just before it), the finger by touch, and the CI bot. The rules live in GazeCore (`MoleGarden`,
/// `FishingPond`); the subclasses wire them to the stage and the HUD. Main thread only, like `AppModel`.
class ArcadeSession: ObservableObject, ToonSource {
    enum Phase: Equatable { case levels, countdown, playing, done }

    let game: ArcadeGame
    let byEye: Bool
    let bot: Bool
    let zoneFloorPt: Double
    /// CI: a shorter round (s).
    let roundSec: Double?
    /// The 30-day plan sent the player here at this level: the round starts at once, with no level choice.
    var planLevel: Int?

    @Published private(set) var phase: Phase = .levels
    @Published private(set) var level = 1
    @Published private(set) var hud = ArcadeHud()
    @Published private(set) var stamps: [ArcadeStamp] = []
    @Published private(set) var countdown = 3
    @Published private(set) var outcome: ArcadeOutcome? = nil
    @Published private(set) var stars: [Int]
    /// The pause plate is up: the round's clock stands still.
    @Published private(set) var paused = false
    private var pausedAt = 0.0

    private(set) var screen = Vec2(844, 390)
    /// The aim this frame (pt): the eyes', the finger's or the bot's.
    private(set) var aim: Vec2?
    private var eyes = WinkBeatEyes(config: WinkBeatEyesConfig(blinksPlay: true))
    private var touchAim: Vec2?
    private(set) var startHost = 0.0
    private var timer: Timer?
    private var stampID = 0
    private var lastHudPush = 0.0
    private var lastPerfLog = 0.0
    private var seedBase = UInt64(Date().timeIntervalSince1970)
    private(set) var toonSceneVersion = 0
    /// Two-eye closures the eyes saw in the round: every one played.
    private(set) var blinks = 0

    /// The round started (level, host s).
    var onBegin: ((Int, Double) -> Void)?
    /// A blink played a target the player was looking at (pt, host s of the blink): the app teaches the aim.
    var onLabel: ((Vec2, Double) -> Void)?
    /// A rules event for the session file: kind, host s, spot (pt), reaction (s), score after it.
    var onEvent: ((String, Double, Vec2?, Double?, Int) -> Void)?
    /// The round ended: its outcome, the host times it started and ended.
    var onEnd: ((ArcadeOutcome, Double, Double) -> Void)?
    /// Every 2 s of play: frames per second, GPU ms per frame, whether heat turned shadows off, host s.
    var onPerf: ((Double, Double, Bool, Double) -> Void)?

    init(game: ArcadeGame, byEye: Bool, bot: Bool, zoneFloorPt: Double, roundSec: Double?) {
        self.game = game
        self.byEye = byEye
        self.bot = bot
        self.zoneFloorPt = zoneFloorPt
        self.roundSec = roundSec
        stars = ArcadeProgress.stars(game)
        let s = stars
        level = (1...ArcadeGame.levels).last { ArcadeProgress.open(game, level: $0, stars: s) } ?? 1
    }

    deinit { timer?.invalidate() }

    // MARK: For the subclasses

    var toonScene: ToonScene? { nil }
    func makeRound(level: Int, seed: UInt64) {}
    func stepRound(t: Double, aim: Vec2?) {}
    func act(t: Double, host: Double, aim: Vec2?) {}
    func paint(into draws: inout [ToonDraw], t: Double) {}
    func botStep(t: Double) -> Vec2? { nil }
    func fillHud(_ hud: inout ArcadeHud, t: Double) {}

    func sceneChanged() { toonSceneVersion += 1 }

    /// The pause plate went up (true) or down: the subclass stops what hums.
    func pauseChanged(_ on: Bool) {}

    /// Pauses or resumes the round; the time on the pause plate does not count.
    func setPaused(_ on: Bool) {
        guard on != paused, phase == .playing || phase == .countdown || !on else { return }
        paused = on
        let now = CACurrentMediaTime()
        if on {
            pausedAt = now
        } else {
            startHost += now - pausedAt
            eyes = WinkBeatEyes(config: WinkBeatEyesConfig(blinksPlay: true))
        }
        pauseChanged(on)
    }

    /// A stamp at `spot`.
    func stamp(_ text: String, at spot: Vec2, _ tone: ArcadeStamp.Tone) {
        stampID += 1
        let now = CACurrentMediaTime()
        stamps.removeAll { now - $0.host > 1.2 }
        stamps.append(ArcadeStamp(id: stampID, text: text, spot: spot, tone: tone, host: now))
    }

    func host(of t: Double) -> Double { startHost + t }

    /// The round ended: results, progress, the account.
    func finish(_ o: ArcadeOutcome, t: Double) {
        guard phase == .playing else { return }
        ArcadeProgress.record(game, level: o.level, got: o.stars)
        stars = ArcadeProgress.stars(game)
        var out = o
        out.nextOpen = o.level < ArcadeGame.levels && ArcadeProgress.open(game, level: o.level + 1, stars: stars)
        outcome = out
        phase = .done
        paused = false
        hud.reel = nil
        onEnd?(out, startHost, host(of: t))
        if bot {
            print(String(format: "ARCADE_RESULT %@ %d %d %.2f", game.rawValue, out.stars, out.score, out.accuracy))
            fflush(stdout)
        }
    }

    // MARK: The screen

    /// The play's size (pt, the whole screen) before a level is chosen: the stage is built for it.
    func layout(screen s: Vec2) {
        guard phase == .levels || phase == .done, s.x > 100, s.y > 100 else { return }
        if abs(s.x - screen.x) < 0.5, abs(s.y - screen.y) < 0.5, toonScene != nil { return }
        screen = s
        if phase == .levels, let n = planLevel {
            choose(level: n)
            return
        }
        makeRound(level: level, seed: seedBase)
        startTimer()
    }

    func choose(level n: Int) {
        guard ArcadeProgress.open(game, level: n, stars: stars) || bot || planLevel != nil else { return }
        level = n
        seedBase &+= 1
        makeRound(level: n, seed: seedBase)
        outcome = nil
        stamps = []
        blinks = 0
        hud = ArcadeHud()
        eyes = WinkBeatEyes(config: WinkBeatEyesConfig(blinksPlay: true))
        countdown = 3
        startHost = CACurrentMediaTime() + 3
        phase = .countdown
        startTimer()
    }

    func again() { choose(level: level) }

    func next() {
        guard level < ArcadeGame.levels else { return }
        choose(level: level + 1)
    }

    func toLevels() {
        if paused { setPaused(false) }
        phase = .levels
        outcome = nil
        stamps = []
        hud = ArcadeHud()
    }

    func leave() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Input

    /// One tracking frame (eye mode): host time, the calibrated aim (pt), the lids (0 open ... 1 closed), nil
    /// when no face is seen.
    func sample(host: Double, aim raw: Vec2?, lids: (left: Double, right: Double)?) {
        guard byEye, !bot, !paused, phase == .playing || phase == .countdown else { return }
        guard let lids else {
            eyes.faceLost()
            aim = nil
            return
        }
        let r = eyes.update(time: host, aim: raw, left: lids.left, right: lids.right)
        aim = r.aim
        guard phase == .playing else { return }
        for c in r.closures {
            switch c {
            case let .wink(_, onset, a), let .beatBlink(onset, a), let .longBlink(onset, a):
                if case .beatBlink = c { blinks += 1 }
                act(t: onset - startHost, host: onset, aim: a)
            case .blink:
                blinks += 1
            }
        }
    }

    /// The finger on the screen (finger mode): it aims while it is down.
    func touch(at p: Vec2) {
        guard !byEye, !bot else { return }
        touchAim = p
        aim = p
    }

    /// The finger lifted: the blink of finger play.
    func release(at p: Vec2) {
        guard !byEye, !bot, !paused, phase == .playing else { return }
        // A lifted finger stops holding a fish; for a mole the lift is the blink, at the spot it left.
        touchAim = game == .fishing ? nil : p
        aim = touchAim
        let now = CACurrentMediaTime()
        act(t: now - startHost, host: now, aim: p)
    }

    // MARK: The clock

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if paused { return }
        switch phase {
        case .levels:
            // CI: the bot picks level 3 after a look at the choice.
            if bot, now - lastHudPush > 2.5 {
                if lastHudPush > 0 { choose(level: 3) } else { lastHudPush = now }
            }
        case .countdown:
            let left = Int(ceil(startHost - now))
            if left != countdown { countdown = max(0, left) }
            if now >= startHost {
                phase = .playing
                onBegin?(level, startHost)
            }
        case .playing:
            let t = now - startHost
            if bot { aim = botStep(t: t) } else if !byEye { aim = touchAim }
            stepRound(t: t, aim: aim)
            if phase == .playing, now - lastHudPush >= 0.05 {
                lastHudPush = now
                var h = hud
                fillHud(&h, t: t)
                if h != hud { hud = h }
                if stamps.contains(where: { now - $0.host > 1.2 }) { stamps.removeAll { now - $0.host > 1.2 } }
            }
        case .done:
            break
        }
    }

    // MARK: ToonSource

    func toonFrame(into draws: inout [ToonDraw], host: Double) -> Double {
        let t: Double
        switch phase {
        case .levels: t = host - seedTimeZero
        default: t = host - startHost
        }
        paint(into: &draws, t: t)
        // Small numbers for the water's waves: Float keeps its precision.
        return host - seedTimeZero
    }

    /// The level choice shows the scene alive with no round in it.
    private let seedTimeZero = CACurrentMediaTime()

    func toonPerf(fps: Double, gpuMs: Double, shadowsOff: Bool) {
        guard phase == .playing else { return }
        let now = CACurrentMediaTime()
        guard now - lastPerfLog >= 2 else { return }
        lastPerfLog = now
        onPerf?(fps, gpuMs, shadowsOff, now)
    }
}

// MARK: - «Кроты»

final class MoleSession: ArcadeSession {
    private(set) var garden: MoleGarden?
    private var stage: MoleStage?
    private var swings: [MoleSwing] = []
    private var botPlan: [(t: Double, hole: Int)] = []
    private var botRandom = SeededRandom(seed: 5)

    override var toonScene: ToonScene? { stage }

    override func makeRound(level: Int, seed: UInt64) {
        var c = MoleConfig()
        if let s = roundSec { c.roundSec = s }
        let g = MoleGarden(level: level, screen: screen, startTime: 0, seed: seed, zoneFloor: zoneFloorPt, config: c)
        garden = g
        if stage == nil || abs((stage?.camera.screen.x ?? 0) - screen.x) > 0.5 || abs((stage?.camera.screen.y ?? 0) - screen.y) > 0.5 {
            stage = MoleStage(garden: g)
            sceneChanged()
        }
        swings.removeAll()
        botPlan.removeAll()
    }

    override func stepRound(t: Double, aim: Vec2?) {
        guard let events = garden?.update(time: t, aim: aim), let g = garden else { return }
        for e in events {
            switch e {
            case .popped(let p):
                if bot, !p.kind.isDecoy || Double.random(in: 0..<1, using: &botRandom) < 0.1 {
                    botPlan.append((t + 0.45 + 0.2 * Double.random(in: 0..<1, using: &botRandom), p.hole))
                }
                onEvent?("mole_pop_\(p.kind.rawValue)", host(of: t), g.holeCenter(p.hole), nil, g.score)
            case .escaped(let p):
                onEvent?("mole_escaped", host(of: t), g.holeCenter(p.hole), nil, g.score)
            case .decoyLeft(let p):
                onEvent?("\(p.kind.rawValue)_left", host(of: t), g.holeCenter(p.hole), nil, g.score)
            case .ended(let r):
                finish(summary(r), t: t)
            default:
                break
            }
        }
    }

    private func summary(_ r: MoleResult) -> ArcadeOutcome {
        var lines = [L("Кротов: {0} из {1}", r.hits, r.hits + r.escaped), L("Лучшая серия: {0}", r.bestCombo)]
        if r.golden > 0 { lines.append(L("Золотых кротов: {0}", r.golden)) }
        if r.hedgehogHits > 0 { lines.append(L("Ёжиков задето: {0}", r.hedgehogHits)) }
        if r.rabbitHits > 0 { lines.append(L("Кроликов задето: {0}", r.rabbitHits)) }
        if r.rabbitsLeft > 0, r.rabbitHits == 0 { lines.append(L("Кролика не тронули ни разу!")) }
        if let m = r.meanReactionSec { lines.append(L("Среднее время до моргания: {0} с", String(format: "%.2f", m))) }
        return ArcadeOutcome(game: .moles, level: r.level, stars: r.stars, score: r.score, accuracy: r.accuracy,
                             hits: r.hits, misses: r.escaped + r.whiffs, lines: lines, nextOpen: false,
                             reactionSec: r.meanReactionSec)
    }

    override func act(t: Double, host: Double, aim: Vec2?) {
        guard var g = garden, !g.ended else { return }
        let e = g.bonk(onset: t, aim: aim)
        garden = g
        let spot = aim ?? Vec2(screen.x / 2, screen.y / 2)
        switch e {
        case let .hit(p, points, reaction)?:
            let c = g.holeCenter(p.hole)
            swings.append(MoleSwing(spot: c, hole: p.hole, time: t, hit: true))
            stamp("+\(points)", at: c, p.kind == .golden ? .gold : .good)
            onLabel?(c, host)
            onEvent?(g.lastAssisted ? "mole_hit_assist" : "mole_hit", host, c, reaction, g.score)
        case let .decoyHit(p)?:
            let c = g.holeCenter(p.hole)
            swings.append(MoleSwing(spot: c, hole: p.hole, time: t, hit: true))
            stamp(p.kind == .rabbit ? L("Ой, кролик!") : L("Ой, ёжик!"), at: c, .bad)
            onLabel?(c, host)
            onEvent?("\(p.kind.rawValue)_hit", host, c, nil, g.score)
        case let .whiff(hole)?:
            swings.append(MoleSwing(spot: hole.map { g.holeCenter($0) } ?? spot, hole: hole, time: t, hit: false))
            onEvent?("mole_whiff", host, spot, nil, g.score)
        default:
            break
        }
        swings.removeAll { t - $0.time > MoleSwing.duration }
    }

    override func paint(into draws: inout [ToonDraw], t: Double) {
        guard let stage, let g = garden else { return }
        stage.draw(g, at: t, swings: swings, into: &draws)
    }

    override func fillHud(_ hud: inout ArcadeHud, t: Double) {
        guard let g = garden else { return }
        hud.score = g.score
        hud.combo = g.combo
        hud.secondsLeft = Int(ceil(g.remaining(at: t)))
    }

    /// CI: looks at each mole that comes up (hedgehogs mostly left alone) and blinks at it a moment later.
    override func botStep(t: Double) -> Vec2? {
        guard let g = garden else { return nil }
        botPlan.sort { $0.t < $1.t }
        guard let next = botPlan.first else { return lastAim }
        let c = g.holeCenter(next.hole)
        let a = Vec2(c.x + 10, c.y - 6)
        if t >= next.t {
            botPlan.removeFirst()
            act(t: t, host: host(of: t), aim: a)
        }
        lastAim = a
        return a
    }

    private var lastAim: Vec2?
}

// MARK: - «Рыбалка»

/// Fishing as the meteors play (Aziz, 2026-11-28): hold the eyes on a fish and the phone hums as the hold fills, then
/// taps with the meteors' crack and pop when it is caught; the fish goes into the catch at once. Blinks do nothing.
final class FishingSession: ArcadeSession {
    private(set) var pond: FishingPond?
    private var stage: PondStage?
    private var moments: [PondMoment] = []
    private var over: [ToonDraw] = []
    private var sounds: PopSounds?
    private var charging = false

    override var toonScene: ToonScene? { stage }

    override func makeRound(level: Int, seed: UInt64) {
        var c = FishingConfig()
        if let s = roundSec { c.roundSec = s }
        let p = FishingPond(level: level, screen: screen, startTime: 0, seed: seed, zoneFloor: zoneFloorPt, config: c)
        pond = p
        if stage == nil || abs((stage?.camera.screen.x ?? 0) - screen.x) > 0.5 || abs((stage?.camera.screen.y ?? 0) - screen.y) > 0.5 {
            stage = PondStage(pond: p)
            sceneChanged()
        }
        moments.removeAll()
        over.reserveCapacity(256)
        if sounds == nil { sounds = PopSounds(seed: seed) }
        sounds?.prepare(seed: seed)
        sounds?.resetLadder()
        Haptics.shared.prepare()
        endCharge()
    }

    override func stepRound(t: Double, aim: Vec2?) {
        guard let events = pond?.update(time: t, aim: aim), let p = pond else { return }
        for e in events {
            switch e {
            case .looked(let f):
                if !bot { sounds?.charge(pan: pan(f.position)) }
                onEvent?("fish_look_\(f.kind.rawValue)", host(of: t), f.position, nil, p.score)
            case let .caught(f, points, held):
                endCharge()
                moments.append(PondMoment(kind: .caught(f.kind), spot: f.position, heading: f.heading, time: t))
                stamp("+\(points)", at: f.position, f.kind == .goldfish ? .gold : .good)
                if !bot {
                    Haptics.shared.lock()
                    sounds?.lock(pan: pan(f.position), at: host(of: t))
                }
                onLabel?(f.position, host(of: t))
                onEvent?("fish_caught_\(f.kind.rawValue)", host(of: t), f.position, held, p.score)
            case .ended(let r):
                endCharge()
                finish(summary(r), t: t)
            }
        }
        // The hum of the hold, as on a meteor: on while a fish is under the eyes, rising with its hold.
        if !bot, phase == .playing, let h = p.holding {
            if !charging { Haptics.shared.chargeBegan(); charging = true }
            Haptics.shared.chargeProgress(h.progress)
        } else if charging {
            endCharge()
        }
        moments.removeAll { t - $0.time > $0.duration }
    }

    private func endCharge() {
        guard charging else { return }
        charging = false
        Haptics.shared.chargeEnded()
    }

    private func pan(_ p: Vec2) -> Float { Float(max(-1, min(1, (p.x / max(1, screen.x)) * 2 - 1))) * 0.8 }

    override func pauseChanged(_ on: Bool) {
        if on { endCharge(); sounds?.resetLadder() }
    }

    override func leave() {
        endCharge()
        sounds?.hold(false)
        super.leave()
    }

    private func summary(_ r: FishingResult) -> ArcadeOutcome {
        var lines = [L("Поймано: {0} из {1}", r.landed, r.goal)]
        if let m = r.meanHoldSec { lines.append(L("Среднее время взгляда на рыбу: {0} с", String(format: "%.1f", m))) }
        lines.append(L("Время: {0}", ArcadeView.clock(Int(r.durationSec.rounded()))))
        return ArcadeOutcome(game: .fishing, level: r.level, stars: r.stars, score: r.score, accuracy: r.accuracy,
                             hits: r.landed, misses: max(0, r.goal - r.landed), lines: lines, nextOpen: false,
                             reactionSec: r.meanHoldSec)
    }

    /// Blinks do nothing here: the hold catches.
    override func act(t: Double, host: Double, aim: Vec2?) {}

    override func paint(into draws: inout [ToonDraw], t: Double) {
        guard let stage, let p = pond else { return }
        stage.draw(p, at: t, moments: moments, into: &draws, over: &over)
    }

    override func fillHud(_ hud: inout ArcadeHud, t: Double) {
        guard let p = pond else { return }
        let r = p.result(at: t)
        hud.score = p.score
        hud.landed = r.landed
        hud.goal = r.goal
        hud.secondsLeft = Int(ceil(p.remaining(at: t)))
        if let h = p.holding {
            hud.reel = h.progress
            hud.reelSpot = h.fish.position
            hud.reelRadius = p.radius(h.fish) * 1.6
        } else {
            hud.reel = nil
            hud.reelSpot = nil
        }
    }

    /// CI: holds the fish nearest the top until it is caught, then the next.
    override func botStep(t: Double) -> Vec2? {
        guard let p = pond else { return nil }
        if let h = p.holding { return h.fish.position }
        return p.fish.min { $0.position.y < $1.position.y }?.position
    }
}
