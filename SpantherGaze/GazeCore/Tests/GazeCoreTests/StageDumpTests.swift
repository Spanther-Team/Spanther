import XCTest
import Foundation
@testable import GazeCore

/// Writes a frame of each arcade scene as JSON for a look in a browser without a phone: run with STAGE_DUMP=<dir>
/// and open tools/stage-preview (three.js; see its README). Does nothing without STAGE_DUMP.
final class StageDumpTests: XCTestCase {
    func testDump() throws {
        guard let dir = ProcessInfo.processInfo.environment["STAGE_DUMP"] else { return }
        let screen = Vec2(844, 390)
        func meshJSON(_ m: ToonMesh) -> [String: Any] {
            var p: [Float] = [], n: [Float] = [], c: [Float] = []
            for v in m.vertices {
                p += [v.position.x, v.position.y, v.position.z]
                n += [v.normal.x, v.normal.y, v.normal.z]
                c += [v.color.x, v.color.y, v.color.z]
            }
            return ["p": p, "n": n, "c": c, "i": m.indices.map { Int($0) }]
        }
        func drawJSON(_ d: ToonDraw) -> [String: Any] {
            let m = d.model
            return ["mesh": d.mesh, "m": [m.c0, m.c1, m.c2, m.c3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
                    "tint": [d.tint.x, d.tint.y, d.tint.z, d.tint.w], "outline": d.outline, "style": d.style.rawValue,
                    "shadow": d.shadow]
        }
        func write(_ name: String, _ scene: ToonScene, _ draws: [ToonDraw]) throws {
            let c = scene.camera
            let obj: [String: Any] = [
                "screen": [screen.x, screen.y], "eye": [c.eye.x, c.eye.y, c.eye.z], "target": [c.target.x, c.target.y, c.target.z],
                "fov": c.fovY, "toward": [scene.look.toward.x, scene.look.toward.y, scene.look.toward.z],
                "meshes": scene.meshes.map(meshJSON), "draws": draws.map(drawJSON),
            ]
            let data = try JSONSerialization.data(withJSONObject: obj)
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).json"))
        }
        var g = MoleGarden(level: 9, screen: screen, startTime: 0, seed: 5)
        let moles = MoleStage(garden: g)
        var t = 0.0, bonked = false
        var swings: [MoleSwing] = []
        while t < 12 {
            for e in g.update(time: t, aim: g.holeCenter(4)) {
                if case .popped(let p) = e, p.kind != .hedgehog, !bonked, t > 8 {
                    _ = g.bonk(onset: t + 0.3, aim: g.holeCenter(p.hole))
                    bonked = true
                    swings.append(MoleSwing(spot: g.holeCenter(p.hole), hole: p.hole, time: t + 0.3, hit: true))
                }
            }
            t += 1.0 / 60
            if bonked, let s = swings.first, t > s.time + 0.15 { break }
        }
        var draws: [ToonDraw] = []
        moles.draw(g, at: t, swings: swings, into: &draws)
        try write("moles", moles, draws)

        var p = FishingPond(level: 6, screen: screen, startTime: 0, seed: 8)
        let pond = PondStage(pond: p)
        let id = p.fish[0].id
        t = 0
        while t < 2.2 {
            _ = p.update(time: t, aim: p.fish.first { $0.id == id }?.position)
            t += 1.0 / 60
        }
        _ = p.blink(onset: t, aim: p.fish.first { $0.id == id }?.position)
        for _ in 0..<40 {
            _ = p.update(time: t, aim: p.fish.first { $0.id == id }?.position)
            t += 1.0 / 60
        }
        draws.removeAll()
        var over: [ToonDraw] = []
        pond.draw(p, at: t, moments: [], into: &draws, over: &over)
        try write("pond", pond, draws)
    }
}
