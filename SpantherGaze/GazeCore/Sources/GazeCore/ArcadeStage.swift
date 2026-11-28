import Foundation

// What the toon stage draws for the blink arcades (skill `metal-anime-stage`), as plain data the Metal renderer
// takes as it is: meshes built once per screen, then a list of draws each frame. Every animated value here is a
// function of the round's clock, and every object stands where its screen point (the rules' space) meets the
// ground, so the picture under a target is where the judge looks for it, whatever the camera.

/// How a draw is shaded: `ToonInstance.params.y` in ToonShaders.metal.
public enum ToonStyle: Int, Sendable {
    /// Three tone bands, cast shadows, a hard rim.
    case toon = 0
    /// One unlit colour: pits, the lock ring, eye shine.
    case flat = 1
    /// The pond's surface: see-through, with drifting light bands (the tint's alpha is its opacity).
    case water = 2
    /// Toon bands with the tint's alpha: dust puffs, splashes, a fish that swims off.
    case ghost = 3

    /// Drawn after the solid world, without writing depth.
    public var blended: Bool { self == .water || self == .ghost }
}

/// One instance of a mesh.
public struct ToonDraw: Equatable, Sendable {
    public var mesh: Int
    public var model: ToonMatrix
    /// Multiplies the vertex colours (linear RGB); alpha is the opacity of blended styles.
    public var tint: SIMD4<Float>
    /// Ink outline width (pt), 0 for none.
    public var outline: Float
    public var style: ToonStyle
    /// Whether it casts a shadow on the sun's map.
    public var shadow: Bool

    public init(mesh: Int, model: ToonMatrix, tint: SIMD4<Float> = SIMD4(1, 1, 1, 1), outline: Float = 0,
                style: ToonStyle = .toon, shadow: Bool = true) {
        self.mesh = mesh
        self.model = model
        self.tint = tint
        self.outline = outline
        self.style = style
        self.shadow = shadow
    }
}

/// The light and air of a scene: the sun (direction and its shadow map's box), the sky, the shadow tone, the fog.
public struct ToonLook: Equatable, Sendable {
    /// Unit vector towards the sun.
    public var toward: SIMD3<Float>
    /// World to the shadow map's clip space.
    public var sun: ToonMatrix
    public var skyTop: SIMD3<Float>
    public var skyHorizon: SIMD3<Float>
    /// Mixed into the shadowed band so shade is a cool colour, never grey.
    public var shade: SIMD3<Float>
    /// Fog from `fogStart` to `fogEnd` metres from the eye, towards the horizon colour.
    public var fogStart: Float
    public var fogEnd: Float

    /// The shadow map's box: an orthographic view along the sun that holds every point of `pts` (what the
    /// camera sees) with room above for whatever stands on them.
    public static func sun(toward: SIMD3<Float>, covering pts: [SIMD3<Float>]) -> ToonMatrix {
        guard !pts.isEmpty else { return .identity }
        var centre = SIMD3<Float>(0, 0, 0)
        for p in pts { centre += p }
        centre /= Float(pts.count)
        let dir = toward.unit
        let view = ToonMatrix.lookAt(eye: centre + dir * 40, target: centre, up: SIMD3(0, 1, 0))
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in pts {
            let q = view.point(p)
            lo = SIMD3(min(lo.x, q.x), min(lo.y, q.y), min(lo.z, q.z))
            hi = SIMD3(max(hi.x, q.x), max(hi.y, q.y), max(hi.z, q.z))
        }
        let pad: Float = 1
        let proj = ToonMatrix.orthographic(left: lo.x - pad, right: hi.x + pad, bottom: lo.y - pad, top: hi.y + pad,
                                           near: max(0.1, -hi.z - 25), far: -lo.z + 6)
        return proj * view
    }

    /// The ground the camera sees (y = 0 at the screen's corners and edges) and the same lifted by `tall` metres.
    public static func seen(by camera: ToonCamera, tall: Float = 3) -> [SIMD3<Float>] {
        let w = camera.screen.x, h = camera.screen.y
        var out: [SIMD3<Float>] = []
        for fx in [0.0, 0.5, 1.0] {
            for fy in [0.0, 0.5, 1.0] {
                guard let g = camera.ground(Vec2(fx * w, fy * h)) else { continue }
                out.append(g)
                out.append(g + SIMD3(0, tall, 0))
            }
        }
        return out
    }
}

/// A scene the renderer can draw: its camera, light and meshes (built once).
public protocol ToonScene {
    var camera: ToonCamera { get }
    var look: ToonLook { get }
    var meshes: [ToonMesh] { get }
}

