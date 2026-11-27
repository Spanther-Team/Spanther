import Foundation

// The toon stage's 3D math (skill `metal-anime-stage`): Float matrices laid out like Metal's float4x4 (four column
// vectors), a fixed camera that takes the rules' screen points (pt, origin top left, y down) to the ground and back,
// and the mesh builders the arcade scenes are made of. World space: right-handed, y up, metres, the camera looking
// down at the ground from the +z side. Clip space is Metal's: x and y -1...1, z 0...1. Triangles wind
// counter-clockwise seen from outside, so the renderer culls with `.counterClockwise` front faces.
//
// The rules (`MoleGarden`, `FishingPond`) stay in screen points; the scenes put each object where its screen point
// meets the ground (`ToonCamera.ground`), so what is drawn under a target is always where the judge looks for it.

extension SIMD3 where Scalar == Float {
    public func dot(_ o: SIMD3<Float>) -> Float { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
    public var len: Float { dot(self).squareRoot() }
    /// Unit length; a zero vector stays zero.
    public var unit: SIMD3<Float> { let l = len; return l > 1e-12 ? self / l : self }
}

/// A 4x4 Float matrix in four columns, the memory layout of Metal's `float4x4` (64 bytes).
public struct ToonMatrix: Equatable, Sendable {
    public var c0: SIMD4<Float>
    public var c1: SIMD4<Float>
    public var c2: SIMD4<Float>
    public var c3: SIMD4<Float>

    public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
    }

    public static let identity = ToonMatrix(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))

    public static func * (m: ToonMatrix, v: SIMD4<Float>) -> SIMD4<Float> {
        m.c0 * v.x + m.c1 * v.y + m.c2 * v.z + m.c3 * v.w
    }

    public static func * (a: ToonMatrix, b: ToonMatrix) -> ToonMatrix {
        ToonMatrix(a * b.c0, a * b.c1, a * b.c2, a * b.c3)
    }

    public func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4(p.x, p.y, p.z, 1)
        return SIMD3(r.x, r.y, r.z)
    }

    public func direction(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4(d.x, d.y, d.z, 0)
        return SIMD3(r.x, r.y, r.z)
    }

    public static func translation(_ t: SIMD3<Float>) -> ToonMatrix {
        ToonMatrix(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    public static func scale(_ s: SIMD3<Float>) -> ToonMatrix {
        ToonMatrix(SIMD4(s.x, 0, 0, 0), SIMD4(0, s.y, 0, 0), SIMD4(0, 0, s.z, 0), SIMD4(0, 0, 0, 1))
    }

    public static func scale(_ s: Float) -> ToonMatrix { scale(SIMD3(s, s, s)) }

    /// Turns about x by `a` radians (y towards z).
    public static func rotationX(_ a: Float) -> ToonMatrix {
        let c = cos(a), s = sin(a)
        return ToonMatrix(SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1))
    }

    /// Turns about y by `a` radians (z towards x).
    public static func rotationY(_ a: Float) -> ToonMatrix {
        let c = cos(a), s = sin(a)
        return ToonMatrix(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))
    }

    /// Turns about z by `a` radians (x towards y).
    public static func rotationZ(_ a: Float) -> ToonMatrix {
        let c = cos(a), s = sin(a)
        return ToonMatrix(SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    }

    /// Right-handed perspective into Metal's clip space: view z = -near goes to depth 0, -far to 1.
    public static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> ToonMatrix {
        let ys = 1 / tan(fovY / 2), xs = ys / aspect, zs = far / (near - far)
        return ToonMatrix(SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0))
    }

    /// Right-handed orthographic box into Metal's clip space (the sun's shadow map).
    public static func orthographic(left l: Float, right r: Float, bottom b: Float, top t: Float,
                                    near n: Float, far f: Float) -> ToonMatrix {
        ToonMatrix(SIMD4(2 / (r - l), 0, 0, 0), SIMD4(0, 2 / (t - b), 0, 0), SIMD4(0, 0, 1 / (n - f), 0),
                   SIMD4((l + r) / (l - r), (t + b) / (b - t), n / (n - f), 1))
    }

    /// The view from `eye` towards `target`: the camera looks down its own -z, with y up.
    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> ToonMatrix {
        let f = (target - eye).unit, s = f.cross(up).unit, u = s.cross(f)
        return ToonMatrix(SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                          SIMD4(-s.dot(eye), -u.dot(eye), f.dot(eye), 1))
    }

    /// Takes the unit cylinder (y 0...1, radius 1) to a rod from `a` to `b` of `radius`: fishing lines, stems.
    public static func rod(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float) -> ToonMatrix {
        let axis = b - a
        let dir = axis.unit
        let helper: SIMD3<Float> = abs(dir.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let x = dir.cross(helper).unit * radius, z = x.unit.cross(dir).unit * radius
        return ToonMatrix(SIMD4(x.x, x.y, x.z, 0), SIMD4(axis.x, axis.y, axis.z, 0), SIMD4(z.x, z.y, z.z, 0),
                          SIMD4(a.x, a.y, a.z, 1))
    }

    /// The inverse transpose of the upper 3x3 as three columns (w = 0): normals stay square to the surface under
    /// any scale. The shader normalises them, so only the direction matters.
    public var normalColumns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let a = SIMD3(c0.x, c0.y, c0.z), b = SIMD3(c1.x, c1.y, c1.z), c = SIMD3(c2.x, c2.y, c2.z)
        let bc = b.cross(c), ca = c.cross(a), ab = a.cross(b)
        let det = a.dot(bc)
        guard abs(det) > 1e-12 else { return (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)) }
        let k = 1 / det
        return (SIMD4(bc.x * k, bc.y * k, bc.z * k, 0), SIMD4(ca.x * k, ca.y * k, ca.z * k, 0),
                SIMD4(ab.x * k, ab.y * k, ab.z * k, 0))
    }
}

