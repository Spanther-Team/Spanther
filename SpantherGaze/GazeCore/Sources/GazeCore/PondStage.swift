import Foundation

/// Something that just happened on the pond and plays out for a moment: a fish caught (a splash of light and drops
/// where it was, the fish gone at once into the catch) or a plain splash. Screen pt and round time.
public struct PondMoment: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case caught(FishKind)
        case splash
    }
    public var kind: Kind
    public var spot: Vec2
    public var heading: Double
    public var time: Double

    public init(kind: Kind, spot: Vec2, heading: Double = 0, time: Double) {
        self.kind = kind
        self.spot = spot
        self.heading = heading
        self.time = time
    }

    public var duration: Double {
        if case .caught = kind { return 0.55 }
        return 0.6
    }
}

/// «Рыбалка» in 3D: a round pond the size of the rules' pond rectangle, sandy shallows and a deep middle under a
/// see-through surface, reeds and lily pads at the edges, a jetty with a rod and a bucket at the near shore. Fish
/// swim under the surface exactly below their screen points.
public struct PondStage: ToonScene {
    public enum Mesh: Int, CaseIterable {
        case ground, props, grass, water, crucian, perch, goldfish, catfish, bobber, line, ring, droplet, bubble
    }

    public let camera: ToonCamera
    public let look: ToonLook
    public let meshes: [ToonMesh]
    private let screen: Vec2
    private let fishY: Float = -0.38
    /// The water's surface (metres).
    public static let surface: Float = -0.12
    /// Where the rod's tip hangs and where the bucket stands (world).
    public let rodTip: SIMD3<Float>
    public let bucket: SIMD3<Float>

    public static let outline: Float = 1.5