extension ToonMesh {
    /// A star of `points` tips in the x-y plane facing +z, `depth` thick: dizzy stars and sparkles.
    public static func star(outer: Float, inner: Float, depth: Float, points: Int = 5, color: SIMD3<Float>) -> ToonMesh {
        var m = ToonMesh()
        let n = points * 2
        func corner(_ k: Int) -> SIMD3<Float> {
            let a = Float(k) / Float(n) * 2 * .pi + .pi / 2, r = k % 2 == 0 ? outer : inner
            return SIMD3(cos(a) * r, sin(a) * r, 0)
        }
        for front in [true, false] {
            let z: Float = front ? depth / 2 : -depth / 2, nz = SIMD3<Float>(0, 0, front ? 1 : -1)
            let centre = UInt32(m.vertices.count)
            m.vertices.append(ToonVertex(SIMD3(0, 0, z), nz, color))
            for k in 0..<n {
                var p = corner(k)
                p.z = z
                m.vertices.append(ToonVertex(p, nz, color))
            }
            for k in 0..<n {
                let a = centre + 1 + UInt32(k), b = centre + 1 + UInt32((k + 1) % n)
                let tri: [UInt32] = front ? [centre, a, b] : [centre, b, a]
                m.indices += tri
            }
        }
        let half = SIMD3<Float>(0, 0, depth / 2)
        for k in 0..<n {
            let p = corner(k), q = corner((k + 1) % n)
            let side = (q - p).cross(SIMD3(0, 0, 1)).unit
            let base = UInt32(m.vertices.count)
            let quad: [SIMD3<Float>] = [p - half, q - half, q + half, p + half]
            for v in quad { m.vertices.append(ToonVertex(v, side, color)) }
            let tri: [UInt32] = [base, base + 1, base + 2, base, base + 2, base + 3]
            m.indices += tri
        }
        return m
    }
}

/// Small shapes both gardens use.
enum ArcadeProps {
    /// A round bush of three to four leaf balls.
    static func bush(_ rng: inout SeededRandom, size: Float) -> ToonMesh {
        var m = ToonMesh()
        let balls = 3 + Int(rng.next() % 2)
        for b in 0..<balls {
            let a = Float(b) / Float(balls) * 2 * .pi + Float.random(in: 0..<1, using: &rng)
            let r = size * Float.random(in: 0.55...0.8, using: &rng)
            let c = ToonColor.mix(ToonColor.leaf, ToonColor.grass, Float.random(in: 0...0.5, using: &rng))
            let at = SIMD3<Float>(cos(a) * size * 0.45, r * 0.85, sin(a) * size * 0.35)
            m.append(.sphere(radius: r, segments: 10, rings: 7, color: c), .translation(at))
        }
        return m
    }

    /// A tree: a trunk and a crown of three balls.
    static func tree(_ rng: inout SeededRandom, height: Float) -> ToonMesh {
        var m = ToonMesh.cylinder(bottom: height * 0.09, top: height * 0.065, height: height * 0.5, segments: 8,
                                  color: ToonColor.woodDark)
        let crown: [SIMD3<Float>] = [SIMD3(0, 0.62, 0), SIMD3(-0.2, 0.5, 0.08), SIMD3(0.22, 0.52, -0.05)]
        for (i, c) in crown.enumerated() {
            let r = height * (i == 0 ? 0.34 : 0.26) * Float.random(in: 0.9...1.1, using: &rng)
            let tone = ToonColor.mix(ToonColor.leaf, ToonColor.emerald, Float.random(in: 0...0.6, using: &rng))
            m.append(.sphere(radius: r, segments: 12, rings: 8, color: tone), .translation(c * height))
        }
        return m
    }

    /// A flower: a short stem, five round petals facing up and a gold heart.
    static func flower(_ rng: inout SeededRandom, size: Float) -> ToonMesh {
        let petals: [SIMD3<Float>] = [ToonColor.cream, ToonColor.hex(0xF6E27A), ToonColor.hex(0xF2A0B4), ToonColor.hex(0x9CC8F2),
                                      ToonColor.hex(0xF7B98A)]
        let stem = size * 0.55
        var m = ToonMesh.cylinder(bottom: size * 0.05, top: size * 0.045, height: stem, segments: 5,
                                  color: ToonColor.leaf, caps: false)
        let petal = petals[Int(rng.next() % UInt64(petals.count))]
        for k in 0..<5 {
            let a = Float(k) * 1.2566
            m.append(.sphere(radius: 1, segments: 7, rings: 5, color: petal),
                     ToonMatrix.translation(SIMD3(cos(a) * size * 0.2, stem, sin(a) * size * 0.2))
                        * ToonMatrix.rotationY(-a) * ToonMatrix.scale(SIMD3(size * 0.2, size * 0.07, size * 0.13)))
        }
        m.append(.sphere(radius: size * 0.12, segments: 7, rings: 5, color: ToonColor.gold),
                 .translation(SIMD3(0, stem + size * 0.05, 0)))
        m.append(.sphere(radius: 1, segments: 6, rings: 4, color: ToonColor.emerald),
                 ToonMatrix.translation(SIMD3(size * 0.08, stem * 0.45, 0)) * ToonMatrix.rotationZ(-0.7)
                    * ToonMatrix.scale(SIMD3(size * 0.16, size * 0.05, size * 0.08)))
        return m
    }

    /// A tuft of grass: five blades leaning out.
    static func tuft(_ rng: inout SeededRandom, size: Float) -> ToonMesh {
        var m = ToonMesh()
        for k in 0..<5 {
            let a = Float(k) * 1.2566 + Float.random(in: 0...0.6, using: &rng)
            let lean = Float.random(in: 0.25...0.5, using: &rng)
            let h = size * Float.random(in: 0.7...1.1, using: &rng)
            let tone = ToonColor.mix(ToonColor.grassDeep, ToonColor.hex(0x8CCB6E), Float.random(in: 0...1, using: &rng))
            m.append(cone(color: tone, segments: 4),
                     .rod(from: SIMD3(cos(a) * size * 0.08, 0, sin(a) * size * 0.08),
                          to: SIMD3(cos(a) * h * lean, h, sin(a) * h * lean), radius: size * 0.07))
        }
        return m
    }

