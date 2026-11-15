import SpriteKit
import UIKit

/// Paints Feel's sky stones into SpriteKit textures, off the main thread, so a stone costs a few textured quads to
/// draw. A stone gets two pictures of itself, cool (paper tones, an engraver's hatching on its shadow side, an ink
/// rim) and hot (the same in vermilion), which RockNode fades between as the hold fills. When the gaze first rests
/// on it, its fracture is worked out (StoneFracture) and painted too: the cracks, with each pixel's distance from
/// the impact along the cracks kept in the green channel for the crack shader, and one picture per shard, cut from
/// the hot stone, for the burst. Pictures are drawn y up with the stone's centre in the middle; `radius` is the
/// stone's in pt (its farthest corner), `scale` px per pt.
enum StoneBaker {
    static let queue = DispatchQueue(label: "spanther.stones", qos: .userInitiated)

    struct Art {
        let cool: SKTexture
        let hot: SKTexture
        /// The hot picture, kept to cut the shards from.
        let hotImage: CGImage
        /// The pictures' side (pt): the stone and the stroke of its rim.
        let side: CGFloat
    }

    struct Broken {
        let fracture: StoneFracture
        /// Same size and place as the stone's pictures.
        let cracks: SKTexture
        /// One per shard of the fracture, in its order, with the shard's centroid in the middle.
        let shards: [SKTexture]
        let shardSides: [CGFloat]
    }

    static func side(radius: CGFloat) -> CGFloat { 2 * radius + 6 }

    // The atlas palette: three tones of paper, three of vermilion, the ink.
    private static let coolTones: [CGColor] = [rgb(0xF2ECE1), rgb(0xE7DFD1), rgb(0xD6CBB6)]
    private static let hotTones: [CGColor] = [rgb(0xD26A4C), rgb(0xC2452D), rgb(0xA23A2A)]
    private static let ink = rgb(0x1D2438)

    static func art(_ stone: SkyStone, radius: CGFloat, scale: CGFloat) -> Art? {
        let side = side(radius: radius)
        guard let cool = paint(stone, radius: radius, side: side, scale: scale, tones: coolTones),
              let hot = paint(stone, radius: radius, side: side, scale: scale, tones: hotTones) else { return nil }
        return Art(cool: SKTexture(cgImage: cool), hot: SKTexture(cgImage: hot), hotImage: hot, side: side)
    }

    /// The fracture for a look at `impact` (stone frame) and its pictures. Seconds of work at most for the largest
    /// stone on an old phone; usually a few milliseconds.
    static func broken(_ stone: SkyStone, art: Art, impact: FeelPoint, radius: CGFloat, scale: CGFloat,
                       seed: UInt64) -> Broken? {
        let fracture = StoneFracture.make(outline: stone.outline, impact: impact, seed: seed)
        guard !fracture.shards.isEmpty, let cracks = paintCracks(fracture, radius: radius, side: art.side, scale: scale,
                                                                 seed: seed) else { return nil }
        var shards: [SKTexture] = [], sides: [CGFloat] = []
        for shard in fracture.shards {
            let reach = shard.polygon.map { Planar.distance($0, shard.centroid) }.max() ?? 0
            let side = 2 * CGFloat(reach) * radius + 4
            guard let image = cut(shard, from: art.hotImage, stoneSide: art.side, radius: radius, side: side, scale: scale)
            else { return nil }
            shards.append(SKTexture(cgImage: image))
            sides.append(side)
        }
        return Broken(fracture: fracture, cracks: SKTexture(cgImage: cracks), shards: shards, shardSides: sides)
    }

    /// The crack overlay's shader: a crack shows once the hold's front (`a_progress`, 0...1 of the farthest crack)
    /// has passed its distance, with a short soft edge so it grows rather than ticks; its core glows amber as the
    /// stone heats (`a_heat`). One shader for every stone, so it is compiled once.
    static let crackShader: SKShader = {
        let shader = SKShader(source: """
        void main() {
            vec4 c = texture2D(u_texture, v_tex_coord);
            float a = max(c.a, 0.0001);
            float d = c.g / a;
            float core = c.r / a;
            float front = a_progress * 1.06;
            float shown = 1.0 - smoothstep(front - 0.07, front, d);
            vec3 col = mix(vec3(0.114, 0.141, 0.220), vec3(0.851, 0.588, 0.161), core * a_heat);
            float alpha = c.a * shown;
            gl_FragColor = vec4(col * alpha, alpha);
        }
        """)
        shader.attributes = [SKAttribute(name: "a_progress", type: .float), SKAttribute(name: "a_heat", type: .float)]
        return shader
    }()

