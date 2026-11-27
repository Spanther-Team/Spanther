import SwiftUI

/// The blink arcades' screen. The 3D toon stage fills it; over the stage: the level choice, a 3-2-1, the play's HUD
/// (time, score, the combo or the catch, rising stamps, the mark over a biting fish, the reel ring round a hooked
/// one) and the results. In finger play the finger aims and lifting it is the blink.
struct ArcadeView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: ArcadeSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ToonStageView(source: session)
                if !session.byEye, session.phase == .playing {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { session.touch(at: Vec2(Double($0.location.x), Double($0.location.y))) }
                            .onEnded { session.release(at: Vec2(Double($0.location.x), Double($0.location.y))) })
                }
                marks
                switch session.phase {
                case .levels:
                    ArcadeLevels(session: session)
                case .countdown:
                    hud
                    ArcadeCountdown(session: session)
                case .playing:
                    hud
                case .done:
                    if let o = session.outcome { ArcadeResults(session: session, outcome: o) }
                }
            }
            .onAppear { session.layout(screen: Vec2(Double(geo.size.width), Double(geo.size.height))) }
            .onChange(of: geo.size) { _, s in session.layout(screen: Vec2(Double(s.width), Double(s.height))) }
        }
        .ignoresSafeArea()
        .onDisappear { session.leave() }
    }

    /// Stamps, the bite mark and the reel ring, at their screen points (the stage's own space).
    private var marks: some View {
        ZStack {
            ForEach(session.stamps) { s in
                ArcadeStampView(stamp: s, still: reduceMotion)
            }
            if let b = session.hud.biteSpot {
                BiteMark()
                    .position(x: b.x, y: b.y - 46)
                    .allowsHitTesting(false)
            }
            if let r = session.hud.reel, let at = session.hud.reelSpot {
                ZStack {
                    Circle().stroke(Atlas.ink.opacity(0.35), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.02, r)))
                        .stroke(Atlas.gold, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 78, height: 78)
                .position(x: at.x, y: at.y)
                .allowsHitTesting(false)
            }
        }
    }

    /// The top bar: leave, the game and level, the clock, the combo or the catch, the score.
    private var hud: some View {
        VStack {
            HStack(alignment: .top, spacing: 10) {
                Button { session.toLevels() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Atlas.ink)
                        .frame(width: 40, height: 36)
                        .background(InkSlab(shape: Slant(lean: 6), fill: Atlas.paper, depth: 3))
                }
                .accessibilityLabel(L("К уровням"))
                Text(L("{0} · уровень {1}", session.game.title, session.level))
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Atlas.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(InkSlab(shape: Slant(lean: 8), fill: Atlas.paper, depth: 3))
                Spacer()
                Text(Self.clock(session.hud.secondsLeft))
                    .font(Atlas.metric(22, weight: .heavy))
                    .foregroundStyle(session.hud.secondsLeft <= 10 ? Atlas.vermilion : Atlas.ink)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(InkSlab(shape: Slant(lean: 10), fill: Atlas.paper, depth: 3))
                Spacer()
                if session.game == .moles {
                    if session.hud.combo >= 2 {
                        Text(L("серия ×{0}", session.hud.combo))
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(Atlas.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(InkSlab(shape: Slant(lean: 8), fill: Atlas.energy, depth: 3))
                            .transition(.scale.combined(with: .opacity))
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "fish.fill").font(.system(size: 15, weight: .bold))
                        Text("\(session.hud.landed)/\(session.hud.goal)").font(Atlas.metric(17, weight: .heavy))
                    }
                    .foregroundStyle(Atlas.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(InkSlab(shape: Slant(lean: 8), fill: Atlas.sky, depth: 3))
                    .accessibilityLabel(L("Поймано: {0} из {1}", session.hud.landed, session.hud.goal))
                }
                Text("\(session.hud.score)")
                    .font(Atlas.metric(22, weight: .heavy))
                    .foregroundStyle(Atlas.ink)
                    .padding(.horizontal, 16)
                    .frame(minWidth: 84)
                    .frame(height: 40)
                    .background(InkSlab(shape: Slant(lean: 10), fill: Atlas.gold, depth: 3))
                    .accessibilityLabel(L("Очки: {0}", session.hud.score))
            }
            .animation(Atlas.snap, value: session.hud.combo >= 2)
            Spacer()
        }
        .padding(.horizontal, 56)
        .padding(.top, 12)
    }

    static func clock(_ s: Int) -> String { String(format: "%d:%02d", max(0, s) / 60, max(0, s) % 60) }
}

/// A word or a number rising from where it happened.
private struct ArcadeStampView: View {
    let stamp: ArcadeStamp
    let still: Bool
    @State private var up = false

    var body: some View {
        Text(stamp.text)
            .font(.system(size: stamp.tone == .quiet ? 18 : 24, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .shadow(color: Atlas.ink, radius: 0, x: 2, y: 2)
            .padding(4)
            .offset(y: up && !still ? -46 : 0)
            .opacity(up ? 0 : 1)
            .position(x: stamp.spot.x, y: stamp.spot.y - 34)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 1.0)) { up = true }
            }
    }

    private var color: Color {
        switch stamp.tone {
        case .good: return Atlas.cream
        case .gold: return Atlas.gold
        case .bad: return Atlas.vermilion
        case .quiet: return Atlas.paperShade
        }
    }
}

/// «!» over a biting fish: blink now.
private struct BiteMark: View {
    @State private var big = false

