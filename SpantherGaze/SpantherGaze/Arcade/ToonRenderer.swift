import MetalKit
import SwiftUI
import UIKit

/// One draw's instance data: `ToonInstance` in ToonShaders.metal (144 bytes, nine float4).
struct ToonInstance {
    var m0: SIMD4<Float>
    var m1: SIMD4<Float>
    var m2: SIMD4<Float>
    var m3: SIMD4<Float>
    var n0: SIMD4<Float>
    var n1: SIMD4<Float>
    var n2: SIMD4<Float>
    var tint: SIMD4<Float>
    /// x: ink outline (pt), y: style.
    var params: SIMD4<Float>

    init(_ d: ToonDraw) {
        m0 = d.model.c0
        m1 = d.model.c1
        m2 = d.model.c2
        m3 = d.model.c3
        let nc = d.model.normalColumns
        n0 = nc.0
        n1 = nc.1
        n2 = nc.2
        tint = d.tint
        params = SIMD4(d.outline, Float(d.style.rawValue), 0, 0)
    }
}

/// `ToonFrame` in ToonShaders.metal (256 bytes).
struct ToonFrameUniforms {
    var viewProjection: ToonMatrix
    var sun: ToonMatrix
    var toward: SIMD4<Float>
    var eye: SIMD4<Float>
    var skyTop: SIMD4<Float>
    var skyHorizon: SIMD4<Float>
    /// rgb: the shadow tone; w: shadow strength (0 with the shadow pass off).
    var shade: SIMD4<Float>
    /// x: stage time (s); y, z: viewport (px); w: pixels per point.
    var misc: SIMD4<Float>
    /// x: fog start, y: fog end (m).
    var fog: SIMD4<Float>
    var ink: SIMD4<Float>
}

/// What the toon stage draws: a scene (built once per play) and each frame's draws. Called on the main thread.
protocol ToonSource: AnyObject {
    var toonScene: ToonScene? { get }
    /// Goes up whenever `toonScene` is replaced, so the renderer uploads the new meshes.
    var toonSceneVersion: Int { get }
    /// Fills `draws` (empty, its capacity kept) for the frame shown at `host` and returns the stage time (s).
    func toonFrame(into draws: inout [ToonDraw], host: Double) -> Double
    /// The stage's frame rate, GPU time per frame (ms) and whether the heat turned shadows off.
    func toonPerf(fps: Double, gpuMs: Double, shadowsOff: Bool)
}

/// The arcades' Metal renderer (skill `metal-anime-stage`): the sun's shadow map, then the world in toon bands with
/// 4x MSAA, its ink outlines, and the see-through draws (water, puffs) last. Three frames in flight; nothing is
/// allocated per frame (the meshes are uploaded once per scene, the MSAA targets once per drawable size).
/// Heat: at `.serious` the shadow pass stops; at `.critical` the stage also drops to 30 FPS. Tracking always wins.
final class ToonRenderer: NSObject, MTKViewDelegate {
    static let capacity = 1500
    static let shadowSize = 2048
    let device: MTLDevice?
    weak var source: ToonSource?

    private let queue: MTLCommandQueue?
    private var solid: MTLRenderPipelineState?
    private var blended: MTLRenderPipelineState?
    private var ink: MTLRenderPipelineState?
    private var sunPass: MTLRenderPipelineState?
    private var depthWrite: MTLDepthStencilState?
    private var depthRead: MTLDepthStencilState?
    private var sunMap: MTLTexture?
    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private var sampleCount = 4
    private var instances: [MTLBuffer] = []
    private var index = 0
    private let inFlight = DispatchSemaphore(value: 3)

    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var ranges: [(start: Int, count: Int)] = []
    private var uploadedVersion = -1

    private var draws: [ToonDraw] = []
    private let sunDesc = MTLRenderPassDescriptor()
    private let worldDesc = MTLRenderPassDescriptor()
    private var lastHost = 0.0
    private var fps = 60.0
    private let gpuLock = NSLock()
    private var gpuMs = 0.0

