import SpriteKit
import UIKit

/// Textures shared by every stone of a play (the rings of each stone size, the lamp, dust and motes) and the one crack
/// shader. Main thread.
final class StoneArt {
    let scale: CGFloat
    let lamp: SKTexture?
    let dust: SKTexture?
    let mote: SKTexture?
    private var ringCache: [Int: [(texture: SKTexture, radius: CGFloat)]] = [:]

    init(scale: CGFloat) {
        self.scale = scale
        lamp = SceneArt.glow(Atlas.UI.vermilion.cgColor, alpha: 0.22, scale: scale)
        dust = SceneArt.glow(SceneArt.stoneMid, alpha: 0.6, scale: scale)
        mote = SceneArt.mote(scale: scale)
    }

    /// The three engraved rings round a stone of `radius` pt at target scale `k`: radii radius + (8, 13, 18) × k.
    func rings(radius: CGFloat, k: CGFloat) -> [(texture: SKTexture, radius: CGFloat)] {
        let key = Int((radius * 2).rounded())
        if let cached = ringCache[key] { return cached }
        let made: [(texture: SKTexture, radius: CGFloat)] = [8.0, 13.0, 18.0].enumerated().compactMap { i, gap in
            let r = radius + CGFloat(gap) * k
            guard let t = SceneArt.ring(radius: r, ticks: i == 1, scale: scale) else { return nil }
            return (t, r)
        }
        ringCache[key] = made
        return made
    }

    /// One crack shader for every overlay (FeelShaders.crackReveal): the reveal reads each overlay's own progress from
    /// the attribute `a_progress`, so all overlays share one compiled program.
    static let crackShader: SKShader = {
        let source = FeelShaders.crackReveal.replacingOccurrences(of: "u_progress", with: "a_progress")
        // The atlas look's ink at 90%, premultiplied.
        let ink = SIMD4<Float>(0.114 * 0.9, 0.141 * 0.9, 0.220 * 0.9, 0.9)
        let shader = SKShader(source: source, uniforms: [SKUniform(name: "u_ink", vectorFloat4: ink)])
        shader.attributes = [SKAttribute(name: "a_progress", type: .float)]
        return shader
    }()
}

/// Sky-stones baked ahead on a background queue, a few per size, so a spawn takes a finished texture; every stone
/// drawn is a new one. A stone is baked on the spot only when its size's pool has run dry.
final class StoneFactory {
    private let queue = DispatchQueue(label: "spanther.stones", qos: .userInitiated)
    private let lock = NSLock()
    private var pools: [Int: [SceneArt.BakedStone]] = [:]
    private var rng: FeelRandom
    private let scale: CGFloat
    private let perSize = 6

    init(scale: CGFloat, seed: UInt64) {
        self.scale = scale
        rng = FeelRandom(seed: seed)
    }

    private static func key(_ radius: Double) -> Int { Int((radius * 2).rounded()) }

    /// Fills the pools for these radii (pt) in the background.
    func prewarm(radii: [Double]) {
        for r in radii { refill(radius: r) }
    }

    /// A finished stone of `radius` pt; the pool is topped up behind it.
    func take(radius: Double) -> SceneArt.BakedStone? {
        let k = Self.key(radius)
        var pooled: SceneArt.BakedStone?
        lock.lock()
        if var list = pools[k], !list.isEmpty {
            pooled = list.removeFirst()
            pools[k] = list
        }
        lock.unlock()
        refill(radius: radius)
        if let pooled { return pooled }
        return bake(radius: radius)
    }

    private func refill(radius: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            let k = Self.key(radius)
            while true {
                self.lock.lock()
                let have = self.pools[k]?.count ?? 0
                self.lock.unlock()
                guard have < self.perSize, let stone = self.bake(radius: radius) else { return }
                self.lock.lock()
                self.pools[k, default: []].append(stone)
                self.lock.unlock()
            }
        }
    }

    private func bake(radius: Double) -> SceneArt.BakedStone? {
        lock.lock()
        let stone = SkyStone.make(radius: radius, rng: &rng)
        lock.unlock()
        return SceneArt.bake(stone, scale: scale)
    }
}

