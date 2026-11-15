import SpriteKit

/// A broken stone after the lock: its shards in flight (Feel's ShardFlight: gravity, drag, one bounce on the Earth,
/// then a fade) and a few motes of light curving off to the score (MotePath). GameScene steps it every frame and
/// drops it once both are over. Scene coordinates, y up.
final class ShardBurst {
    private var flight: ShardFlight
    private let shards: [SKSpriteNode]
    private let motes: [(path: MotePath, node: SKShapeNode)]
    private var age = 0.0

    var isOver: Bool { flight.isOver && motes.allSatisfy { $0.node.parent == nil } }

    init(flight: ShardFlight, textures: [SKTexture], sides: [CGFloat], scale: CGFloat, motes: [MotePath],
         in parent: SKNode) {
        self.flight = flight
        var shards: [SKSpriteNode] = []
        for (piece, (texture, side)) in zip(flight.pieces, zip(textures, sides)) {
            let s = SKSpriteNode(texture: texture, size: CGSize(width: side, height: side))
            s.setScale(scale)
            s.position = CGPoint(x: piece.position.x, y: piece.position.y)
            s.zRotation = CGFloat(piece.angle)
            s.zPosition = 12
            parent.addChild(s)
            shards.append(s)
        }
        self.shards = shards
        self.motes = motes.map { (path: MotePath) -> (path: MotePath, node: SKShapeNode) in
            let dot = SKShapeNode(circleOfRadius: 2.6)
            dot.fillColor = Atlas.UI.amber
            dot.strokeColor = .clear
            dot.zPosition = 55
            dot.isHidden = true
            dot.position = CGPoint(x: path.start.x, y: path.start.y)
            parent.addChild(dot)
            return (path: path, node: dot)
        }
    }

    func step(_ dt: Double) {
        guard dt > 0 else { return }
        age += dt
        flight.step(dt)
        let alpha = CGFloat(flight.alpha)
        for (node, piece) in zip(shards, flight.pieces) {
            node.position = CGPoint(x: piece.position.x, y: piece.position.y)
            node.zRotation = CGFloat(piece.angle)
            node.alpha = alpha
        }
        if flight.isOver { shards.forEach { $0.removeFromParent() } }
        for m in motes where m.node.parent != nil {
            if let p = m.path.position(at: age) {
                m.node.isHidden = false
                m.node.position = CGPoint(x: p.x, y: p.y)
            } else if age > m.path.delaySec {
                m.node.removeFromParent()
            }
        }
    }

    /// The scene is going away or the play starts again: everything off at once.
    func cancel() {
        shards.forEach { $0.removeFromParent() }
        motes.forEach { $0.node.removeFromParent() }
    }
}