    public init(screen: Vec2, pond: (minX: Double, minY: Double, maxX: Double, maxY: Double), shore: Vec2, seed: UInt64 = 11) {
        self.screen = screen
        let cam = ToonCamera(eye: SIMD3(0, 10.5, 7.2), target: SIMD3(0, 0, -0.4), fovY: 0.56, screen: screen)
        camera = cam
        let toward = SIMD3<Float>(-0.45, 1, 0.38).unit
        look = ToonLook(toward: toward, sun: ToonLook.sun(toward: toward, covering: ToonLook.seen(by: cam)),
                        skyTop: ToonColor.sky, skyHorizon: ToonColor.hex(0xD3EAF8), shade: ToonColor.hex(0x4F6FAE),
                        fogStart: 17, fogEnd: 32)
        // How far a ground point is from the pond's middle: < 1 inside the water, measured on the screen against
        // the rules' pond rectangle grown a little, as a rounded square so the corners hold water too.
        let cx = (pond.minX + pond.maxX) / 2, cy = (pond.minY + pond.maxY) / 2
        let hx = (pond.maxX - pond.minX) / 2 + 0.045, hy = (pond.maxY - pond.minY) / 2 + 0.055
        func pondness(_ x: Float, _ z: Float) -> Float {
            guard let pt = cam.project(SIMD3(x, 0, z)) else { return 3 }
            let u = abs((pt.x / screen.x - cx) / hx), v = abs((pt.y / screen.y - cy) / hy)
            return Float(pow(pow(u, 4) + pow(v, 4), 0.25))
        }
        func depth(_ d: Float) -> Float { -1.15 * (1 - ArcadeProps.smooth(0.72, 1.02, d)) }
        let shoreGround = cam.ground(Vec2(shore.x * screen.x, min(shore.y, 0.995) * screen.y)) ?? SIMD3(0, 0, 4)
        let tip = shoreGround + SIMD3<Float>(-1.7, 1.5, -2.1), pail = shoreGround + SIMD3<Float>(0.95, 0.12, 0.05)
        rodTip = tip
        bucket = pail
        var rng = SeededRandom(seed: seed)
        var m: [ToonMesh] = Array(repeating: ToonMesh(), count: Mesh.allCases.count)
        m[Mesh.ground.rawValue] = ToonMesh.grid(minX: -22, maxX: 22, minZ: -24, maxZ: 10, cellsX: 88, cellsZ: 68,
                                                height: { x, z in
            let d = pondness(x, z)
            let back = max(0, -z - 8)
            return depth(d) + ArcadeProps.smooth(1.05, 1.6, d) * (0.08 * sin(x * 0.9 + z * 0.7) + back * 0.18)
        }, color: { x, z, y in
            if y < Self.surface + 0.02 {
                let deep = ArcadeProps.smooth(0, 1, -y / 1.15)
                return ToonColor.mix(ToonColor.sand, ToonColor.hex(0x2A7F86), deep)
            }
            let bank = ArcadeProps.smooth(1.0, 1.12, pondness(x, z))
            var c = ToonColor.mix(ToonColor.sand, ToonColor.grass, bank)
            c = ToonColor.mix(c, ToonColor.grassDeep, ArcadeProps.smooth(0.3, 1, sin(x * 0.5 + z * 0.8)) * 0.3 * bank)
            return ToonColor.mix(c, ToonColor.hex(0x9ACF8A), ArcadeProps.smooth(1.5, 4.5, y) * 0.5)
        })
        m[Mesh.water.rawValue] = ToonMesh.grid(minX: -22, maxX: 22, minZ: -24, maxZ: 10, cellsX: 44, cellsZ: 34,
                                               height: { _, _ in Self.surface }, color: { x, z, _ in
            let deep = 1 - ArcadeProps.smooth(0.55, 1.0, pondness(x, z))
            return ToonColor.mix(ToonColor.hex(0x7FD3E0), ToonColor.water, deep)
        })
        let (props, grass) = Self.props(&rng, camera: cam, pondness: pondness, shore: shoreGround, rodTip: tip, bucket: pail)
        m[Mesh.props.rawValue] = props
        m[Mesh.grass.rawValue] = grass
        m[Mesh.crucian.rawValue] = Self.fish(.crucian)
        m[Mesh.perch.rawValue] = Self.fish(.perch)
        m[Mesh.goldfish.rawValue] = Self.fish(.goldfish)
        m[Mesh.catfish.rawValue] = Self.fish(.catfish)
        var bob = ToonMesh.sphere(radius: 1, segments: 14, rings: 10, color: ToonColor.vermilion)
            .painted { p, c in p.y < -0.05 ? ToonColor.cream : c }
        bob.append(.cylinder(bottom: 0.12, top: 0.08, height: 0.9, segments: 6, color: ToonColor.vermilion),
                   ToonMatrix.translation(SIMD3(0, 0.85, 0)))
        m[Mesh.bobber.rawValue] = bob
        m[Mesh.line.rawValue] = ToonMesh.cylinder(bottom: 1, top: 1, height: 1, segments: 5, color: ToonColor.cream, caps: false)
        m[Mesh.ring.rawValue] = ToonMesh.torus(radius: 1, tube: 0.06, segments: 36, sides: 6, color: ToonColor.gold)
        m[Mesh.droplet.rawValue] = ToonMesh.sphere(radius: 1, segments: 8, rings: 6, color: ToonColor.hex(0xE6F7FB))
        m[Mesh.bubble.rawValue] = ToonMesh.torus(radius: 1, tube: 0.12, segments: 16, sides: 5, color: ToonColor.hex(0xE6F7FB))
        meshes = m
    }

    public init(pond p: FishingPond, seed: UInt64 = 11) {
        self.init(screen: p.screen, pond: p.config.pond, shore: p.config.shore, seed: seed)
    }

    /// Where a fish shows (world) for its screen point: it rises toward the surface as its hold fills.
    public func place(_ f: Fish, _ p: FishingPond, at time: Double) -> (at: SIMD3<Float>, alpha: Float) {
        let y = fishY + 0.03 * Float(sin(time * 2 + Double(f.id))) + 0.14 * Float(f.interest)
        return (camera.ground(f.position, height: y) ?? .zero, 1)
    }