/// The stage's fixed camera over a screen of `screen` pt.
public struct ToonCamera: Equatable, Sendable {
    public var eye: SIMD3<Float>
    public var target: SIMD3<Float>
    public var up = SIMD3<Float>(0, 1, 0)
    /// Vertical field of view (radians).
    public var fovY: Float
    public var near: Float
    public var far: Float
    public var screen: Vec2

    public init(eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float, screen: Vec2, near: Float = 0.3, far: Float = 90) {
        self.eye = eye
        self.target = target
        self.fovY = fovY
        self.screen = screen
        self.near = near
        self.far = far
    }

    public var aspect: Float { Float(screen.x / max(screen.y, 1)) }
    public var view: ToonMatrix { .lookAt(eye: eye, target: target, up: up) }
    public var projection: ToonMatrix { .perspective(fovY: fovY, aspect: aspect, near: near, far: far) }
    public var viewProjection: ToonMatrix { projection * view }

    /// Where a world point shows on the screen (pt), nil behind the camera.
    public func project(_ p: SIMD3<Float>) -> Vec2? {
        let c = viewProjection * SIMD4(p.x, p.y, p.z, 1)
        guard c.w > 1e-5 else { return nil }
        return Vec2(Double((c.x / c.w + 1) / 2) * screen.x, Double((1 - c.y / c.w) / 2) * screen.y)
    }

    /// The ray from the eye through a screen point (pt): origin and unit direction.
    public func ray(_ pt: Vec2) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let nx = Float(pt.x / max(screen.x, 1) * 2 - 1), ny = Float(1 - pt.y / max(screen.y, 1) * 2)
        let t = tan(fovY / 2)
        let f = (target - eye).unit, s = f.cross(up).unit, u = s.cross(f)
        return (eye, (s * (nx * t * aspect) + u * (ny * t) + f).unit)
    }

    /// Where a screen point (pt) meets the level plane at `height`, nil when it looks above it.
    public func ground(_ pt: Vec2, height: Float = 0) -> SIMD3<Float>? {
        let r = ray(pt)
        guard abs(r.direction.y) > 1e-5 else { return nil }
        let k = (height - r.origin.y) / r.direction.y
        guard k > 0 else { return nil }
        return r.origin + r.direction * k
    }

    /// Metres of the plane at `height` per screen point around `pt`, measured across the screen: sizes a model so
    /// that it covers the screen radius the rules give it.
    public func metresPerPoint(at pt: Vec2, height: Float = 0) -> Float {
        guard let a = ground(pt, height: height), let b = ground(Vec2(pt.x + 10, pt.y), height: height) else { return 0.02 }
        return (b - a).len / 10
    }

    /// The heading on the ground (radians about y, 0 = +x, towards -z positive) of a screen heading (radians,
    /// 0 = right, y down) at `pt`.
    public func groundHeading(at pt: Vec2, screenHeading h: Double, height: Float = 0) -> Float {
        let ahead = Vec2(pt.x + 12 * cos(h), pt.y + 12 * sin(h))
        guard let a = ground(pt, height: height), let b = ground(ahead, height: height) else { return Float(-h) }
        let d = b - a
        return atan2(-d.z, d.x)
    }
}

/// One vertex: position, normal and colour (linear RGB), each a float3 of 16 bytes as Metal lays it out (48 bytes).
public struct ToonVertex: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var color: SIMD3<Float>

    public init(_ position: SIMD3<Float>, _ normal: SIMD3<Float>, _ color: SIMD3<Float>) {
        self.position = position
        self.normal = normal
        self.color = color
    }
}

