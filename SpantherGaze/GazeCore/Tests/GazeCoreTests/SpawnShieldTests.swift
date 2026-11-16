@testable import GazeCore
import XCTest

/// A new meteor flies in under a shield: for its first 1.5 cm in from the edge a look finds it but cannot burn it.
final class SpawnShieldTests: XCTestCase {
    let screen = Vec2(844, 390)
    let dt = 1.0 / 60

    /// The model with the first meteor the play brings in, and that meteor.
    private func firstMeteor(_ c: BalanceConfig, seed: UInt64) throws -> (GameModel, Asteroid) {
        let m = GameModel(config: c, screen: screen, marginPt: 40, seed: seed)
        var spawned: Asteroid?
        var t = 0.0
        while spawned == nil, t < 5 {
            for e in m.update(dt: dt, gaze: .notLooking) { if case .spawned(let a) = e { spawned = a } }
            t += dt
        }
        return (m, try XCTUnwrap(spawned))
    }

    private func now(_ m: GameModel, _ a: Asteroid) -> Asteroid? { m.asteroids.first { $0.id == a.id } }

    func testBalanceJsonAsksForOneAndAHalfCentimetres() throws {
        let c = try BalanceTests.config()
        XCTAssertEqual(c.spawnShieldPt(), 90, accuracy: 1e-9, "1.5 cm at 60 pt/cm")
        XCTAssertEqual(c.spawnShieldPt(ptPerCm: 64), 96, accuracy: 1e-9)
        var off = c
        off.spawnShieldCm = 0
        XCTAssertEqual(off.spawnShieldPt(), 0)
        off.spawnShieldCm = -1
        XCTAssertEqual(off.spawnShieldPt(), 0)
        off.spawnShieldCm = nil
        XCTAssertEqual(off.spawnShieldPt(), 90, accuracy: 1e-9)
    }

    func testTheMeteorThePlayBringsInIsShielded() throws {
        let (m, a) = try firstMeteor(try BalanceTests.config(), seed: 41)
        XCTAssertTrue(a.isShielded)
        XCTAssertEqual(a.shieldPt, 90, accuracy: 1e-9)
        XCTAssertFalse(m.spawn().isShielded, "spawn alone builds it bare: the play shields what it brings in")
    }

    /// The look lands on it from the first frame, so the reaction time still counts from the moment it is seen,
    /// but nothing charges, nothing brakes it and the pool does not starve until it has flown 90 pt.
    func testALookFindsItButBurnsNothingUntilItHasFlownInOneAndAHalfCentimetres() throws {
        let (m, a) = try firstMeteor(try BalanceTests.config(), seed: 42)
        let start = a.position
        let speed = a.velocity.length
        var charged: Vec2?
        var t = 0.0
        while charged == nil, t < 4, let cur = now(m, a) {
            let before = cur.position
            m.update(dt: dt, gaze: .point(cur.position))
            guard let after = now(m, a) else { break }
            XCTAssertTrue(after.isTargeted)
            if after.progress > 0 {
                charged = after.position
            } else {
                XCTAssertTrue(after.isShielded || after.position.distance(to: start) >= 90 - 1e-9)
                XCTAssertEqual(after.position.distance(to: before), speed * dt, accuracy: 1e-9, "no gaze brake under the shield")
                XCTAssertFalse(m.starved)
            }
            t += dt
        }
        XCTAssertEqual(try XCTUnwrap(now(m, a)?.firstLookTime), a.spawnTime + dt, accuracy: 1e-9, "seen on the first frame")
        let p = try XCTUnwrap(charged, "it charges once the shield is down")
        XCTAssertEqual(p.distance(to: start), 90, accuracy: speed * dt * 2, "the shield ends after 90 pt of flight")
        XCTAssertGreaterThan(t, 90 / speed - 2 * dt)
    }

    /// Once the shield is down the meteor burns in its own hold time, with the brake back on.
    func testAfterTheShieldItBurnsInItsHoldTime() throws {
        let (m, a) = try firstMeteor(try BalanceTests.config(), seed: 43)
        var t = 0.0, freeAt: Double?, burnedAt: Double?
        while burnedAt == nil, t < 15 {
            let cur = m.asteroids.first { $0.id == a.id }
            if freeAt == nil, let cur, !cur.isShielded { freeAt = t }
            let events = m.update(dt: dt, gaze: cur.map { .point($0.position) } ?? .notLooking)
            t += dt
            for e in events { if case .destroyed(let x, let rec) = e, x.id == a.id { burnedAt = t; XCTAssertEqual(rec.slips, 0) } }
            if m.starved { m.reload() }
        }
        let free = try XCTUnwrap(freeAt), burned = try XCTUnwrap(burnedAt)
        XCTAssertEqual(burned - free, a.dwellSec, accuracy: 2 * dt + 1e-9)
    }

    func testZeroCentimetresTurnsTheShieldOff() throws {
        var c = try BalanceTests.config()
        c.spawnShieldCm = 0
        let (_, a) = try firstMeteor(c, seed: 44)
        XCTAssertFalse(a.isShielded)
    }

    /// The shield is a distance, so a pause for a lost face does not use it up.
    func testAPauseForALostFaceDoesNotUseTheShieldUp() throws {
        let (m, a) = try firstMeteor(try BalanceTests.config(), seed: 45)
        var frames = 0
        while !m.pausedForFace, frames < 600 { m.update(dt: dt, gaze: .lost); frames += 1 }
        XCTAssertTrue(m.pausedForFace)
        let paused = try XCTUnwrap(now(m, a))
        for _ in 0..<180 { m.update(dt: dt, gaze: .lost) }
        let later = try XCTUnwrap(now(m, a))
        XCTAssertEqual(later.position.distance(to: paused.position), 0, accuracy: 1e-9)
        XCTAssertEqual(later.shieldPt, paused.shieldPt, accuracy: 1e-9)
        XCTAssertEqual(paused.shieldPt, max(0, 90 - paused.position.distance(to: a.position)), accuracy: 1e-6)
    }
}