    /// A stone: a squashed ball.
    static func stone(_ rng: inout SeededRandom, size: Float) -> ToonMesh {
        let tone = ToonColor.mix(ToonColor.stone, ToonColor.cream, Float.random(in: 0...0.3, using: &rng))
        return ToonMesh.sphere(radius: 1, segments: 10, rings: 6, color: tone)
            .transformed(ToonMatrix.scale(SIMD3(size, size * 0.55, size * Float.random(in: 0.7...1, using: &rng))))
    }

    /// A unit cone (radius 1 at y = 0, tip at y = 1), for `ToonMatrix.rod`.
    static func cone(color: SIMD3<Float>, segments: Int = 6) -> ToonMesh {
        .cylinder(bottom: 1, top: 0, height: 1, segments: segments, color: color)
    }

    /// The smooth step 0...1 between `a` and `b`.
    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - The mole garden

/// A blink the player made in the garden: where (screen pt), when (round s), and whether it bonked a mole.
public struct MoleSwing: Equatable, Sendable {
    public var spot: Vec2
    public var hole: Int?
    public var time: Double
    public var hit: Bool

    public init(spot: Vec2, hole: Int?, time: Double, hit: Bool) {
        self.spot = spot
        self.hole = hole
        self.time = time
        self.hit = hit
    }

    /// How long the mallet stays on screen (s).
    public static let duration = 0.42
}

/// «Кроты» in 3D: a mowed lawn with six molehills, a fence, trees and flowers; moles, golden moles, hedgehogs and the
/// rabbit rise from the holes the rules give, and a mallet drops where the player blinks.
public struct MoleStage: ToonScene {
    public enum Mesh: Int, CaseIterable {
        case ground, props, grass, mound, pit, mole, golden, hedgehog, mallet, star, puff, ring, rabbit
    }

    public let camera: ToonCamera
    public let look: ToonLook
    public let meshes: [ToonMesh]
    /// Each hole's centre on the ground and radius (metres): the rules' hole centre and radius in pt, unprojected.
    public let holeCentres: [SIMD3<Float>]
    public let holeRadii: [Float]
    private let screen: Vec2

    /// The ink outline of the actors and props (pt).
    public static let outline: Float = 1.6

    public init(screen: Vec2, holes: [Vec2], holeRadiusPt: Double, seed: UInt64 = 7) {
        self.screen = screen
        // Low enough to see the fence and the trees behind it: depth without making the far holes look like a
        // giant's (the rules keep every hole the same size on the screen).
        let cam = ToonCamera(eye: SIMD3(0, 8.2, 8.6), target: SIMD3(0, 0, -0.6), fovY: 0.56, screen: screen)
        camera = cam
        let toward = SIMD3<Float>(-0.5, 1, 0.32).unit
        look = ToonLook(toward: toward, sun: ToonLook.sun(toward: toward, covering: ToonLook.seen(by: cam)),
                        skyTop: ToonColor.sky, skyHorizon: ToonColor.hex(0xCFE6F7), shade: ToonColor.hex(0x5A6FB0),
                        fogStart: 16, fogEnd: 30)
        var centres: [SIMD3<Float>] = [], radii: [Float] = []
        for h in holes {
            let c = cam.ground(h) ?? .zero
            centres.append(c)
            radii.append(Float(holeRadiusPt) * cam.metresPerPoint(at: h))
        }
        holeCentres = centres
        holeRadii = radii
        var rng = SeededRandom(seed: seed)
        var m: [ToonMesh] = Array(repeating: ToonMesh(), count: Mesh.allCases.count)
        m[Mesh.ground.rawValue] = Self.lawn()
        let (props, grass) = Self.props(&rng, holes: centres, radii: radii, camera: cam)
        m[Mesh.props.rawValue] = props
        m[Mesh.grass.rawValue] = grass
        m[Mesh.mound.rawValue] = Self.mound()
        m[Mesh.pit.rawValue] = ToonMesh.disc(radius: 1, segments: 28, color: ToonColor.hex(0x3A2616))
        m[Mesh.mole.rawValue] = Self.mole(body: ToonColor.hex(0x8A5A3C), crown: false)
        m[Mesh.golden.rawValue] = Self.mole(body: ToonColor.gold, crown: true)
        m[Mesh.hedgehog.rawValue] = Self.hedgehog()
        m[Mesh.rabbit.rawValue] = Self.rabbit()
        m[Mesh.mallet.rawValue] = Self.mallet()
        m[Mesh.star.rawValue] = ToonMesh.star(outer: 1, inner: 0.45, depth: 0.3, color: ToonColor.gold)
        m[Mesh.puff.rawValue] = ToonMesh.sphere(radius: 1, segments: 10, rings: 6, color: ToonColor.sand)
        m[Mesh.ring.rawValue] = ToonMesh.torus(radius: 1, tube: 0.07, segments: 36, sides: 6, color: ToonColor.gold)
        meshes = m
    }

    public init(garden g: MoleGarden, seed: UInt64 = 7) {
        self.init(screen: g.screen, holes: g.config.holes.indices.map { g.holeCenter($0) }, holeRadiusPt: g.holeRadiusPt,
                  seed: seed)
    }