/// Linear RGB from an sRGB hex colour, as the sRGB render target wants it.
public enum ToonColor {
    public static func hex(_ v: UInt32) -> SIMD3<Float> {
        func ch(_ c: UInt32) -> Float {
            let x = Float(c & 0xFF) / 255
            return x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)
        }
        return SIMD3(ch(v >> 16), ch(v >> 8), ch(v))
    }

    public static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ k: Float) -> SIMD3<Float> { a + (b - a) * k }

    // The sunlit palette (agreed 2026-11-16) and the garden's own tones.
    public static let ink = hex(0x1D1A17)
    public static let cream = hex(0xFBF4E2)
    public static let sky = hex(0x388EE8)
    public static let gold = hex(0xE8A838)
    public static let emerald = hex(0x47A851)
    public static let energy = hex(0xFF8A1E)
    public static let vermilion = hex(0xC2452D)
    public static let grass = hex(0x5DB955)
    public static let grassDeep = hex(0x3E9A48)
    public static let leaf = hex(0x2F8A44)
    public static let soil = hex(0x9A6A3E)
    public static let soilDeep = hex(0x5A3A22)
    public static let wood = hex(0xC99A62)
    public static let woodDark = hex(0x8E6238)
    public static let stone = hex(0xB9B0A0)
    public static let water = hex(0x3FA7C9)
    public static let waterDeep = hex(0x1F6F8B)
    public static let sand = hex(0xE3CC92)
}

/// A triangle mesh: vertices and counter-clockwise triangles (three indices each).
public struct ToonMesh: Sendable {
    public var vertices: [ToonVertex] = []
    public var indices: [UInt32] = []

    public init() {}

    public var triangleCount: Int { indices.count / 3 }

    /// Adds `m` moved by `transform` (normals by its inverse transpose), recoloured if `color` is given.
    public mutating func append(_ m: ToonMesh, _ transform: ToonMatrix = .identity, color: SIMD3<Float>? = nil) {
        let base = UInt32(vertices.count)
        let n = transform.normalColumns
        let nm = ToonMatrix(n.0, n.1, n.2, SIMD4(0, 0, 0, 1))
        vertices.reserveCapacity(vertices.count + m.vertices.count)
        for v in m.vertices {
            vertices.append(ToonVertex(transform.point(v.position), nm.direction(v.normal).unit, color ?? v.color))
        }
        indices.reserveCapacity(indices.count + m.indices.count)
        for i in m.indices { indices.append(base + i) }
    }

    public func transformed(_ t: ToonMatrix) -> ToonMesh {
        var out = ToonMesh()
        out.append(self, t)
        return out
    }

    /// Every vertex colour through `f` (position, colour).
    public func painted(_ f: (SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>) -> ToonMesh {
        var out = self
        for i in out.vertices.indices { out.vertices[i].color = f(out.vertices[i].position, out.vertices[i].color) }
        return out
    }

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = vertices.first?.position else { return (.zero, .zero) }
        var lo = first, hi = first
        for v in vertices {
            lo = SIMD3(Swift.min(lo.x, v.position.x), Swift.min(lo.y, v.position.y), Swift.min(lo.z, v.position.z))
            hi = SIMD3(Swift.max(hi.x, v.position.x), Swift.max(hi.y, v.position.y), Swift.max(hi.z, v.position.z))
        }
        return (lo, hi)
    }

    // MARK: Builders

