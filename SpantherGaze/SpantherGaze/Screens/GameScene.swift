import SpriteKit
import UIKit

/// Score, shields and level for the SwiftUI HUD. Updated on game events, not every frame.
final class GameHUD: ObservableObject {
    @Published var score = 0
    @Published var shields = 5
    @Published var level = 1
    /// Whole seconds left in a timed level, nil when levels are not timed.
    @Published var secondsLeft: Int?
    @Published var lookBack = false
    @Published var banner: String?
    @Published var energy = 0
    @Published var energyMax = 0
    /// Looking at a meteor the pool cannot pay for, or the pool is empty: show the reload hint.
    @Published var needsReload = false
    /// Blinks (or taps) counted toward the next reload, and how many a reload takes.
    @Published var reloadProgress = 0
    @Published var reloadNeeded = 3
    /// Bumped on every reload so the HUD can pulse.
    @Published var reloadCount = 0
    /// A quiet line under the top row («На красный знак не смотрим»); it fades in and out, nothing flashes.
    @Published var notice: String?
    /// Red signs that have left the play, and how many of them the player looked at. Shown on the pause plate.
    @Published var decoys = 0
    @Published var decoyErrors = 0
    /// Stones burnt in a row, broken by a stone reaching Earth or a look at a red sign, and the celebration.
    let fx = StreakFX()
}

/// Draws GameModel as sky-stones over the living garden, which the scene draws itself (GardenNode): the SKView is
/// opaque, one renderer for the whole screen. No aim is drawn, as in the rhythm mode: the stone being looked at gets a warm light under
/// it, its three engraved rings turn into alignment over the hold, cracks grow from the gaze point, and the lock bursts
/// it into shards with the four-layer pop (architecture proposal §3). Every piece is a baked quad: no SKShapeNode. Model
/// space is screen pt with y down; SpriteKit is y up, so `sk(_:)` flips.
final class GameScene: SKScene {
    var gazeSource: () -> GazeInput = { .notLooking }
    var useTouch = false
    var marginPt = 30.0
    var config: BalanceConfig!
    var onRecord: ((AsteroidRecord) -> Void)?
    /// Returns true once per finished 3-blink reload (AppModel.consumeBlinkReload).
    var blinkReload: () -> Bool = { false }
    /// Blinks counted toward the next reload, for the HUD.
    var pendingBlinks: () -> Int = { 0 }
    /// CSV event rows: kind ("energy" per kill, "reload", "level" for a new level, "restart" when shields ran
    /// out, "recharge" when they ran out on a timed level), the energy left after it, and the level it happened on.
    var onGameEvent: ((_ kind: String, _ energy: Int, _ level: Int) -> Void)?
    /// Eye mode: the centre of the meteor taken as looked at on this frame (screen pt), or nil. The aim adapter
    /// learns from it.
    var onLookedAt: ((Vec2?) -> Void)?
    /// «Мелкие цели»: the scale of the meteors, the red signs and their hit zones, and the smallest zone it may
    /// give (screen pt). From AppModel.targetScale and zoneFloorPt.
    var targetScale = 1.0
    var zoneFloorPt = 0.0
    /// The play has red signs to pass by.
    var decoysOn = false
    /// Eye mode: the gaze point is the one kept from before a blink (AppModel.gazeHeld).
    var gazeHeld: () -> Bool = { false }
    /// A red sign left the play (looked at or passed by), with where it was (screen pt).
    var onDecoy: ((DecoyRecord, Vec2) -> Void)?
    let hud = GameHUD()
    var paused_ = false {
        // The pause plate: the rumble stops and the next lock starts the chime ladder from the bottom.
        didSet { if paused_ { endCharge(); sounds?.resetLadder() } }
    }
    /// Draw the aim (debugging only): a cursor a little off where the player looks pulls the eyes after it.
    var showAim = false

    private(set) var model: GameModel?
    private let world = SKNode()
    private var stones: [Int: StoneNode] = [:]
    private var signs: [Int: SignNode] = [:]
    /// Red signs sent in so far: the first one comes with a line that says what to do.
    private var signsSeen = 0
    /// The bubble's rule has been said in this play (the first look at a stone still in its bubble).
    private var bubbleExplained = false
    /// The debug aim, a baked ring: ink, or vermilion while it rests on a stone the pool can't pay for.
    private let reticle = SKSpriteNode()
    private var reticleStarved = false
    private var touchPoint: Vec2?
    private var lastTime: TimeInterval = 0
    private let hitHaptic = UINotificationFeedbackGenerator()
    private var tapBurst = BurstCounter(count: 3, windowSec: 2)

