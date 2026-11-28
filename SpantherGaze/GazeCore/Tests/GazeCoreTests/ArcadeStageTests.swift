import XCTest
@testable import GazeCore

final class ArcadeStageTests: XCTestCase {
    let screens = [Vec2(844, 390), Vec2(932, 430), Vec2(667, 375)]

    private func translation(_ d: ToonDraw) -> SIMD3<Float> { SIMD3(d.model.c3.x, d.model.c3.y, d.model.c3.z) }

    /// Every hole is drawn where the rules look for it, at the size they give it, on every phone.
    func testHolesSitUnderTheRulesPoints() {
        for screen in screens {
            let g = MoleGarden(level: 1, screen: screen, startTime: 0, seed: 1)
            let stage = MoleStage(garden: g)
            for i in g.config.holes.indices {
                let c = stage.holeCentres[i]
                XCTAssertEqual(c.y, 0, accuracy: 1e-4)
                let p = stage.camera.project(c)!
                XCTAssertEqual(p.x, g.holeCenter(i).x, accuracy: 0.5)
                XCTAssertEqual(p.y, g.holeCenter(i).y, accuracy: 0.5)
                let edge = stage.camera.project(c + SIMD3(stage.holeRadii[i], 0, 0))!
                XCTAssertEqual(edge.x - p.x, g.holeRadiusPt, accuracy: g.holeRadiusPt * 0.06)
            }
        }
    }

    func testMolesRiseFromTheirHoleAndTheFrameStaysSmall() {
        let screen = screens[0]
        var g = MoleGarden(level: 10, screen: screen, startTime: 0, seed: 4)
        let stage = MoleStage(garden: g)
        var draws: [ToonDraw] = []
        var t = 0.0, most = 0, sawMole = false
        while t < 30 {
            _ = g.update(time: t, aim: g.holeCenter(1))
            draws.removeAll(keepingCapacity: true)
            let swings = [MoleSwing(spot: g.holeCenter(2), hole: 2, time: t - 0.05, hit: false)]
            stage.draw(g, at: t, swings: swings, into: &draws)
            most = max(most, draws.count)
            for p in g.pops where p.state(at: t, config: g.config) == .up {
                let mesh = MoleStage.mesh(p.kind)
                let c = stage.holeCentres[p.hole]
                guard let d = draws.first(where: {
                    $0.mesh == mesh.rawValue && abs(translation($0).x - c.x) < 1e-3 && abs(translation($0).z - c.z) < 1e-3
                })
                else { return XCTFail("no actor over hole \(p.hole)") }
                // Up: the head is out of the ground, the base below it.
                XCTAssertLessThan(translation(d).y, 0)
                XCTAssertGreaterThan(translation(d).y + 2.1 * d.model.c1.y, 0.5)
                sawMole = true
            }
            t += 1.0 / 30
        }
        XCTAssertTrue(sawMole)
        XCTAssertLessThan(most, 90)
        XCTAssertTrue(draws.contains { $0.mesh == MoleStage.Mesh.ring.rawValue }, "the looked-at hole is lit")
    }

    func testTheSunCoversWhatTheCameraSees() {
        let g = MoleGarden(level: 1, screen: screens[0], startTime: 0, seed: 1)
        let stage = MoleStage(garden: g)
        for p in ToonLook.seen(by: stage.camera) {
            let c = stage.look.sun * SIMD4(p.x, p.y, p.z, 1)
            XCTAssertLessThanOrEqual(abs(c.x), 1)
            XCTAssertLessThanOrEqual(abs(c.y), 1)
            XCTAssertGreaterThanOrEqual(c.z, 0)
            XCTAssertLessThanOrEqual(c.z, 1)
        }
    }

    /// Meshes stay well inside a phone's budget, and none is empty.
    func testMeshBudget() {
        let g = MoleGarden(level: 1, screen: screens[0], startTime: 0, seed: 1)
        let moles = MoleStage(garden: g).meshes
        let pond = PondStage(pond: FishingPond(level: 1, screen: screens[0], startTime: 0, seed: 1)).meshes
        for m in moles + pond { XCTAssertGreaterThan(m.triangleCount, 0) }
        XCTAssertLessThan(moles.reduce(0) { $0 + $1.triangleCount }, 60_000)
        XCTAssertLessThan(pond.reduce(0) { $0 + $1.triangleCount }, 60_000)
        let star = ToonMesh.star(outer: 1, inner: 0.45, depth: 0.3, color: ToonColor.gold)
        for t in 0..<star.triangleCount {
            let a = star.vertices[Int(star.indices[3 * t])].position, b = star.vertices[Int(star.indices[3 * t + 1])].position
            let c = star.vertices[Int(star.indices[3 * t + 2])].position
            XCTAssertGreaterThan((b - a).cross(c - a).dot((a + b + c) / 3), 0)
        }
    }

    func testFishSwimUnderTheirPointsAndTheWaterCoversThem() {
        for screen in screens {
            var p = FishingPond(level: 5, screen: screen, startTime: 0, seed: 3)
            let stage = PondStage(pond: p)
            var draws: [ToonDraw] = [], over: [ToonDraw] = []
            var t = 0.0, sawRing = false
            let id = p.fish[0].id
            while t < 0.8 {
                _ = p.update(time: t, aim: p.fish.first { $0.id == id }?.position)
                draws.removeAll(keepingCapacity: true)
                stage.draw(p, at: t, moments: [], into: &draws, over: &over)
                let water = draws.firstIndex { $0.style == .water }!
                for f in p.fish {
                    let (at, alpha) = stage.place(f, p, at: t)
                    XCTAssertLessThan(at.y, PondStage.surface)
                    let shown = stage.camera.project(at)!
                    XCTAssertEqual(shown.x, f.position.x, accuracy: 0.5)
                    XCTAssertEqual(shown.y, f.position.y, accuracy: 0.5)
                    if alpha > 0.99 {
                        let i = draws.firstIndex { abs(translation($0).x - at.x) < 1e-4 && abs(translation($0).z - at.z) < 1e-4 }
                        XCTAssertNotNil(i)
                        XCTAssertLessThan(i ?? .max, water)
                    }
                }
                if p.lockedFish == id {
                    XCTAssertTrue(over.contains { $0.mesh == PondStage.Mesh.ring.rawValue }, "the held fish has its ring")
                    sawRing = true
                }
                t += 1.0 / 30
            }
            XCTAssertTrue(sawRing)
            let caught = PondMoment(kind: .caught(.perch), spot: p.fish[0].position, time: t)
            draws.removeAll()
            stage.draw(p, at: t + 0.2, moments: [caught], into: &draws, over: &over)
            XCTAssertFalse(draws.contains { $0.mesh == PondStage.Mesh.perch.rawValue && translation($0).y > 0 },
                           "no leap: the catch goes straight into the catch")
            XCTAssertTrue(over.contains { $0.mesh == PondStage.Mesh.droplet.rawValue }, "a splash where it was")
        }
    }
}