    // MARK: Per frame

    /// The draws of one frame at round time `time`: the lawn and props, the holes, every pop in them, the lock
    /// ring on the looked-at hole, and the mallet of each recent blink.
    public func draw(_ g: MoleGarden, at time: Double, swings: [MoleSwing], into out: inout [ToonDraw]) {
        out.append(ToonDraw(mesh: Mesh.ground.rawValue, model: .identity, shadow: false))
        out.append(ToonDraw(mesh: Mesh.props.rawValue, model: .identity, outline: Self.outline))
        out.append(ToonDraw(mesh: Mesh.grass.rawValue, model: .identity))
        for (i, c) in holeCentres.enumerated() {
            let r = holeRadii[i]
            out.append(ToonDraw(mesh: Mesh.mound.rawValue,
                                model: ToonMatrix.translation(c) * ToonMatrix.scale(SIMD3(r, r, r)),
                                outline: Self.outline * 0.8))
            out.append(ToonDraw(mesh: Mesh.pit.rawValue,
                                model: ToonMatrix.translation(c + SIMD3(0, 0.015, 0)) * ToonMatrix.scale(SIMD3(r * 0.86, 1, r * 0.86)),
                                style: .flat, shadow: false))
        }
        if let h = g.lockedHole, h < holeCentres.count {
            let r = holeRadii[h] * (1.2 + 0.04 * Float(sin(time * 7)))
            out.append(ToonDraw(mesh: Mesh.ring.rawValue,
                                model: ToonMatrix.translation(holeCentres[h] + SIMD3(0, 0.06, 0)) * ToonMatrix.scale(SIMD3(r, r, r)),
                                style: .flat, shadow: false))
        }
        for p in g.pops { pop(p, g, time, &out) }
        for s in swings { mallet(s, g, time, &out) }
    }

    private func pop(_ p: MolePop, _ g: MoleGarden, _ time: Double, _ out: inout [ToonDraw]) {
        let state = p.state(at: time, config: g.config)
        guard state != .gone, p.hole < holeCentres.count, time >= p.start else { return }
        let c = holeCentres[p.hole], r = holeRadii[p.hole], s = r * 0.8
        let rise = Float(p.rise(at: time, config: g.config))
        // A little overshoot on the way up: out of the hole with a hop.
        let k = state == .rising ? Self.backOut(rise) : rise
        // The rabbit is taller with its ears: it starts deeper, so no ear tip shows before it comes up.
        let depth: Float = p.kind == .rabbit ? 2.7 : 2.15
        var y = -depth * s + k * (depth - 0.72) * s
        var sx: Float = 1, sy: Float = 1, sway: Float = 0
        if state == .up { y += 0.04 * s * Float(sin(time * 6 + Double(p.id))) }
        if let b = p.bonkedAt {
            let since = Float(time - b)
            if since < 0.2 {
                let q = since / 0.2
                sy = 0.7 + 0.3 * q
                sx = 1.16 - 0.16 * q
            }
            sway = 0.18 * Float(sin((time - b) * 14)) * max(0, 1 - since / Float(g.config.dizzySec))
        }
        let mesh = Self.mesh(p.kind)
        var tint = SIMD4<Float>(1, 1, 1, 1)
        if p.kind.isDecoy, let b = p.bonkedAt, time - b < 0.5 {
            // Not this one: a red flush.
            let f = Float(1 - (time - b) / 0.5)
            tint = SIMD4(1, 1 - 0.45 * f, 1 - 0.5 * f, 1)
        }
        let model = ToonMatrix.translation(c + SIMD3(0, y, 0)) * ToonMatrix.rotationZ(sway)
            * ToonMatrix.scale(SIMD3(s * sx, s * sy, s * sx))
        out.append(ToonDraw(mesh: mesh.rawValue, model: model, tint: tint, outline: Self.outline))
        // Dust from the hole as it comes up.
        if state == .rising {
            let a = Float((time - p.start) / g.config.riseSec)
            for i in 0..<3 {
                let ang = Float(i) * 2.1 + Float(p.id)
                let at = c + SIMD3(cos(ang) * r * (0.6 + 0.5 * a), 0.1 + 0.35 * r * a, sin(ang) * r * (0.5 + 0.4 * a))
                let size = r * (0.16 + 0.1 * a)
                out.append(ToonDraw(mesh: Mesh.puff.rawValue, model: ToonMatrix.translation(at) * ToonMatrix.scale(size),
                                    tint: SIMD4(1, 1, 1, 0.85 * (1 - a)), style: .ghost, shadow: false))
            }
        }
        let top = c.y + y + 2.1 * s * sy
        if state == .dizzy, let b = p.bonkedAt, !p.kind.isDecoy {
            for i in 0..<3 {
                let a = Float(time - b) * 4.5 + Float(i) * 2.094
                let at = SIMD3<Float>(c.x + cos(a) * s * 0.75, top + 0.18 * s + 0.08 * s * sin(a * 2), c.z + sin(a) * s * 0.5)
                out.append(ToonDraw(mesh: Mesh.star.rawValue,
                                    model: ToonMatrix.translation(at) * ToonMatrix.rotationZ(a * 1.5) * ToonMatrix.scale(s * 0.2),
                                    outline: 1, shadow: false))
            }
        }
        if p.kind == .golden, state == .up || state == .rising {
            for i in 0..<2 {
                let ph = time * 2.2 + Double(i) * 1.7 + Double(p.id)
                let blink = Float(max(0, sin(ph * 2)))
                guard blink > 0.05 else { continue }
                let at = SIMD3<Float>(c.x + Float(cos(ph)) * s * 0.9, top - 0.3 * s + 0.2 * s * Float(i), c.z + 0.4 * s)
                out.append(ToonDraw(mesh: Mesh.star.rawValue,
                                    model: ToonMatrix.translation(at) * ToonMatrix.scale(s * 0.14 * blink),
                                    style: .flat, shadow: false))
            }
        }
    }

