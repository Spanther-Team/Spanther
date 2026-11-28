import SwiftUI

/// The arcades' screen. The 3D toon stage fills it; over the stage: the level choice, a 3-2-1, the play's HUD
/// (time, score, the combo or the catch, rising stamps, the hold's ring round the looked-at fish), the pause plate
/// and the results. In finger play the finger aims, and lifting it is the blink of «Кроты».
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
                    hudForGame
                    if !session.paused { ArcadeCountdown(session: session) }
                case .playing:
                    hudForGame
                case .done:
                    if let o = session.outcome { ArcadeResults(session: session, outcome: o) }
                }
                if session.paused { ArcadePausePlate(session: session) }
            }
            .onAppear { session.layout(screen: Vec2(Double(geo.size.width), Double(geo.size.height))) }
            .onChange(of: geo.size) { _, s in session.layout(screen: Vec2(Double(s.width), Double(s.height))) }
        }
        .ignoresSafeArea()
        .onDisappear { session.leave() }
    }

    /// Stamps and the hold's ring, at their screen points (the stage's own space).
    private var marks: some View {
        ZStack {
            ForEach(session.stamps) { s in
                ArcadeStampView(stamp: s, still: reduceMotion)
            }
            if let r = session.hud.reel, let at = session.hud.reelSpot, !session.paused {
                // A glowing ring that fills as the eyes hold the fish (his reference picture, 2026-11-28).
                let d = CGFloat(max(56, session.hud.reelRadius * 2))
                ZStack {
                    Circle().stroke(Color.white.opacity(0.35), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.02, r)))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: Color(red: 0.55, green: 0.9, blue: 1), radius: 6)
                }
                .frame(width: d, height: d)
                .position(x: at.x, y: at.y)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var hudForGame: some View {
        if session.game == .fishing { fishingHud } else { hud }
    }

    /// «Рыбалка»'s top row, after his reference picture: the catch on the left (fish and «3 / 10»), the clock in the
    /// middle, a round pause button on the right, all on dark-blue glass over the water.
    private var fishingHud: some View {
        VStack {
            ZStack {
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: "fish.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Atlas.energy)
                        Text("\(session.hud.landed) / \(session.hud.goal)")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .background(Capsule().fill(Self.glass))
                    .scaleEffect(catchPulse ? 1.18 : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Поймано: {0} из {1}", session.hud.landed, session.hud.goal))
                    Spacer()
                    Button { session.setPaused(true) } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(Self.glass))
                    }
                    .accessibilityLabel(L("Пауза"))
                }
                HStack(spacing: 10) {
                    Image(systemName: "stopwatch")
                        .font(.system(size: 20, weight: .bold))
                    Text(Self.clock(session.hud.secondsLeft, padMinutes: true))
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(session.hud.secondsLeft <= 10 ? Color(red: 1, green: 0.55, blue: 0.5) : .white)
                .padding(.horizontal, 18)
                .frame(height: 46)
                .background(Capsule().fill(Self.glass))
            }
            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.top, 12)
        .onChange(of: session.hud.landed) { old, new in
            guard new > old, !reduceMotion else { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) { catchPulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { catchPulse = false }
            }
        }
    }

    @State private var catchPulse = false
    static let glass = Color(red: 0.09, green: 0.2, blue: 0.38).opacity(0.78)

    /// The top bar: leave, the game and level, the clock, the combo or the catch, the score.
    private var hud: some View {
        VStack {
            HStack(alignment: .top, spacing: 10) {
                Button { session.setPaused(true) } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Atlas.ink)
                        .frame(width: 40, height: 36)
                        .background(InkSlab(shape: Slant(lean: 6), fill: Atlas.paper, depth: 3))
                }
                .accessibilityLabel(L("Пауза"))
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

    static func clock(_ s: Int, padMinutes: Bool = false) -> String {
        String(format: padMinutes ? "%02d:%02d" : "%d:%02d", max(0, s) / 60, max(0, s) % 60)
    }
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
            ? L("Смотри на нору и моргни, когда из неё вылезет крот. Кролика и ёжика не трогай!")
            : L("Смотри на рыбу и держи взгляд, пока круг не замкнётся: рыба поймана.")
        if !session.byEye {
            s += " " + (session.game == .moles ? L("Пальцем: держи палец на цели и отпусти его вместо моргания.")
                                               : L("Пальцем: держи палец на рыбе."))
        }
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
            Text(session.game == .moles ? L("Моргни, когда крот вылезет") : L("Держи взгляд на рыбе"))
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

/// The pause: the round's clock stands still until «Продолжить».
private struct ArcadePausePlate: View {
    @ObservedObject var session: ArcadeSession

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(L("Пауза")).font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                Button { session.setPaused(false) } label: { Text(L("Продолжить")) }.buttonStyle(AtlasPrimaryButton())
                Button { session.toLevels() } label: { Text(L("Уровни")) }.buttonStyle(AtlasSecondaryButton())
            }
            .frame(maxWidth: 300)
            .atlasPlate(padding: 22, accent: Atlas.sky)
            .kineticEntrance()
        }
    }
}
