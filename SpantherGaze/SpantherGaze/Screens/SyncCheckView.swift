import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

/// Where the sound goes now; each kind keeps its own sync offset (Bluetooth adds far more delay than the speaker).
enum AudioRoute: String {
    case speaker, wired, bluetooth, other

    static var current: AudioRoute {
        switch AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType {
        case .builtInSpeaker?, .builtInReceiver?: return .speaker
        case .headphones?, .lineOut?, .usbAudio?: return .wired
        case .bluetoothA2DP?, .bluetoothLE?, .bluetoothHFP?: return .bluetooth
        default: return .other
        }
    }

    var name: String {
        switch self {
        case .speaker: return L("Динамик")
        case .wired: return L("Проводные наушники")
        case .bluetooth: return "Bluetooth"
        case .other: return L("Другой выход")
        }
    }
}

/// Wink Beat's sync offsets in ms, one per kind of output, kept on the phone (skill `avaudio-rhythm-sync`, section 3).
enum WinkBeatOffsets {
    private static func key(_ r: AudioRoute) -> String { "winkBeatOffsetMs.\(r.rawValue)" }
    static func ms(for r: AudioRoute) -> Int { UserDefaults.standard.integer(forKey: key(r)) }
    static func set(_ ms: Int, for r: AudioRoute) { UserDefaults.standard.set(ms, forKey: key(r)) }
    static func seconds(for r: AudioRoute) -> Double { Double(ms(for: r)) / 1000 }
}

/// The sync check: clicks from the music player, the player taps on each, `WinkBeatSync` gives the offset.
@MainActor
final class SyncCheckModel: ObservableObject {
    enum Phase: Equatable { case ready, running, done }

    @Published private(set) var phase: Phase = .ready
    /// The offset to save (ms), the measured one nudged by the player.
    @Published private(set) var resultMs = 0
    @Published private(set) var route = AudioRoute.current
    @Published private(set) var savedMs = WinkBeatOffsets.ms(for: .current)
    /// The output changed mid-check: it was stopped and must start again.
    @Published private(set) var routeChanged = false
    @Published private(set) var silent = false

    /// Read every frame by the screen, so not published.
    private(set) var sync = WinkBeatSync()
    private var clock = WinkBeatClock()
    private var startHost = 0.0
    private var hadReading = false
    private var buffer: AVAudioPCMBuffer?
    private var routeObserver: NSObjectProtocol?
    /// The CI bot (`-SpantherAutoplay sync`) taps 35 ms after each click.
    private let bot: Bool
    private var botRng = BotJitter(seed: 5)

    init(bot: Bool) {
        self.bot = bot
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    var result: WinkBeatSync.Result { sync.result }

    func start() {
        sync = WinkBeatSync()
        routeChanged = false
        route = .current
        savedMs = WinkBeatOffsets.ms(for: route)
        let session = AVAudioSession.sharedInstance()
        // Measured with no offset of its own, so the result is the whole offset.
        clock = WinkBeatClock(outputLatency: session.outputLatency, ioBuffer: session.ioBufferDuration)
        hadReading = false
        if buffer == nil { buffer = SoundEngine.shared.musicBuffer(sync.samples(sampleRate: 48_000), sampleRate: 48_000) }
        SoundEngine.shared.hold("music", true)
        startHost = CACurrentMediaTime() + 0.3
        if let buffer { SoundEngine.shared.playMusic(buffer, startHost: startHost) }
        phase = .running
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.phase == .running else { return }
            self.silent = !SoundEngine.shared.isRunning
        }
    }

    /// The heard track time now, nil when not running. Every frame, from the screen's timeline.
    func tick(hostNow: Double) -> Double? {
        guard phase == .running else { return nil }
        var reading = SoundEngine.shared.musicReading()
        if reading != nil { hadReading = true }
        // Before the first render, or with no sound at all, time runs from the planned start.
        if reading == nil, !hadReading { reading = .init(renderedSec: 0, host: startHost) }
        guard let t = clock.heard(reading: reading, hostNow: hostNow) else { return nil }
        if bot, let i = sync.click(atOrBefore: t - 0.035), sync.deltas[i] == nil {
            sync.tap(at: sync.clicks[i] + 0.035 + (botRng.next() - 0.5) * 0.012)
        }
        if t > sync.endSec {
            // Not while the screen is being drawn.
            DispatchQueue.main.async { [weak self] in self?.finish() }
        }
        return t
    }

    /// A touch on the screen at host time `host` (`UITouch.timestamp`, the same clock).
    func tap(host: Double) {
        guard phase == .running, let t = clock.trackTime(host: host) else { return }
        sync.tap(at: t)
    }

    private func finish() {
        guard phase == .running else { return }
        stopSound()
        switch sync.result {
        case let .steady(offset), let .uneven(offset): resultMs = WinkBeatSync.steppedMs(offset)
        case .tooFewTaps: resultMs = savedMs
        }
        phase = .done
        if bot {
            // For the Simulator smoke test's check.
            print("SYNC_RESULT \(resultMs) \(sync.result)")
            fflush(stdout)
        }
    }