    // MARK: Painting

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A square premultiplied RGBA context of `side` pt, origin in the middle, y up, units pt.
    private static func context(side: CGFloat, scale: CGFloat, space: CGColorSpace) -> CGContext? {
        let px = max(1, Int((side * scale).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        ctx.scaleBy(x: CGFloat(px) / side, y: CGFloat(px) / side)
        return ctx
    }

    private static func pt(_ p: FeelPoint, _ radius: CGFloat) -> CGPoint { CGPoint(x: p.x * radius, y: p.y * radius) }

    private static func polygon(_ points: [FeelPoint], _ radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { pt($0, radius) })
        path.closeSubpath()
        return path
    }

    private static func paint(_ stone: SkyStone, radius: CGFloat, side: CGFloat, scale: CGFloat,
                              tones: [CGColor]) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = context(side: side, scale: scale, space: space) else { return nil }
        let outline = polygon(stone.outline, radius)
        // The middle tone under everything, so the seams between facets never let the paper behind show through.
        ctx.addPath(outline)
        ctx.setFillColor(tones[1])
        ctx.fillPath()
        for facet in stone.facets {
            ctx.addPath(polygon(facet.points, radius))
            ctx.setFillColor(tones[min(tones.count - 1, max(0, facet.tone))])
            ctx.fillPath()
        }
        // The engraver's hatching on the facets in shadow: fine parallel strokes, 45 degrees, 3 pt apart.
        ctx.setStrokeColor(rgb(0x1D2438, 0.2))
        ctx.setLineWidth(0.55)
        for facet in stone.facets where facet.tone == SkyStone.toneCount - 1 {
            ctx.saveGState()
            ctx.addPath(polygon(facet.points, radius))
            ctx.clip()
            var x = -2 * radius
            while x < 2 * radius {
                ctx.move(to: CGPoint(x: x, y: -radius))
                ctx.addLine(to: CGPoint(x: x + 2 * radius, y: radius))
                x += 3
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        // The ridges from the apex to the corners, faint; then the rim, firm.
        ctx.setStrokeColor(rgb(0x1D2438, 0.22))
        ctx.setLineWidth(0.6)
        for corner in stone.outline {
            ctx.move(to: pt(stone.apex, radius))
            ctx.addLine(to: pt(corner, radius))
        }
        ctx.strokePath()
        ctx.addPath(outline)
        ctx.setStrokeColor(rgb(0x1D2438, 0.9))
        ctx.setLineWidth(1.6)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// The cracks, in short pieces of at most 2 px so the distance in green grows smoothly along them. Red marks
    /// the line's core. The lines thin out away from the impact. Device RGB, so the numbers stay as written.
    private static func paintCracks(_ fracture: StoneFracture, radius: CGFloat, side: CGFloat, scale: CGFloat,
                                    seed: UInt64) -> CGImage? {
        guard let ctx = context(side: side, scale: scale, space: CGColorSpaceCreateDeviceRGB()) else { return nil }
        let strokes = fracture.drawnCracks(seed: seed)
        let reach = max(fracture.reach, 1e-9)
        let width = max(1.3, radius * 0.028)
        ctx.setLineCap(.round)
        for core in [false, true] {
            for c in strokes {
                let length = Double(Planar.distance(c.from, c.to)) * Double(radius * scale)
                let m = max(1, Int((length / 2).rounded(.up)))
                for k in 0..<m {
                    let t0 = Double(k) / Double(m), t1 = Double(k + 1) / Double(m)
                    let d = (c.fromDistance + (c.toDistance - c.fromDistance) * (t0 + t1) / 2) / reach
                    ctx.setStrokeColor(red: core ? 1 : 0, green: CGFloat(min(1, max(0, d))), blue: 0, alpha: 1)
                    ctx.setLineWidth(width * CGFloat(1 - 0.45 * min(1, d)) * (core ? 0.42 : 1))
                    ctx.move(to: pt(c.from + (c.to - c.from) * t0, radius))
                    ctx.addLine(to: pt(c.from + (c.to - c.from) * t1, radius))
                    ctx.strokePath()
                }
            }
        }
        return ctx.makeImage()
    }

    /// One shard: the hot stone seen through the shard's outline, its broken edges inked.
    private static func cut(_ shard: StoneFracture.Shard, from stone: CGImage, stoneSide: CGFloat, radius: CGFloat,
                            side: CGFloat, scale: CGFloat) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = context(side: side, scale: scale, space: space) else { return nil }
        let c = pt(shard.centroid, radius)
        ctx.translateBy(x: -c.x, y: -c.y)
        let outline = polygon(shard.polygon, radius)
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip()
        ctx.draw(stone, in: CGRect(x: -stoneSide / 2, y: -stoneSide / 2, width: stoneSide, height: stoneSide))
        ctx.restoreGState()
        ctx.addPath(outline)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(1.2)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        return ctx.makeImage()
    }
}
