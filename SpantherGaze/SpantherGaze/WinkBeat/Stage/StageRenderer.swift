import MetalKit
import SwiftUI
import UIKit

/// One shape of the play layer. Same fields, order and sizes as `StageInstance` in StageShaders.metal (64 bytes):
/// positions and sizes in screen pt, colours linear RGB with straight alpha.
struct StageInstance {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var radius: Float
    var width: Float
    var kind: Float
    var pad: Float = 0
    var color: SIMD4<Float>
    var color2: SIMD4<Float> = .zero
}

/// `StageUniforms` in StageShaders.metal (16 bytes).
struct StageUniforms {
    var viewSize: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
}

/// The sunlit palette in linear RGB for the sRGB target.
enum StageColor {
    static func linear(_ hex: UInt32, _ alpha: Float = 1) -> SIMD4<Float> {
        func ch(_ v: UInt32) -> Float {
            let c = Float(v & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        return SIMD4(ch(hex >> 16), ch(hex >> 8), ch(hex), alpha)
    }
    static let ink = linear(0x1D1A17)
    static let cream = linear(0xFBF4E2)
    static let sky = linear(0x388EE8)
    static let gold = linear(0xE8A838)
    static let emerald = linear(0x47A851)
    static let white = linear(0xFFFFFF)

    /// The eye an object asks for: sky for the left, gold for the right, emerald for either (approved mockups).
    static func side(_ s: NoteSide) -> SIMD4<Float> {
        switch s {
        case .left: return sky
        case .right: return gold
        case .any: return emerald
        }
    }

    static func grade(_ g: WinkBeatGrade) -> SIMD4<Float> {
        switch g {
        case .perfect: return gold
        case .great: return emerald
        case .good: return sky
        case .miss: return ink
        }
    }

    static func faded(_ c: SIMD4<Float>, _ k: Double) -> SIMD4<Float> { SIMD4(c.x, c.y, c.z, c.w * Float(k)) }
    static func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ k: Float) -> SIMD4<Float> { a + (b - a) * k }
}

/// Writes the play layer's shapes for one frame into the instance buffer (skill `metal-anime-stage`, section 2).
/// Every animated value comes from the track time. On the main actor, where the session lives.
@MainActor
struct StagePainter {
    private let out: UnsafeMutablePointer<StageInstance>
    private let capacity: Int
    private(set) var count = 0

    init(out: UnsafeMutablePointer<StageInstance>, capacity: Int) {
        self.out = out
        self.capacity = capacity
    }

    private mutating func add(_ s: StageInstance) {
        guard count < capacity else { return }
        out[count] = s
        count += 1
    }

    private static func f2(_ v: Vec2) -> SIMD2<Float> { SIMD2(Float(v.x), Float(v.y)) }

    mutating func capsule(_ a: Vec2, _ b: Vec2, _ r: Double, fill: SIMD4<Float>, outline: Double = 0,
                          ink: SIMD4<Float> = StageColor.ink) {
        add(StageInstance(a: Self.f2(a), b: Self.f2(b), radius: Float(r), width: Float(outline), kind: 0,
                          color: fill, color2: outline > 0 ? SIMD4(ink.x, ink.y, ink.z, fill.w) : fill))
    }

    mutating func disc(_ c: Vec2, _ r: Double, fill: SIMD4<Float>, outline: Double = 0) {
        capsule(c, c, r, fill: fill, outline: outline)
    }

    mutating func ring(_ c: Vec2, _ r: Double, width: Double, _ color: SIMD4<Float>) {
        add(StageInstance(a: Self.f2(c), b: Self.f2(c), radius: Float(r), width: Float(width), kind: 1, color: color))
    }

    mutating func glow(_ c: Vec2, _ r: Double, _ color: SIMD4<Float>) {
        add(StageInstance(a: Self.f2(c), b: Self.f2(c), radius: Float(r), width: 0, kind: 2, color: color))
    }

    mutating func corners(_ c: Vec2, half: Double, width: Double, arm: Double, _ color: SIMD4<Float>) {
        add(StageInstance(a: Self.f2(c), b: Self.f2(c), radius: Float(half), width: Float(width), kind: 3,
                          color: color, color2: SIMD4(Float(arm), 0, 0, 0)))
    }