    /// A sphere round the origin.
    public static func sphere(radius r: Float = 1, segments: Int = 16, rings: Int = 10, color: SIMD3<Float>) -> ToonMesh {
        var m = ToonMesh()
        for i in 0...rings {
            let th = Float(i) / Float(rings) * .pi
            for j in 0...segments {
                let ph = Float(j) / Float(segments) * 2 * .pi
                let n = SIMD3<Float>(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
                m.vertices.append(ToonVertex(n * r, n, color))
            }
        }
        m.strip(rows: rings, columns: segments)
        return m
    }

    /// A cylinder or cone standing on the origin, from radius `bottom` at y = 0 to `top` at y = `height`.
    public static func cylinder(bottom rb: Float, top rt: Float, height h: Float, segments: Int = 12,
                                color: SIMD3<Float>, caps: Bool = true) -> ToonMesh {
        var m = ToonMesh()
        for (y, r) in [(h, rt), (Float(0), rb)] {
            for j in 0...segments {
                let ph = Float(j) / Float(segments) * 2 * .pi
                let n = SIMD3<Float>(cos(ph) * h, rb - rt, sin(ph) * h).unit
                m.vertices.append(ToonVertex(SIMD3(cos(ph) * r, y, sin(ph) * r), n, color))
            }
        }
        m.strip(rows: 1, columns: segments)
        if caps {
            if rt > 0 { m.cap(y: h, radius: rt, segments: segments, up: true, color: color) }
            if rb > 0 { m.cap(y: 0, radius: rb, segments: segments, up: false, color: color) }
        }
        return m
    }

    /// A ring lying flat round the y axis: `radius` to the tube's centre, `tube` thick.
    public static func torus(radius: Float, tube: Float, segments: Int = 24, sides: Int = 8, color: SIMD3<Float>) -> ToonMesh {
        var m = ToonMesh()
        for i in 0...segments {
            let u = Float(i) / Float(segments) * 2 * .pi
            for j in 0...sides {
                let v = Float(j) / Float(sides) * 2 * .pi
                let n = SIMD3<Float>(cos(v) * cos(u), sin(v), cos(v) * sin(u))
                let p = SIMD3<Float>((radius + tube * cos(v)) * cos(u), tube * sin(v), (radius + tube * cos(v)) * sin(u))
                m.vertices.append(ToonVertex(p, n, color))
            }
        }
        let w = UInt32(sides + 1)
        for i in 0..<UInt32(segments) {
            for j in 0..<UInt32(sides) {
                let a = i * w + j, b = i * w + j + 1, c = (i + 1) * w + j + 1, d = (i + 1) * w + j
                m.indices += [a, b, c, a, c, d]
            }
        }
        return m
    }

    /// A box of `size` centred on the origin, with flat faces.
    public static func box(_ size: SIMD3<Float>, color: SIMD3<Float>) -> ToonMesh {
        var m = ToonMesh()
        let h = size / 2
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
        ]
        for (n, s, t) in faces {
            let c: SIMD3<Float> = n * h, sh: SIMD3<Float> = s * h, th: SIMD3<Float> = t * h
            let base = UInt32(m.vertices.count)
            let lo: SIMD3<Float> = c - sh, hi: SIMD3<Float> = c + sh
            let corners: [SIMD3<Float>] = [lo - th, hi - th, hi + th, lo + th]
            for p in corners { m.vertices.append(ToonVertex(p, n, color)) }
            let quad: [UInt32] = [base, base + 1, base + 2, base, base + 2, base + 3]
            m.indices += quad
        }
        return m
    }

    /// A flat disc at y = 0 facing up.
    public static func disc(radius: Float, segments: Int = 24, color: SIMD3<Float>) -> ToonMesh {
        var m = ToonMesh()
        m.cap(y: 0, radius: radius, segments: segments, up: true, color: color)
        return m
    }

    /// A height field over x `minX...maxX`, z `minZ...maxZ`, facing up: `height(x, z)` and `color(x, z, y)`.
    public static func grid(minX: Float, maxX: Float, minZ: Float, maxZ: Float, cellsX: Int, cellsZ: Int,
                            height: (Float, Float) -> Float,
                            color: (Float, Float, Float) -> SIMD3<Float>) -> ToonMesh {
        var m = ToonMesh()
        let dx = (maxX - minX) / Float(cellsX), dz = (maxZ - minZ) / Float(cellsZ), e = min(dx, dz) * 0.5
        for j in 0...cellsZ {
            for i in 0...cellsX {
                let x = minX + Float(i) * dx, z = minZ + Float(j) * dz, y = height(x, z)
                let n = SIMD3<Float>(height(x - e, z) - height(x + e, z), 2 * e, height(x, z - e) - height(x, z + e)).unit
                m.vertices.append(ToonVertex(SIMD3(x, y, z), n, color(x, z, y)))
            }
        }
        let w = UInt32(cellsX + 1)
        for j in 0..<UInt32(cellsZ) {
            for i in 0..<UInt32(cellsX) {
                let a = j * w + i, b = a + 1, c = a + w + 1, d = a + w
                m.indices += [a, c, b, a, d, c]
            }
        }
        return m
    }

    /// Triangles between rows of `columns + 1` vertices running downward (the sphere's and the cylinder's sides).
    private mutating func strip(rows: Int, columns: Int) {
        let w = UInt32(columns + 1)
        for i in 0..<UInt32(rows) {
            for j in 0..<UInt32(columns) {
                let a = i * w + j, b = (i + 1) * w + j, c = (i + 1) * w + j + 1, d = i * w + j + 1
                indices += [a, c, b, a, d, c]
            }
        }
    }

    private mutating func cap(y: Float, radius: Float, segments: Int, up: Bool, color: SIMD3<Float>) {
        let n = SIMD3<Float>(0, up ? 1 : -1, 0)
        let centre = UInt32(vertices.count)
        vertices.append(ToonVertex(SIMD3(0, y, 0), n, color))
        for j in 0...segments {
            let ph = Float(j) / Float(segments) * 2 * .pi
            vertices.append(ToonVertex(SIMD3(cos(ph) * radius, y, sin(ph) * radius), n, color))
        }
        for j in 0..<UInt32(segments) {
            let a = centre + 1 + j, b = centre + 2 + j
            indices += up ? [centre, b, a] : [centre, a, b]
        }
    }
}
