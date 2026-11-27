import XCTest
@testable import GazeCore

final class Toon3DTests: XCTestCase {
    let screen = Vec2(844, 390)

    private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4, file: StaticString = #file, line: UInt = #line) {
        XCTAssertLessThan((a - b).len, eps, "\(a) vs \(b)", file: file, line: line)
    }

    func testMatricesCompose() {
        let t = ToonMatrix.translation(SIMD3(1, 2, 3)), r = ToonMatrix.rotationY(.pi / 2)
        near((t * r).point(SIMD3(1, 0, 0)), SIMD3(1, 2, 2))
        near((ToonMatrix.identity * t).point(.zero), SIMD3(1, 2, 3))
        near(ToonMatrix.rotationX(.pi / 2).point(SIMD3(0, 1, 0)), SIMD3(0, 0, 1))
        near(ToonMatrix.rotationZ(.pi / 2).point(SIMD3(1, 0, 0)), SIMD3(0, 1, 0))
        // A squashed sphere's normal stays square to its surface.
        let s = ToonMatrix.scale(SIMD3(2, 0.5, 1))
        let n = s.normalColumns
        let nm = ToonMatrix(n.0, n.1, n.2, SIMD4(0, 0, 0, 1))
        let p = SIMD3<Float>(0.6, 0.8, 0), tangent = SIMD3<Float>(-0.8, 0.6, 0)
        XCTAssertEqual(nm.direction(p).unit.dot(s.direction(tangent).unit), 0, accuracy: 1e-5)
    }

    func testProjectionDepthRange() {
        let p = ToonMatrix.perspective(fovY: 0.6, aspect: 2, near: 0.5, far: 50)
        let a = p * SIMD4(0, 0, -0.5, 1), b = p * SIMD4(0, 0, -50, 1)
        XCTAssertEqual(a.z / a.w, 0, accuracy: 1e-5)
        XCTAssertEqual(b.z / b.w, 1, accuracy: 1e-5)
        let o = ToonMatrix.orthographic(left: -2, right: 2, bottom: -1, top: 1, near: 1, far: 11)
        let c = o * SIMD4(2, 1, -1, 1), d = o * SIMD4(-2, -1, -11, 1)
        near(SIMD3(c.x, c.y, c.z), SIMD3(1, 1, 0))
        near(SIMD3(d.x, d.y, d.z), SIMD3(-1, -1, 1))
        let v = ToonMatrix.lookAt(eye: SIMD3(0, 5, 5), target: .zero, up: SIMD3(0, 1, 0))
        near(v.point(.zero), SIMD3(0, 0, -(50 as Float).squareRoot()))
    }

    func testScreenToGroundAndBack() {
        let cam = ToonCamera(eye: SIMD3(0, 9, 8), target: .zero, fovY: 0.56, screen: screen)
        for pt in [Vec2(422, 195), Vec2(10, 380), Vec2(830, 20), Vec2(211, 156)] {
            guard let g = cam.ground(pt) else { return XCTFail("no ground under \(pt)") }
            XCTAssertEqual(g.y, 0, accuracy: 1e-4)
            let back = cam.project(g)!
            XCTAssertEqual(back.x, pt.x, accuracy: 0.05)
            XCTAssertEqual(back.y, pt.y, accuracy: 0.05)
            let h = cam.ground(pt, height: -0.2)!
            XCTAssertEqual(cam.project(h)!.x, pt.x, accuracy: 0.05)
        }
        // The screen's centre looks at the target; nearer the bottom a point covers less ground.
        near(cam.ground(Vec2(422, 195))!, .zero, 1e-3)
        XCTAssertLessThan(cam.metresPerPoint(at: Vec2(422, 380)), cam.metresPerPoint(at: Vec2(422, 20)))
        // A heading to the right on the screen is +x on the ground; up the screen is away (-z).
        XCTAssertEqual(cam.groundHeading(at: Vec2(422, 195), screenHeading: 0), 0, accuracy: 1e-3)
        XCTAssertEqual(cam.groundHeading(at: Vec2(422, 195), screenHeading: -.pi / 2), .pi / 2, accuracy: 1e-3)
        XCTAssertNil(ToonCamera(eye: SIMD3(0, 2, 8), target: SIMD3(0, 2, 0), fovY: 0.5, screen: screen).ground(Vec2(422, 10)))
    }

    /// Every triangle faces away from the shape's inside (counter-clockwise from outside), and normals are unit.
    private func assertOutward(_ m: ToonMesh, centre: SIMD3<Float> = .zero, file: StaticString = #file, line: UInt = #line) {
        var bad = 0
        for t in 0..<m.triangleCount {
            let a = m.vertices[Int(m.indices[3 * t])].position, b = m.vertices[Int(m.indices[3 * t + 1])].position
            let c = m.vertices[Int(m.indices[3 * t + 2])].position
            let n = (b - a).cross(c - a)
            if n.len < 1e-9 { continue }
            if n.dot((a + b + c) / 3 - centre) <= 0 { bad += 1 }
        }
        XCTAssertEqual(bad, 0, "inward triangles", file: file, line: line)
        for v in m.vertices { XCTAssertEqual(v.normal.len, 1, accuracy: 1e-4, file: file, line: line) }
    }

    func testBuildersWindOutward() {
        assertOutward(.sphere(radius: 2, color: ToonColor.cream))
        assertOutward(.cylinder(bottom: 1, top: 0.5, height: 2, color: ToonColor.wood), centre: SIMD3(0, 1, 0))
        assertOutward(.box(SIMD3(1, 2, 3), color: ToonColor.stone))
        let ring = ToonMesh.torus(radius: 2, tube: 0.4, color: ToonColor.gold)
        // A torus's inside is its tube's centre line.
        var bad = 0
        for t in 0..<ring.triangleCount {
            let a = ring.vertices[Int(ring.indices[3 * t])].position, b = ring.vertices[Int(ring.indices[3 * t + 1])].position
            let c = ring.vertices[Int(ring.indices[3 * t + 2])].position
            let m = (a + b + c) / 3, spine = SIMD3<Float>(m.x, 0, m.z).unit * 2
            let n = (b - a).cross(c - a)
            if n.len > 1e-9, n.dot(m - spine) <= 0 { bad += 1 }
        }
        XCTAssertEqual(bad, 0)
        let disc = ToonMesh.disc(radius: 1, color: ToonColor.soil)
        for t in 0..<disc.triangleCount {
            let a = disc.vertices[Int(disc.indices[3 * t])].position, b = disc.vertices[Int(disc.indices[3 * t + 1])].position
            let c = disc.vertices[Int(disc.indices[3 * t + 2])].position
            XCTAssertGreaterThan((b - a).cross(c - a).y, 0)
        }
        let hill = ToonMesh.grid(minX: -2, maxX: 2, minZ: -1, maxZ: 1, cellsX: 8, cellsZ: 4,
                                 height: { x, _ in 0.1 * x }, color: { _, _, _ in ToonColor.grass })
        XCTAssertEqual(hill.vertices.count, 45)
        XCTAssertEqual(hill.triangleCount, 64)
        for t in 0..<hill.triangleCount {
            let a = hill.vertices[Int(hill.indices[3 * t])].position, b = hill.vertices[Int(hill.indices[3 * t + 1])].position
            let c = hill.vertices[Int(hill.indices[3 * t + 2])].position
            XCTAssertGreaterThan((b - a).cross(c - a).y, 0)
        }
        near(hill.vertices[20].normal, SIMD3<Float>(-0.1, 1, 0).unit)
    }

    func testAppendMovesAndRecolours() {
        var m = ToonMesh.box(SIMD3(1, 1, 1), color: ToonColor.stone)
        let count = m.vertices.count
        m.append(.sphere(radius: 1, segments: 8, rings: 4, color: ToonColor.cream),
                 ToonMatrix.translation(SIMD3(5, 0, 0)) * ToonMatrix.scale(SIMD3(1, 2, 1)), color: ToonColor.ink)
        XCTAssertEqual(m.vertices[count].color, ToonColor.ink)
        XCTAssertEqual(m.vertices[count].position.y, 2, accuracy: 1e-5)
        XCTAssertEqual(Int(m.indices.max()!), m.vertices.count - 1)
        XCTAssertEqual(m.bounds.max.x, 6, accuracy: 1e-5)
        let rod = ToonMatrix.rod(from: SIMD3(1, 1, 1), to: SIMD3(1, 4, 5), radius: 0.1)
        near(rod.point(SIMD3(0, 1, 0)), SIMD3(1, 4, 5))
        XCTAssertEqual((rod.point(SIMD3(1, 0, 0)) - SIMD3(1, 1, 1)).len, 0.1, accuracy: 1e-5)
        XCTAssertEqual(ToonColor.hex(0xFFFFFF), SIMD3(1, 1, 1))
        XCTAssertEqual(ToonColor.hex(0x000000), SIMD3(0, 0, 0))
    }
}