    /// The draws of one frame at round time `time`. `over` is scratch space the caller keeps (so no frame
    /// allocates): what floats on the surface or rises out of it, drawn after the water.
    public func draw(_ p: FishingPond, at time: Double, moments: [PondMoment], into out: inout [ToonDraw],
                     over: inout [ToonDraw]) {
        over.removeAll(keepingCapacity: true)
        out.append(ToonDraw(mesh: Mesh.ground.rawValue, model: .identity, shadow: false))
        out.append(ToonDraw(mesh: Mesh.props.rawValue, model: .identity, outline: Self.outline))
        out.append(ToonDraw(mesh: Mesh.grass.rawValue, model: .identity))
        for f in p.fish { fish(f, p, time, &out, &over) }
        for mo in moments { moment(mo, p, time, &out, &over) }
        // The surface over everything under it, then what floats on it or rises out of it.
        out.append(ToonDraw(mesh: Mesh.water.rawValue, model: .identity, tint: SIMD4(1, 1, 1, 0.4), style: .water,
                            shadow: false))
        out.append(contentsOf: over)
    }

    private func fishMesh(_ k: FishKind) -> Mesh {
        switch k {
        case .crucian: return .crucian
        case .perch: return .perch
        case .goldfish: return .goldfish
        case .catfish: return .catfish
        }
    }

    private func fish(_ f: Fish, _ p: FishingPond, _ time: Double, _ out: inout [ToonDraw], _ ghosts: inout [ToonDraw]) {
        let (at, alpha) = place(f, p, at: time)
        let size = Float(p.radius(f)) * camera.metresPerPoint(at: f.position, height: at.y)
        let wiggleRate = 8 + 10 * f.interest
        let yaw = camera.groundHeading(at: f.position, screenHeading: f.heading, height: at.y)
            + 0.12 * Float(sin(time * wiggleRate + Double(f.id)))
        let model = ToonMatrix.translation(at) * ToonMatrix.rotationY(yaw) * ToonMatrix.scale(size)
        if alpha < 0.99 {
            ghosts.append(ToonDraw(mesh: fishMesh(f.kind).rawValue, model: model, tint: SIMD4(1, 1, 1, alpha), style: .ghost,
                                   shadow: false))
            return
        }
        out.append(ToonDraw(mesh: fishMesh(f.kind).rawValue, model: model, outline: Self.outline))
        let forward = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let mouth = SIMD3<Float>(at.x, Self.surface, at.z) + forward * size * 1.05
        if p.lockedFish == f.id {
            // The hold's ring on the water, a little wider as it fills (the HUD draws the progress arc over it).
            let r = size * (1.45 + 0.12 * Float(f.interest) + 0.04 * Float(sin(time * 7)))
            ghosts.append(ToonDraw(mesh: Mesh.ring.rawValue,
                                   model: ToonMatrix.translation(SIMD3(at.x, Self.surface + 0.02, at.z)) * ToonMatrix.scale(SIMD3(r, r, r)),
                                   tint: SIMD4(1, 1, 1, 0.95), style: .ghost, shadow: false))
        }
        if f.interest > 0.05 {
            // Bubbles from the mouth, more of them as the hold fills.
            let n = 1 + Int(f.interest * 3)
            for i in 0..<n {
                let ph = (time * 1.6 + Double(i) / Double(n)).truncatingRemainder(dividingBy: 1)
                let r = size * Float(0.08 + 0.1 * ph)
                ghosts.append(ToonDraw(mesh: Mesh.bubble.rawValue,
                                       model: ToonMatrix.translation(mouth + SIMD3(0, 0.02, 0) + forward * size * Float(ph) * 0.4)
                                        * ToonMatrix.scale(SIMD3(r, r, r)),
                                       tint: SIMD4(1, 1, 1, Float(0.85 * (1 - ph))), style: .ghost, shadow: false))
            }
        }
    }