    // The pop (architecture proposal §3): baked art, stones made ahead, bursts in flight, the sound bank, the jar.
    private var art: StoneArt?
    private var factory: StoneFactory?
    private var sounds: PopSounds?
    private var pops: [PopEffect] = []
    private let jar = SKSpriteNode()
    private var signTextures: [Int: SKTexture] = [:]
    private var waveTexture: SKTexture?
    private var impactTexture: SKTexture?
    /// The stone the gaze is charging now (it can be burned), and when its charge tone last sounded.
    private var chargingID: Int?
    private var chargeToneAt = (id: -1, time: 0.0)
    private var bursts: UInt64 = 0
    private var gardenNode: GardenNode?
    /// The sunlit sky and the golden motes drifting up through it, behind the garden and the play.
    private var skyNode: SKSpriteNode?
    private var motes: SKEmitterNode?
    private var frameIndex = 0
    /// The size `start()` laid the play out for; whether the play has had its first result yet (a stone burned or
    /// landed, a red sign looked at or passed by); and when the scene last took another size before that.
    private var laidOutFor: CGSize = .zero
    private var playBegun = false
    private var resizedAt: TimeInterval?

    #if DEBUG
    /// Bot for the Simulator smoke test (see AppModel.autoplay).
    var autoplay = false
    /// The bot leaves for the menu after this many seconds of play, so the run also shows the summary. Nil: stays.
    var botQuitAfter: Double?
    var botQuit: (() -> Void)?
    private var botDrySince: Double?
    private var botNextPress = 0.0
    private var botBlinks = 0
    #endif

    override func didMove(to view: SKView) {
        // One renderer for the whole screen (architecture proposal, "Rendering"): the scene is opaque paper and
        // draws the garden itself, so SwiftUI no longer composites a canvas under it. 60 fps at most.
        backgroundColor = Atlas.UI.paper
        view.allowsTransparency = false
        view.preferredFramesPerSecond = 60
        view.shouldCullNonVisibleNodes = true
        // SpriteView may present the scene again when SwiftUI rebuilds the view; keep the running game.
        guard world.parent == nil else {
            sounds?.hold(true)
            return
        }
        addChild(world)
        start()
    }

    override func willMove(from view: SKView) {
        endCharge()
        sounds?.hold(false)
    }

