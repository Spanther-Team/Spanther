import XCTest
@testable import Feel

final class SoundBankTests: XCTestCase {
    /// A small bank, quick to make.
    private func small(seed: UInt64) -> SoundBank {
        return SoundBank.make(sampleRate: 24000.0, seed: seed, variantsPerLayer: 6, chimePerStep: 2)
    }

    private func same(_ a: SoundBank, _ b: SoundBank) -> Bool {
        for layer in SoundLayer.allCases {
            if a.count(layer) != b.count(layer) { return false }
            for i in 0..<a.count(layer) {
                if a.variant(layer, i) != b.variant(layer, i) { return false }
            }
        }
        return true
    }

    func testCountsAndLayout() {
        let bank = small(seed: 1)
        XCTAssertEqual(bank.sampleRate, 24000.0)
        XCTAssertEqual(bank.chimePerStep, 2)
        XCTAssertEqual(bank.count(.charge), 8)
        XCTAssertEqual(bank.count(.crack), 6)
        XCTAssertEqual(bank.count(.pop), 6)
        XCTAssertEqual(bank.count(.crumble), 6)
        XCTAssertEqual(bank.count(.chime), ChimeLadder.frequencies.count * 2)

        // The index wraps.
        XCTAssertEqual(bank.variant(.pop, 6), bank.variant(.pop, 0))
        XCTAssertEqual(bank.variant(.pop, -1), bank.variant(.pop, 5))
        XCTAssertEqual(bank.variant(.charge, 19), bank.variant(.charge, 3))

        // Chimes are laid out step-major; the step is clamped, the variant wraps.
        for step in 0..<ChimeLadder.frequencies.count {
            for k in 0..<2 {
                XCTAssertEqual(bank.chime(step: step, variant: k), bank.variant(.chime, step * 2 + k))
            }
        }
        XCTAssertEqual(bank.chime(step: 99, variant: 0), bank.variant(.chime, 14))
        XCTAssertEqual(bank.chime(step: -3, variant: 1), bank.variant(.chime, 1))
        XCTAssertEqual(bank.chime(step: 2, variant: 5), bank.variant(.chime, 5))
        XCTAssertEqual(bank.chime(step: 2, variant: -1), bank.variant(.chime, 5))

        // Each chime step sounds its own note: the energy at its frequency beats the energy at its neighbours'.
        for step in 0..<ChimeLadder.frequencies.count {
            let x = bank.chime(step: step, variant: 0)
            let own = FeelCheck.goertzel(x, frequency: ChimeLadder.frequencies[step], sampleRate: 24000.0)
            if step > 0 {
                let below = FeelCheck.goertzel(x, frequency: ChimeLadder.frequencies[step - 1], sampleRate: 24000.0)
                XCTAssertGreaterThan(own, 4.0 * below, "step \(step)")
            }
            if step + 1 < ChimeLadder.frequencies.count {
                let above = FeelCheck.goertzel(x, frequency: ChimeLadder.frequencies[step + 1], sampleRate: 24000.0)
                XCTAssertGreaterThan(own, 4.0 * above, "step \(step)")
            }
        }
    }

    func testVariantsDifferAndStayUnderTheLevel() {
        let bank = small(seed: 2)
        var bytes = 0
        for layer in SoundLayer.allCases {
            let n = bank.count(layer)
            XCTAssertGreaterThan(n, 1)
            for i in 0..<n {
                let x = bank.variant(layer, i)
                XCTAssertFalse(x.isEmpty)
                bytes += 4 * x.count
                // Normalized to −12 dBFS, then a level factor in 0.88...1.0 (0.88 is −1.11 dB).
                let db = FeelCheck.peakDB(x)
                XCTAssertLessThanOrEqual(db, -12.0 + 0.01, "\(layer.rawValue) \(i)")
                XCTAssertGreaterThanOrEqual(db, -12.0 - 1.12, "\(layer.rawValue) \(i)")
                for j in 0..<i {
                    XCTAssertNotEqual(x, bank.variant(layer, j), "\(layer.rawValue) \(i) and \(j)")
                }
            }
        }
        XCTAssertEqual(bank.byteCount, bytes)
    }

    func testSameSeedSameBankDifferentSeedDifferentBank() {
        let a = small(seed: 77)
        let b = small(seed: 77)
        let c = small(seed: 78)
        XCTAssertTrue(same(a, b))
        XCTAssertFalse(same(a, c))
    }