    private func moment(_ mo: PondMoment, _ p: FishingPond, _ time: Double, _ out: inout [ToonDraw], _ ghosts: inout [ToonDraw]) {
        let t = time - mo.time
        guard t >= 0, t < mo.duration else { return }
        let k = Float(t / mo.duration)
        let from = camera.ground(mo.spot, height: Self.surface) ?? .zero
        let size = Float(0.075 * screen.y) * camera.metresPerPoint(at: mo.spot, height: Self.surface)
        switch mo.kind {
        case .caught(let kind):
            // No leap and no line: drops and a widening ring of light where it was, sized to the fish.
            let r = Float(FishSpecies.of(kind).radius / 0.075)
            splash(at: from, size: size * r, k: k, &ghosts)
            let ring = size * r * (1.2 + 2.2 * k)
            ghosts.append(ToonDraw(mesh: Mesh.ring.rawValue,
                                   model: ToonMatrix.translation(from + SIMD3(0, 0.03, 0)) * ToonMatrix.scale(SIMD3(ring, ring, ring)),
                                   tint: SIMD4(1, 0.95, 0.75, 0.95 * (1 - k)), style: .ghost, shadow: false))
        case .splash:
            splash(at: from, size: size, k: k, &ghosts)
        }
    }

    private func splash(at c: SIMD3<Float>, size: Float, k: Float, _ ghosts: inout [ToonDraw]) {
        for i in 0..<6 {
            let ang = Float(i) * 1.047 + 0.3
            let d = SIMD3<Float>(cos(ang), 0, sin(ang)) * size * (0.3 + 1.1 * k)
            let lift = 4 * k * (1 - k) * size * 1.4
            ghosts.append(ToonDraw(mesh: Mesh.droplet.rawValue,
                                   model: ToonMatrix.translation(c + d + SIMD3(0, lift, 0)) * ToonMatrix.scale(size * 0.13 * (1 - 0.5 * k)),
                                   tint: SIMD4(1, 1, 1, 0.9 * (1 - k)), style: .ghost, shadow: false))
        }
        let r = size * (0.4 + 1.6 * k)
        ghosts.append(ToonDraw(mesh: Mesh.bubble.rawValue,
                               model: ToonMatrix.translation(c + SIMD3(0, 0.02, 0)) * ToonMatrix.scale(SIMD3(r, r * 0.25, r)),
                               tint: SIMD4(1, 1, 1, 0.8 * (1 - k)), style: .ghost, shadow: false))
    }

    // MARK: Meshes