/// A sky-stone in play (architecture proposal, "Cel look that stays cheap" and "The pop, step by step"): one quad of
/// baked stone that turns with the model and leans toward the gaze point on a damped spring; a warm lamp under it
/// while it is looked at; three engraved rings that turn into alignment over the hold (alignment is the lock; there
/// is still no cursor); and, from the hold's start, a crack overlay whose shader reveals the cracks as far as the hold
/// has come, healing when the gaze leaves. The cracks run along the shards it will burst into, which are cut off the
/// main thread when the hold starts.
final class StoneNode: SKNode {
    let baked: SceneArt.BakedStone
    let radius: CGFloat
    let body: SKSpriteNode
    private let lamp: SKSpriteNode?
    private let rings: [SKSpriteNode]
    private var overlay: SKSpriteNode?
    private var lean = DampedSpring(frequency: 5, dampingRatio: 0.6)
    private var ringsShown: CGFloat = 0
    private var starvedShown = false
    /// The shards and the impact point (stone-local pt), once the background bake is done.
    private(set) var prefracture: Prefracture?
    private var prefractureAsked = false

    /// How far each ring starts turned away from the lock (rad).
    private static let turns: [CGFloat] = [1.35, -2.25, 2.95]
    private static let bakeQueue = DispatchQueue(label: "spanther.fracture", qos: .userInitiated)
    private static var bakes: UInt64 = 0

    struct Prefracture {
        let impact: SIMD2<Double>
        let shards: [SceneArt.BakedShard]
    }

    /// `k`: «Мелкие цели», the rings and the lamp shrink with the stone.
    init(baked: SceneArt.BakedStone, art: StoneArt, k: CGFloat) {
        self.baked = baked
        radius = CGFloat(baked.stone.radius)
        body = SKSpriteNode(texture: baked.texture, size: CGSize(width: baked.side, height: baked.side))
        if let t = art.lamp {
            let l = SKSpriteNode(texture: t)
            let d = (CGFloat(baked.stone.radius) + 18 * k) * 2.4
            l.size = CGSize(width: d, height: d)
            l.isHidden = true
            lamp = l
        } else {
            lamp = nil
        }
        rings = art.rings(radius: CGFloat(baked.stone.radius), k: k).map { ring in
            let side = ring.radius * 2 + 16
            let s = SKSpriteNode(texture: ring.texture, size: CGSize(width: side, height: side))
            s.alpha = 0
            return s
        }
        super.init()
        if let lamp { addChild(lamp) }
        addChild(body)
        rings.forEach { addChild($0) }
        zPosition = 10
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Places the stone for this frame. `gaze`: where the player looks (scene pt), nil when nowhere; `dt`: seconds
    /// since the last frame. The first frame of a hold starts the pre-fracture at the gaze point.
    func sync(_ a: Asteroid, at p: CGPoint, gaze: CGPoint?, dt: Double) {
        position = p
        body.zRotation = CGFloat(a.rotation)
        let t = CGFloat(max(0, min(1, a.progress)))
        // The lean: up to 6% of the radius toward the gaze point while it rests on the stone.
        var target = SIMD2<Double>(0, 0)
        if a.isTargeted, let g = gaze {
            let d = SIMD2<Double>(Double(g.x - p.x), Double(g.y - p.y))
            let len = (d * d).sum().squareRoot()
            if len > 0.5 { target = d * (0.06 * min(len, Double(radius)) / len) }
        }
        lean.step(toward: target, dt: max(0, min(0.1, dt)))
        body.position = CGPoint(x: lean.position.x, y: lean.position.y)
        lamp?.isHidden = !a.isTargeted
        // The rings show while the stone is looked at or charged, and turn into alignment as the hold fills.
        let want: CGFloat = (a.isTargeted || t > 0) ? 1 : 0
        ringsShown += (want - ringsShown) * min(1, CGFloat(dt) * 10)
        let eased = 1 - (1 - t) * (1 - t)
        for (i, ring) in rings.enumerated() {
            ring.alpha = ringsShown
            ring.zRotation = Self.turns[i % Self.turns.count] * (1 - eased)
        }
        // Looked at without the energy to pay for it: the rings and the light turn vermilion ("reload first").
        if a.isStarved != starvedShown {
            starvedShown = a.isStarved
            for ring in rings {
                ring.color = Atlas.UI.vermilion
                ring.colorBlendFactor = a.isStarved ? 1 : 0
            }
        }
        if t > 0, !prefractureAsked, !a.isStarved { requestPrefracture(gaze: gaze, center: p, rotation: a.rotation) }
        overlay?.setValue(SKAttributeValue(float: Float(max(0, (t - 0.08) / 0.92))), forAttribute: "a_progress")
    }

    private func requestPrefracture(gaze: CGPoint?, center p: CGPoint, rotation: Double) {
        prefractureAsked = true
        let impact = Self.local(gaze, center: p, rotation: rotation)
        let baked = self.baked
        Self.bakes &+= 1
        let seed = Self.bakes &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(baked.stone.radius * 1000)
        Self.bakeQueue.async { [weak self] in
            let made = Self.cut(baked, impact: impact, seed: seed)
            DispatchQueue.main.async { self?.install(made.prefracture, crackMap: made.crackMap) }
        }
    }

    /// A scene point turned into the stone's own frame (stone-local pt): the centre when there is none.
    static func local(_ point: CGPoint?, center p: CGPoint, rotation: Double) -> SIMD2<Double> {
        guard let point else { return SIMD2<Double>(0, 0) }
        let dx = Double(point.x - p.x), dy = Double(point.y - p.y)
        let c = cos(-rotation), s = sin(-rotation)
        return SIMD2<Double>(dx * c - dy * s, dx * s + dy * c)
    }

    /// The Voronoi shards round `impact`, the cracks along their shared edges and both baked. Any thread.
    static func cut(_ baked: SceneArt.BakedStone, impact: SIMD2<Double>, seed: UInt64) -> (prefracture: Prefracture, crackMap: SKTexture?) {
        var rng = FeelRandom(seed: seed)
        let outline = baked.stone.outline
        let at = outline.pulledInside(impact)
        let shards = Fracture.shatter(outline, impact: at, rng: &rng)
        let cracks = CrackPattern.along(shards, impact: at, outline: outline)
        let map = SceneArt.crackMap(cracks, side: baked.side, scale: baked.scale)
        return (Prefracture(impact: at, shards: SceneArt.shards(shards, of: baked)), map)
    }

    private func install(_ pre: Prefracture, crackMap: SKTexture?) {
        guard parent != nil else { return }
        prefracture = pre
        guard let crackMap, overlay == nil else { return }
        let o = SKSpriteNode(texture: crackMap, size: body.size)
        o.shader = StoneArt.crackShader
        o.setValue(SKAttributeValue(float: 0), forAttribute: "a_progress")
        body.addChild(o)
        overlay = o
    }
}

/// The burst after a lock (architecture proposal, "The pop, step by step", 4): a 60 ms squash of the stone, then its
/// shards fly out under Feel's ShardFlight (gravity, drag, spin, one bounce off Earth), a dust puff, and 3–5 motes that
/// curve into the collection jar. Driven by the scene's update, gone after about 1.3 s.
final class PopEffect {
    let node = SKNode()
    private let squashNode = SKNode()
    private var sprites: [SKSpriteNode] = []
    private var flight: ShardFlight
    private var motes: [(path: MotePath, sprite: SKSpriteNode, arrived: Bool)] = []
    private let baseRotation: CGFloat
    private let squash: Double
    private let center: CGPoint
    private let radius: CGFloat
    private weak var jar: SKNode?
    private let art: StoneArt
    private var t = 0.0
    private var burst = false
    private var rng: FeelRandom
    private(set) var finished = false

