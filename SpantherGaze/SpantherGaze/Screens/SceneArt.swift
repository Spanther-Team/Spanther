import CoreGraphics
import SpriteKit
import UIKit

/// The meteor game's art, baked with Core Graphics (architecture proposal, "Cel look that stays cheap"): sky-stones
/// as flat facets in three quantized tones under an ink line, their crack maps and shards, the engraved rings, the
/// lamp, dust, motes, the jar, the red sign, Earth's cap and the small rings of the reload, the impact and the debug
/// aim. Every piece becomes one textured quad: no SKShapeNode or SKEffectNode is drawn during play. Stones, cracks and
/// shards are baked off the main thread; the rest once at the start of a play.
///
/// Drawing space: a bitmap context with its origin at the centre (unless said otherwise), points, y up, the same as
/// Feel's stone-local frame and SpriteKit's.
enum SceneArt {
    // The stone tones (architecture proposal, "Palette"): warm stone lit, warm stone, warm stone in shade, deep stone
    // for the facet seams and muted gold for the amber inlay. The ink line is the atlas look's ink.
    static let stoneLit = rgb(0xB6A691)
    static let stoneMid = rgb(0x9C8A74)
    static let stoneShade = rgb(0x776858)
    static let deepStone = rgb(0x5E5246)
    static let mutedGold = rgb(0xC9A24E)
    static let parchment = rgb(0xF1E8D4)
    static var ink: CGColor { Atlas.UI.ink.cgColor }
    static var vermilion: CGColor { Atlas.UI.vermilion.cgColor }
    /// The outline round a stone (pt).
    static let inkLine: CGFloat = 2

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A transparent bitmap `size` pt big at `scale` px/pt. `centred`: origin in the middle, else bottom-left; y up.
    static func context(size: CGSize, scale: CGFloat, centred: Bool = true) -> CGContext? {
        let w = max(1, Int((size.width * scale).rounded(.up)))
        let h = max(1, Int((size.height * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if centred { ctx.translateBy(x: size.width / 2, y: size.height / 2) }
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.interpolationQuality = .high
        return ctx
    }

    static func texture(_ ctx: CGContext) -> SKTexture? {
        guard let image = ctx.makeImage() else { return nil }
        return SKTexture(cgImage: image)
    }

    static func path(_ polygon: ConvexPolygon) -> CGPath {
        let p = CGMutablePath()
        guard let first = polygon.vertices.first else { return p }
        p.move(to: CGPoint(x: first.x, y: first.y))
        for v in polygon.vertices.dropFirst() { p.addLine(to: CGPoint(x: v.x, y: v.y)) }
        p.closeSubpath()
        return p
    }

    // MARK: Sky-stones

    /// A stone baked into its own image: `side` pt square round the stone's centre.
    struct BakedStone {
        let stone: SkyStone
        let image: CGImage
        let texture: SKTexture
        /// The image's side, pt (the stone's diameter plus room for the ink line).
        let side: CGFloat
        let scale: CGFloat
    }

    /// Flat facets in three tones over a mid-tone base (so no seam shows between facets), fine seams in deep stone, an
    /// amber inlay on one lit facet of the bigger stones, and the ink line round the outline.
    static func bake(_ stone: SkyStone, scale: CGFloat) -> BakedStone? {
        let side = CGFloat(stone.radius * 2) + inkLine * 2 + 4
        guard let ctx = context(size: CGSize(width: side, height: side), scale: scale) else { return nil }
        let outline = path(stone.outline)
        ctx.addPath(outline)
        ctx.setFillColor(stoneMid)
        ctx.fillPath()
        let tones = [stoneLit, stoneMid, stoneShade]
        for facet in stone.facets {
            ctx.addPath(path(facet.polygon))
            ctx.setFillColor(tones[max(0, min(2, facet.tone))])
            ctx.fillPath()
        }
        // The inlay: the largest lit facet of a stone wider than about 1.4 cm, shrunk toward its own centre.
        if stone.radius > 40, let lit = stone.facets.filter({ $0.tone == 0 }).max(by: { $0.polygon.area < $1.polygon.area }) {
            let c = lit.polygon.centroid
            let inner = ConvexPolygon(vertices: lit.polygon.vertices.map { c + ($0 - c) * 0.45 })
            ctx.addPath(path(inner))
            ctx.setFillColor(mutedGold)
            ctx.fillPath()
        }
        ctx.setStrokeColor(rgb(0x5E5246, alpha: 0.55))
        ctx.setLineWidth(0.6)
        for facet in stone.facets {
            ctx.addPath(path(facet.polygon))
            ctx.strokePath()
        }
        ctx.addPath(outline)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(inkLine)
        ctx.strokePath()
        guard let image = ctx.makeImage() else { return nil }
        return BakedStone(stone: stone, image: image, texture: SKTexture(cgImage: image), side: side, scale: scale)
    }

    /// The crack map for the crack overlay (FeelShaders.crackReveal): the same square as the stone's image, red = the
    /// distance along the cracks from the gaze point (0...1 of the pattern's longest), alpha = the crack. Cracks are
    /// wider near the gaze point.
    static func crackMap(_ pattern: CrackPattern, side: CGFloat, scale: CGFloat) -> SKTexture? {
        guard pattern.maxDistance > 0, let ctx = context(size: CGSize(width: side, height: side), scale: scale) else { return nil }
        for s in pattern.segments {
            let t = CGFloat(s.distanceA / pattern.maxDistance)
            ctx.setStrokeColor(CGColor(srgbRed: t, green: 0, blue: 0, alpha: 1))
            ctx.setLineWidth(2.4 - 1.2 * t)
            ctx.move(to: CGPoint(x: s.a.x, y: s.a.y))
            ctx.addLine(to: CGPoint(x: s.b.x, y: s.b.y))
            ctx.strokePath()
        }
        return texture(ctx)
    }

    /// One shard cut from a baked stone: its own texture, the size it is drawn at and the anchor that puts the shard's
    /// centroid at the sprite's position.
    struct BakedShard {
        let shard: Shard
        let texture: SKTexture
        let size: CGSize
        let anchor: CGPoint
    }

    /// Cuts the stone's image along the shards (stone-local pt) and inks every cut edge.
    static func shards(_ shards: [Shard], of baked: BakedStone) -> [BakedShard] {
        shards.compactMap { shard in
            let xs = shard.polygon.vertices.map(\.x), ys = shard.polygon.vertices.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            let margin = 1.5
            let box = CGRect(x: minX - margin, y: minY - margin, width: maxX - minX + 2 * margin, height: maxY - minY + 2 * margin)
            guard let ctx = context(size: box.size, scale: baked.scale, centred: false) else { return nil }
            ctx.translateBy(x: -box.minX, y: -box.minY)
            let p = path(shard.polygon)
            ctx.saveGState()
            ctx.addPath(p)
            ctx.clip()
            let half = baked.side / 2
            ctx.draw(baked.image, in: CGRect(x: -half, y: -half, width: baked.side, height: baked.side))
            ctx.restoreGState()
            ctx.addPath(p)
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(1.2)
            ctx.strokePath()
            guard let tex = texture(ctx) else { return nil }
            let anchor = CGPoint(x: (CGFloat(shard.centroid.x) - box.minX) / box.width,
                                 y: (CGFloat(shard.centroid.y) - box.minY) / box.height)
            return BakedShard(shard: shard, texture: tex, size: box.size, anchor: anchor)
        }
    }

    // MARK: Shared pieces, baked once per play

    /// An engraved ring of the target instrument: a fine circle with a notch at 12 o'clock and, on every other ring,
    /// small ticks round it like an astrolabe's scale. The notches of all three rings meet at the top at the lock.
    static func ring(radius: CGFloat, ticks: Bool, scale: CGFloat) -> SKTexture? {
        let side = radius * 2 + 16
        guard let ctx = context(size: CGSize(width: side, height: side), scale: scale) else { return nil }
        ctx.setStrokeColor(ink.copy(alpha: 0.75) ?? ink)
        ctx.setLineWidth(1.4)
        ctx.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        ctx.strokePath()
        if ticks {
            ctx.setStrokeColor(ink.copy(alpha: 0.4) ?? ink)
            ctx.setLineWidth(0.8)
            for i in 0..<24 where i % 6 != 0 {
                let a = CGFloat(i) / 24 * 2 * .pi
                ctx.move(to: CGPoint(x: cos(a) * (radius - 2.5), y: sin(a) * (radius - 2.5)))
                ctx.addLine(to: CGPoint(x: cos(a) * radius, y: sin(a) * radius))
            }
            ctx.strokePath()
        }
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(2.4)
        ctx.move(to: CGPoint(x: 0, y: radius - 4))
        ctx.addLine(to: CGPoint(x: 0, y: radius + 6))
        ctx.strokePath()
        return texture(ctx)
    }

    /// A soft round light: `color` in the middle fading to nothing at the edge. Drawn at 64 pt and scaled.
    static func glow(_ color: CGColor, alpha: CGFloat, scale: CGFloat) -> SKTexture? {
        let side: CGFloat = 64
        guard let ctx = context(size: CGSize(width: side, height: side), scale: scale),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: [color.copy(alpha: alpha) ?? color,
                                                                     color.copy(alpha: alpha * 0.55) ?? color,
                                                                     color.copy(alpha: 0) ?? color] as CFArray,
                                        locations: [0, 0.55, 1]) else { return nil }
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: side / 2,
                               options: [])
        return texture(ctx)
    }

    /// A mote: a small amber bead with an ink rim. 10 pt.
    static func mote(scale: CGFloat) -> SKTexture? {
        guard let ctx = context(size: CGSize(width: 10, height: 10), scale: scale) else { return nil }
        ctx.addEllipse(in: CGRect(x: -3.2, y: -3.2, width: 6.4, height: 6.4))
        ctx.setFillColor(mutedGold)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(0.9)
        ctx.drawPath(using: .fillStroke)
        return texture(ctx)
    }

    /// The collection jar the motes fly into: a small ink-drawn jar on parchment. 26 × 30 pt.
    static func jar(scale: CGFloat) -> SKTexture? {
        let size = CGSize(width: 26, height: 30)
        guard let ctx = context(size: size, scale: scale) else { return nil }
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -7, y: 10))
        body.addLine(to: CGPoint(x: -7, y: 7))
        body.addQuadCurve(to: CGPoint(x: -10, y: 0), control: CGPoint(x: -11, y: 6))
        body.addLine(to: CGPoint(x: -10, y: -10))
        body.addQuadCurve(to: CGPoint(x: -6, y: -13), control: CGPoint(x: -10, y: -13))
        body.addLine(to: CGPoint(x: 6, y: -13))
        body.addQuadCurve(to: CGPoint(x: 10, y: -10), control: CGPoint(x: 10, y: -13))
        body.addLine(to: CGPoint(x: 10, y: 0))
        body.addQuadCurve(to: CGPoint(x: 7, y: 7), control: CGPoint(x: 11, y: 6))
        body.addLine(to: CGPoint(x: 7, y: 10))
        body.closeSubpath()
        ctx.addPath(body)
        ctx.setFillColor(parchment)
        ctx.fillPath()
        ctx.addRect(CGRect(x: -9.5, y: -12.5, width: 19, height: 8))
        ctx.setFillColor(mutedGold.copy(alpha: 0.85) ?? mutedGold)
        ctx.fillPath()
        ctx.addPath(body)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(1.4)
        ctx.strokePath()
        ctx.addRect(CGRect(x: -8.5, y: 10, width: 17, height: 3.5))
        ctx.setFillColor(stoneMid)
        ctx.drawPath(using: .fillStroke)
        return texture(ctx)
    }

    /// The red sign (the "no entry" of road signs): a vermilion disc with a bar of paper across it, `radius` pt.
    static func redSign(radius: CGFloat, scale: CGFloat) -> SKTexture? {
        let side = radius * 2 + 4
        guard let ctx = context(size: CGSize(width: side, height: side), scale: scale) else { return nil }
        ctx.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        ctx.setFillColor(vermilion)
        ctx.setStrokeColor(ink.copy(alpha: 0.55) ?? ink)
        ctx.setLineWidth(1.2)
        ctx.drawPath(using: .fillStroke)
        let bar = CGRect(x: -radius * 0.575, y: -radius * 0.16, width: radius * 1.15, height: radius * 0.32)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: radius * 0.08, cornerHeight: radius * 0.08, transform: nil))
        ctx.setFillColor(Atlas.UI.paper.cgColor)
        ctx.fillPath()
        return texture(ctx)
    }

    /// A ring `radius` pt: stroke only (the reload wave, the debug aim) or with a fill (the impact flash).
    static func circle(radius: CGFloat, stroke: CGColor, width: CGFloat, fill: CGColor? = nil, scale: CGFloat) -> SKTexture? {
        let side = radius * 2 + width + 2
        guard let ctx = context(size: CGSize(width: side, height: side), scale: scale) else { return nil }
        ctx.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        if let fill {
            ctx.setFillColor(fill)
            ctx.fillPath()
            ctx.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        }
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(width)
        ctx.strokePath()
        return texture(ctx)
    }

    /// Earth's cap along the bottom edge, engraved like a globe on an old chart: the paper's shade under an ink line,
    /// two parallels, short meridian ticks and seven continents tilted with the arc. `surfaceY(x)`: the surface's
    /// height at scene x (scene pt, y up). The image covers scene x from −`margin` to width + `margin` (room for the
    /// shake of an impact) and y from 0 to `top`; place it with its bottom-left corner at (−margin, 0).
    static func earth(width: CGFloat, top: CGFloat, margin: CGFloat, surfaceY: (Double) -> Double, centreX: Double,
                      radius: Double, scale: CGFloat) -> SKTexture? {
        guard let ctx = context(size: CGSize(width: width + 2 * margin, height: top), scale: scale, centred: false) else {
            return nil
        }
        ctx.translateBy(x: margin, y: 0)
        let steps = 64
        func xAt(_ i: Int) -> Double { -20 + (Double(width) + 40) * Double(i) / Double(steps) }
        let cap = CGMutablePath()
        for i in 0...steps {
            let p = CGPoint(x: xAt(i), y: surfaceY(xAt(i)))
            if i == 0 { cap.move(to: p) } else { cap.addLine(to: p) }
        }
        cap.addLine(to: CGPoint(x: Double(width) + 20, y: -20))
        cap.addLine(to: CGPoint(x: -20, y: -20))
        cap.closeSubpath()
        ctx.addPath(cap)
        ctx.setFillColor(Atlas.UI.paperShade.cgColor)
        ctx.fillPath()
        for (depth, alpha) in [(14.0, 0.22), (32.0, 0.14)] {
            ctx.setStrokeColor(ink.copy(alpha: CGFloat(alpha)) ?? ink)
            ctx.setLineWidth(0.8)
            for i in 0...steps {
                let p = CGPoint(x: xAt(i), y: surfaceY(xAt(i)) - depth)
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
        ctx.setStrokeColor(ink.copy(alpha: 0.3) ?? ink)
        for i in 0..<14 {
            let x = Double(width) * (Double(i) + 0.5) / 14
            ctx.move(to: CGPoint(x: x, y: surfaceY(x) - 3))
            ctx.addLine(to: CGPoint(x: x, y: surfaceY(x) - 10))
        }
        ctx.strokePath()
        let land = CGColor(srgbRed: 0.235, green: 0.478, blue: 0.420, alpha: 0.28)
        for i in 0..<7 {
            let x = Double(width) * (Double(i) + 0.5) / 7
            let dx = x - centreX
            let slope = dx / max(1, (radius * radius - dx * dx).squareRoot())
            let w = 50 + 30 * Double(i % 3)
            ctx.saveGState()
            ctx.translateBy(x: x + 12 * Double(i % 2), y: surfaceY(x) - 20 - 6 * Double(i % 2))
            // The slope is the arc's in screen space (y down); in this y-up drawing the tilt turns the other way.
            ctx.rotate(by: CGFloat(-atan(slope)))
            ctx.addEllipse(in: CGRect(x: -w / 2, y: -6, width: w, height: 12))
            ctx.setFillColor(land)
            ctx.setStrokeColor(ink.copy(alpha: 0.35) ?? ink)
            ctx.setLineWidth(0.8)
            ctx.drawPath(using: .fillStroke)
            ctx.restoreGState()
        }
        ctx.addPath(cap)
        ctx.setStrokeColor(ink.copy(alpha: 0.75) ?? ink)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        return texture(ctx)
    }
}
