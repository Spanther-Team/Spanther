import QuartzCore
import SwiftUI

/// One firework in the pool: where and when it went off. Its sparks are worked out from the seed at every frame,
/// so a burst is these few numbers and nothing is allocated while it flies.
struct FireworkBurst: Equatable {
    var origin: CGPoint
    var start: Double
    var tier: Int
    var seed: UInt64
    var scale: CGFloat
}

/// A milestone's banner.
struct StreakCallout: Equatable, Identifiable {
    let id: Int
    let text: String
    let tier: Int
}

/// The streak of one play and its celebration (sunlit redesign, part 3): the count for the angled combo counter, the
/// banner of a milestone, the pool of fireworks, and the chimes and haptics that go with them. A play feeds it locks
/// and breaks; the screen shows it with `CelebrationLayer`. Safe to call from any thread: the work is done on main.
final class StreakFX: ObservableObject {
    /// Locks in a row now.
    @Published private(set) var count = 0
    /// The banner on screen, if any.
    @Published private(set) var callout: StreakCallout?
    /// True while a firework is in the air: the fireworks canvas redraws only then.
    @Published private(set) var live = false

    /// The play's count (best run, milestones), for the victory screen.
    private(set) var streak = Streak()
    /// At most `poolSize` bursts; the oldest makes room for a new one.
    private(set) var bursts: [FireworkBurst] = []

    /// Fireworks smaller than 1 where the play needs the eyes close by (the warm-up's dot).
    let burstScale: CGFloat
    /// Whether milestones chime. Off in the rhythm game, where a chime over the track would blur the beat.
    let chimes: Bool

    static let poolSize = 4
    static let burstLife = 1.2
    static let calloutSec = 1.5

    private var serial = 0
    private var seed: UInt64 = 0x5EED_F12E_0000_0001
    private var liveUntil = 0.0

    init(burstScale: CGFloat = 1, chimes: Bool = true) {
        self.burstScale = burstScale
        self.chimes = chimes
    }

    var best: Int { streak.best }
    var milestones: Int { streak.milestones }

    /// Warms up what a milestone needs (the haptic engine, the chime notes), so nothing is built at that moment.
    func prepare() {
        onMain {
            Haptics.shared.prepare()
            if self.chimes { StreakChimes.shared.prepare() }
        }
    }

    /// A lock at `point` (screen pt), where a milestone's firework goes off.
    func lock(at point: CGPoint?) {
        onMain {
            let m = self.streak.lock()
            self.count = self.streak.count
            if let m { self.celebrate(m, at: point) }
        }
    }

    /// A miss or a distractor: the run is over.
    func breakStreak() {
        onMain {
            guard self.streak.count > 0 else { return }
            self.streak.breakRun()
            self.count = 0
        }
    }

    /// Follows a count kept elsewhere (the rhythm judge's combo).
    func follow(_ n: Int, at point: CGPoint?) {
        onMain {
            guard n != self.streak.count else { return }
            let passed = self.streak.follow(n)
            self.count = self.streak.count
            if let m = passed.last { self.celebrate(m, at: point) }
        }
    }

    /// The end of a play that keeps no streak (the probe): fireworks at `points`, one after another, with the
    /// chime and the haptics of a big milestone, and no banner.
    func finale(at points: [CGPoint]) {
        onMain {
            for (k, p) in points.enumerated() { self.burst(at: p, tier: 2, delay: 0.45 * Double(k)) }
            if self.chimes { StreakChimes.shared.play(tier: 2) }
            Haptics.shared.milestone(tier: 2)
        }
    }

