import SwiftUI
import UIKit

/// Wink Beat: the difficulty choice, the play over the Metal stage, the results. Laid out after the approved mockups
/// (Persona-inspired composition in the sunlit palette: tilted ink slabs, oversized numbers, burst stamps).
struct WinkBeatView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: WinkBeatSession

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch session.phase {
                case .select:
                    WinkBeatSelect(session: session, size: geo.size)
                case .ready, .playing:
                    WinkBeatPlayScreen(session: session, size: geo.size)
                case .done:
                    WinkBeatResults(session: session, size: geo.size)
                }
            }
        }
        .ignoresSafeArea()
        .onDisappear { session.leave() }
    }
}

// MARK: - Shared pieces

/// A slant like the mockups' `skewX(-14deg)`, about the view's middle so it stays in its place.
struct Skew: GeometryEffect {
    var degrees: Double
    var animatableData: Double {
        get { degrees }
        set { degrees = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let c = CGFloat(tan(degrees * Double.pi / 180))
        return ProjectionTransform(CGAffineTransform(a: 1, b: 0, c: c, d: 1, tx: -c * size.height / 2, ty: 0))
    }
}

extension View {
    func skewed(_ degrees: Double = -14) -> some View { modifier(Skew(degrees: degrees)) }
}

enum WinkBeatText {
    static func difficulty(_ d: WinkBeatDifficulty) -> String {
        switch d {
        case .easy: return L("Лёгкий")
        case .normal: return L("Средний")
        case .hard: return L("Сложный")
        }
    }

    static func hint(_ d: WinkBeatDifficulty) -> String {
        switch d {
        case .easy: return L("Моргни, когда кольцо сойдётся с кругом. Энергия не кончится.")
        case .normal: return L("Моргай в такт, нот больше. Первые полминуты энергия не кончится.")
        case .hard: return L("Только подмигивания: синие круги левым глазом, золотые правым.")
        }
    }

    /// Grade words stay in English in every language: they are the game's terms, like the ranks.
    static func grade(_ g: WinkBeatGrade) -> String {
        switch g {
        case .perfect: return "PERFECT"
        case .great: return "GREAT"
        case .good: return "GOOD"
        case .miss: return "MISS"
        }
    }

    static func clock(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func eyes(_ n: WinkBeatEyesNote) -> (title: String, detail: String) {
        switch n {
        case .open: return (L("Глаза открыты"), L("слежу за взглядом"))
        case .blink: return (L("Моргание не считается"), L("прицел на месте"))
        case .winkLeft: return (L("Левый глаз"), L("подмигивание"))
        case .winkRight: return (L("Правый глаз"), L("подмигивание"))
        case .longBlink: return (L("Долгое моргание"), L("засчитано"))
        case .beatBlink: return (L("Моргание"), L("засчитано"))
        case .blinkOffTarget: return (L("Моргание мимо"), L("смотри на круг"))
        case .blinkOffBeat: return (L("Моргание"), L("не в такт"))
        case .noFace: return (L("Лицо не видно"), L("посмотри на экран"))
        }
    }
}

enum WinkBeatColors {
    static func side(_ s: NoteSide) -> Color {
        switch s {
        case .left: return Atlas.sky
        case .right: return Atlas.gold
        case .any: return Atlas.emerald
        }
    }

    static func grade(_ g: WinkBeatGrade) -> Color {
        switch g {
        case .perfect: return Atlas.gold
        case .great: return Atlas.emerald
        case .good: return Atlas.sky
        case .miss: return Atlas.ink
        }
    }
}

/// The eye marks of the mockups in a 40 x 20 box: a closed lid with lashes for the eye that winks, an open eye for
/// the one that stays open.
struct EyeGlyph: View {
    enum Part { case closed(x: Double), open(x: Double) }
    let parts: [Part]
    var color: Color = Atlas.ink

    static func wink(_ side: NoteSide) -> EyeGlyph {
        switch side {
        case .left: return EyeGlyph(parts: [.closed(x: 0), .open(x: 29)])
        case .right: return EyeGlyph(parts: [.open(x: 11), .closed(x: 20)])
        case .any: return EyeGlyph(parts: [.closed(x: 10)])
        }
    }