    /// A leaf from `root` along `direction` (unit), `length` long.
    mutating func petal(root: Vec2, direction: Vec2, length: Double, fill: SIMD4<Float>, outline: Double) {
        let tip = root + direction * length
        let ink = StageColor.ink
        add(StageInstance(a: Self.f2(root), b: Self.f2(tip), radius: Float(length), width: Float(outline), kind: 4,
                          color: fill, color2: SIMD4(ink.x, ink.y, ink.z, fill.w)))
    }

    // MARK: - The frame

    /// Lays out the frame at host time `host`; `count` then says how many shapes it wrote.
    mutating func paint(_ session: WinkBeatSession, host: Double, reduceMotion: Bool) {
        let s = session.field.height / 390
        switch session.phase {
        case .ready:
            paintStart(session, host: host, s: s, reduceMotion: reduceMotion)
        case .playing:
            guard let play = session.play, let t = session.drawTime(host: host), let map = session.map else { return }
            paintPlay(session, play, t: t, beatSec: map.beatSec, firstBeat: map.firstBeatSec, s: s,
                      reduceMotion: reduceMotion)
        case .select, .done:
            break
        }
    }

    /// The start disc: look at it and wink.
    private mutating func paintStart(_ session: WinkBeatSession, host: Double, s: Double, reduceMotion: Bool) {
        let c = session.startPoint
        let pulse = reduceMotion ? 0 : WinkBeatLook.beatPulse(host, firstBeat: 0, beatSec: 60.0 / 99)
        glow(c, 120 * s, StageColor.faded(StageColor.cream, 0.7))
        ring(c, (78 + 10 * pulse) * s, width: 9 * s, StageColor.ink)
        ring(c, (78 + 10 * pulse) * s, width: 5 * s, StageColor.emerald)
        disc(c, 58 * s, fill: StageColor.cream, outline: 4 * s)
        disc(c, 46 * s, fill: StageColor.emerald, outline: 3 * s)
    }

    private mutating func paintPlay(_ session: WinkBeatSession, _ play: WinkBeatPlay, t: Double, beatSec: Double,
                                    firstBeat: Double, s: Double, reduceMotion: Bool) {
        let lead = play.rules.difficulty.leadSec
        let waiting = Set(play.lockTargets(at: t).map(\.id))
        let visible = play.visible(at: t)
        let pulse = reduceMotion ? 0 : WinkBeatLook.beatPulse(t, firstBeat: firstBeat, beatSec: beatSec)
        let outer = 40 * s, inner = 31 * s
        let thermal = ProcessInfo.processInfo.thermalState

        // Soft light under the object the aim is locked on (glow only there and around hits).
        if let id = session.lock.locked, waiting.contains(id) {
            glow(play.positions[id], 78 * s, StageColor.faded(StageColor.cream, 0.75))
        }

        // Later objects first, so the next one to play is drawn on top.
        for i in visible.reversed() {
            let o = play.objects[i]
            let progress = WinkBeatLook.approach(t, objectTime: o.time, lead: lead)
            let alpha = WinkBeatLook.fadeIn(progress)
            let col = StageColor.side(o.side)
            switch o.kind {
            case .circle:
                guard waiting.contains(i) else { continue }
                hitCircle(play.positions[i], col, alpha: alpha, outer: outer, inner: inner, s: s)
                approachRing(play.positions[i], col, progress: progress, alpha: alpha, outer: outer, s: s)
            case .slider:
                paintSlider(play, i, t: t, col: col, alpha: alpha, progress: progress, waiting: waiting.contains(i),
                            beatSec: beatSec, s: s, pulse: pulse, aim: session.aim)
            case .spinner:
                paintSpinner(session, play, i, t: t, alpha: alpha, s: s)
            }
        }

        // Lock corners on the locked circle or head, pulsing on the beat.
        if let id = session.lock.locked, waiting.contains(id) {
            let half = 56 * s * (1 + 0.1 * pulse)
            corners(play.positions[id], half: half, width: 9 * s, arm: 15 * s, StageColor.cream)
            corners(play.positions[id], half: half, width: 4.5 * s, arm: 15 * s, StageColor.ink)
        }

        // Hit bursts: a shockwave and leaf shards, fewer when the phone runs warm.
        let shards = thermal == .critical ? 0 : thermal == .serious ? 5 : 10
        for st in session.stamps where st.grade != .miss {
            let age = t - st.time
            guard let w = WinkBeatLook.shockwave(age: age) else { continue }
            glow(st.at, outer * 1.9 * w.scale, StageColor.faded(StageColor.cream, 0.55 * w.alpha))
            ring(st.at, outer * w.scale, width: 6 * s, StageColor.faded(StageColor.grade(st.grade), w.alpha))
            let colors = [StageColor.gold, StageColor.cream, StageColor.emerald]
            for k in 0..<shards {
                guard let sh = WinkBeatLook.shard(index: st.index, k: k, age: age) else { continue }
                let off = sh.offset * outer
                let len = off.length
                guard len > 1 else { continue }
                let dir = off * (1 / len)
                petal(root: st.at + off, direction: dir, length: 16 * s * sh.size + 4 * s,
                      fill: colors[k % 3], outline: 1.5 * s)
            }
        }
    }