    private func celebrate(_ milestone: Int, at point: CGPoint?) {
        let tier = Streak.tier(milestone)
        serial += 1
        let c = StreakCallout(id: serial, text: Self.calloutText(milestone), tier: tier)
        callout = c
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.calloutSec) { [weak self] in
            if self?.callout?.id == c.id { self?.callout = nil }
        }
        if let point { burst(at: point, tier: tier) }
        if chimes { StreakChimes.shared.play(tier: tier) }
        Haptics.shared.milestone(tier: tier)
    }

    private func burst(at p: CGPoint, tier: Int, delay: Double = 0) {
        let now = CACurrentMediaTime()
        bursts.removeAll { now - $0.start > Self.burstLife }
        if bursts.count >= Self.poolSize { bursts.removeFirst() }
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bursts.append(FireworkBurst(origin: p, start: now + delay, tier: tier, seed: seed, scale: burstScale))
        liveUntil = max(liveUntil, now + delay + Self.burstLife)
        if !live { live = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + (liveUntil - now) + 0.05) { [weak self] in
            guard let self, CACurrentMediaTime() >= self.liveUntil else { return }
            self.live = false
            self.bursts.removeAll()
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// The banner's words for a milestone.
    static func calloutText(_ milestone: Int) -> String {
        switch milestone {
        case 5: return "×5 · ФОКУС!"
        case 10: return "×10 · ВЗГЛЯД МАСТЕРА!"
        case 15: return "×15 · ГЛАЗ БЕРКУТА!"
        default: return "×\(milestone) · ВЗГЛЯД ПАНТЕРЫ!"
        }
    }

    static func tierColour(_ tier: Int) -> Color {
        switch tier {
        case 0: return Atlas.gold
        case 1: return Atlas.sky
        case 2: return Atlas.emerald
        default: return Atlas.energy
        }
    }
}

/// The celebration over a play: the fireworks, the angled combo counter and a milestone's banner. It spans the whole
/// screen (screen pt, like the plays' targets) and never takes a touch. With Reduce Motion the fireworks stay off
/// and the banner fades instead of sliding; the counter, the chime and the haptics stay.
struct CelebrationLayer: View {
    @ObservedObject var fx: StreakFX
    /// Where the combo counter sits, from the screen's top left corner.
    var comboTop: CGFloat = 64
    var comboLeading: CGFloat = 64
    /// How far down the banner comes in.
    var calloutTop: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !reduceMotion { FireworksCanvas(fx: fx) }
            ComboBadge(count: fx.count, reduceMotion: reduceMotion)
                .padding(.top, comboTop)
                .padding(.leading, comboLeading)
            VStack {
                if let c = fx.callout {
                    CalloutBanner(callout: c)
                        .id(c.id)
                        .transition(reduceMotion
                                    ? AnyTransition.opacity
                                    : AnyTransition.asymmetric(
                                        insertion: AnyTransition.move(edge: .leading).combined(with: .opacity),
                                        removal: AnyTransition.move(edge: .trailing).combined(with: .opacity)))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, calloutTop)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? Animation.easeOut(duration: 0.2) : Atlas.snap, value: fx.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { fx.prepare() }
    }
}

/// The combo counter: an ink plate leaning into the play, «×7 подряд» in cream, with an amber shadow. It kicks on
/// every lock (harder on a milestone) and drops away when the run breaks.
private struct ComboBadge: View {
    let count: Int
    let reduceMotion: Bool
    @State private var kick: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            if count >= 2 {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("×").font(Atlas.display(18))
                    Text("\(count)").font(Atlas.display(32).monospacedDigit())
                    Text("подряд")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .padding(.leading, 3)
                }
                .foregroundStyle(Atlas.paper)
                .padding(.horizontal, 18)
                .padding(.vertical, 1)
                .background(InkSlab(shape: Slant(lean: 12), fill: Atlas.ink, depth: 4, shadow: Atlas.energy))
                .rotationEffect(.degrees(-6))
                .scaleEffect(kick, anchor: .bottomLeading)
                .transition(AnyTransition.asymmetric(
                    insertion: AnyTransition.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity),
                    removal: AnyTransition.offset(y: 36).combined(with: .opacity)))
            }
        }
        .animation(reduceMotion ? Animation.easeOut(duration: 0.15) : Atlas.snap, value: count >= 2)
        .onChange(of: count) { n in
            guard n >= 2, !reduceMotion else { return }
            withAnimation(Animation.spring(response: 0.12, dampingFraction: 0.6)) {
                kick = Streak.isMilestone(n) ? 1.3 : 1.12
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(Atlas.snap) { kick = 1 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count >= 2 ? "\(count) подряд" : "")
        .accessibilityHidden(count < 2)
    }
}

