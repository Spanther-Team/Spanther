import SpriteKit
import SwiftUI

struct GameView: View {
    @EnvironmentObject var app: AppModel
    @State private var scene: GameScene?
    @State private var paused = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let scene {
                    // Opaque: the scene draws the paper and the garden itself (one renderer for the screen).
                    SpriteView(scene: scene, options: [.ignoresSiblingOrder])
                    HUDView(hud: scene.hud, paused: $paused, musicOn: $app.musicOn, onQuit: { app.route = .menu },
                            onRecalibrate: { app.beginCalibration(then: .game) },
                            canRecalibrate: app.mode == .eyes, touchMode: app.mode == .touch, decoysOn: scene.decoysOn,
                            onEnergyTap: { [weak scene] in scene?.reloadTap() })
                    // The combo counter under the score, past the jar; the banner below the top row.
                    if !paused { CelebrationLayer(fx: scene.hud.fx, comboTop: 66, comboLeading: 104, calloutTop: 84) }
                }
            }
            .onAppear { if scene == nil { scene = makeScene(size: geo.size) } }
            .onChange(of: paused) { p in
                scene?.paused_ = p
                // Hidden behind the pause plate, the scene stops drawing and updating altogether.
                scene?.isPaused = p
                // The music fades out on the pause plate and comes back with the play.
                app.gamePaused = p
            }
            .onChange(of: app.showDebug) { d in scene?.showAim = d }
        }
        .ignoresSafeArea()
    }

    private func makeScene(size: CGSize) -> GameScene {
        let s = GameScene(size: size)
        s.scaleMode = .resizeFill
        s.config = app.balance
        s.marginPt = app.hitMarginPt
        s.useTouch = app.mode == .touch
        s.showAim = app.showDebug
        // «Мелкие цели» and «Красные знаки», as they are set when the play starts.
        s.targetScale = app.targetScale
        s.zoneFloorPt = app.zoneFloorPt
        s.decoysOn = app.decoysOn
        let model = app
        #if DEBUG
        s.autoplay = app.autoplay != nil
        if app.autoplay == "eyes" {
            // The Simulator run by eye ends by itself, so that it also shows the summary and saves the play.
            s.botQuitAfter = 120
            s.botQuit = { [weak model] in model?.route = .menu }
        }
        #endif
        s.gazeSource = { [weak model] in model?.gaze ?? .lost }
        s.gazeHeld = { [weak model] in model?.gazeHeld ?? false }
        s.onRecord = { [weak model] r in model?.log(r) }
        s.onDecoy = { [weak model] r, p in model?.log(r, at: p) }
        s.blinkReload = { [weak model] in model?.consumeBlinkReload() ?? false }
        s.pendingBlinks = { [weak model] in model?.pendingBlinks ?? 0 }
        s.onGameEvent = { [weak model] kind, energy, level in model?.logGameEvent(kind: kind, energy: energy, level: level) }
        s.onLookedAt = { [weak model] p in model?.lookedAtMeteor = p }
        app.playFX = s.hud.fx
        return s
    }
}