    init(stone: StoneNode, center: CGPoint, rotation: Double, floorY: Double, jar: SKNode?, art: StoneArt,
         seed: UInt64, squash: Double = 0.06) {
        var random = FeelRandom(seed: seed)
        // The shards: those cut when the hold began, or cut now if the hold was too short for the background bake.
        let pre = stone.prefracture ?? StoneNode.cut(stone.baked, impact: SIMD2<Double>(0, 0), seed: seed).prefracture
        // Feel's shards are in the stone's own frame; turned by the stone's rotation they start where they show.
        let c = cos(rotation), s = sin(rotation)
        func turn(_ v: SIMD2<Double>) -> SIMD2<Double> { SIMD2<Double>(v.x * c - v.y * s, v.x * s + v.y * c) }
        let turned: [Shard] = pre.shards.map { piece in
            var shard = piece.shard
            shard.polygon = ConvexPolygon(vertices: shard.polygon.vertices.map(turn))
            shard.seed = turn(shard.seed)
            shard.centroid = turn(shard.centroid)
            return shard
        }
        let made = ShardFlight.burst(turned, center: SIMD2<Double>(Double(center.x), Double(center.y)),
                                     impact: turn(pre.impact), floorY: floorY, rng: &random)
        self.center = center
        radius = stone.radius
        baseRotation = CGFloat(rotation)
        self.squash = squash
        self.jar = jar
        self.art = art
        flight = made
        rng = random
        // During the squash the stone's own quad, flattened and widened in screen axes.
        let copy = SKSpriteNode(texture: stone.body.texture, size: stone.body.size)
        copy.zRotation = CGFloat(rotation)
        copy.position = stone.body.position
        squashNode.addChild(copy)
        squashNode.position = center
        squashNode.zPosition = 12
        node.addChild(squashNode)
        for piece in pre.shards {
            let sprite = SKSpriteNode(texture: piece.texture, size: piece.size)
            sprite.anchorPoint = piece.anchor
            sprite.isHidden = true
            sprite.zPosition = 12
            node.addChild(sprite)
            sprites.append(sprite)
        }
    }

