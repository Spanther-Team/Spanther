import Foundation

// The sky-stone: a low-poly rock, drawn once at load. The app bakes it with Core Graphics from the facets below
// (3 flat tones and a 2 px ink line around the outline). Everything is in stone-local pt: origin at the stone's
// centre, x right, y up.

/// One flat face of the stone.
public struct StoneFacet: Sendable, Equatable {
    /// Stone-local pt.
    public var polygon: ConvexPolygon
    /// 0 lit, 1 mid, 2 shade.
    public var tone: Int

    public init(polygon: ConvexPolygon, tone: Int) {
        self.polygon = polygon
        self.tone = tone
    }
}

public struct SkyStone: Sendable, Equatable {
    /// Unit vector toward the light, upper left (y up).
    public static let light: SIMD2<Double> = SIMD2<Double>(-0.6, 0.8)

    /// Pt. No point of the stone is farther than this from its centre.
    public var radius: Double
    /// Stone-local pt. Every vertex is between 0.82 and 1.0 radius from the centre.
    public var outline: ConvexPolygon
    /// The faces. Together they tile the outline exactly: no gaps, no overlaps.
    public var facets: [StoneFacet]

    public init(radius: Double, outline: ConvexPolygon, facets: [StoneFacet]) {
        self.radius = radius
        self.outline = outline
        self.facets = facets
    }

    /// A new stone of `radius` pt. The rim is 9...13 points at uneven angles and distances, made convex. The apex
    /// (the point nearest the viewer) sits 0.15...0.2 radius from the centre toward the light. Between the apex and
    /// the rim runs one inner ring, so each rim edge gives two faces: a rim face (inner ring to rim) and a crown
    /// face (apex to inner ring). A face's tone comes from how much its outer edge looks toward the light: rim faces
    /// are lit above +0.3 and in shade below −0.3; crown faces lie flatter toward the viewer, so they are lit only
    /// above +0.6 and in shade only below −0.6.
    public static func make(radius: Double, rng: inout FeelRandom) -> SkyStone {
        let count = rng.int(in: 9...13)
        let slice = 2.0 * Double.pi / Double(count)
        let turn = rng.uniform(0.0, 2.0 * Double.pi)
        var ring: [FeelPoint] = []
        ring.reserveCapacity(count)
        for i in 0..<count {
            let angle = turn + (Double(i) + rng.uniform(-0.3, 0.3)) * slice
            let r = radius * rng.uniform(0.85, 0.995)
            ring.append(FeelPoint(r * cos(angle), r * sin(angle)))
        }
        let outline = ConvexPolygon.hull(ring)
        let rim = outline.vertices
        let n = rim.count

        let apex = light * (radius * rng.uniform(0.15, 0.2))
        var inner: [FeelPoint] = []
        inner.reserveCapacity(n)
        for i in 0..<n {
            let share = rng.uniform(0.48, 0.58)
            inner.append(apex + (rim[i] - apex) * share)
        }

        var facets: [StoneFacet] = []
        facets.reserveCapacity(2 * n)
        if n >= 3 {
            for i in 0..<n {
                let j = (i + 1) % n
                let rimFace = ConvexPolygon(vertices: [inner[i], rim[i], rim[j], inner[j]])
                facets.append(StoneFacet(polygon: rimFace, tone: tone(from: rim[i], to: rim[j], threshold: 0.3)))
                let crownFace = ConvexPolygon(vertices: [apex, inner[i], inner[j]])
                facets.append(StoneFacet(polygon: crownFace, tone: tone(from: inner[i], to: inner[j], threshold: 0.6)))
            }
        }
        return SkyStone(radius: radius, outline: outline, facets: facets)
    }

    /// The tone of a face whose outer edge runs counter-clockwise from a to b: the dot product of the edge's outward
    /// normal with the light, cut at ±threshold.
    private static func tone(from a: FeelPoint, to b: FeelPoint, threshold: Double) -> Int {
        let e = b - a
        let length = FeelMath.length(e)
        if length <= 0 { return 1 }
        let outward = FeelPoint(e.y / length, -e.x / length)
        let facing = FeelMath.dot(outward, light)
        if facing > threshold { return 0 }
        if facing < -threshold { return 2 }
        return 1
    }
}
