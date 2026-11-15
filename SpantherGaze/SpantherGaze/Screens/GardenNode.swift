import SpriteKit
import SwiftUI

/// The living garden inside the meteor game's SpriteKit scene (architecture proposal, "Rendering": one renderer per
/// screen, so SwiftUI no longer composites a Canvas under the game). The trees and the lianas are baked once into two
/// layers with GardenPainter, the same drawing and seed as the garden behind the menu, and sway with the wind shader
/// (FeelShaders.windSway): the trees still at the bottom edge, the lianas hanging from the top. The spores are small
/// sprites that rise and twinkle. The light pulses along the lianas are left out: visuals give way before tracking.
final class GardenNode: SKNode {
    private let garden: Garden
    private let height: CGFloat
    private var spores: [SKSpriteNode] = []

    init(size: CGSize, scale: CGFloat) {
        garden = Garden(size: Vec2(Double(size.width), Double(size.height)), seed: Atlas.gardenSeed)
        height = size.height
        super.init()
        let now = CACurrentMediaTime()
        let layers: [(GardenPainter.Parts, Float, Float)] = [(.trees, 0.0025, 0), (.lianas, 0.006, 1)]
        for (i, layer) in layers.enumerated() {
            guard let texture = Self.bake(garden, size: size, parts: layer.0, time: now, scale: scale) else { continue }
            let sprite = SKSpriteNode(texture: texture, size: size)
            sprite.anchorPoint = .zero
            sprite.shader = SKShader(source: FeelShaders.windSway, uniforms: [
                SKUniform(name: "u_amplitude", float: layer.1),
                SKUniform(name: "u_speed", float: 0.9 + 0.35 * Float(i)),
                SKUniform(name: "u_phase", float: 1.7 * Float(i)),
                SKUniform(name: "u_anchor", float: layer.2),
            ])
            sprite.zPosition = CGFloat(i)
            addChild(sprite)
        }
        let ink = Self.star(glow: false, scale: scale)
        let amber = Self.star(glow: true, scale: scale)
        for s in garden.spores {
            let sprite = SKSpriteNode(texture: s.glows ? amber : ink)
            let side = CGFloat(s.glows ? 14 : 8) * CGFloat(max(0.5, s.size / 2))
            sprite.size = CGSize(width: side, height: side)
            sprite.zPosition = 3
            addChild(sprite)
            spores.append(sprite)
        }
        update(time: now)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Moves the spores to where they are at host time `time`.
    func update(time: Double) {
        for (i, sprite) in spores.enumerated() {
            let (p, twinkle) = garden.spore(i, time: time)
            sprite.position = CGPoint(x: p.x, y: Double(height) - p.y)
            sprite.alpha = CGFloat(twinkle)
        }
    }

    /// One layer of the garden at host time `time`, screen pt, as GardenPainter draws it for SwiftUI.
    private static func bake(_ garden: Garden, size: CGSize, parts: GardenPainter.Parts, time: Double,
                             scale: CGFloat) -> SKTexture? {
        let canvas = Canvas { g, _ in
            GardenPainter.draw(&g, garden, time: time, growth: 1, parts: parts)
        }
        .frame(width: size.width, height: size.height)
        return texture(canvas, scale: scale)
    }

    /// A spore: a small ink star, or an amber one with a soft glow.
    private static func star(glow: Bool, scale: CGFloat) -> SKTexture? {
        let side: CGFloat = glow ? 14 : 8
        let canvas = Canvas { g, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            if glow {
                g.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(Atlas.amber.opacity(0.14)))
                g.fill(Atlas.star(c, 2.6), with: .color(Atlas.amber.opacity(0.8)))
            } else {
                g.fill(Atlas.star(c, 2), with: .color(Atlas.ink.opacity(0.24)))
            }
        }
        .frame(width: side, height: side)
        return texture(canvas, scale: scale)
    }

    private static func texture<V: View>(_ view: V, scale: CGFloat) -> SKTexture? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        return SKTexture(cgImage: image)
    }
}