private struct HUDView: View {
    @ObservedObject var hud: GameHUD
    @Binding var paused: Bool
    @Binding var musicOn: Bool
    let onQuit: () -> Void
    let onRecalibrate: () -> Void
    let canRecalibrate: Bool
    let touchMode: Bool
    /// The play has red signs: the top row counts the looks at them.
    let decoysOn: Bool
    let onEnergyTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    pill { Text("\(hud.score)").font(Atlas.display(20)).rolling(hud.score) }
                    pill {
                        HStack(spacing: 4) {
                            ForEach(0..<5, id: \.self) { i in
                                Circle().fill(i < hud.shields ? Atlas.sky : .clear)
                                    .overlay(Circle().stroke(Atlas.ink, lineWidth: 1.5))
                                    .frame(width: 10, height: 10)
                            }
                        }
                        .accessibilityLabel("Щиты: \(hud.shields) из 5")
                    }
                    pill { Text("Уровень \(hud.level)").font(.system(size: 15, weight: .heavy, design: .rounded)).rolling(hud.level) }
                    if decoysOn {
                        // The count of looks at red signs: the sign itself and a number, no word and no alarm.
                        pill {
                            HStack(spacing: 6) {
                                RedSign().frame(width: 14, height: 14)
                                Text("\(hud.decoyErrors)").font(.system(size: 15, weight: .heavy, design: .rounded))
                                    .rolling(hud.decoyErrors)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(touchMode ? "Касаний красных знаков: \(hud.decoyErrors)"
                                                      : "Взглядов на красные знаки: \(hud.decoyErrors)")
                    }
                    // Landscape: one row, so the meteors keep the height. The energy bar sits in it.
                    if hud.energyMax > 0 {
                        EnergyBar(energy: hud.energy, max: hud.energyMax, reloadProgress: hud.reloadProgress,
                                  needsReload: hud.needsReload, pulse: hud.reloadCount, touchMode: touchMode, onTap: onEnergyTap)
                            .frame(maxWidth: 300)
                    }
                    Spacer(minLength: 0)
                    Button { musicOn.toggle() } label: {
                        pill {
                            Image(systemName: musicOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 22)
                        }
                    }
                    .accessibilityLabel(musicOn ? "Выключить музыку" : "Включить музыку")
                    Button { paused = true } label: {
                        pill { Image(systemName: "pause.fill").font(.system(size: 15, weight: .semibold)) }
                    }
                    .accessibilityLabel("Пауза")
                }
                // The front camera's notch is on the left.
                .padding(.leading, 56)
                .padding(.trailing, 20)
                .padding(.top, 10)
                // The quiet line of the red signs: it fades in and out, nothing flashes.
                if let line = hud.notice, !paused {
                    Text(line)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Atlas.ink)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .atlasChip(border: Atlas.vermilion)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                Spacer()
                if hud.needsReload && !paused && !hud.lookBack {
                    ReloadHint(touchMode: touchMode, progress: hud.reloadProgress, needed: hud.reloadNeeded)
                        .padding(.bottom, 80)
                }
            }
            .animation(.easeInOut(duration: 0.45), value: hud.notice)
            // The level's banner slams in on the slant from the left and leaves to the right.
            if let b = hud.banner {
                Text(b).font(Atlas.display(26)).foregroundStyle(Atlas.ink)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(InkSlab(shape: Slant(lean: 16), fill: Atlas.gold, depth: 5))
                    .rotationEffect(.degrees(-3))
                    .transition(reduceMotion ? AnyTransition.opacity
                                : .asymmetric(insertion: .offset(x: -420).combined(with: .opacity),
                                              removal: .offset(x: 420).combined(with: .opacity)))
                    .allowsHitTesting(false)
            }
            if hud.lookBack && !paused {
                Text("Посмотри на экран").font(Atlas.display(26)).foregroundStyle(Atlas.ink)
                    .atlasPlate(padding: 16, accent: Atlas.sky)
            }
            if paused {
                VStack(spacing: 12) {
                    Text("Пауза").font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                    if hud.decoys > 0 {
                        Text(touchMode ? "Касаний красных знаков: \(hud.decoyErrors) из \(hud.decoys)"
                                       : "Взглядов на красные знаки: \(hud.decoyErrors) из \(hud.decoys)")
                            .font(Atlas.caption)
                            .foregroundStyle(Atlas.inkSoft)
                    }
                    Button { paused = false } label: { Text("Продолжить") }.buttonStyle(AtlasPrimaryButton())
                    if canRecalibrate {
                        Button(action: onRecalibrate) { Text("Калибровка") }.buttonStyle(AtlasSecondaryButton())
                    }
                    Button(action: onQuit) { Text("Главное меню") }.buttonStyle(AtlasSecondaryButton())
                }
                .frame(maxWidth: 320)
                .atlasPlate(padding: 22, accent: Atlas.sky)
                .padding(16)
                .kineticEntrance()
            }
        }
        .animation(reduceMotion ? nil : Atlas.snap, value: hud.banner)
    }

    private func pill<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().font(.system(size: 15, weight: .bold, design: .rounded))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(minHeight: 36)
            .atlasChip()
            .foregroundStyle(Atlas.ink)
    }
}

/// The red sign as the HUD and the report draw it: a vermilion disc with a bar of paper across, like the one that
/// flies in the game (SignNode).
struct RedSign: View {
    var body: some View {
        Canvas { g, size in
            let d = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            g.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(Atlas.vermilion))
            let w = d * 0.58, h = d * 0.16
            g.fill(Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), cornerRadius: h * 0.25),
                   with: .color(Atlas.paper))
        }
        .accessibilityHidden(true)
    }
}

/// Energy pool as segments. In touch mode the whole bar is the reload button (3 taps).
private struct EnergyBar: View {
    let energy: Int
    let max: Int
    let reloadProgress: Int
    let needsReload: Bool
    let pulse: Int
    let touchMode: Bool
    let onTap: () -> Void
    @State private var glow = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(energy > 0 ? Atlas.ink : Atlas.vermilion)
            HStack(spacing: 3) {
                ForEach(0..<max, id: \.self) { i in
                    Slant(lean: 3)
                        .fill(i < energy ? Atlas.energy : Atlas.ink.opacity(0.1))
                        .overlay(Slant(lean: 3).strokeBorder(Atlas.ink, lineWidth: 1.5))
                        .frame(height: 12)
                }
            }
            Text("\(energy)").font(.system(size: 15, weight: .heavy, design: .rounded)).rolling(energy)
                .foregroundStyle(Atlas.ink)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .atlasChip(fill: glow ? Atlas.gold : Atlas.paper, border: needsReload ? Atlas.vermilion : Atlas.ink)
        .scaleEffect(glow ? 1.06 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if touchMode { onTap() } }
        .accessibilityLabel("Энергия \(energy) из \(max)")
        .onChange(of: pulse) { _ in
            withAnimation(.easeOut(duration: 0.15)) { glow = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(.easeIn(duration: 0.3)) { glow = false } }
        }
    }
}

/// "Blink 3 times" with one icon per blink (or tap) that fills as they are counted.
private struct ReloadHint: View {
    let touchMode: Bool
    let progress: Int
    let needed: Int

    /// 2, 3, 4, 22... раза; 5...20, 25... раз.
    private var times: String {
        let n = needed % 100
        return (2...4).contains(n % 10) && !(12...14).contains(n) ? "\(needed) раза" : "\(needed) раз"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(touchMode ? "Нажми на энергию \(times)" : "Моргни \(times)")
                .font(Atlas.title)
                .foregroundStyle(Atlas.ink)
            HStack(spacing: 10) {
                ForEach(0..<needed, id: \.self) { i in
                    Image(systemName: touchMode ? "hand.tap.fill" : (i < progress ? "eye.slash.fill" : "eye"))
                        .foregroundStyle(i < progress ? Atlas.vermilion : Atlas.ink.opacity(0.5))
                }
            }
            .font(.title2)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .atlasPlate(padding: 0, accent: Atlas.energy)
        .allowsHitTesting(false)
    }
}