    private func mallet(_ swing: MoleSwing, _ g: MoleGarden, _ time: Double, _ out: inout [ToonDraw]) {
        let since = time - swing.time
        guard since >= 0, since < MoleSwing.duration else { return }
        let target: SIMD3<Float>, r: Float
        if let h = swing.hole, h < holeCentres.count {
            target = holeCentres[h]
            r = holeRadii[h]
        } else {
            target = camera.ground(swing.spot) ?? .zero
            r = holeRadii.first ?? 1
        }
        // Down in 0.1 s, a beat on the head, then up and away.
        let t = Float(since)
        let down: Float = t < 0.1 ? 1 - (t / 0.1) * (t / 0.1) : t < 0.2 ? 0 : (t - 0.2) / 0.22
        let restY: Float = swing.hit ? 1.25 * r : 0.3 * r
        let at = target + SIMD3(r * 0.15, restY + down * 2.2 * r, r * 0.1)
        let tilt = -0.15 - 0.9 * down
        let fade = t < 0.3 ? 1 : max(0, 1 - (t - 0.3) / 0.12)
        out.append(ToonDraw(mesh: Mesh.mallet.rawValue,
                            model: ToonMatrix.translation(at) * ToonMatrix.rotationZ(tilt) * ToonMatrix.scale(r * 0.9),
                            tint: SIMD4(1, 1, 1, fade), outline: fade > 0.99 ? Self.outline : 0,
                            style: fade > 0.99 ? .toon : .ghost))
        // A miss throws dust up from the grass.
        if !swing.hit, t >= 0.1 {
            let a = (t - 0.1) / 0.32
            for i in 0..<4 {
                let ang = Float(i) * 1.571 + 0.4
                let p = target + SIMD3(cos(ang) * r * (0.3 + 0.7 * a), 0.12 + 0.3 * r * a, sin(ang) * r * (0.3 + 0.5 * a))
                out.append(ToonDraw(mesh: Mesh.puff.rawValue, model: ToonMatrix.translation(p) * ToonMatrix.scale(r * (0.14 + 0.12 * a)),
                                    tint: SIMD4(1, 1, 1, 0.8 * (1 - a)), style: .ghost, shadow: false))
            }
        }
    }

    static func backOut(_ x: Float) -> Float {
        let c: Float = 1.6
        let t = x - 1
        return 1 + (c + 1) * t * t * t + c * t * t
    }

    // MARK: Meshes

    /// The lawn: mowed stripes in two greens, flat where the holes are, rising to hills behind the fence.
    static func lawn() -> ToonMesh {
        ToonMesh.grid(minX: -22, maxX: 22, minZ: -24, maxZ: 10, cellsX: 66, cellsZ: 44, height: { x, z in
            let back = max(0, -z - 6.5)
            return back * 0.2 + ArcadeProps.smooth(0, 4, back) * 0.5 * sin(x * 0.42 + 0.7)
        }, color: { x, z, y in
            let stripe = ArcadeProps.smooth(-0.25, 0.25, sin(x * 1.05))
            var c = ToonColor.mix(ToonColor.grass, ToonColor.grassDeep, stripe * 0.4)
            c = ToonColor.mix(c, ToonColor.hex(0x8CCB6E), ArcadeProps.smooth(0.2, 1, sin(x * 0.31 + z * 0.43)) * 0.25)
            // Far hills paler, into the air.
            return ToonColor.mix(c, ToonColor.hex(0x9ACF8A), ArcadeProps.smooth(1.5, 4.5, y) * 0.5)
        })
    }

    /// The hill of soil round a hole (radius 1; the draw scales it to the hole).
    static func mound() -> ToonMesh {
        var m = ToonMesh.torus(radius: 1.02, tube: 0.3, segments: 28, sides: 8, color: ToonColor.soil)
            .transformed(ToonMatrix.scale(SIMD3(1, 0.5, 1)))
        // Clods on the rim.
        for i in 0..<5 {
            let a = Float(i) * 1.257 + 0.3
            m.append(.sphere(radius: 0.13, segments: 8, rings: 5, color: ToonColor.mix(ToonColor.soil, ToonColor.soilDeep, 0.35)),
                     ToonMatrix.translation(SIMD3(cos(a) * 1.3, 0.05, sin(a) * 1.25)) * ToonMatrix.scale(SIMD3(1, 0.6, 1)))
        }
        return m
    }