    func nudge(_ ms: Int) {
        let lo = Int(WinkBeatSync.range.lowerBound * 1000), hi = Int(WinkBeatSync.range.upperBound * 1000)
        resultMs = min(hi, max(lo, resultMs + ms))
    }

    func save() {
        WinkBeatOffsets.set(resultMs, for: route)
        savedMs = resultMs
    }

    func leave() {
        stopSound()
        phase = .ready
    }

    private func stopSound() {
        SoundEngine.shared.stopMusic()
        SoundEngine.shared.hold("music", false)
    }

    private func outputChanged() {
        let now = AudioRoute.current
        if phase == .running {
            stopSound()
            phase = .ready
            routeChanged = true
        }
        if now != route {
            route = now
            savedMs = WinkBeatOffsets.ms(for: now)
            if phase == .done { phase = .ready }
        }
    }
}

/// A small seeded generator for the bot's jitter (SplitMix64).
struct BotJitter {
    private var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> Double {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// «Синхронизация звука»: tap on every click, and the phone learns how late this output plays sound. In the
/// Persona-style look of the Wink Beat mockups: a slanted ink tag, a beat ring that flashes on the click, the taps on
/// a ruler from early to late, and the result as one big number.
struct SyncCheckView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model: SyncCheckModel

    init(bot: Bool = false) {
        _model = StateObject(wrappedValue: SyncCheckModel(bot: bot))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                backdrop(geo.size)
                TouchCatcher { model.tap(host: $0) }
                HStack(alignment: .center, spacing: 28) {
                    TimelineView(.animation) { _ in
                        let t = model.tick(hostNow: CACurrentMediaTime())
                        Canvas { g, size in draw(&g, size, t) }
                    }
                    .frame(width: min(geo.size.width * 0.38, 360))
                    .allowsHitTesting(false)
                    side
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 70)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                header
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear { if app.autoplay == "sync" { model.start() } }
        .onDisappear { model.leave() }
    }

    // MARK: Parts

    private func backdrop(_ size: CGSize) -> some View {
        Canvas { g, s in
            var slab = Path()
            slab.move(to: .zero)
            slab.addLine(to: CGPoint(x: s.width * 0.52, y: 0))
            slab.addLine(to: CGPoint(x: s.width * 0.40, y: s.height))
            slab.addLine(to: CGPoint(x: 0, y: s.height))
            slab.closeSubpath()
            g.fill(slab, with: .color(Atlas.sky.opacity(0.9)))
            var stripe = Path()
            stripe.move(to: CGPoint(x: s.width * 0.52, y: 0))
            stripe.addLine(to: CGPoint(x: s.width * 0.56, y: 0))
            stripe.addLine(to: CGPoint(x: s.width * 0.44, y: s.height))
            stripe.addLine(to: CGPoint(x: s.width * 0.40, y: s.height))
            stripe.closeSubpath()
            g.fill(stripe, with: .color(Atlas.emerald))
            g.stroke(stripe, with: .color(Atlas.ink), lineWidth: 3)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L("Синхронизация звука"))
                .font(.system(size: 24, weight: .black).italic())
                .foregroundStyle(Atlas.cream)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(InkSlab(shape: Slant(), fill: Atlas.ink, depth: 5, shadow: Atlas.gold))
            Text(model.route.name)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Atlas.cream)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(InkSlab(shape: Slant(), fill: Atlas.sky, depth: 2))
            Spacer()
            Button {
                model.leave()
                app.route = .menu
            } label: { Text(L("Назад")) }
                .buttonStyle(AtlasSecondaryButton())
                .frame(width: 120)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }

    @ViewBuilder private var side: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .ready, .running:
                bubble(L("Касайся экрана на каждый щелчок. Первые два не считаются."))
                if model.routeChanged { note(L("Выход звука поменялся. Начни заново.")) }
                if model.silent { note(L("Звук не играет: проверь громкость.")) }
                if model.phase == .ready {
                    Button { model.start() } label: { Text(L("Начать")) }
                        .buttonStyle(AtlasPrimaryButton(fill: Atlas.gold))
                        .frame(maxWidth: 260)
                }
                saved
            case .done:
                outcome
            }
        }
    }

    private var outcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("{0} мс", signed(model.resultMs)))
                .font(.system(size: 76, weight: .black).italic())
                .monospacedDigit()
                .foregroundStyle(Atlas.ink)
                .shadow(color: Atlas.sky, radius: 0, x: 5, y: 5)
                .accessibilityLabel(L("{0} мс", signed(model.resultMs)))
            switch model.result {
            case .steady: note(L("Ровно: можно сохранять."))
            case .uneven: note(L("Касания разбросаны. Лучше пройти ещё раз."))
            case .tooFewTaps: note(L("Мало касаний. Пройди ещё раз."))
            }
            HStack(spacing: 10) {
                Button { model.nudge(-5) } label: { Text(L("{0} мс", "−5")) }
                    .buttonStyle(AtlasSecondaryButton()).frame(width: 96)
                Button { model.nudge(5) } label: { Text(L("{0} мс", "+5")) }
                    .buttonStyle(AtlasSecondaryButton()).frame(width: 96)
            }
            HStack(spacing: 12) {
                Button { model.save() } label: { Text(L("Сохранить")).lineLimit(1) }
                    .buttonStyle(AtlasPrimaryButton(fill: Atlas.gold))
                    .disabled(model.result == .tooFewTaps || model.resultMs == model.savedMs)
                Button { model.start() } label: { Text(L("Ещё раз")) }
                    .buttonStyle(AtlasSecondaryButton())
                    .frame(width: 130)
            }
            saved
        }
    }

    private var saved: some View {
        Text(L("Сохранено: {0}", L("{0} мс", signed(model.savedMs))))
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Atlas.inkSoft)
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(Atlas.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Atlas.cream))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Atlas.ink, lineWidth: 3))
            .background(RoundedRectangle(cornerRadius: 14).fill(Atlas.ink).offset(x: 4, y: 4))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Atlas.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func signed(_ ms: Int) -> String { ms > 0 ? "+\(ms)" : ms < 0 ? "−\(-ms)" : "0" }

    // MARK: The beat ring and the ruler

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ t: Double?) {
        let s = model.sync
        let r = min(size.width * 0.3, size.height * 0.3)
        let c = CGPoint(x: size.width / 2, y: size.height * 0.40)
        // The flash: full on the click, gone a quarter second later.
        var flash = 0.0
        if let t, let i = s.click(atOrBefore: t) { flash = max(0, 1 - (t - s.clicks[i]) / 0.25) }
        let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        g.fill(ring.offsetBy(dx: 6, dy: 6), with: .color(Atlas.ink))
        g.fill(ring, with: .color(flash > 0 ? Atlas.gold.opacity(0.35 + 0.65 * flash) : Atlas.cream))
        g.stroke(ring, with: .color(Atlas.ink), lineWidth: 4)
        let grow = r * (1 + 0.18 * flash)
        if flash > 0 {
            let burst = Path(ellipseIn: CGRect(x: c.x - grow, y: c.y - grow, width: 2 * grow, height: 2 * grow))
            g.stroke(burst, with: .color(Atlas.gold.opacity(flash)), lineWidth: 6)
        }
        let count = t.flatMap { s.click(atOrBefore: $0) }.map { $0 + 1 } ?? (model.phase == .done ? s.clicks.count : 0)
        g.draw(Text("\(count)/\(s.clicks.count)").font(.system(size: r * 0.42, weight: .black).italic())
                .monospacedDigit().foregroundStyle(Atlas.ink), at: c)

        // The ruler: 150 ms early to 150 ms late, one tick per tap.
        let y = c.y + r + 46, half = size.width * 0.45, span = 0.15
        var line = Path()
        line.move(to: CGPoint(x: c.x - half, y: y))
        line.addLine(to: CGPoint(x: c.x + half, y: y))
        g.stroke(line, with: .color(Atlas.ink), lineWidth: 3)
        var zero = Path()
        zero.move(to: CGPoint(x: c.x, y: y - 14))
        zero.addLine(to: CGPoint(x: c.x, y: y + 14))
        g.stroke(zero, with: .color(Atlas.ink), lineWidth: 3)
        for (i, d) in s.deltas {
            let x = c.x + CGFloat(max(-span, min(span, d)) / span) * half
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: y - 10))
            tick.addLine(to: CGPoint(x: x, y: y + 10))
            g.stroke(tick, with: .color(i < s.warmUp ? Atlas.missGrey : Atlas.emerald), lineWidth: 4)
        }
        g.draw(Text(L("Раньше")).font(.system(size: 12, weight: .bold)).foregroundStyle(Atlas.inkSoft),
               at: CGPoint(x: c.x - half, y: y + 22), anchor: .leading)
        g.draw(Text(L("Позже")).font(.system(size: 12, weight: .bold)).foregroundStyle(Atlas.inkSoft),
               at: CGPoint(x: c.x + half, y: y + 22), anchor: .trailing)
    }
}

/// Reports each new touch's timestamp (the host clock `CACurrentMediaTime` uses), which SwiftUI's tap does not give.
private struct TouchCatcher: UIViewRepresentable {
    let onTouch: (Double) -> Void

    func makeUIView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        v.onTouch = onTouch
        return v
    }

    func updateUIView(_ v: CatcherView, context: Context) { v.onTouch = onTouch }

    final class CatcherView: UIView {
        var onTouch: ((Double) -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { onTouch?(t.timestamp) }
        }
    }
}