    static let shut = EyeGlyph(parts: [.closed(x: 0), .closed(x: 20)])
    static let open = EyeGlyph(parts: [.open(x: 11), .open(x: 29)])

    var body: some View {
        Canvas { g, size in
            let k = min(size.width / 40, size.height / 20)
            g.translateBy(x: (size.width - 40 * k) / 2, y: (size.height - 20 * k) / 2)
            g.scaleBy(x: k, y: k)
            for part in parts {
                switch part {
                case let .closed(x):
                    var lid = Path()
                    lid.move(to: CGPoint(x: x + 3, y: 8))
                    lid.addQuadCurve(to: CGPoint(x: x + 17, y: 8), control: CGPoint(x: x + 10, y: 15))
                    lid.move(to: CGPoint(x: x + 5.5, y: 10.2))
                    lid.addLine(to: CGPoint(x: x + 3.9, y: 13.4))
                    lid.move(to: CGPoint(x: x + 10, y: 11.5))
                    lid.addLine(to: CGPoint(x: x + 10, y: 15))
                    lid.move(to: CGPoint(x: x + 14.5, y: 10.2))
                    lid.addLine(to: CGPoint(x: x + 16.1, y: 13.4))
                    g.stroke(lid, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                case let .open(x):
                    g.fill(Path(ellipseIn: CGRect(x: x - 5.5, y: 3, width: 11, height: 14)), with: .color(color))
                    g.fill(Path(ellipseIn: CGRect(x: x + 0.1, y: 5.5, width: 3.4, height: 3.4)), with: .color(Atlas.cream))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A jagged burst behind a word, the same for the same seed.
struct BurstShape: Shape {
    var points = 9
    var inner = 0.72
    var seed: UInt64 = 11

    func path(in rect: CGRect) -> Path {
        var rng = BotJitter(seed: seed)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        for i in 0..<(points * 2) {
            let a = Double(i) / Double(points * 2) * 2 * Double.pi
            let k = i % 2 == 1 ? inner + (rng.next() - 0.5) * 0.12 : 1 + (rng.next() - 0.5) * 0.14
            let q = CGPoint(x: c.x + CGFloat(cos(a) * k) * rect.width / 2, y: c.y + CGFloat(sin(a) * k) * rect.height / 2)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }
}

/// Text in cream with an ink outline and a hard ink shadow.
struct InkedText: View {
    let text: String
    let size: CGFloat
    var fill: Color = Atlas.cream
    var shadow: CGFloat = 0

    var body: some View {
        let base = Text(text).font(.system(size: size, weight: .black).italic()).monospacedDigit()
        ZStack {
            if shadow > 0 { base.foregroundStyle(Atlas.ink).offset(x: shadow, y: shadow) }
            ForEach(0..<8, id: \.self) { k in
                let a = Double(k) * Double.pi / 4
                base.foregroundStyle(Atlas.ink).offset(x: CGFloat(cos(a)) * size * 0.06, y: CGFloat(sin(a)) * size * 0.06)
            }
            base.foregroundStyle(fill)
        }
    }
}

/// The sky behind the play: the mockups' daylight gradient, a sun and soft cel clouds. Static: the 3D world of
/// floating islands comes in the next milestone.
struct WinkBeatSky: View {
    var body: some View {
        Canvas { g, size in
            let rect = CGRect(origin: .zero, size: size)
            g.fill(Path(rect), with: .linearGradient(
                Gradient(stops: [.init(color: Color(red: 0.227, green: 0.561, blue: 0.910), location: 0),
                                 .init(color: Color(red: 0.557, green: 0.761, blue: 0.945), location: 0.62),
                                 .init(color: Color(red: 0.851, green: 0.918, blue: 0.965), location: 1)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let sun = CGPoint(x: size.width * 0.92, y: size.height * 0.03)
            g.fill(Path(ellipseIn: CGRect(x: sun.x - 190, y: sun.y - 190, width: 380, height: 380)),
                   with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.965, blue: 0.867).opacity(0.95),
                                                           Color(red: 1, green: 0.965, blue: 0.867).opacity(0)]),
                                         center: sun, startRadius: 0, endRadius: 190))
            let k = size.height / 390
            for (x, y, s) in [(0.86, 0.24, 0.8), (0.08, 0.91, 1.35), (0.51, 0.98, 1.15), (0.2, 0.14, 0.6)] {
                cloud(&g, CGPoint(x: size.width * x, y: size.height * y), s * k)
            }
            g.fill(Path(rect), with: .color(Atlas.cream.opacity(0.16)))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cloud(_ g: inout GraphicsContext, _ c: CGPoint, _ s: Double) {
        var p = Path()
        for (x, y, r) in [(-58.0, 2.0, 32.0), (-16, -20, 42), (34, -6, 36), (72, 8, 24)] {
            p.addEllipse(in: CGRect(x: c.x + (x - r) * s, y: c.y + (y - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        p.addRoundedRect(in: CGRect(x: c.x - 90 * s, y: c.y + 2 * s, width: 186 * s, height: 30 * s),
                         cornerSize: CGSize(width: 15 * s, height: 15 * s))
        g.fill(p, with: .color(.white.opacity(0.92)))
        var base = Path()
        base.move(to: CGPoint(x: c.x - 80 * s, y: c.y + 26 * s))
        base.addLine(to: CGPoint(x: c.x + 88 * s, y: c.y + 26 * s))
        g.stroke(base, with: .color(Color(red: 0.812, green: 0.886, blue: 0.965)),
                 style: StrokeStyle(lineWidth: 10 * s, lineCap: .round))
    }
}

/// Touches with their `UITouch.timestamp` (the host clock the music clock uses) and spot.
struct WinkBeatTouches: UIViewRepresentable {
    let began: (Double, CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: () -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.backgroundColor = .clear
        update(v)
        return v
    }

    func updateUIView(_ v: TouchView, context: Context) { update(v) }

    private func update(_ v: TouchView) {
        v.began = began
        v.moved = moved
        v.ended = ended
    }

    final class TouchView: UIView {
        var began: ((Double, CGPoint) -> Void)?
        var moved: ((CGPoint) -> Void)?
        var ended: (() -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { began?(t.timestamp, t.location(in: self)) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let t = touches.first { moved?(t.location(in: self)) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { ended?() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { ended?() }
    }
}

// MARK: - Difficulty choice

struct WinkBeatSelect: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: WinkBeatSession
    let size: CGSize

    var body: some View {
        let s = size.height / 390
        ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Wink Beat").font(.system(size: 24 * s, weight: .black).italic())
                    Text(L("Выбери сложность")).font(.system(size: 12 * s, weight: .heavy)).foregroundStyle(Atlas.gold)
                }
                .foregroundStyle(Atlas.cream)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Atlas.ink.shadow(.drop(color: Atlas.gold, radius: 0, x: 5, y: 5)))
                .skewed()
                .padding(.top, 16 * s)
                track(s)
                    .padding(.top, 26 * s)
                    .padding(.leading, 18 * s)
            }
            .padding(.leading, 34 * s)
            detail(s)
                .frame(width: 300 * s, alignment: .leading)
                .position(x: size.width - 170 * s, y: size.height / 2)
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            guard session.bot else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { session.prepare(screen: size) }
        }
    }

    /// The track's first word, written large behind the sky slab.
    private var bigTitle: String { session.map.map { String($0.title.split(separator: " ").first ?? "") } ?? "" }

    private var backdrop: some View {
        let title = self.bigTitle
        return Canvas { g, sz in
            g.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(Atlas.cream))
            var sky = Path()
            sky.move(to: .zero)
            sky.addLine(to: CGPoint(x: sz.width * 0.59, y: 0))
            sky.addLine(to: CGPoint(x: sz.width * 0.43, y: sz.height))
            sky.addLine(to: CGPoint(x: 0, y: sz.height))
            sky.closeSubpath()
            g.fill(sky, with: .color(Atlas.sky))
            var stripe = Path()
            stripe.move(to: CGPoint(x: sz.width * 0.59, y: 0))
            stripe.addLine(to: CGPoint(x: sz.width * 0.65, y: 0))
            stripe.addLine(to: CGPoint(x: sz.width * 0.48, y: sz.height))
            stripe.addLine(to: CGPoint(x: sz.width * 0.43, y: sz.height))
            stripe.closeSubpath()
            g.fill(stripe, with: .color(Atlas.emerald))
            g.stroke(stripe, with: .color(Atlas.ink), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            g.drawLayer { l in
                l.opacity = 0.2
                l.translateBy(x: -14, y: sz.height - 6)
                l.rotate(by: .degrees(-8))
                l.draw(Text(title).font(.system(size: sz.height * 0.64, weight: .black).italic()).foregroundColor(.white),
                       at: .zero, anchor: .bottomLeading)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func track(_ s: CGFloat) -> some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(Atlas.paperShade)
                Canvas { g, sz in
                    var p = Path()
                    var x = -sz.height
                    while x < sz.width {
                        p.move(to: CGPoint(x: x, y: sz.height))
                        p.addLine(to: CGPoint(x: x + sz.height, y: 0))
                        x += 12
                    }
                    g.stroke(p, with: .color(Atlas.ink.opacity(0.13)), lineWidth: 6)
                }
                Text(L("обложка")).font(.system(size: 9 * s, weight: .bold)).foregroundStyle(Atlas.inkSoft).padding(.bottom, 3)
            }
            .frame(width: 66 * s, height: 66 * s)
            .overlay(Rectangle().stroke(Atlas.ink, lineWidth: 3))
            VStack(alignment: .leading, spacing: 4) {
                Text(session.map?.title ?? "—").font(.system(size: 31 * s, weight: .black).italic())
                Text(session.map?.author ?? "").font(.system(size: 12 * s, weight: .bold))
            }
            .foregroundStyle(Atlas.ink)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12).padding(.trailing, 16)
        .frame(width: 342 * s, height: 94 * s)
        .background(InkSlab(shape: Rectangle(), fill: Atlas.cream, depth: 9 * s, shadow: Atlas.gold, line: 4))
        .skewed(-8)
        .rotationEffect(.degrees(-4))
    }

    private func detail(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12 * s) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("\(Int((session.map?.bpm ?? 0).rounded()))")
                    .font(.system(size: 96 * s, weight: .black).italic())
                    .shadow(color: Atlas.sky, radius: 0, x: 6, y: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BPM").font(.system(size: 22 * s, weight: .black).italic())
                    Text(WinkBeatText.clock(session.map?.durationSec ?? 0)).font(.system(size: 12 * s, weight: .bold))
                }
            }
            .foregroundStyle(Atlas.ink)
            HStack(spacing: 8 * s) {
                ForEach(WinkBeatDifficulty.allCases, id: \.self) { d in
                    let on = session.difficulty == d
                    let shut = !session.opened(d)
                    Button { session.difficulty = d } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(WinkBeatText.difficulty(d)).font(.system(size: 14 * s, weight: .black).italic())
                            if shut {
                                Label(L("после Среднего"), systemImage: "lock.fill")
                                    .font(.system(size: 10 * s, weight: .bold))
                            } else {
                                Text(L("{0} нот", session.count(d))).font(.system(size: 10 * s, weight: .bold))
                            }
                        }
                        .foregroundStyle(on ? Atlas.cream : Atlas.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7).padding(.vertical, 6)
                        .background(InkSlab(shape: Rectangle(), fill: on ? Atlas.sky : Atlas.cream, depth: on ? 5 : 3, line: 3))
                        .skewed(-12)
                        .offset(y: on ? -6 : 0)
                        .opacity(shut ? 0.55 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(shut)
                    .accessibilityHint(shut ? L("Откроется, когда пройдёшь Средний до конца.") : "")
                }
            }
            Text(WinkBeatText.hint(session.difficulty))
                .font(.system(size: 12 * s, weight: .semibold))
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { session.prepare(screen: size) } label: { Text(L("Начать")) }
                    .buttonStyle(AtlasPrimaryButton(fill: Atlas.gold))
                    .disabled(session.map == nil)
                Button { app.route = .syncCheck } label: { Image(systemName: "metronome") }
                    .buttonStyle(AtlasSecondaryButton())
                    .frame(width: 56)
                    .accessibilityLabel(L("Синхронизация звука"))
                Button { app.leaveWinkBeat() } label: { Text(L("Назад")) }
                    .buttonStyle(AtlasSecondaryButton())
                    .frame(width: 96)
            }
        }
    }
}

// MARK: - Play

struct WinkBeatPlayScreen: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: WinkBeatSession
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = size.height / 390
        ZStack(alignment: .topLeading) {
            WinkBeatSky()
            StageView(session: session, reduceMotion: reduceMotion)
                .allowsHitTesting(false)
            marks(s)
            spinner(s)
            stampLayer(s)
            WinkBeatTouches(
                began: { host, p in session.touchBegan(host: host, at: Vec2(Double(p.x), Double(p.y))) },
                moved: { p in session.touchMoved(to: Vec2(Double(p.x), Double(p.y))) },
                ended: { session.touchEnded() })
            if session.phase == .ready { startPrompt(s) }
            WinkBeatHUD(session: session, size: size)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The eye mark in each circle and slider head that waits for a wink.
    private func marks(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let play = session.play {
                ForEach(session.marks, id: \.self) { i in
                    (play.rules.difficulty.blinksPlay ? EyeGlyph.shut : EyeGlyph.wink(play.objects[i].side))
                        .frame(width: 38 * s, height: 19 * s)
                        .position(x: CGFloat(play.positions[i].x), y: CGFloat(play.positions[i].y))
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: session.marks)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func spinner(_ s: CGFloat) -> some View {
        if let play = session.play, let i = session.spinnerShown {
            let c = play.positions[i]
            let hops = session.spin?.index == i ? session.spin?.hops ?? 0 : 0
            let needed = play.hopsNeeded(i)
            VStack(spacing: 0) {
                Text("\(min(hops, needed))/\(needed)").font(.system(size: 26 * s, weight: .black).italic()).monospacedDigit()
                Text(L("прыжков")).font(.system(size: 10 * s, weight: .heavy))
            }
            .foregroundStyle(Atlas.ink)
            .position(x: CGFloat(c.x), y: CGFloat(c.y))
            .allowsHitTesting(false)
            Text(L("Прыгай взглядом с лепестка на лепесток по кругу."))
                .font(.system(size: 13 * s, weight: .heavy, design: .rounded))
                .foregroundStyle(Atlas.ink)
                .frame(width: 170 * s, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(InkSlab(shape: RoundedRectangle(cornerRadius: 16), fill: Atlas.cream, depth: 4, line: 3))
                .position(x: CGFloat(c.x + play.rules.spinnerRadiusPt * 1.1) + 110 * s, y: CGFloat(c.y) + 60 * s)
                .allowsHitTesting(false)
        }
    }

    private func stampLayer(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(session.stamps) { st in
                ZStack {
                    BurstShape(seed: UInt64(st.id)).fill(Atlas.ink).offset(x: 5, y: 5)
                    BurstShape(seed: UInt64(st.id)).fill(WinkBeatColors.grade(st.grade))
                    BurstShape(seed: UInt64(st.id)).stroke(Atlas.ink, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                    InkedText(text: WinkBeatText.grade(st.grade), size: 20 * s)
                }
                .frame(width: 124 * s, height: 56 * s)
                .rotationEffect(.degrees(st.id % 2 == 0 ? -9 : 7))
                .position(x: CGFloat(st.at.x),
                          y: CGFloat(st.at.y) < 120 * s ? CGFloat(st.at.y) + 62 * s : CGFloat(st.at.y) - 62 * s)
                .transition(reduceMotion ? .opacity
                            : .asymmetric(insertion: .scale(scale: 2.2).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: session.stamps.map(\.id))
        .allowsHitTesting(false)
    }

    private func startPrompt(_ s: CGFloat) -> some View {
        let text = !session.byEye ? L("Коснись круга, чтобы начать.")
            : session.difficulty.blinksPlay ? L("Посмотри на круг и моргни, чтобы начать.")
            : L("Посмотри на круг и подмигни, чтобы начать.")
        return Text(text)
            .font(.system(size: 16 * s, weight: .heavy, design: .rounded))
            .foregroundStyle(Atlas.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(InkSlab(shape: RoundedRectangle(cornerRadius: 16), fill: Atlas.cream, depth: 4, line: 3))
            .position(x: size.width / 2, y: size.height / 2 + 108 * s)
            .allowsHitTesting(false)
    }
}

struct WinkBeatHUD: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: WinkBeatSession
    let size: CGSize

    var body: some View {
        let s = size.height / 390
        let h = session.hud
        ZStack(alignment: .topLeading) {
            // Score and accuracy, top left.
            VStack(alignment: .leading, spacing: 10 * s) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Очки")).font(.system(size: 11 * s, weight: .heavy)).foregroundStyle(Atlas.gold)
                    Text(h.score.formatted()).font(.system(size: 30 * s, weight: .black).italic()).monospacedDigit()
                        .foregroundStyle(Atlas.cream)
                }
                .padding(.leading, 14).padding(.trailing, 20).padding(.vertical, 5)
                .background(Atlas.ink.shadow(.drop(color: Atlas.gold, radius: 0, x: 6, y: 6)))
                .skewed()
                Text(String(format: "%.1f%%", h.accuracy * 100))
                    .font(.system(size: 17 * s, weight: .black).italic()).monospacedDigit()
                    .foregroundStyle(Atlas.ink)
                    .padding(.horizontal, 12).padding(.vertical, 1)
                    .background(InkSlab(shape: Rectangle(), fill: Atlas.cream, depth: 4, line: 3))
                    .skewed()
                    .padding(.leading, 20 * s)
            }
            .padding(.leading, 16 * s).padding(.top, 12 * s)

            // Energy, top middle.
            HStack(spacing: 10) {
                Text(L("Энергия")).font(.system(size: 12 * s, weight: .black).italic()).foregroundStyle(Atlas.cream)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Atlas.ink).skewed()
                HStack(spacing: 3) {
                    ForEach(0..<10, id: \.self) { k in
                        Rectangle().fill(Double(k) < (h.energy * 10).rounded(.up) ? Atlas.energy : Atlas.paperShade)
                    }
                }
                .padding(3)
                .frame(width: 180 * s, height: 22 * s)
                .background(InkSlab(shape: Rectangle(), fill: Atlas.cream, depth: 4, line: 3))
                .skewed(-24)
            }
            .position(x: size.width / 2, y: 28 * s)

            // Track, time and progress, top right.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session.map?.title ?? "").font(.system(size: 16 * s, weight: .black).italic())
                    Spacer()
                    Text(WinkBeatText.difficulty(session.difficulty)).font(.system(size: 10 * s, weight: .heavy))
                        .foregroundStyle(Atlas.cream)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Atlas.sky.overlay(Rectangle().stroke(Atlas.ink, lineWidth: 2)))
                }
                HStack(spacing: 8) {
                    Text(WinkBeatText.clock(h.elapsed))
                    GeometryReader { g in
                        let total = max(1, session.map?.durationSec ?? 1)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Atlas.paperShade)
                            Rectangle().fill(Atlas.sky).frame(width: g.size.width * CGFloat(min(1, h.elapsed / total)))
                        }
                        .overlay(Rectangle().stroke(Atlas.ink, lineWidth: 2))
                    }
                    .frame(height: 8)
                    Text(WinkBeatText.clock(session.map?.durationSec ?? 0))
                }
                .font(.system(size: 11 * s, weight: .heavy)).monospacedDigit()
            }
            .foregroundStyle(Atlas.ink)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
            .frame(width: 214 * s)
            .background(InkSlab(shape: Rectangle(), fill: Atlas.cream, depth: 5, shadow: Atlas.sky, line: 3))
            .skewed()
            .position(x: size.width - 125 * s, y: 36 * s)

            // Combo, bottom left.
            VStack(alignment: .leading, spacing: 4) {
                InkedText(text: "\(h.combo)", size: 72 * s, shadow: 6)
                Text(L("комбо")).font(.system(size: 14 * s, weight: .black).italic()).foregroundStyle(Atlas.ink)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(InkSlab(shape: Rectangle(), fill: Atlas.gold, depth: 0, line: 3))
                    .skewed().rotationEffect(.degrees(-4))
                    .padding(.leading, 12)
            }
            .position(x: 90 * s, y: size.height - 70 * s)

            // What the eyes did, bottom right, and the way out.
            HStack(spacing: 10) {
                Button { session.toSelect() } label: {
                    Image(systemName: "xmark").font(.system(size: 14 * s, weight: .black))
                        .foregroundStyle(Atlas.ink)
                        .frame(width: 34 * s, height: 30 * s)
                        .background(InkSlab(shape: Rectangle(), fill: Atlas.cream, depth: 3, line: 3))
                        .skewed()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Стоп"))
                let e = WinkBeatText.eyes(h.eyes)
                HStack(spacing: 9) {
                    (h.eyes.shut ? EyeGlyph.shut : EyeGlyph.open)
                        .with(color: Atlas.cream)
                        .frame(width: 40 * s, height: 20 * s)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 12 * s, weight: .black).italic())
                        Text(e.detail).font(.system(size: 10 * s, weight: .bold)).foregroundStyle(Atlas.gold)
                    }
                    .foregroundStyle(Atlas.cream)
                }
                .padding(.leading, 10).padding(.trailing, 16).padding(.vertical, 6)
                .background(Atlas.ink.shadow(.drop(color: Atlas.emerald, radius: 0, x: 5, y: 5)))
                .skewed()
            }
            .fixedSize()
            .position(x: size.width - 140 * s, y: size.height - 32 * s)

            if session.silent {
                Text(L("Звук не играет: проверь громкость."))
                    .font(.system(size: 13 * s, weight: .heavy))
                    .foregroundStyle(Atlas.cream)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Atlas.vermilion)
                    .skewed()
                    .position(x: size.width / 2, y: size.height - 24 * s)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

extension EyeGlyph {
    func with(color: Color) -> EyeGlyph { EyeGlyph(parts: parts, color: color) }
}

// MARK: - Results

struct WinkBeatResults: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: WinkBeatSession
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let s = size.height / 390
        ZStack(alignment: .topLeading) {
            backdrop
            if let play = session.play {
                stamp(play, s)
                    .position(x: size.width * 0.2, y: size.height * 0.46)
                numbers(play, s)
                    .frame(width: size.width * 0.45, alignment: .leading)
                    .position(x: size.width * 0.75, y: size.height / 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.15)) { shown = true } }
        }
    }

    private var backdrop: some View {
        Canvas { g, sz in
            g.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(Atlas.cream))
            var slab = Path()
            slab.move(to: .zero)
            slab.addLine(to: CGPoint(x: sz.width * 0.46, y: 0))
            slab.addLine(to: CGPoint(x: sz.width * 0.32, y: sz.height))
            slab.addLine(to: CGPoint(x: 0, y: sz.height))
            slab.closeSubpath()
            g.fill(slab, with: .color(Atlas.emerald))
            var stripe = Path()
            stripe.move(to: CGPoint(x: sz.width * 0.46, y: 0))
            stripe.addLine(to: CGPoint(x: sz.width * 0.50, y: 0))
            stripe.addLine(to: CGPoint(x: sz.width * 0.36, y: sz.height))
            stripe.addLine(to: CGPoint(x: sz.width * 0.32, y: sz.height))
            stripe.closeSubpath()
            g.fill(stripe, with: .color(Atlas.gold))
            g.stroke(stripe, with: .color(Atlas.ink), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func stamp(_ play: WinkBeatPlay, _ s: CGFloat) -> some View {
        let rank = play.failed ? nil : play.rank
        return VStack(spacing: 14 * s) {
            ZStack {
                BurstShape(points: 11, inner: 0.78, seed: 4).fill(Atlas.ink).offset(x: 8, y: 8)
                BurstShape(points: 11, inner: 0.78, seed: 4).fill(Atlas.gold)
                BurstShape(points: 11, inner: 0.78, seed: 4).stroke(Atlas.ink, style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                InkedText(text: rank?.label ?? "—", size: 120 * s, shadow: 7)
            }
            .frame(width: 250 * s, height: 220 * s)
            .rotationEffect(.degrees(shown ? -8 : -26))
            .scaleEffect(shown ? 1 : 2.2)
            .opacity(shown ? 1 : 0)
            HStack(spacing: 4) {
                ForEach(WinkBeatRank.allCases.reversed(), id: \.self) { r in
                    Text(r.label)
                        .font(.system(size: 13 * s, weight: .black).italic())
                        .foregroundStyle(r == rank ? Atlas.cream : Atlas.ink)
                        .frame(width: 30 * s, height: 22 * s)
                        .background(InkSlab(shape: Rectangle(), fill: r == rank ? Atlas.ink : Atlas.cream, depth: 0, line: 2))
                        .skewed()
                }
            }
        }
    }

    private func numbers(_ play: WinkBeatPlay, _ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            HStack(spacing: 8) {
                Text(session.map?.title ?? "").font(.system(size: 20 * s, weight: .black).italic())
                Text(WinkBeatText.difficulty(session.difficulty)).font(.system(size: 11 * s, weight: .heavy))
                    .foregroundStyle(Atlas.cream)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Atlas.sky.overlay(Rectangle().stroke(Atlas.ink, lineWidth: 2)))
                if play.failed {
                    Text(L("Энергия кончилась")).font(.system(size: 11 * s, weight: .heavy)).foregroundStyle(Atlas.cream)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(Atlas.vermilion)
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 18 * s) {
                metric(L("Очки"), play.score.formatted(), big: true, s)
                metric(L("Точность"), String(format: "%.1f%%", play.accuracy * 100), big: false, s)
                metric(L("Макс. комбо"), "\(play.maxCombo)", big: false, s)
            }
            HStack(spacing: 6) {
                ForEach(WinkBeatGrade.allCases, id: \.self) { g in
                    VStack(spacing: 1) {
                        Text("\(play.count(g))").font(.system(size: 18 * s, weight: .black).italic()).monospacedDigit()
                        Text(WinkBeatText.grade(g)).font(.system(size: 9 * s, weight: .heavy))
                    }
                    .foregroundStyle(g == .miss ? Atlas.cream : Atlas.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                    .background(InkSlab(shape: Rectangle(), fill: WinkBeatColors.grade(g), depth: 3, line: 2))
                    .skewed()
                }
            }
            Text(L("Подмигиваний: левым {0}, правым {1}. Морганий: {2}.",
                   play.closuresLeft, play.closuresRight, session.blinksSeen))
                .font(.system(size: 12 * s, weight: .semibold)).foregroundStyle(Atlas.inkSoft)
            HStack(spacing: 10) {
                Button { session.prepare(screen: size) } label: { Text(L("Ещё раз")) }
                    .buttonStyle(AtlasPrimaryButton(fill: Atlas.gold))
                Button { session.toSelect() } label: { Text(L("Сложность")) }
                    .buttonStyle(AtlasSecondaryButton())
                Button { app.leaveWinkBeat() } label: { Text(L("Меню")) }
                    .buttonStyle(AtlasSecondaryButton())
                    .frame(width: 96)
            }
        }
        .foregroundStyle(Atlas.ink)
        .padding(.trailing, 20 * s)
    }

    private func metric(_ title: String, _ value: String, big: Bool, _ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11 * s, weight: .heavy)).foregroundStyle(Atlas.inkSoft)
            Text(value).font(.system(size: (big ? 34 : 22) * s, weight: .black).italic()).monospacedDigit()
                .shadow(color: big ? Atlas.sky : .clear, radius: 0, x: 4, y: 4)
        }
    }
}