    /// A mole about 2.1 tall standing on the origin, facing +z (the camera). Original design: round cocoa body,
    /// cream belly, pink snout and paws, a sprout on its head; the golden one has a small crown.
    static func mole(body: SIMD3<Float>, crown: Bool) -> ToonMesh {
        let dark = body * 0.78, pink = ToonColor.hex(0xEBA69A), belly = ToonColor.hex(0xEFD3AA)
        var m = ToonMesh.sphere(radius: 1, segments: 20, rings: 14, color: body)
            .transformed(ToonMatrix.translation(SIMD3(0, 1.05, 0)) * ToonMatrix.scale(SIMD3(0.8, 1.05, 0.74)))
        func ball(_ at: SIMD3<Float>, _ size: SIMD3<Float>, _ c: SIMD3<Float>, _ seg: Int = 12) {
            m.append(.sphere(radius: 1, segments: seg, rings: max(5, seg / 2 + 1), color: c),
                     ToonMatrix.translation(at) * ToonMatrix.scale(size))
        }
        ball(SIMD3(0, 0.95, 0.42), SIMD3(0.52, 0.62, 0.36), belly)
        ball(SIMD3(0, 1.36, 0.66), SIMD3(0.33, 0.24, 0.26), pink)
        ball(SIMD3(0, 1.43, 0.9), SIMD3(0.11, 0.09, 0.08), ToonColor.hex(0xD45D74), 8)
        for sx in [Float(-1), 1] {
            ball(SIMD3(0.27 * sx, 1.66, 0.6), SIMD3(0.11, 0.13, 0.08), ToonColor.ink, 10)
            ball(SIMD3(0.24 * sx, 1.71, 0.67), SIMD3(0.035, 0.035, 0.02), ToonColor.cream, 6)
            ball(SIMD3(0.45 * sx, 1.38, 0.55), SIMD3(0.12, 0.07, 0.04), ToonColor.hex(0xF4A3A3), 8)
            ball(SIMD3(0.56 * sx, 1.92, 0.05), SIMD3(0.16, 0.15, 0.1), dark, 10)
            ball(SIMD3(0.46 * sx, 0.86, 0.62), SIMD3(0.22, 0.13, 0.17), pink, 10)
        }
        if crown {
            m.append(.cylinder(bottom: 0.3, top: 0.34, height: 0.2, segments: 10, color: ToonColor.energy),
                     ToonMatrix.translation(SIMD3(0, 2.02, 0)))
            for i in 0..<5 {
                let a = Float(i) * 1.257
                m.append(ArcadeProps.cone(color: ToonColor.energy, segments: 5),
                         ToonMatrix.translation(SIMD3(cos(a) * 0.28, 2.2, sin(a) * 0.28)) * ToonMatrix.scale(SIMD3(0.09, 0.2, 0.09)))
            }
        } else {
            // A sprout: two leaves on a stalk.
            m.append(.cylinder(bottom: 0.03, top: 0.025, height: 0.22, segments: 5, color: ToonColor.leaf, caps: false),
                     ToonMatrix.translation(SIMD3(0, 2.05, 0)))
            for sx in [Float(-1), 1] {
                ball(SIMD3(0.13 * sx, 2.3, 0), SIMD3(0.15, 0.05, 0.08), ToonColor.emerald, 8)
            }
        }
        return m
    }

    /// The mesh an actor of `kind` is drawn with.
    public static func mesh(_ kind: MoleKind) -> Mesh {
        switch kind {
        case .mole: return .mole
        case .golden: return .golden
        case .hedgehog: return .hedgehog
        case .rabbit: return .rabbit
        }
    }