    private mutating func hitCircle(_ p: Vec2, _ col: SIMD4<Float>, alpha: Double, outer: Double, inner: Double,
                                    s: Double) {
        disc(p, outer, fill: StageColor.faded(StageColor.cream, alpha), outline: 4 * s)
        disc(p, inner, fill: StageColor.faded(col, alpha), outline: 2.5 * s)
    }

    private mutating func approachRing(_ p: Vec2, _ col: SIMD4<Float>, progress: Double, alpha: Double,
                                       outer: Double, s: Double) {
        let r = outer * WinkBeatLook.ringScale(progress)
        ring(p, r, width: 9 * s, StageColor.faded(StageColor.ink, alpha))
        ring(p, r, width: 5 * s, StageColor.faded(col, alpha))
    }

    private mutating func paintSlider(_ play: WinkBeatPlay, _ i: Int, t: Double, col: SIMD4<Float>, alpha: Double,
                                      progress: Double, waiting: Bool, beatSec: Double, s: Double, pulse: Double,
                                      aim: Vec2?) {
        let o = play.objects[i]
        guard let path = play.paths[i], let end = o.end else { return }
        let pts = path.samples
        let tint = StageColor.faded(StageColor.mix(StageColor.cream, col, 0.42), alpha)
        // The body in three passes, each opaque, so the round joints never double up.
        for (r, c) in [(31 * s, StageColor.faded(StageColor.ink, alpha)),
                       (27 * s, StageColor.faded(StageColor.cream, alpha)), (19 * s, tint)] {
            if pts.count < 2 {
                disc(play.positions[i], r, fill: c)
            } else {
                for k in 1..<pts.count { capsule(pts[k - 1], pts[k], r, fill: c) }
            }
        }
        // Ticks on the beats still to come, then the end cap.
        let length = end - o.time
        if length > 0 {
            var k = 1
            while o.time + Double(k) * beatSec < end - 1e-6 {
                let tickTime = o.time + Double(k) * beatSec
                if tickTime > t {
                    let p = path.position(progress: Double(k) * beatSec / length, repeats: o.repeats ?? 0)
                    disc(p, 7 * s, fill: StageColor.faded(StageColor.cream, alpha), outline: 3 * s)
                }
                k += 1
            }
        }
        let tail = WinkBeatPlay.tail(of: o, field: play.field)
        disc(tail, 27 * s, fill: StageColor.faded(StageColor.cream, alpha), outline: 4 * s)
        disc(tail, 18 * s, fill: StageColor.faded(col, alpha), outline: 2.5 * s)
        if waiting {
            hitCircle(play.positions[i], col, alpha: alpha, outer: 40 * s, inner: 31 * s, s: s)
            approachRing(play.positions[i], col, progress: progress, alpha: alpha, outer: 40 * s, s: s)
        }
        // The orb after the head, with the ring that shows it is being followed.
        if t >= o.time, t <= end, let orb = play.orb(i, at: t) {
            let following = aim.map { $0.distance(to: orb) <= play.rules.followPt } ?? false
            if following { glow(orb, 70 * s, StageColor.faded(StageColor.cream, 0.7)) }
            ring(orb, 54 * s, width: 9 * s, StageColor.ink)
            ring(orb, 54 * s, width: 4.5 * s, StageColor.cream)
            disc(orb, 25 * s, fill: col, outline: 4 * s)
            if following {
                let half = 68 * s * (1 + 0.1 * pulse)
                corners(orb, half: half, width: 9 * s, arm: 15 * s, StageColor.cream)
                corners(orb, half: half, width: 4.5 * s, arm: 15 * s, StageColor.ink)
            }
        }
    }

