import Foundation

/// A sky-stone's shape for the cel look: a convex outline, never the same twice, and flat facets that meet at a
/// raised apex, each in one of three tones from a light at the upper left. The app paints it once into a texture
/// (StoneBaker), so a stone costs one textured quad to draw. Units: the stone's own frame (Planar), the farthest
/// corner at radius 1.
public struct SkyStone: Sendable, Equatable {
    public struct Facet: Sendable, Equatable {
        /// The apex and two neighbouring corners of the outline, counter-clockwise.
        public let points: [FeelPoint]
        /// 0 lit, 1 half-lit, 2 in shadow.
        public let tone: Int
    }

    public static let toneCount = 3

    public let outline: [FeelPoint]
    /// Where the facets meet, inside the outline: the stone's highest point.
    public let apex: FeelPoint
    /// One per edge of the outline, in the outline's order.
    public let facets: [Facet]

    /// `corners`: the points the outline is drawn round (a few may fall inside the hull and go). `light`: where
    /// the light comes from in the stone's plane. `apexHeight`: how far the apex stands out of the plane; higher
    /// makes the tones differ more from facet to facet.
    public static func make(seed: UInt64, corners: Int = 9, light: FeelPoint = FeelPoint(-0.6, 0.8),
                            apexHeight: Double = 0.55) -> SkyStone {
        let n = max(5, corners)
        var rng = FeelRandom.stream(seed, 0x5354_4F4E)
        var outline: [FeelPoint] = []
        for _ in 0..<8 where outline.count < 5 {
            let turn = rng.uniform(0, 2 * .pi)
            var points: [FeelPoint] = []
            for i in 0..<n {
                let a = turn + (Double(i) + rng.uniform(-0.3, 0.3)) * 2 * .pi / Double(n)
                points.append(FeelPoint(cos(a), sin(a)) * rng.uniform(0.8, 1.0))
            }
            outline = Planar.convexHull(points)
        }
        if outline.count < 5 {
            outline = (0..<n).map { FeelPoint(cos(Double($0) * 2 * .pi / Double(n)), sin(Double($0) * 2 * .pi / Double(n))) }
        }
        // The stone turns about its own centre of area, and its farthest corner sits on the unit circle.
        let centre = Planar.centroid(outline)
        outline = outline.map { $0 - centre }
        let far = outline.map { Planar.length($0) }.max() ?? 1
        outline = outline.map { $0 / far }
        let apex = FeelPoint(rng.uniform(-0.2, 0.2), rng.uniform(-0.2, 0.2))

        // Each facet's normal, from the raised apex (apex, h) to two corners in the plane, against the light.
        let lightLength = Planar.length(light)
        let l = lightLength > 0 ? light / lightLength : FeelPoint(0, 1)
        let lz = 1.1, ln = (1 + lz * lz).squareRoot()
        let h = max(0.05, apexHeight)
        var shades: [Double] = []
        for i in 0..<outline.count {
            let b = outline[i] - apex, d = outline[(i + 1) % outline.count] - apex
            let nx = h * (d.y - b.y), ny = h * (b.x - d.x), nz = Planar.cross(b, d)
            let nl = (nx * nx + ny * ny + nz * nz).squareRoot()
            shades.append(nl > 0 ? (nx * l.x + ny * l.y + nz * lz) / (nl * ln) : 0)
        }
        // Tones by rank: the brightest third lit, the darkest third in shadow, so every stone shows all three.
        let order = shades.indices.sorted { shades[$0] > shades[$1] }
        var tones = [Int](repeating: 1, count: outline.count)
        let third = Double(outline.count) / 3
        for (rank, i) in order.enumerated() { tones[i] = min(2, Int(Double(rank) / third)) }
        let facets = (0..<outline.count).map {
            Facet(points: [apex, outline[$0], outline[($0 + 1) % outline.count]], tone: tones[$0])
        }
        return SkyStone(outline: outline, apex: apex, facets: facets)
    }
}