    func step(dt: Double) {
        guard !finished else { return }
        t += max(0, min(0.1, dt))
        if t < squash {
            let k = Squash.scale(at: t, duration: squash)
            squashNode.xScale = CGFloat(k.x)
            squashNode.yScale = CGFloat(k.y)
            return
        }
        if !burst {
            burst = true
            squashNode.removeFromParent()
            sprites.forEach { $0.isHidden = false }
            puff()
            if let jar {
                let origin = SIMD2<Double>(Double(center.x), Double(center.y))
                let end = SIMD2<Double>(Double(jar.position.x), Double(jar.position.y))
                for path in MotePath.toJar(from: origin, jar: end, rng: &rng) {
                    let sprite = SKSpriteNode(texture: art.mote, size: CGSize(width: 10, height: 10))
                    sprite.position = center
                    sprite.zPosition = 30
                    node.addChild(sprite)
                    motes.append((path, sprite, false))
                }
            }
        }
        let since = t - squash
        flight.step(dt: min(0.1, dt))
        let fade = CGFloat(since > 0.6 ? max(0, 1 - (since - 0.6) / 0.45) : 1)
        for (i, body) in flight.bodies.enumerated() where i < sprites.count {
            sprites[i].position = CGPoint(x: body.position.x, y: body.position.y)
            sprites[i].zRotation = baseRotation + CGFloat(body.angle)
            sprites[i].alpha = fade
        }
        for i in motes.indices {
            let p = motes[i].path.point(at: since)
            motes[i].sprite.position = CGPoint(x: p.x, y: p.y)
            if !motes[i].arrived, since >= motes[i].path.delay + motes[i].path.duration {
                motes[i].arrived = true
                motes[i].sprite.run(.sequence([.fadeOut(withDuration: 0.12), .removeFromParent()]))
                jar?.run(.sequence([.scale(to: 1.15, duration: 0.06), .scale(to: 1, duration: 0.12)]))
            }
        }
        if since > 1.25 {
            finished = true
            node.removeFromParent()
        }
    }

    /// A dust puff where the stone was: soft blobs that swell, drift up a little and fade.
    private func puff() {
        guard let dust = art.dust else { return }
        for i in 0..<5 {
            let blob = SKSpriteNode(texture: dust)
            let d = radius * CGFloat(rng.uniform(0.7, 1.1))
            blob.size = CGSize(width: d, height: d)
            let a = Double(i) / 5 * 2 * Double.pi + rng.uniform(0, 1)
            blob.position = CGPoint(x: center.x + CGFloat(cos(a)) * radius * 0.35, y: center.y + CGFloat(sin(a)) * radius * 0.35)
            blob.zPosition = 11
            node.addChild(blob)
            blob.run(.sequence([
                .group([.scale(to: 2.2, duration: 0.55), .fadeOut(withDuration: 0.55),
                        .moveBy(x: CGFloat(cos(a)) * radius * 0.4, y: 10, duration: 0.55)]),
                .removeFromParent(),
            ]))
        }
    }
}

/// A red sign as one baked quad: it drifts in like a stone, fades in, and fades away when it leaves the play.
final class SignNode: SKSpriteNode {
    init(_ s: Decoy, texture: SKTexture?) {
        let side = CGFloat(s.radius) * 2 + 4
        super.init(texture: texture, color: .clear, size: CGSize(width: side, height: side))
        zPosition = 9
        alpha = 0
        run(.fadeIn(withDuration: 0.5))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Fades away where it is.
    func leave(seconds: Double) {
        removeAllActions()
        run(.sequence([.group([.fadeOut(withDuration: seconds), .scale(to: 0.85, duration: seconds)]), .removeFromParent()]))
    }
}