    /// A fish one unit long each way from its middle, facing +x, seen from above: a round back, fan fins and tail
    /// lying flat, eyes on top. Each kind has its own colours and shape (original designs).
    public static func fish(_ kind: FishKind) -> ToonMesh {
        let body: SIMD3<Float>, belly: SIMD3<Float>, fin: SIMD3<Float>
        var width: Float = 0.42, tail: Float = 1
        switch kind {
        case .crucian:
            body = ToonColor.hex(0xE0A93A); belly = ToonColor.hex(0xF5DC8E); fin = ToonColor.hex(0xE5703A)
        case .perch:
            body = ToonColor.hex(0x8CC43F); belly = ToonColor.hex(0xE2EE9E); fin = ToonColor.hex(0xF4612A)
        case .goldfish:
            body = ToonColor.energy; belly = ToonColor.hex(0xFFD08A); fin = ToonColor.hex(0xFFB26A); tail = 1.5
        case .catfish:
            body = ToonColor.hex(0x7A6A5A); belly = ToonColor.hex(0xC9B79C); fin = ToonColor.hex(0x5A4C3E); width = 0.5
        }
        var m = ToonMesh.sphere(radius: 1, segments: 18, rings: 12, color: body)
            .transformed(ToonMatrix.scale(SIMD3(1, 0.3, width)))
            .painted { p, c in
                var out = p.y < -0.12 ? belly : c
                // The perch's dark bands across its back.
                if kind == .perch, p.y > -0.05, sin(p.x * 9) > 0.45 { out = ToonColor.hex(0x3F6B2A) }
                return out
            }
        func flat(_ at: SIMD3<Float>, _ size: SIMD3<Float>, _ yaw: Float, _ c: SIMD3<Float>) {
            m.append(.sphere(radius: 1, segments: 10, rings: 6, color: c),
                     ToonMatrix.translation(at) * ToonMatrix.rotationY(yaw) * ToonMatrix.scale(size))
        }
        for s in [Float(-1), 1] {
            flat(SIMD3(-1.05 - 0.1 * tail, 0, 0.17 * s * tail), SIMD3(0.36 * tail, 0.05, 0.15 * tail), -0.55 * s, fin)
            flat(SIMD3(0.15, -0.05, (width + 0.02) * s), SIMD3(0.22, 0.04, 0.13), 0.7 * s, fin)
            m.append(.sphere(radius: 0.09, segments: 8, rings: 5, color: ToonColor.ink),
                     ToonMatrix.translation(SIMD3(0.7, 0.13, 0.2 * s * width / 0.42)))
            m.append(.sphere(radius: 0.03, segments: 5, rings: 4, color: ToonColor.cream),
                     ToonMatrix.translation(SIMD3(0.73, 0.2, 0.19 * s * width / 0.42)))
            if kind == .catfish {
                m.append(.cylinder(bottom: 1, top: 1, height: 1, segments: 4, color: ToonColor.ink, caps: false),
                         .rod(from: SIMD3(0.92, 0, 0.1 * s), to: SIMD3(1.35, 0, 0.45 * s), radius: 0.025))
            }
        }
        // A low fin along the back.
        flat(SIMD3(-0.05, 0.26, 0), SIMD3(0.45, 0.09, 0.04), 0, fin)
        return m
    }