/// A milestone's banner: heavy words on an angled plate in the tier's colour, tilted against the counter.
private struct CalloutBanner: View {
    let callout: StreakCallout

    var body: some View {
        Text(callout.text)
            .font(Atlas.display(28))
            .foregroundStyle(Atlas.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 30)
            .padding(.vertical, 8)
            .background(InkSlab(shape: Slant(lean: 18), fill: StreakFX.tierColour(callout.tier), depth: 6))
            .rotationEffect(.degrees(-4))
            .accessibilityLabel(callout.text)
    }
}

/// The fireworks, drawn only while one is in the air.
private struct FireworksCanvas: View {
    @ObservedObject var fx: StreakFX

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !fx.live)) { _ in
            // The time is read once per frame and captured by the canvas (see RhythmPlayView).
            let now = CACurrentMediaTime()
            let bursts = fx.bursts
            Canvas { g, _ in Fireworks.draw(&g, bursts, now: now) }
        }
        .accessibilityHidden(true)
    }
}

/// Cel fireworks: sparks in the palette with ink outlines that fly out, slow down, fall a little and shrink to
/// nothing in 1.2 s, around a ring that opens at the start. About 130 pt across at full size: a burst never fills
/// the screen, and nothing flashes.
enum Fireworks {
    static let colours: [Color] = [Atlas.gold, Atlas.energy, Atlas.sky, Atlas.emerald, Atlas.paper]

    static func draw(_ g: inout GraphicsContext, _ bursts: [FireworkBurst], now: Double) {
        for b in bursts {
            let t = now - b.start
            guard t >= 0, t < StreakFX.burstLife else { continue }
            let life = t / StreakFX.burstLife
            let k = b.scale
            let o = b.origin
            if t < 0.3 {
                // The pop: an ink ring under a gold one, opening and fading.
                let u = t / 0.3
                let r = k * CGFloat(14 + 64 * u)
                let ring = Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r))
                g.stroke(ring, with: .color(Atlas.ink.opacity(0.55 * (1 - u))), lineWidth: 5 * k)
                g.stroke(ring, with: .color(Atlas.gold.opacity(1 - u)), lineWidth: 2.5 * k)
            }
            var rng = FeelRandom(seed: b.seed)
            let n = 12 + 4 * b.tier
            // With drag the sparks slow down: distance = v (1 − e^(−d t)) / d, plus a little gravity.
            let drag = 3.4
            let travel: Double = (1 - exp(-drag * t)) / drag
            let fall: Double = 70 * t * t
            let shrink = CGFloat(1 - life * life)
            for i in 0..<n {
                let angle: Double = 2 * Double.pi * Double(i) / Double(n) + rng.uniform(-0.2, 0.2)
                let speed: Double = rng.uniform(250, 400) * Double(k)
                let size = CGFloat(rng.uniform(6, 10)) * k * shrink
                guard size > 0.6 else { continue }
                let x = o.x + CGFloat(cos(angle) * speed * travel)
                let y = o.y + CGFloat(sin(angle) * speed * travel + fall * Double(k))
                let colour = colours[(i + b.tier) % colours.count]
                let spark = i % 3 == 2 ? Path(ellipseIn: CGRect(x: x - size * 0.6, y: y - size * 0.6,
                                                                 width: size * 1.2, height: size * 1.2))
                                       : star(CGPoint(x: x, y: y), size, turn: angle + t * 4)
                g.fill(spark, with: .color(colour))
                g.stroke(spark, with: .color(Atlas.ink), lineWidth: 1.4)
            }
        }
    }

    /// A four-pointed sparkle of radius `r`, turned by `turn` radians.
    static func star(_ c: CGPoint, _ r: CGFloat, turn: Double) -> Path {
        var p = Path()
        for i in 0..<8 {
            let a: Double = turn + Double(i) * Double.pi / 4
            let rr: CGFloat = i % 2 == 0 ? r : r * 0.38
            let pt = CGPoint(x: c.x + rr * CGFloat(cos(a)), y: c.y + rr * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}