    /// A rabbit about 2.6 tall with its ears, facing +z: a round snow-white body, long ears with pink insides (one
    /// bent at the tip), big dark eyes, a pink nose, buck teeth and a sky-blue neckerchief. Original design. It must
    /// be left alone, so it looks friendly and nothing like a mole.
    static func rabbit() -> ToonMesh {
        let fur = ToonColor.hex(0xF7F3EA), shade = ToonColor.hex(0xE3DCCF), pink = ToonColor.hex(0xF2A7B5)
        var m = ToonMesh.sphere(radius: 1, segments: 20, rings: 14, color: fur)
            .transformed(ToonMatrix.translation(SIMD3(0, 1.0, 0)) * ToonMatrix.scale(SIMD3(0.78, 0.98, 0.72)))
        func ball(_ at: SIMD3<Float>, _ size: SIMD3<Float>, _ c: SIMD3<Float>, _ seg: Int = 12) {
            m.append(.sphere(radius: 1, segments: seg, rings: max(5, seg / 2 + 1), color: c),
                     ToonMatrix.translation(at) * ToonMatrix.scale(size))
        }
        // Cheeks and muzzle.
        ball(SIMD3(0, 1.22, 0.55), SIMD3(0.4, 0.3, 0.28), fur)
        ball(SIMD3(0, 1.3, 0.8), SIMD3(0.1, 0.08, 0.07), pink, 8)
        ball(SIMD3(0, 1.1, 0.78), SIMD3(0.09, 0.08, 0.04), ToonColor.cream, 8)
        for sx in [Float(-1), 1] {
            ball(SIMD3(0.27 * sx, 1.5, 0.58), SIMD3(0.12, 0.15, 0.08), ToonColor.ink, 10)
            ball(SIMD3(0.24 * sx, 1.56, 0.65), SIMD3(0.04, 0.04, 0.02), ToonColor.cream, 6)
            ball(SIMD3(0.42 * sx, 1.24, 0.52), SIMD3(0.11, 0.06, 0.04), pink, 8)
            // Ears: long, a little apart and back; the left one bends over at the tip.
            let base = SIMD3<Float>(0.24 * sx, 1.85, -0.05)
            let tilt = ToonMatrix.rotationZ(-0.16 * sx) * ToonMatrix.rotationX(-0.12)
            m.append(.sphere(radius: 1, segments: 12, rings: 8, color: fur),
                     ToonMatrix.translation(base) * tilt * ToonMatrix.translation(SIMD3(0, 0.55, 0))
                        * ToonMatrix.scale(SIMD3(0.17, 0.6, 0.1)))
            m.append(.sphere(radius: 1, segments: 10, rings: 7, color: pink),
                     ToonMatrix.translation(base) * tilt * ToonMatrix.translation(SIMD3(0, 0.55, 0.06))
                        * ToonMatrix.scale(SIMD3(0.09, 0.45, 0.05)))
            if sx < 0 {
                m.append(.sphere(radius: 1, segments: 10, rings: 7, color: shade),
                         ToonMatrix.translation(base) * tilt * ToonMatrix.translation(SIMD3(-0.12, 1.08, 0.02))
                            * ToonMatrix.rotationZ(1.1) * ToonMatrix.scale(SIMD3(0.14, 0.24, 0.09)))
            }
            // Paws on the rim.
            ball(SIMD3(0.42 * sx, 0.72, 0.55), SIMD3(0.2, 0.13, 0.17), fur, 10)
        }
        // A neckerchief.
        m.append(.torus(radius: 0.55, tube: 0.09, segments: 18, sides: 5, color: ToonColor.sky),
                 ToonMatrix.translation(SIMD3(0, 0.92, 0.04)) * ToonMatrix.scale(SIMD3(1.15, 0.7, 1.05)))
        m.append(ArcadeProps.cone(color: ToonColor.sky, segments: 4),
                 ToonMatrix.translation(SIMD3(0, 0.78, 0.66)) * ToonMatrix.rotationX(.pi) * ToonMatrix.scale(SIMD3(0.18, 0.22, 0.06)))
        return m
    }

    /// A hedgehog about 1.9 tall: a round prickly back, a cream face and a black nose. Leave it alone.
    static func hedgehog() -> ToonMesh {
        let back = ToonColor.hex(0x6E5A48), spike = ToonColor.hex(0x47392D), face = ToonColor.hex(0xEAD2AE)
        var m = ToonMesh.sphere(radius: 1, segments: 18, rings: 12, color: back)
            .transformed(ToonMatrix.translation(SIMD3(0, 1.0, 0)) * ToonMatrix.scale(SIMD3(0.85, 0.92, 0.8)))
        m.append(.sphere(radius: 1, segments: 14, rings: 9, color: face),
                 ToonMatrix.translation(SIMD3(0, 1.08, 0.5)) * ToonMatrix.scale(SIMD3(0.52, 0.5, 0.42)))
        m.append(.sphere(radius: 1, segments: 10, rings: 7, color: face),
                 ToonMatrix.translation(SIMD3(0, 1.0, 0.86)) * ToonMatrix.scale(SIMD3(0.2, 0.17, 0.24)))
        m.append(.sphere(radius: 0.1, segments: 8, rings: 5, color: ToonColor.ink), ToonMatrix.translation(SIMD3(0, 1.04, 1.1)))
        for sx in [Float(-1), 1] {
            m.append(.sphere(radius: 1, segments: 8, rings: 5, color: ToonColor.ink),
                     ToonMatrix.translation(SIMD3(0.2 * sx, 1.28, 0.82)) * ToonMatrix.scale(SIMD3(0.07, 0.09, 0.05)))
        }
        // Prickles over the back and the crown, out along the body's normal.
        let count = 46
        for i in 0..<count {
            let y = 1 - 2 * (Float(i) + 0.5) / Float(count), r = (1 - y * y).squareRoot()
            let a = Float(i) * 2.39996
            let d = SIMD3<Float>(cos(a) * r, y, sin(a) * r)
            guard d.z < 0.3, d.y > -0.35 else { continue }
            let base = SIMD3<Float>(0, 1.0, 0) + d * SIMD3(0.8, 0.86, 0.74)
            m.append(ArcadeProps.cone(color: spike, segments: 5), ToonMatrix.rod(from: base, to: base + d * 0.5, radius: 0.15))
        }
        return m
    }

    /// A toy mallet: an orange head across, cream bands, a wooden handle up and back. Origin at the head's centre.
    static func mallet() -> ToonMesh {
        var m = ToonMesh.cylinder(bottom: 0.42, top: 0.42, height: 1.1, segments: 16, color: ToonColor.energy)
            .transformed(ToonMatrix.rotationZ(.pi / 2) * ToonMatrix.translation(SIMD3(0, -0.55, 0)))
        for x in [Float(-0.38), 0.38] {
            m.append(.cylinder(bottom: 0.44, top: 0.44, height: 0.1, segments: 16, color: ToonColor.cream, caps: false),
                     ToonMatrix.rotationZ(.pi / 2) * ToonMatrix.translation(SIMD3(0, x - 0.05, 0)))
        }
        m.append(.cylinder(bottom: 0.08, top: 0.07, height: 1.9, segments: 8, color: ToonColor.wood),
                 ToonMatrix.translation(SIMD3(0, 0.3, 0)) * ToonMatrix.rotationX(-0.25))
        return m
    }