    /// Reeds, stones, bushes and trees round the water, lily pads on its edges, and the jetty with the rod and the
    /// bucket at the near shore; grass, reeds and weed in a second mesh drawn without ink.
    static func props(_ rng: inout SeededRandom, camera: ToonCamera, pondness: (Float, Float) -> Float,
                      shore: SIMD3<Float>, rodTip: SIMD3<Float>, bucket: SIMD3<Float>) -> (ToonMesh, ToonMesh) {
        var m = ToonMesh(), grass = ToonMesh()
        // The jetty: a short one, from the bank to the pond's near edge, so no fish ever swims under it.
        let plank = ToonMesh.box(SIMD3(1.9, 0.12, 0.42), color: ToonColor.wood)
        for i in 0..<4 {
            let z = shore.z + 1.3 - Float(i) * 0.46
            let tone = i % 2 == 0 ? ToonColor.wood : ToonColor.mix(ToonColor.wood, ToonColor.woodDark, 0.3)
            m.append(plank, ToonMatrix.translation(SIMD3(shore.x, 0.1, z)), color: tone)
        }
        for sx in [Float(-0.85), 0.85] {
            for dz in [Float(-0.1), 1.2] {
                m.append(.cylinder(bottom: 0.1, top: 0.1, height: 1.4, segments: 8, color: ToonColor.woodDark),
                         ToonMatrix.translation(SIMD3(shore.x + sx, -1.2, shore.z + dz)))
            }
        }
        // The rod: from a holder on the jetty up to its tip over the water.
        let butt = SIMD3<Float>(shore.x - 0.6, 0.2, shore.z + 0.5)
        m.append(.cylinder(bottom: 1, top: 0.45, height: 1, segments: 6, color: ToonColor.vermilion),
                 .rod(from: butt, to: rodTip, radius: 0.04))
        m.append(.sphere(radius: 0.13, segments: 10, rings: 6, color: ToonColor.ink), ToonMatrix.translation(butt + SIMD3(0.05, 0.25, -0.1)))
        // The bucket.
        m.append(.cylinder(bottom: 0.32, top: 0.4, height: 0.55, segments: 14, color: ToonColor.sky),
                 ToonMatrix.translation(bucket - SIMD3(0, 0.05, 0)))
        m.append(.torus(radius: 0.4, tube: 0.04, segments: 18, sides: 5, color: ToonColor.cream),
                 ToonMatrix.translation(bucket + SIMD3(0, 0.5, 0)))
        m.append(.disc(radius: 0.37, segments: 18, color: ToonColor.waterDeep), ToonMatrix.translation(bucket + SIMD3(0, 0.42, 0)))
        // Weed and pebbles on the pond's bed, for depth under the surface.
        var weeds = 0, looked = 0
        while weeds < 16, looked < 300 {
            looked += 1
            let p = SIMD3<Float>(Float.random(in: -12...12, using: &rng), 0, Float.random(in: -8...5, using: &rng))
            let d = pondness(p.x, p.z)
            guard d > 0.45, d < 0.9 else { continue }
            let bed = -1.15 * (1 - ArcadeProps.smooth(0.72, 1.02, d))
            if weeds % 3 == 0 {
                m.append(ArcadeProps.stone(&rng, size: Float.random(in: 0.2...0.35, using: &rng)), ToonMatrix.translation(SIMD3(p.x, bed, p.z)))
            } else {
                for k in 0..<4 {
                    let a = Float(k) * 1.57 + Float.random(in: 0...0.5, using: &rng)
                    let h = Float.random(in: 0.5...0.85, using: &rng)
                    grass.append(ArcadeProps.cone(color: ToonColor.hex(0x3D8A5A), segments: 4),
                             .rod(from: SIMD3(p.x + cos(a) * 0.1, bed, p.z + sin(a) * 0.1),
                                  to: SIMD3(p.x + cos(a) * 0.35, min(bed + h, Self.surface - 0.08), p.z + sin(a) * 0.3), radius: 0.07))
                }
            }
            weeds += 1
        }
        // Lily pads (with a notch) and two lotus flowers on the pond's edges, where fish seldom pass.
        var pads = 0, tries = 0
        while pads < 9, tries < 300 {
            tries += 1
            let p = SIMD3<Float>(Float.random(in: -12...12, using: &rng), 0, Float.random(in: -8...5, using: &rng))
            let d = pondness(p.x, p.z)
            guard d > 0.82, d < 0.95, abs(p.x - shore.x) > 2.5 || p.z < shore.z - 3 else { continue }
            let r = Float.random(in: 0.45...0.75, using: &rng)
            var pad = ToonMesh()
            let notch: Float = 0.5, seg = 18
            let centre = UInt32(0)
            pad.vertices.append(ToonVertex(SIMD3(0, 0, 0), SIMD3(0, 1, 0), ToonColor.emerald))
            for j in 0...seg {
                let a = notch / 2 + Float(j) / Float(seg) * (2 * .pi - notch)
                pad.vertices.append(ToonVertex(SIMD3(cos(a), 0, sin(a)), SIMD3(0, 1, 0),
                                               ToonColor.mix(ToonColor.emerald, ToonColor.leaf, 0.3)))
            }
            for j in 0..<UInt32(seg) {
                let tri: [UInt32] = [centre, centre + 2 + j, centre + 1 + j]
                pad.indices += tri
            }
            let yaw = Float.random(in: 0...6.28, using: &rng)
            m.append(pad, ToonMatrix.translation(SIMD3(p.x, Self.surface + 0.015, p.z)) * ToonMatrix.rotationY(yaw)
                        * ToonMatrix.scale(SIMD3(r, 1, r)))
            if pads % 4 == 1 {
                let lotus = SIMD3<Float>(p.x + 0.1, Self.surface + 0.05, p.z)
                for k in 0..<6 {
                    let a = Float(k) * 1.047
                    m.append(.sphere(radius: 1, segments: 8, rings: 5, color: ToonColor.hex(0xF4B6C8)),
                             ToonMatrix.translation(lotus + SIMD3(cos(a) * 0.13, 0.08, sin(a) * 0.13))
                                * ToonMatrix.rotationY(-a) * ToonMatrix.rotationZ(0.6) * ToonMatrix.scale(SIMD3(0.16, 0.07, 0.08)))
                }
                m.append(.sphere(radius: 0.08, segments: 8, rings: 5, color: ToonColor.gold), ToonMatrix.translation(lotus + SIMD3(0, 0.12, 0)))
            }
            pads += 1
        }
        // Reeds with brown heads, stones, bushes and grass on the banks; trees behind the far bank.
        var tufts = 0
        tries = 0
        while tufts < 40, tries < 600 {
            tries += 1
            let p = SIMD3<Float>(Float.random(in: -16...16, using: &rng), 0, Float.random(in: -10...7, using: &rng))
            let d = pondness(p.x, p.z)
            guard d > 1.12, d < 1.8, abs(p.x - shore.x) > 1.4 || p.z < shore.z - 2.5 else { continue }
            grass.append(ArcadeProps.tuft(&rng, size: Float.random(in: 0.25...0.42, using: &rng)), ToonMatrix.translation(p))
            tufts += 1
        }
        var placed = 0
        tries = 0
        while placed < 48, tries < 900 {
            tries += 1
            let p = SIMD3<Float>(Float.random(in: -16...16, using: &rng), 0, Float.random(in: -10...7, using: &rng))
            let d = pondness(p.x, p.z)
            guard d > 0.98, d < 1.6, abs(p.x - shore.x) > 1.8 || p.z < shore.z - 2.5 else { continue }
            guard camera.project(p).map({ $0.y > -30 && $0.y < camera.screen.y + 60 }) == true else { continue }
            if d < 1.15 {
                for k in 0..<3 {
                    let h = Float.random(in: 0.8...1.5, using: &rng)
                    let base = p + SIMD3(Float(k) * 0.12 - 0.12, 0, Float.random(in: -0.1...0.1, using: &rng))
                    let tip = base + SIMD3(Float.random(in: -0.15...0.15, using: &rng), h, 0)
                    grass.append(.cylinder(bottom: 1, top: 0.6, height: 1, segments: 5, color: ToonColor.leaf, caps: false),
                                 .rod(from: base, to: tip, radius: 0.045))
                    if k == 1 {
                        m.append(.cylinder(bottom: 1, top: 1, height: 1, segments: 6, color: ToonColor.woodDark),
                                 .rod(from: tip - SIMD3(0, 0.32, 0), to: tip - SIMD3(0, 0.05, 0), radius: 0.07))
                    }
                }
            } else if placed % 2 == 0 {
                m.append(ArcadeProps.stone(&rng, size: Float.random(in: 0.25...0.5, using: &rng)), ToonMatrix.translation(p))
            } else {
                m.append(ArcadeProps.bush(&rng, size: Float.random(in: 0.6...1.1, using: &rng)), ToonMatrix.translation(p))
            }
            placed += 1
        }
        var tx: Float = -20
        while tx <= 20 {
            let z = -10 - Float.random(in: 0...4, using: &rng)
            if pondness(tx, z) > 1.25 {
                m.append(ArcadeProps.tree(&rng, height: Float.random(in: 3.2...4.6, using: &rng)),
                         ToonMatrix.translation(SIMD3(tx, max(0, -z - 8) * 0.18 - 0.1, z)))
            }
            tx += Float.random(in: 2.4...3.8, using: &rng)
        }
        return (m, grass)
    }
}