    // The scene can be shown before it has the whole screen: on a phone SwiftUI first gave it only the safe area
    // (734 x 372 of 852 x 393 pt), and `.resizeFill` then grew it without laying the play out again, so the sky, the
    // hill and the play kept to the bottom-left with bare cream on the right and at the top. So until the play's
    // first result, a new size lays the play out again, once the size has held for a moment (`update`).
    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard model != nil, !playBegun, size.width > 1, size.height > 1 else { return }
        if abs(size.width - laidOutFor.width) > 0.5 || abs(size.height - laidOutFor.height) > 0.5 {
            resizedAt = CACurrentMediaTime()
        }
    }

    func start() {
        laidOutFor = size
        playBegun = false
        resizedAt = nil
        world.removeAllChildren()
        stones.removeAll()
        signs.removeAll()
        pops.removeAll()
        signsSeen = 0
        bubbleExplained = false
        chargingID = nil
        let m = GameModel(config: config, screen: Vec2(size.width, size.height), marginPt: marginPt,
                          targetScale: targetScale, zoneFloorPt: zoneFloorPt, decoys: decoysOn)
        model = m
        let scale = view?.contentScaleFactor ?? 2
        // The garden behind the play, still when Earth shakes (it is not in `world`).
        gardenNode?.removeFromParent()
        let gardenMade = GardenNode(size: size, scale: scale)
        gardenMade.zPosition = -10
        addChild(gardenMade)
        gardenNode = gardenMade
        addSkyAndMotes()
        // Earth: only the cap that shows above the bottom edge, engraved like a globe on an old chart (one baked
        // quad). In landscape the whole circle would be about 3,100 pt across.
        let h = Double(size.height)
        let top = CGFloat(h - m.earthTopY + 6)
        if let earthTex = SceneArt.earth(width: size.width, top: top, margin: 20, surfaceY: { h - m.earthSurfaceY(atX: $0) },
                                         centreX: m.earthCenter.x, radius: m.earthRadius, scale: scale) {
            let earth = SKSpriteNode(texture: earthTex, size: CGSize(width: size.width + 40, height: top))
            earth.anchorPoint = .zero
            earth.position = CGPoint(x: -20, y: 0)
            earth.name = "earth"
            world.addChild(earth)
        }
        addGrass(m, scale: scale)
        reticle.texture = SceneArt.circle(radius: 14, stroke: Atlas.UI.ink.withAlphaComponent(0.7).cgColor, width: 2,
                                          scale: scale)
        reticle.size = CGSize(width: 32, height: 32)
        reticle.zPosition = 50
        reticle.isHidden = true
        world.addChild(reticle)
        // The pop's pieces: shared art, stones baked ahead for every size, the sound bank and the haptic players.
        let artNow = StoneArt(scale: scale)
        art = artNow
        bursts &+= 1
        let seed = UInt64(Date().timeIntervalSince1970 * 1000) &+ bursts
        let made = StoneFactory(scale: scale, seed: seed)
        made.prewarm(radii: config.classes.values.map { $0.sizePt / 2 * targetScale })
        factory = made
        if sounds == nil { sounds = PopSounds(seed: seed) }
        sounds?.prepare(seed: seed)
        Haptics.shared.prepare()
        waveTexture = SceneArt.circle(radius: 30, stroke: Atlas.UI.ink.withAlphaComponent(0.6).cgColor, width: 2, scale: scale)
        impactTexture = SceneArt.circle(radius: 40, stroke: Atlas.UI.vermilion.cgColor, width: 1.5,
                                        fill: Atlas.UI.vermilion.withAlphaComponent(0.45).cgColor, scale: scale)
        signTextures.removeAll()
        // The jar the motes fly into, under the score at the top left (the camera's notch is further left).
        jar.texture = SceneArt.jar(scale: scale)
        jar.size = CGSize(width: 26, height: 30)
        jar.position = CGPoint(x: 74, y: size.height - 80)
        jar.zPosition = 40
        world.addChild(jar)
        // The crack shader compiles the first time it draws: draw it once now, almost invisibly, not at the first hold.
        let warm = SKSpriteNode(texture: artNow.mote, size: CGSize(width: 2, height: 2))
        warm.shader = StoneArt.crackShader
        warm.setValue(SKAttributeValue(float: 0), forAttribute: "a_progress")
        warm.alpha = 0.01
        warm.position = CGPoint(x: 4, y: 4)
        world.addChild(warm)
        warm.run(.sequence([.wait(forDuration: 0.5), .removeFromParent()]))
        hud.shields = m.shields; hud.level = m.level; hud.score = 0
        hud.secondsLeft = m.levelTimeLeft.map { Int($0.rounded(.up)) }
        hud.energy = m.energy; hud.energyMax = m.energyMax
        if let e = config.energy {
            tapBurst = BurstCounter(count: e.touchReloadTaps, windowSec: e.reloadWindowSec)
            hud.reloadNeeded = useTouch ? e.touchReloadTaps : e.reloadBlinks
        }
        _ = blinkReload()   // drop a reload blinked on the menu
    }

    /// Touch mode: one tap on the energy bar. Three inside the window reload.
    /// The sky (a small baked gradient stretched over the screen) and golden motes rising slowly through it. They sit
    /// outside `world`, so they stay still when Earth shakes. About 20 motes at a time, soft and slow: light in the
    /// air, not something to chase.
    private func addSkyAndMotes() {
        skyNode?.removeFromParent()
        if let t = SceneArt.sky() {
            let sky = SKSpriteNode(texture: t, size: size)
            sky.anchorPoint = .zero
            sky.zPosition = -20
            addChild(sky)
            skyNode = sky
        }
        motes?.removeFromParent()
        guard let t = SceneArt.glow(SceneArt.mutedGold, alpha: 0.95, scale: 1) else { return }
        let e = SKEmitterNode()
        e.particleTexture = t
        e.particleBirthRate = 2.2
        e.particleLifetime = 10
        e.particleLifetimeRange = 3
        e.position = CGPoint(x: size.width / 2, y: size.height * 0.4)
        e.particlePositionRange = CGVector(dx: size.width, dy: size.height * 0.6)
        e.emissionAngle = .pi / 2
        e.emissionAngleRange = 0.7
        e.particleSpeed = 9
        e.particleSpeedRange = 5
        e.particleScale = 0.17
        e.particleScaleRange = 0.08
        e.particleAlpha = 0
        e.particleAlphaSequence = SKKeyframeSequence(keyframeValues: [0.0, 0.85, 0.85, 0.0], times: [0, 0.2, 0.75, 1])
        e.particleBlendMode = .alpha
        e.zPosition = -5
        e.advanceSimulationTime(10)
        addChild(e)
        motes = e
    }

    /// Grass along the hill's crest in short strips, each turned to the slope and swaying from its roots in the wind
    /// (FeelShaders.windSway anchored at the bottom). Three wind phases, so neighbouring strips do not move as one.
    private func addGrass(_ m: GameModel, scale: CGFloat) {
        let strip: CGFloat = 96, high: CGFloat = 22
        let h = Double(size.height)
        let winds = (0..<3).map { k in
            SKShader(source: FeelShaders.windSway, uniforms: [
                SKUniform(name: "u_amplitude", float: 0.03),
                SKUniform(name: "u_speed", float: 1.3 + 0.25 * Float(k)),
                SKUniform(name: "u_phase", float: 2.1 * Float(k)),
                SKUniform(name: "u_anchor", float: 0),
            ])
        }
        var x: CGFloat = -10, k = 0
        while x < size.width + 10 {
            let cx = Double(x + strip / 2)
            let left = h - m.earthSurfaceY(atX: cx - 20), right = h - m.earthSurfaceY(atX: cx + 20)
            let tilt: Double = atan2(right - left, 40.0)
            if let t = SceneArt.grass(width: strip, height: high, seed: UInt64(k + 1) &* 0x9E37_79B9, scale: scale) {
                let g = SKSpriteNode(texture: t, size: CGSize(width: strip + 12, height: high))
                g.anchorPoint = CGPoint(x: 0.5, y: 0)
                g.position = CGPoint(x: CGFloat(cx), y: CGFloat(h - m.earthSurfaceY(atX: cx)) - 3)
                g.zRotation = CGFloat(tilt)
                g.shader = winds[k % winds.count]
                g.zPosition = 1
                world.addChild(g)
            }
            x += strip
            k += 1
        }
    }

    func reloadTap() {
        guard useTouch, let m = model else { return }
        let now = CACurrentMediaTime()
        if tapBurst.press(at: now) { doReload(m) }
        hud.reloadProgress = tapBurst.pending(at: now)
    }

    private func doReload(_ m: GameModel) {
        guard m.reload() else { return }
        hitHaptic.notificationOccurred(.success)
        hud.energy = m.energy
        hud.reloadCount += 1
        onGameEvent?("reload", m.energy, m.level)
        let wave = SKSpriteNode(texture: waveTexture, size: CGSize(width: 64, height: 64))
        wave.position = CGPoint(x: size.width / 2, y: size.height - 120)
        wave.zPosition = 60
        world.addChild(wave)
        wave.run(.sequence([.group([.scale(to: 9, duration: 0.6), .fadeOut(withDuration: 0.6)]), .removeFromParent()]))
    }

    private func sk(_ p: Vec2) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }

    override func update(_ currentTime: TimeInterval) {
        // The scene took another size before the play's first result (`didChangeSize`): once that size has held for
        // 0.15 s, the play is laid out again for it, from the start.
        if let t = resizedAt, CACurrentMediaTime() - t > 0.15 {
            resizedAt = nil
            if !playBegun, size != laidOutFor { start() }
        }
        // A paused scene skips frames: the first frame after a pause must not jump by the whole pause.
        let dt = lastTime == 0 ? 0 : min(0.1, currentTime - lastTime)
        lastTime = currentTime
        // The garden's spores only drift: 30 updates a second are enough.
        frameIndex &+= 1
        if frameIndex % 2 == 0 { gardenNode?.update(time: CACurrentMediaTime()) }
        let reloadBlinked = blinkReload()
        guard let m = model, !paused_ else { return }
        var botGaze: GazeInput?
        #if DEBUG
        if autoplay { botGaze = botStep(m) }
        #endif
        if botGaze == nil {
            if !useTouch {
                if reloadBlinked { doReload(m) }
                let pb = pendingBlinks()
                if hud.reloadProgress != pb { hud.reloadProgress = pb }
            } else if hud.reloadProgress > 0, tapBurst.pending(at: CACurrentMediaTime()) == 0 {
                hud.reloadProgress = 0
            }
        }
        let gaze: GazeInput = botGaze ?? (useTouch ? (touchPoint.map { .point($0) } ?? .notLooking) : gazeSource())
        let held = botGaze == nil && !useTouch && gazeHeld()

        for e in m.update(dt: dt, gaze: gaze, held: held) {
            switch e {
            case .destroyed, .hitEarth, .decoyLooked, .decoyPassed: playBegun = true
            default: break
            }
            switch e {
            case .spawned(let a):
                if let art, let baked = factory?.take(radius: a.radius) {
                    let n = StoneNode(baked: baked, art: art, k: CGFloat(m.targetScale), shielded: a.isShielded)
                    n.position = sk(a.position)
                    stones[a.id] = n
                    world.addChild(n)
                }
            case .decoySpawned(let s):
                let n = SignNode(s, texture: signTexture(radius: s.radius))
                n.position = sk(s.position)
                signs[s.id] = n
                world.addChild(n)
                signsSeen += 1
                if signsSeen == 1 { notice(useTouch ? L("Красный знак не трогаем") : L("На красный знак не смотрим"), seconds: 4) }
            case .decoyLooked(let s, let rec):
                // An error, said quietly: the sign fades and a line reminds the rule. No flash, no shake, no buzz.
                signs.removeValue(forKey: s.id)?.leave(seconds: 0.7)
                hud.decoys += 1
                hud.decoyErrors += 1
                notice(useTouch ? L("Красный знак не трогаем") : L("На красный знак не смотрим"), seconds: 2.5)
                hud.fx.breakStreak()
                onDecoy?(rec, s.position)
            case .decoyPassed(let s, let rec):
                signs.removeValue(forKey: s.id)?.leave(seconds: 0.4)
                hud.decoys += 1
                onDecoy?(rec, s.position)
            case .destroyed(let a, let rec):
                if let stone = stones.removeValue(forKey: a.id) { pop(stone, a, m) }
                hud.score = m.score
                hud.fx.lock(at: CGPoint(x: a.position.x, y: a.position.y))
                onRecord?(rec)
            case .energySpent(_, let left):
                hud.energy = left
                onGameEvent?("energy", left, m.level)
            case .starved:
                break
            case .hitEarth(let a, let rec):
                impact(at: sk(a.position), radius: CGFloat(a.radius))
                stones.removeValue(forKey: a.id)?.removeFromParent()
                if chargingID == a.id { endCharge() }
                // A stone that got through breaks the run: the chime ladder starts from the bottom again.
                sounds?.resetLadder()
                hud.fx.breakStreak()
                hud.shields = max(0, m.shields)
                onRecord?(rec)
            case .shieldsDepleted(let lvl):
                stones.values.forEach { $0.removeFromParent() }
                stones.removeAll()
                endCharge()
                hud.shields = m.shields
                hud.energy = m.energy
                onGameEvent?("restart", m.energy, lvl)
                flash(L("Щиты кончились. Уровень {0} ещё раз", lvl))
            case .shieldsRecharged(let lvl):
                stones.values.forEach(fadeAway)
                stones.removeAll()
                endCharge()
                hud.shields = m.shields
                onGameEvent?("recharge", m.energy, lvl)
                flash(L("Щиты кончились и снова заряжены. Держись до конца уровня!"))
            case .levelEnded(_, let ratio, let next):
                // A timed level ends with meteors still up: they fade away with it.
                stones.values.forEach(fadeAway)
                stones.removeAll()
                endCharge()
                hud.level = next
                hud.shields = m.shields
                hud.energy = m.energy
                onGameEvent?("level", m.energy, next)
                flash(m.config.levelTimeLimitSec == nil
                      ? String(format: L("Сбито %.0f%% · Уровень %d"), ratio * 100, next)
                      : String(format: L("Уровень пройден! Сбито %.0f%% · Уровень %d"), ratio * 100, next))
            case .pausedForFace(let on):
                hud.lookBack = on
            }
        }

        let left = m.levelTimeLeft.map { Int($0.rounded(.up)) }
        if hud.secondsLeft != left { hud.secondsLeft = left }

        var gazePoint: CGPoint?
        if case .point(let p) = gaze { gazePoint = sk(p) }
        for a in m.asteroids { stones[a.id]?.sync(a, at: sk(a.position), gaze: gazePoint, dt: dt) }
        for s in m.decoys { signs[s.id]?.position = sk(s.position) }
        if !useTouch, botGaze == nil { onLookedAt?(m.asteroids.first { $0.isTargeted }?.position) }
        if !bubbleExplained, m.asteroids.contains(where: { $0.isTargeted && $0.isShielded }) {
            bubbleExplained = true
            notice(L("Метеорит в пузыре: жди, пока пузырь лопнет"), seconds: 3)
        }
        if hud.needsReload != m.needsReload { hud.needsReload = m.needsReload }
        charge(m)
        for p in pops { p.step(dt: dt) }
        pops.removeAll { $0.finished }

        if showAim, case .point(let p) = gaze {
            reticle.isHidden = false
            reticle.position = sk(p)
            let r = useTouch ? 14 : max(10, marginPt * 0.5)
            reticle.setScale(r / 14)
            // In eye mode the aim is about as big as the meteor's rings and sits right on them, so it would hide the
            // vermilion "no energy" rings. The aim turns vermilion as well while it rests on a stone the pool can't pay for.
            if reticleStarved != m.starved {
                reticleStarved = m.starved
                reticle.color = Atlas.UI.vermilion
                reticle.colorBlendFactor = m.starved ? 1 : 0
            }
        } else {
            reticle.isHidden = true
        }
    }

    /// The charge (architecture proposal, "The pop, step by step", 1): while the gaze rests on a stone it can burn, a
    /// soft rising tone from the stone's side when it lands and a faint rumble rising with the hold. A stone still in
    /// its bubble cannot be burned: no tone, no rumble.
    private func charge(_ m: GameModel) {
        let holding = m.asteroids.first { $0.isTargeted && !$0.isStarved && !$0.isShielded }
        if holding?.id != chargingID {
            chargingID = holding?.id
            if let h = holding {
                let now = CACurrentMediaTime()
                // A gaze that flickers at the zone's edge does not retrigger the tone.
                if chargeToneAt.id != h.id || now - chargeToneAt.time > 0.6 {
                    sounds?.charge(pan: StereoPlacement.pan(x: h.position.x, width: Double(size.width)))
                    chargeToneAt = (h.id, now)
                }
                Haptics.shared.chargeBegan()
            } else {
                Haptics.shared.chargeEnded()
            }
        }
        if let h = holding { Haptics.shared.chargeProgress(h.progress) }
    }

    /// A stone that leaves with its level or with the shields: it fades where it is.
    private func fadeAway(_ stone: StoneNode) {
        stone.removeAllActions()
        stone.run(.sequence([.group([.fadeOut(withDuration: 0.4), .scale(to: 0.85, duration: 0.4)]), .removeFromParent()]))
    }

    private func endCharge() {
        chargingID = nil
        Haptics.shared.chargeEnded()
    }

    /// The lock (architecture proposal, "The pop, step by step", 4): the stone squashes for 60 ms and bursts into the
    /// shards its cracks ran along; the crack, pop, chime and crumble play on one timeline with the crack and thud of
    /// the haptics.
    private func pop(_ stone: StoneNode, _ a: Asteroid, _ m: GameModel) {
        guard let art else {
            stone.removeFromParent()
            return
        }
        bursts &+= 1
        let center = stone.position
        let floorY = Double(size.height) - m.earthSurfaceY(atX: Double(center.x))
        let effect = PopEffect(stone: stone, center: center, rotation: a.rotation, floorY: floorY, jar: jar, art: art,
                               seed: bursts &* 0x2545_F491_4F6C_DD1D)
        stone.removeFromParent()
        world.addChild(effect.node)
        pops.append(effect)
        if chargingID == a.id { chargingID = nil }
        sounds?.lock(pan: StereoPlacement.pan(x: Double(center.x), width: Double(size.width)), at: CACurrentMediaTime() + 0.005)
        Haptics.shared.lock()
    }

    /// The red sign's quad for one radius, baked on first use.
    private func signTexture(radius: Double) -> SKTexture? {
        let key = Int((radius * 2).rounded())
        if let t = signTextures[key] { return t }
        let t = SceneArt.redSign(radius: CGFloat(radius), scale: view?.contentScaleFactor ?? 2)
        signTextures[key] = t
        return t
    }

    #if DEBUG
    /// Looks at the lowest meteor, even one it cannot afford (so the red ring and hint show). Two seconds
    /// after running dry it "blinks" (eyes) or taps the energy bar (touch) every 0.4 s until it reloads.
    private func botStep(_ m: GameModel) -> GazeInput {
        if let after = botQuitAfter, m.time > after {
            botQuitAfter = nil
            botQuit?()
        }
        // Every third red sign catches the bot's eye once it is well into view, so a run has both kinds: signs
        // looked at and signs passed by.
        if signsSeen % 3 == 2, let s = m.decoys.first, s.position.y > m.screen.y * 0.2, s.position.x > 0, s.position.x < m.screen.x {
            touchPoint = useTouch ? s.position : nil
            return .point(s.position)
        }
        // Like a player: reacts once a meteor is well into view (a third of the way down), then follows the lowest.
        let target = m.asteroids.filter { $0.position.y > m.screen.y * 0.33 }.max { $0.position.y < $1.position.y }
        if m.needsReload {
            if botDrySince == nil { botDrySince = m.time; botBlinks = 0 }
            if m.time - (botDrySince ?? m.time) > 2, m.time >= botNextPress {
                botNextPress = m.time + 0.4
                if useTouch {
                    reloadTap()
                } else {
                    botBlinks += 1
                    hud.reloadProgress = botBlinks
                    if botBlinks >= hud.reloadNeeded { botBlinks = 0; hud.reloadProgress = 0; doReload(m) }
                }
            }
        } else {
            botDrySince = nil
            botBlinks = 0
            if hud.reloadProgress != 0 { hud.reloadProgress = 0 }
        }
        touchPoint = useTouch ? target?.position : nil
        return target.map { .point($0.position) } ?? .notLooking
    }
    #endif

    private func flash(_ s: String) {
        hud.banner = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.hud.banner == s { self?.hud.banner = nil }
        }
    }

    /// How many quiet lines have been shown: a line is taken away only if no newer one has replaced it.
    private var noticeCount = 0

    /// Shows the quiet line under the top row for a few seconds (the HUD fades it in and out).
    private func notice(_ s: String, seconds: Double) {
        noticeCount += 1
        let mine = noticeCount
        hud.notice = s
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.noticeCount == mine { self?.hud.notice = nil }
        }
    }

    /// A stone that reached Earth: a vermilion flash where it hit (one baked quad) and a short shake of the world.
    private func impact(at p: CGPoint, radius: CGFloat) {
        hitHaptic.notificationOccurred(.error)
        let d = radius * 2.8
        let flash = SKSpriteNode(texture: impactTexture, size: CGSize(width: d, height: d))
        flash.position = p
        world.addChild(flash)
        flash.run(.sequence([.group([.scale(to: 2, duration: 0.5), .fadeOut(withDuration: 0.5)]), .removeFromParent()]))
        let s: CGFloat = 10
        world.run(.sequence([.moveBy(x: s, y: 0, duration: 0.04), .moveBy(x: -2 * s, y: 0, duration: 0.08), .moveBy(x: s, y: 0, duration: 0.04)]))
    }

    // Touch fallback: a finger on a meteor counts as looking at it.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { setTouch(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { setTouch(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touchPoint = nil }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchPoint = nil }
    private func setTouch(_ touches: Set<UITouch>) {
        guard let t = touches.first, let v = view else { return }
        let p = t.location(in: v)   // UIKit: top-left origin, y down = model space
        touchPoint = Vec2(p.x, p.y)
    }
}