    /// The fence and trees behind the lawn, bushes and a carrot bed at the sides, flowers and stones between the
    /// holes (never on one or in front of one), in one mesh; grass tufts in another, drawn without ink (an outline
    /// is thicker than a blade).
    static func props(_ rng: inout SeededRandom, holes: [SIMD3<Float>], radii: [Float], camera: ToonCamera) -> (ToonMesh, ToonMesh) {
        var m = ToonMesh(), grass = ToonMesh()
        let fenceZ: Float = -6.6
        let post = ToonMesh.box(SIMD3(0.2, 1.1, 0.2), color: ToonColor.wood)
        let rail = ToonMesh.box(SIMD3(1.75, 0.13, 0.08), color: ToonColor.mix(ToonColor.wood, ToonColor.cream, 0.25))
        var x: Float = -21
        while x <= 21 {
            m.append(post, ToonMatrix.translation(SIMD3(x, 0.55, fenceZ)))
            if x < 21 {
                for y in [Float(0.4), 0.82] { m.append(rail, ToonMatrix.translation(SIMD3(x + 0.875, y, fenceZ + 0.12))) }
            }
            x += 1.75
        }
        var tx: Float = -20
        while tx <= 20 {
            let z = -9.0 - Float.random(in: 0...4, using: &rng)
            let ground = max(0, -z - 6.5) * 0.2
            m.append(ArcadeProps.tree(&rng, height: Float.random(in: 3.2...4.6, using: &rng)),
                     ToonMatrix.translation(SIMD3(tx, ground - 0.1, z)))
            tx += Float.random(in: 2.6...4.2, using: &rng)
        }
        // Keeps a prop out of the holes and out of the line from the camera to them.
        func clear(_ p: SIMD3<Float>, _ size: Float) -> Bool {
            for (i, h) in holes.enumerated() {
                let r = radii[i] * 1.7 + size
                let d = SIMD3<Float>(p.x - h.x, 0, p.z - h.z)
                if d.len < r { return false }
                if p.z > h.z, abs(p.x - h.x) < r * 0.8, p.z - h.z < 2.4 { return false }
            }
            return true
        }
        for side in [Float(-1), 1] {
            for i in 0..<4 {
                let p = SIMD3<Float>(side * Float.random(in: 8.5...12, using: &rng), 0, -4.5 + Float(i) * 2.6)
                guard clear(p, 1) else { continue }
                m.append(ArcadeProps.bush(&rng, size: Float.random(in: 0.9...1.4, using: &rng)), ToonMatrix.translation(p))
            }
        }
        // The carrot bed on the left: soil rows with leafy tops.
        for row in 0..<3 {
            let z = -5.2 + Float(row) * 1.1
            m.append(.box(SIMD3(4.2, 0.18, 0.6), color: ToonColor.soil), ToonMatrix.translation(SIMD3(-11.5, 0.05, z)))
            for k in 0..<6 {
                let p = SIMD3<Float>(-13.3 + Float(k) * 0.72, 0.15, z)
                // Tip down in the soil, the orange shoulder showing.
                m.append(ArcadeProps.cone(color: ToonColor.energy, segments: 6),
                         ToonMatrix.translation(p + SIMD3(0, 0.14, 0)) * ToonMatrix.rotationX(.pi)
                            * ToonMatrix.scale(SIMD3(0.11, 0.25, 0.11)))
                for l in 0..<3 {
                    let a = Float(l) * 2.1 + Float(k)
                    m.append(.sphere(radius: 1, segments: 6, rings: 4, color: ToonColor.emerald),
                             ToonMatrix.translation(p + SIMD3(cos(a) * 0.1, 0.32, sin(a) * 0.08))
                                * ToonMatrix.rotationZ(cos(a) * 0.5) * ToonMatrix.scale(SIMD3(0.06, 0.2, 0.06)))
                }
            }
        }
        var tufts = 0, tufted = 0
        while tufts < 46, tufted < 500 {
            tufted += 1
            let p = SIMD3<Float>(Float.random(in: -12...12, using: &rng), 0, Float.random(in: -6.4...6, using: &rng))
            guard clear(p, 0.2) else { continue }
            grass.append(ArcadeProps.tuft(&rng, size: Float.random(in: 0.25...0.4, using: &rng)), ToonMatrix.translation(p))
            tufts += 1
        }
        var placed = 0, tries = 0
        while placed < 30, tries < 400 {
            tries += 1
            let p = SIMD3<Float>(Float.random(in: -11...11, using: &rng), 0, Float.random(in: -6...6, using: &rng))
            guard clear(p, 0.4), camera.project(p).map({ $0.y > 0 && $0.y < camera.screen.y + 40 }) == true else { continue }
            if placed % 4 == 3 {
                m.append(ArcadeProps.stone(&rng, size: Float.random(in: 0.18...0.36, using: &rng)), ToonMatrix.translation(p))
            } else {
                m.append(ArcadeProps.flower(&rng, size: Float.random(in: 0.38...0.55, using: &rng)), ToonMatrix.translation(p))
            }
            placed += 1
        }
        return (m, grass)
    }
}