    init(source: ToonSource) {
        self.source = source
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init()
        draws.reserveCapacity(Self.capacity)
        guard let device, let library = device.makeDefaultLibrary() else { return }
        if !device.supportsTextureSampleCount(sampleCount) { sampleCount = 1 }
        func pipeline(_ vertex: String, _ fragment: String?, blend: Bool, color: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
            d.depthAttachmentPixelFormat = .depth32Float
            if color {
                d.rasterSampleCount = sampleCount
                if let a = d.colorAttachments[0] {
                    a.pixelFormat = .bgra8Unorm_srgb
                    a.isBlendingEnabled = blend
                    a.sourceRGBBlendFactor = .one
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    a.sourceAlphaBlendFactor = .one
                    a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            } else {
                d.rasterSampleCount = 1
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        solid = pipeline("toon_vertex", "toon_fragment", blend: false, color: true)
        blended = pipeline("toon_vertex", "toon_fragment", blend: true, color: true)
        ink = pipeline("outline_vertex", "outline_fragment", blend: false, color: true)
        sunPass = pipeline("sun_vertex", nil, blend: false, color: false)
        let w = MTLDepthStencilDescriptor()
        w.depthCompareFunction = .less
        w.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: w)
        let r = MTLDepthStencilDescriptor()
        r.depthCompareFunction = .less
        r.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: r)
        let s = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: Self.shadowSize,
                                                         height: Self.shadowSize, mipmapped: false)
        s.usage = [.renderTarget, .shaderRead]
        s.storageMode = .private
        sunMap = device.makeTexture(descriptor: s)
        instances = (0..<3).compactMap { _ in
            device.makeBuffer(length: MemoryLayout<ToonInstance>.stride * Self.capacity, options: .storageModeShared)
        }
        sunDesc.depthAttachment.texture = sunMap
        sunDesc.depthAttachment.loadAction = .clear
        sunDesc.depthAttachment.storeAction = .store
        sunDesc.depthAttachment.clearDepth = 1
        worldDesc.colorAttachments[0].loadAction = .clear
        worldDesc.depthAttachment.loadAction = .clear
        worldDesc.depthAttachment.storeAction = .dontCare
        worldDesc.depthAttachment.clearDepth = 1
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { makeTargets(size) }

    private func makeTargets(_ size: CGSize) {
        guard let device, size.width >= 1, size.height >= 1 else { return }
        let w = Int(size.width), h = Int(size.height)
        if let c = msaaColor, c.width == w, c.height == h { return }
        #if targetEnvironment(simulator)
        let storage = MTLStorageMode.private
        #else
        let storage = MTLStorageMode.memoryless
        #endif
        let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        c.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
        c.sampleCount = sampleCount
        c.usage = .renderTarget
        c.storageMode = storage
        msaaColor = device.makeTexture(descriptor: c)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        d.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
        d.sampleCount = sampleCount
        d.usage = .renderTarget
        d.storageMode = storage
        msaaDepth = device.makeTexture(descriptor: d)
    }

    /// The scene's meshes in one vertex and one index buffer (indices already offset): once per scene.
    private func upload(_ scene: ToonScene, version: Int) {
        guard let device else { return }
        uploadedVersion = version
        var vertices: [ToonVertex] = [], indices: [UInt32] = []
        ranges = []
        for m in scene.meshes {
            let base = UInt32(vertices.count)
            ranges.append((indices.count, m.indices.count))
            vertices += m.vertices
            indices += m.indices.map { $0 + base }
        }
        guard !vertices.isEmpty, !indices.isEmpty else { return }
        vertexBuffer = vertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared)
        }
        indexBuffer = indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared)
        }
    }

    func draw(in view: MTKView) {
        guard let solid, let blended, let ink, let sunPass, let queue, instances.count == 3, let source,
              let scene = source.toonScene, !scene.meshes.isEmpty else { return }
        if uploadedVersion != source.toonSceneVersion { upload(scene, version: source.toonSceneVersion) }
        let size = view.drawableSize
        if msaaColor?.width != Int(size.width) || msaaColor?.height != Int(size.height) { makeTargets(size) }
        guard let vertexBuffer, let indexBuffer, let msaaColor, let msaaDepth, let sunMap else { return }

        let host = CACurrentMediaTime()
        if lastHost > 0 { fps += (1 / max(host - lastHost, 1e-3) - fps) * 0.05 }
        lastHost = host
        let thermal = ProcessInfo.processInfo.thermalState
        let shadowsOn = thermal != .serious && thermal != .critical
        let wantFPS = thermal == .critical ? 30 : 60
        if view.preferredFramesPerSecond != wantFPS { view.preferredFramesPerSecond = wantFPS }
        gpuLock.lock()
        let lastGpu = gpuMs
        gpuLock.unlock()
        source.toonPerf(fps: fps, gpuMs: lastGpu, shadowsOff: !shadowsOn)

        inFlight.wait()
        guard let drawable = view.currentDrawable, let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        draws.removeAll(keepingCapacity: true)
        let time = source.toonFrame(into: &draws, host: host)
        let n = min(draws.count, Self.capacity)
        let buffer = instances[index]
        index = (index + 1) % instances.count
        let out = buffer.contents().bindMemory(to: ToonInstance.self, capacity: Self.capacity)
        for i in 0..<n { out[i] = ToonInstance(draws[i]) }

        let cam = scene.camera, look = scene.look
        let scale = Float(size.width / max(view.bounds.width, 1))
        var frame = ToonFrameUniforms(
            viewProjection: cam.viewProjection, sun: look.sun,
            toward: SIMD4(look.toward.x, look.toward.y, look.toward.z, 0),
            eye: SIMD4(cam.eye.x, cam.eye.y, cam.eye.z, 1),
            skyTop: SIMD4(look.skyTop.x, look.skyTop.y, look.skyTop.z, 1),
            skyHorizon: SIMD4(look.skyHorizon.x, look.skyHorizon.y, look.skyHorizon.z, 1),
            shade: SIMD4(look.shade.x, look.shade.y, look.shade.z, shadowsOn ? 1 : 0),
            misc: SIMD4(Float(time), Float(size.width), Float(size.height), scale),
            fog: SIMD4(look.fogStart, look.fogEnd, 0, 0),
            ink: SIMD4(ToonColor.ink.x, ToonColor.ink.y, ToonColor.ink.z, 1))
        let frameSize = MemoryLayout<ToonFrameUniforms>.stride

        // 1. The sun's depth map (skipped when the heat turned shadows off; the shader then reads none).
        if shadowsOn, let e = commands.makeRenderCommandEncoder(descriptor: sunDesc) {
            e.setRenderPipelineState(sunPass)
            e.setDepthStencilState(depthWrite)
            e.setCullMode(.none)
            e.setDepthBias(0.0005, slopeScale: 1.6, clamp: 0.01)
            e.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            e.setVertexBuffer(buffer, offset: 0, index: 1)
            e.setVertexBytes(&frame, length: frameSize, index: 2)
            runs(e, n, indexBuffer) { $0.shadow && !$0.style.blended }
            e.endEncoding()
        }

        // 2. The world, its ink, then the see-through draws, into the MSAA target resolved into the drawable.
        let pass = worldDesc
        pass.colorAttachments[0].texture = sampleCount > 1 ? msaaColor : drawable.texture
        pass.colorAttachments[0].resolveTexture = sampleCount > 1 ? drawable.texture : nil
        pass.colorAttachments[0].storeAction = sampleCount > 1 ? .multisampleResolve : .store
        let sky = look.skyHorizon
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(sky.x), green: Double(sky.y), blue: Double(sky.z), alpha: 1)
        pass.depthAttachment.texture = msaaDepth
        let semaphore = inFlight
        let lock = gpuLock
        commands.addCompletedHandler { [weak self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if ms > 0, let self {
                lock.lock()
                self.gpuMs = ms
                lock.unlock()
            }
            semaphore.signal()
        }
        if let e = commands.makeRenderCommandEncoder(descriptor: pass) {
            e.setFrontFacing(.counterClockwise)
            e.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            e.setVertexBuffer(buffer, offset: 0, index: 1)
            e.setVertexBytes(&frame, length: frameSize, index: 2)
            e.setFragmentBytes(&frame, length: frameSize, index: 0)
            e.setFragmentTexture(sunMap, index: 0)
            e.setRenderPipelineState(solid)
            e.setDepthStencilState(depthWrite)
            e.setCullMode(.back)
            runs(e, n, indexBuffer) { !$0.style.blended }
            e.setRenderPipelineState(ink)
            e.setCullMode(.front)
            runs(e, n, indexBuffer) { $0.outline > 0 && !$0.style.blended }
            e.setRenderPipelineState(blended)
            e.setDepthStencilState(depthRead)
            e.setCullMode(.back)
            runs(e, n, indexBuffer) { $0.style.blended }
            e.endEncoding()
        }
        commands.present(drawable)
        commands.commit()
    }

    /// One instanced draw per run of neighbouring draws of the same mesh that `include` takes.
    private func runs(_ e: MTLRenderCommandEncoder, _ n: Int, _ indexBuffer: MTLBuffer, _ include: (ToonDraw) -> Bool) {
        var i = 0
        while i < n {
            let d = draws[i]
            guard include(d), d.mesh >= 0, d.mesh < ranges.count, ranges[d.mesh].count > 0 else {
                i += 1
                continue
            }
            var j = i + 1
            while j < n, draws[j].mesh == d.mesh, include(draws[j]) { j += 1 }
            let r = ranges[d.mesh]
            e.drawIndexedPrimitives(type: .triangle, indexCount: r.count, indexType: .uint32, indexBuffer: indexBuffer,
                                    indexBufferOffset: r.start * MemoryLayout<UInt32>.stride, instanceCount: j - i,
                                    baseVertex: 0, baseInstance: i)
            i = j
        }
    }
}

/// The toon stage as a SwiftUI view, under the HUD; it takes no touches (they go to the play screen).
struct ToonStageView: UIViewRepresentable {
    let source: ToonSource

    func makeCoordinator() -> ToonRenderer { ToonRenderer(source: source) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.colorPixelFormat = .bgra8Unorm_srgb
        v.depthStencilPixelFormat = .invalid
        v.sampleCount = 1
        v.framebufferOnly = true
        v.isOpaque = true
        v.backgroundColor = UIColor(red: 0.81, green: 0.9, blue: 0.97, alpha: 1)
        v.preferredFramesPerSecond = 60
        v.isUserInteractionEnabled = false
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        context.coordinator.source = source
    }

    static func dismantleUIView(_ v: MTKView, coordinator: ToonRenderer) {
        v.isPaused = true
        v.delegate = nil
    }
}
