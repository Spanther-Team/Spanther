import SwiftUI

/// A play's victory (sunlit redesign, part 4), between the play and its report: fireworks, the rank stamp (S, A or B)
/// slamming down, the Steppe Observatory's landmarks the stars have opened, and the panther cub with its gifts.
/// It comes after every meteor, rhythm and warm-up play; the probe has its own end screen.
struct VictoryView: View {
    let summary: SessionSummary
    let award: VictoryAward
    let onContinue: () -> Void
    @StateObject private var fx = StreakFX()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SunlitBackdrop().ignoresSafeArea()
            GeometryReader { geo in
                CelebrationLayer(fx: fx)
                    .onAppear {
                        let w = geo.size.width, h = geo.size.height
                        // The first one goes off as the stamp lands.
                        fx.finale(at: [CGPoint(x: w * 0.2, y: h * 0.22), CGPoint(x: w * 0.82, y: h * 0.18),
                                       CGPoint(x: w * 0.55, y: h * 0.1)],
                                  after: 0.5, tier: award.rank == .s ? 3 : 2)
                    }
            }
            .ignoresSafeArea()
            HStack(alignment: .center, spacing: 24) {
                rankPlate
                    .frame(width: 236)
                    .kineticEntrance(order: 0)
                observatory
                    .kineticEntrance(order: 1)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
        }
        .environment(\.colorScheme, .light)
    }

    private var rankPlate: some View {
        VStack(spacing: 8) {
            Text("Итог · \(Self.gameName(summary.game))")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(Atlas.ink)
            RankStamp(rank: award.rank, reduceMotion: reduceMotion)
                .frame(width: 132, height: 132)
                .padding(.vertical, 4)
            HStack(alignment: .top, spacing: 18) {
                if let share = award.share {
                    VStack(spacing: 0) {
                        RollUp(value: share * 100, font: Atlas.display(24)) { String(format: "%.0f%%", $0) }
                        Text(Self.shareLabel(summary.game)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                    }
                }
                if award.bestStreak >= 2 {
                    VStack(spacing: 0) {
                        Text(summary.game == .pursuit ? "\(award.bestStreak * 2) с" : "×\(award.bestStreak)")
                            .font(Atlas.display(24).monospacedDigit())
                            .foregroundStyle(Atlas.ink)
                        Text(summary.game == .pursuit ? "на точке подряд" : "лучшая серия")
                            .font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: i < award.rank.stars ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(i < award.rank.stars ? Atlas.energy : Atlas.inkSoft.opacity(0.4))
                }
                Text("+\(award.rank.stars)")
                    .font(Atlas.metric(15))
                    .foregroundStyle(Atlas.ink)
                    .padding(.leading, 4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Плюс \(award.rank.stars) звезды обсерватории")
        }
        .frame(maxWidth: .infinity)
        .atlasPlate(padding: 14, accent: Self.rankColour(award.rank))
    }

    private var observatory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Обсерватория").font(Atlas.display(22)).foregroundStyle(Atlas.ink)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(Atlas.energy)
                    RollUp(value: Double(award.after.stars), font: Atlas.metric(17)) { String(Int($0.rounded())) }
                        .foregroundStyle(Atlas.ink)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Звёзд: \(award.after.stars)")
            }
            LandmarkRow(open: award.after.landmarks, new: award.newLandmarks, reduceMotion: reduceMotion)
            Text(landmarkLine)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Atlas.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            HStack(alignment: .center, spacing: 12) {
                PantherCub(gifts: award.after.gifts, reduceMotion: reduceMotion)
                    .frame(width: 92, height: 92)
                Text(cubLine)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Atlas.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(InkSlab(shape: CutPlate(cut: 10), fill: Atlas.paper, depth: 3))
                Spacer(minLength: 0)
            }
            HStack {
                Spacer(minLength: 0)
                Button(action: onContinue) { Text("Дальше") }
                    .buttonStyle(AtlasPrimaryButton())
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var landmarkLine: String {
        if let i = award.newLandmarks.last { return "Открыто: «\(Landmark.all[i].name)»" }
        guard let cost = award.after.nextLandmarkCost else { return "Вся обсерватория открыта!" }
        let next = Landmark.all[min(award.after.landmarks, Landmark.all.count - 1)].name
        return "До «\(next)» ещё \(cost - award.after.stars) ★"
    }

    private var cubLine: String {
        if let g = award.newGifts.last { return "Мне подарок: \(PantherCub.giftNames[g])! Спасибо!" }
        switch award.rank {
        case .s: return "Ррр! Вот это взгляд пантеры!"
        case .a: return "Здорово! До ранга S совсем чуть-чуть."
        case .b: return "Хорошее начало! Сыграем ещё?"
        }
    }

    static func gameName(_ g: SessionSummary.Game) -> String {
        switch g {
        case .meteors: return "Метеориты"
        case .rhythm: return "Ритм"
        case .pursuit: return "Разминка"
        }
    }

    static func shareLabel(_ g: SessionSummary.Game) -> String {
        switch g {
        case .meteors: return "сбито"
        case .rhythm: return "точность"
        case .pursuit: return "рядом с точкой"
        }
    }

    static func rankColour(_ r: VictoryRank) -> Color {
        switch r {
        case .s: return Atlas.energy
        case .a: return Atlas.gold
        case .b: return Atlas.sky
        }
    }
}

/// The rank as a stamp: a toothed seal in the rank's colour with an ink rim and a dashed inner ring, the letter in
/// heavy type. It drops from above, big and turned, and lands with a spring; with Reduce Motion it fades in.
private struct RankStamp: View {
    let rank: VictoryRank
    let reduceMotion: Bool
    @State private var landed = false

    var body: some View {
        ZStack {
            Rosette().fill(Atlas.ink).offset(x: 5, y: 5)
            Rosette().fill(VictoryView.rankColour(rank))
            Rosette().stroke(Atlas.ink, lineWidth: 3)
            Circle()
                .inset(by: 20)
                .stroke(Atlas.ink.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            Text(rank.rawValue)
                .font(.system(size: 76, weight: .black, design: .rounded))
                .foregroundStyle(Atlas.ink)
                .shadow(color: Atlas.paper.opacity(0.9), radius: 0, x: -2, y: -2)
        }
        .rotationEffect(.degrees(landed ? -10 : -32))
        .scaleEffect(landed ? 1 : 2.3)
        .opacity(landed ? 1 : 0)
        .onAppear {
            if reduceMotion {
                withAnimation(Animation.easeOut(duration: 0.25)) { landed = true }
            } else {
                withAnimation(Animation.spring(response: 0.32, dampingFraction: 0.55).delay(0.3)) { landed = true }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ранг \(rank.rawValue)")
    }
}

/// A round seal with `teeth` points on its rim.
private struct Rosette: Shape {
    var teeth = 18
    var depth: CGFloat = 0.08

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        let n = teeth * 2
        for i in 0..<n {
            let a: Double = Double(i) / Double(n) * 2 * Double.pi - Double.pi / 2
            let rr: CGFloat = i % 2 == 0 ? r : r * (1 - depth)
            let pt = CGPoint(x: c.x + rr * CGFloat(cos(a)), y: c.y + rr * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// One of the Steppe Observatory's landmarks.
struct Landmark {
    let name: String
    let symbol: String

    static let all: [Landmark] = [
        Landmark(name: "Каменный круг", symbol: "circle.dotted"),
        Landmark(name: "Солнечные часы", symbol: "sun.max.fill"),
        Landmark(name: "Юрта звездочёта", symbol: "tent.fill"),
        Landmark(name: "Астролябия", symbol: "safari"),
        Landmark(name: "Башня ветров", symbol: "wind"),
        Landmark(name: "Лунное зеркало", symbol: "moon.stars.fill"),
        Landmark(name: "Купол", symbol: "building.columns.fill"),
        Landmark(name: "Большой телескоп", symbol: "scope"),
    ]
}

/// The landmarks as a row of cut plates: open ones in gold and pale sky, the ones this play opened in amber with
/// a pop, closed ones pale with a lock.
private struct LandmarkRow: View {
    let open: Int
    let new: Range<Int>
    let reduceMotion: Bool
    @State private var popped = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Landmark.all.indices, id: \.self) { i in
                let isOpen = i < open
                let isNew = new.contains(i)
                Image(systemName: isOpen ? Landmark.all[i].symbol : "lock.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isOpen ? Atlas.ink : Atlas.inkSoft.opacity(0.45))
                    .frame(maxWidth: 46, maxHeight: 46)
                    .aspectRatio(1, contentMode: .fit)
                    .background(InkSlab(shape: CutPlate(cut: 8),
                                        fill: isNew ? Atlas.energy : isOpen ? (i % 2 == 0 ? Atlas.gold : Atlas.skyPale)
                                                                            : Atlas.paperShade,
                                        depth: isOpen ? 3 : 1))
                    .selectedPop(isNew && popped)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(isOpen ? Landmark.all[i].name : "Закрыто")
            }
        }
        .onAppear {
            guard !new.isEmpty, !reduceMotion else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { popped = true }
        }
    }
}

/// The panther cub, drawn simply in cel style: a black cub with amber eyes and slit pupils (the logo's panther
/// eye). It bobs and blinks, and wears its gifts: a scarf, a star on it, an explorer's cap, a spyglass.
struct PantherCub: View {
    let gifts: Int
    let reduceMotion: Bool

    static let giftNames = ["шарф", "звезда на шарф", "шапка исследователя", "подзорная труба"]

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { g, size in Self.draw(&g, size, t: 0, gifts: gifts) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    Canvas { g, size in Self.draw(&g, size, t: t, gifts: gifts) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Пантерёнок")
    }

    private static let fur = Color(red: 0.169, green: 0.149, blue: 0.133)      // 2B2622
    private static let furLit = Color(red: 0.290, green: 0.259, blue: 0.231)   // 4A423B
    private static let muzzle = Color(red: 0.361, green: 0.333, blue: 0.298)   // 5C554C
    private static let nose = Color(red: 0.541, green: 0.353, blue: 0.290)     // 8A5A4A

    static func draw(_ g: inout GraphicsContext, _ size: CGSize, t: Double, gifts: Int) {
        let u = min(size.width, size.height) / 100
        let bobWave: Double = sin(t * 3.2)
        let bob = CGFloat(bobWave) * 1.6 * u
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * u, y: y * u + bob, width: w * u, height: h * u)
        }
        func ink(_ p: Path, _ fill: Color, _ line: CGFloat = 2) {
            g.fill(p, with: .color(fill))
            g.stroke(p, with: .color(Atlas.ink), lineWidth: line)
        }
        // Shoulders, ears, head.
        ink(Path(ellipseIn: r(18, 78, 64, 34)), fur)
        for x in [14.0, 62.0] as [CGFloat] {
            ink(Path(ellipseIn: r(x, 14, 24, 24)), fur)
            g.fill(Path(ellipseIn: r(x + 6, 20, 12, 12)), with: .color(muzzle))
        }
        let head = Path(ellipseIn: r(16, 22, 68, 60))
        ink(head, fur)
        // The cel light: a paler crescent on the upper left of the head.
        var lit = g
        lit.clip(to: head)
        lit.fill(Path(ellipseIn: r(14, 18, 44, 34)), with: .color(furLit))
        lit.fill(Path(ellipseIn: r(22, 28, 44, 34)), with: .color(fur))
        // Eyes: amber, slit pupils, a glint; a blink every few seconds.
        let blinkPhase = t.truncatingRemainder(dividingBy: 3.7)
        let blinking = blinkPhase < 0.14
        for x in [30.0, 56.0] as [CGFloat] {
            if blinking {
                var lid = Path()
                lid.move(to: CGPoint(x: x * u, y: 49 * u + bob))
                lid.addQuadCurve(to: CGPoint(x: (x + 14) * u, y: 49 * u + bob),
                                 control: CGPoint(x: (x + 7) * u, y: 53 * u + bob))
                g.stroke(lid, with: .color(Atlas.energy), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            } else {
                ink(Path(ellipseIn: r(x, 42, 14, 13)), Atlas.energy, 1.5)
                g.fill(Path(ellipseIn: r(x + 5.3, 43, 3.4, 11)), with: .color(Atlas.ink))
                g.fill(Path(ellipseIn: r(x + 8.5, 44, 3, 3)), with: .color(Atlas.paper))
            }
        }
        // Muzzle, nose, mouth, whiskers.
        ink(Path(ellipseIn: r(35, 58, 30, 20)), muzzle, 1.5)
        var n = Path()
        n.move(to: CGPoint(x: 46 * u, y: 60 * u + bob))
        n.addLine(to: CGPoint(x: 54 * u, y: 60 * u + bob))
        n.addLine(to: CGPoint(x: 50 * u, y: 65 * u + bob))
        n.closeSubpath()
        ink(n, nose, 1.2)
        var mouth = Path()
        mouth.move(to: CGPoint(x: 50 * u, y: 65 * u + bob))
        mouth.addQuadCurve(to: CGPoint(x: 44 * u, y: 70 * u + bob), control: CGPoint(x: 48 * u, y: 71 * u + bob))
        mouth.move(to: CGPoint(x: 50 * u, y: 65 * u + bob))
        mouth.addQuadCurve(to: CGPoint(x: 56 * u, y: 70 * u + bob), control: CGPoint(x: 52 * u, y: 71 * u + bob))
        g.stroke(mouth, with: .color(Atlas.paper.opacity(0.85)), lineWidth: 1.3)
        var whiskers = Path()
        for (dy, out) in [(-2.0, 18.0), (2.0, 19.0)] as [(CGFloat, CGFloat)] {
            whiskers.move(to: CGPoint(x: 38 * u, y: (66 + dy) * u + bob))
            whiskers.addLine(to: CGPoint(x: (38 - out) * u, y: (64 + dy * 2.5) * u + bob))
            whiskers.move(to: CGPoint(x: 62 * u, y: (66 + dy) * u + bob))
            whiskers.addLine(to: CGPoint(x: (62 + out) * u, y: (64 + dy * 2.5) * u + bob))
        }
        g.stroke(whiskers, with: .color(Atlas.paper.opacity(0.7)), lineWidth: 1)
        // Gifts.
        if gifts >= 1 {
            ink(Path(roundedRect: r(24, 78, 52, 9), cornerRadius: 4 * u), Atlas.emerald)
            ink(Path(roundedRect: r(60, 84, 9, 15), cornerRadius: 2 * u), Atlas.emerald)
        }
        if gifts >= 2 {
            ink(Fireworks.star(CGPoint(x: 38 * u, y: 82.5 * u + bob), 6 * u, turn: -Double.pi / 2), Atlas.gold, 1.2)
        }
        if gifts >= 3 {
            var cap = Path()
            cap.addArc(center: CGPoint(x: 50 * u, y: 28 * u + bob), radius: 20 * u,
                       startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            cap.closeSubpath()
            ink(cap, Atlas.sky)
            ink(Path(roundedRect: r(26, 26, 48, 6), cornerRadius: 3 * u), Atlas.sky)
            g.fill(Path(ellipseIn: r(47, 5, 6, 6)), with: .color(Atlas.gold))
        }
        if gifts >= 4 {
            var tube = Path(roundedRect: CGRect(x: -4 * u, y: -4.5 * u, width: 30 * u, height: 9 * u), cornerRadius: 2 * u)
            tube = tube.applying(CGAffineTransform(rotationAngle: -0.75)
                .concatenating(CGAffineTransform(translationX: 4 * u, y: 96 * u + bob)))
            ink(tube, Atlas.gold, 1.5)
        }
    }
}

/// The observatory of each child, kept on the phone (UserDefaults), next to the child's plays.
enum ObservatoryStore {
    private static let prefix = "observatory."

    private static func key(_ child: String) -> String {
        prefix + child.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func load(child: String) -> Observatory {
        guard let d = UserDefaults.standard.data(forKey: key(child)),
              let o = try? JSONDecoder().decode(Observatory.self, from: d) else { return Observatory() }
        return o
    }

    static func save(_ o: Observatory, child: String) {
        guard let d = try? JSONEncoder().encode(o) else { return }
        UserDefaults.standard.set(d, forKey: key(child))
    }

    /// Forgets one child's observatory, or every child's when `child` is empty (with the plays).
    static func reset(child: String) {
        let c = child.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = UserDefaults.standard
        if c.isEmpty {
            for k in d.dictionaryRepresentation().keys where k.hasPrefix(prefix) { d.removeObject(forKey: k) }
        } else {
            d.removeObject(forKey: key(c))
        }
    }
}