    private mutating func paintSpinner(_ session: WinkBeatSession, _ play: WinkBeatPlay, _ i: Int, t: Double,
                                       alpha: Double, s: Double) {
        let c = play.positions[i]
        let R = play.rules.spinnerRadiusPt
        let n = play.rules.petals
        disc(c, R, fill: StageColor.faded(StageColor.cream, 0.55 * alpha), outline: 4 * s)
        ring(c, R * 1.1, width: 12 * s, StageColor.faded(StageColor.ink, alpha))
        ring(c, R * 1.1, width: 7 * s, StageColor.faded(StageColor.sky, alpha))
        let spin = session.spin?.index == i ? session.spin : nil
        let done = WinkBeatLook.petalsDone(hops: spin?.hops ?? 0, needed: spin?.needed ?? play.hopsNeeded(i), petals: n)
        let current = t >= play.objects[i].time ? session.aim.flatMap { play.petal(i, holding: $0) } : nil
        let length = 56 * s
        for k in 0..<n {
            let a = 2 * Double.pi * Double(k) / Double(n) - Double.pi / 2
            let dir = Vec2(cos(a), sin(a))
            let fill: SIMD4<Float> = k == current ? StageColor.gold : k < done ? StageColor.emerald : StageColor.cream
            if k == current { glow(c + dir * (0.7 * R), 44 * s, StageColor.faded(StageColor.gold, 0.45)) }
            petal(root: c + dir * (0.7 * R - length / 2), direction: dir, length: length,
                  fill: StageColor.faded(fill, alpha), outline: 3.5 * s)
        }
        let won = (spin?.hops ?? 0) >= (spin?.needed ?? Int.max)
        disc(c, 46 * s, fill: StageColor.faded(won ? StageColor.gold : StageColor.cream, alpha), outline: 4 * s)
    }
}

/// Draws the play layer with Metal behind the SwiftUI HUD. Three frames in flight; buffers and the pipeline are
/// made once, never inside `draw(in:)`.
final class StageRenderer: NSObject, MTKViewDelegate {
    static let capacity = 4096
    let device: MTLDevice?
    weak var session: WinkBeatSession?
    var reduceMotion = false
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var buffers: [MTLBuffer] = []
    private var index = 0
    private let inFlight = DispatchSemaphore(value: 3)

    init(session: WinkBeatSession) {
        self.session = session
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init()
        guard let device, let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "stage_vertex"),
              let fragment = library.makeFunction(name: "stage_fragment") else { return }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        if let a = d.colorAttachments[0] {
            a.pixelFormat = .bgra8Unorm_srgb
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        pipeline = try? device.makeRenderPipelineState(descriptor: d)
        buffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: MemoryLayout<StageInstance>.stride * Self.capacity, options: .storageModeShared)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let queue, buffers.count == 3 else { return }
        inFlight.wait()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let buffer = buffers[index]
        index = (index + 1) % buffers.count
        let out = buffer.contents().bindMemory(to: StageInstance.self, capacity: Self.capacity)
        let host = CACurrentMediaTime()
        let motionOff = reduceMotion
        // MTKView draws on the main thread, where the session lives.
        let count: Int = MainActor.assumeIsolated {
            guard let session else { return 0 }
            var painter = StagePainter(out: out, capacity: Self.capacity)
            painter.paint(session, host: host, reduceMotion: motionOff)
            return painter.count
        }
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            if count > 0 {
                var uniforms = StageUniforms(viewSize: SIMD2(Float(view.bounds.width), Float(view.bounds.height)))
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<StageUniforms>.stride, index: 1)
                encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            }
            encoder.endEncoding()
        }
        commands.present(drawable)
        commands.commit()
    }
}

/// The Metal play layer as a SwiftUI view: transparent, under the HUD, untouchable (touches go to the screen).
struct StageView: UIViewRepresentable {
    let session: WinkBeatSession
    var reduceMotion = false

    func makeCoordinator() -> StageRenderer { StageRenderer(session: session) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.colorPixelFormat = .bgra8Unorm_srgb
        v.framebufferOnly = true
        v.isOpaque = false
        v.backgroundColor = .clear
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.preferredFramesPerSecond = 60
        v.isUserInteractionEnabled = false
        v.delegate = context.coordinator
        context.coordinator.reduceMotion = reduceMotion
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        context.coordinator.session = session
        context.coordinator.reduceMotion = reduceMotion
    }

    static func dismantleUIView(_ v: MTKView, coordinator: StageRenderer) {
        v.isPaused = true
        v.delegate = nil
    }
}