    func testTheDefaultBankAtFortyEightKilohertz() {
        let bank = SoundBank.make(sampleRate: 48000.0, seed: 2026)
        XCTAssertEqual(bank.count(.charge), 8)
        XCTAssertEqual(bank.count(.crack), 48)
        XCTAssertEqual(bank.count(.pop), 48)
        XCTAssertEqual(bank.count(.crumble), 48)
        XCTAssertEqual(bank.count(.chime), 32)
        XCTAssertEqual(bank.chimePerStep, 4)
        XCTAssertLessThan(bank.byteCount, 12 * 1024 * 1024)
        XCTAssertGreaterThan(bank.byteCount, 1024 * 1024)
        for layer in SoundLayer.allCases {
            for i in 0..<bank.count(layer) {
                XCTAssertLessThanOrEqual(FeelCheck.peakDB(bank.variant(layer, i)), -12.0 + 0.01)
            }
        }
        let again = SoundBank.make(sampleRate: 48000.0, seed: 2026)
        XCTAssertTrue(same(bank, again))
    }

    func testMaterialAndEmptyLayers() {
        let wood = SoundBank.make(sampleRate: 24000.0, seed: 3, variantsPerLayer: 0, chimePerStep: 1, material: .wood)
        XCTAssertEqual(wood.count(.crack), 0)
        XCTAssertEqual(wood.variant(.crack, 4), [])
        XCTAssertEqual(wood.count(.chime), ChimeLadder.frequencies.count)
        let expected = Int((ChimeMaterial.wood.duration * 24000.0).rounded())
        XCTAssertEqual(wood.chime(step: 0, variant: 0).count, expected)

        let none = SoundBank.make(sampleRate: 24000.0, seed: 3, variantsPerLayer: 1, chimePerStep: 0)
        XCTAssertEqual(none.count(.chime), 0)
        XCTAssertEqual(none.chime(step: 1, variant: 0), [])
    }
}

final class FeelShadersTests: XCTestCase {
    private var sources: [String: String] {
        return [
            "crackReveal": FeelShaders.crackReveal,
            "windSway": FeelShaders.windSway,
            "dissolve": FeelShaders.dissolve,
        ]
    }

    func testUniformsHasExactlyTheThreeShaders() {
        XCTAssertEqual(Set(FeelShaders.uniforms.keys), Set(["crackReveal", "windSway", "dissolve"]))
        XCTAssertEqual(FeelShaders.uniforms["crackReveal"], ["u_progress", "u_ink"])
        XCTAssertEqual(FeelShaders.uniforms["windSway"], ["u_amplitude", "u_speed", "u_phase", "u_anchor"])
        XCTAssertEqual(FeelShaders.uniforms["dissolve"], ["u_dissolve", "u_cells", "u_edge"])
    }

    func testEverySourceIsASpriteKitFragmentShader() throws {
        for (name, source) in sources {
            XCTAssertTrue(source.contains("void main()"), name)
            XCTAssertTrue(source.contains("gl_FragColor"), name)
            XCTAssertTrue(source.contains("texture2D(u_texture"), name)
            let uniforms = try XCTUnwrap(FeelShaders.uniforms[name], name)
            XCTAssertFalse(uniforms.isEmpty, name)
            for uniform in uniforms {
                XCTAssertTrue(source.contains(uniform), "\(name) uses \(uniform)")
            }
            // SKShader declares the uniforms itself; the source must not.
            XCTAssertFalse(source.contains("uniform "), name)
            XCTAssertFalse(source.contains("discard"), name)
            // Balanced braces and brackets: the cheapest check that the text is whole.
            var braces = 0
            var brackets = 0
            for character in source {
                if character == "{" { braces += 1 }
                if character == "}" { braces -= 1 }
                if character == "(" { brackets += 1 }
                if character == ")" { brackets -= 1 }
            }
            XCTAssertEqual(braces, 0, name)
            XCTAssertEqual(brackets, 0, name)
        }
    }

    func testWindSwayUsesTheClockAndTheOthersDoNot() {
        XCTAssertTrue(FeelShaders.windSway.contains("u_time"))
        XCTAssertFalse(FeelShaders.crackReveal.contains("u_time"))
        XCTAssertFalse(FeelShaders.dissolve.contains("u_time"))
    }
}