    var body: some View {
        Text("!")
            .font(.system(size: 26, weight: .black, design: .rounded))
            .foregroundStyle(Atlas.ink)
            .frame(width: 38, height: 38)
            .background(InkSlab(shape: Circle(), fill: Atlas.gold, depth: 2))
            .scaleEffect(big ? 1.15 : 0.9)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true)) { big = true }
            }
            .accessibilityLabel(L("Клюёт! Моргни"))
    }
}

/// The level choice over the living scene: how to play, ten levels with their stars, the way back.
private struct ArcadeLevels: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: ArcadeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.game.title)
                .font(Atlas.display(30))
                .foregroundStyle(Atlas.ink)
            Text(hint)
                .font(Atlas.caption)
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 10), count: 5), spacing: 10) {
                ForEach(1...ArcadeGame.levels, id: \.self) { n in tile(n) }
            }
            .padding(.vertical, 4)
            Button { app.leaveArcade() } label: { Text(L("Меню")) }
                .buttonStyle(AtlasSecondaryButton())
                .frame(width: 180)
        }
        .frame(width: 420)
        .atlasPlate(padding: 18, accent: session.game == .moles ? Atlas.emerald : Atlas.sky)
        .kineticEntrance()
    }

    private var hint: String {
        var s = session.game == .moles
            ? L("Смотри на нору и моргни, когда из неё вылезет крот. Ёжиков не трогай!")
            : L("Смотри на рыбу и держи взгляд, пока она не клюнет. Тогда моргни и веди её взглядом к мосткам.")
        if !session.byEye { s += " " + L("Пальцем: держи палец на цели и отпусти его вместо моргания.") }
        return s
    }

    private func tile(_ n: Int) -> some View {
        let open = ArcadeProgress.open(session.game, level: n, stars: session.stars)
        let got = n - 1 < session.stars.count ? session.stars[n - 1] : 0
        return Button { session.choose(level: n) } label: {
            VStack(spacing: 2) {
                if open {
                    Text("\(n)").font(Atlas.metric(20, weight: .heavy))
                    HStack(spacing: 1) {
                        ForEach(0..<3, id: \.self) { i in
                            Image(systemName: i < got ? "star.fill" : "star")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(i < got ? Atlas.gold : Atlas.inkSoft)
                        }
                    }
                } else {
                    Image(systemName: "lock.fill").font(.system(size: 17, weight: .bold))
                }
            }
            .foregroundStyle(Atlas.ink.opacity(open ? 1 : 0.45))
            .frame(width: 70, height: 56)
            .background(InkSlab(shape: CutPlate(cut: 10), fill: open ? (n == session.level ? Atlas.gold : Atlas.paper) : Atlas.paperShade,
                                depth: open ? 3 : 1))
        }
        .buttonStyle(.plain)
        .disabled(!open)
        .accessibilityLabel(open ? L("Уровень {0}, звёзд: {1}", n, got) : L("Уровень {0} закрыт", n))
    }
}

/// 3, 2, 1 and what to do.
private struct ArcadeCountdown: View {
    @ObservedObject var session: ArcadeSession

    var body: some View {
        VStack(spacing: 14) {
            Text("\(max(1, session.countdown))")
                .font(Atlas.display(64))
                .foregroundStyle(Atlas.ink)
                .frame(width: 112, height: 112)
                .background(InkSlab(shape: Circle(), fill: Atlas.gold, depth: 5))
                .id(session.countdown)
                .transition(.scale.combined(with: .opacity))
            Text(session.game == .moles ? L("Моргни, когда крот вылезет") : L("Смотри на рыбу, пока не клюнет"))
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(Atlas.ink)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(InkSlab(shape: Slant(lean: 10), fill: Atlas.paper, depth: 3))
        }
        .animation(Atlas.snap, value: session.countdown)
    }
}

/// The round's stars, score and details, and what next.
private struct ArcadeResults: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: ArcadeSession
    let outcome: ArcadeOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("{0} · уровень {1}", outcome.game.title, outcome.level))
                    .font(Atlas.title)
                    .foregroundStyle(Atlas.ink)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: i < outcome.stars ? "star.fill" : "star")
                            .font(.system(size: 26, weight: .black))
                            .foregroundStyle(i < outcome.stars ? Atlas.gold : Atlas.inkSoft)
                    }
                }
                .accessibilityLabel(L("Звёзд: {0}", outcome.stars))
            }
            Text(L("Очки: {0}", outcome.score))
                .font(Atlas.metric(28, weight: .heavy))
                .foregroundStyle(Atlas.ink)
            ForEach(outcome.lines, id: \.self) { line in
                Text(line).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
            }
            if outcome.stars == 0 {
                Text(L("Одна звезда открывает следующий уровень."))
                    .font(Atlas.caption.weight(.semibold))
                    .foregroundStyle(Atlas.ink)
            }
            HStack(spacing: 12) {
                Button { session.again() } label: { Text(L("Ещё раз")) }
                    .buttonStyle(AtlasPrimaryButton())
                if outcome.nextOpen {
                    Button { session.next() } label: { Text(L("Дальше")) }
                        .buttonStyle(AtlasPrimaryButton(fill: Atlas.gold))
                }
                Button { session.toLevels() } label: { Text(L("Уровни")) }
                    .buttonStyle(AtlasSecondaryButton())
            }
            .padding(.top, 4)
        }
        .frame(width: 440)
        .atlasPlate(padding: 18, accent: Atlas.gold)
        .kineticEntrance()
    }
}
