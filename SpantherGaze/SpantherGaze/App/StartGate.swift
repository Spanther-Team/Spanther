import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

/// The start screen's languages. The rest of the app is in Russian.
enum GateLanguage: String, CaseIterable, Identifiable {
    case ru, kk, en

    var id: String { rawValue }

    /// The language's name in itself, for the switch.
    var name: String {
        switch self {
        case .ru: return "Русский"
        case .kk: return "Қазақша"
        case .en: return "English"
        }
    }

    /// The first of the iPhone's languages that is one of the three; Russian otherwise.
    static var device: GateLanguage {
        for id in Locale.preferredLanguages {
            if let l = GateLanguage(rawValue: String(id.prefix(2))) { return l }
        }
        return .ru
    }
}

/// The camera as the start screen sees it.
enum CameraAccess: Equatable {
    /// This iPhone cannot track a face (no TrueDepth camera, or the Simulator): finger play only, no camera.
    case unsupported
    case notDetermined, authorized, denied
    /// Screen Time or a device profile forbids the camera.
    case restricted

    static var current: CameraAccess {
        guard FaceTracker.isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }
}

/// The screen before the menu, at every launch: what the app does with the camera, and the camera permission.
/// The games are played by eye, so on an iPhone that tracks faces the menu stays locked until the camera is
/// allowed. Face tracking (and with it the camera) starts only once this has passed (`SpantherGazeApp`).
///
/// Debug builds pass it by themselves for the CI bots and the report screenshots. `-SpantherGate ask|denied|
/// restricted|allowed|unsupported` holds it in that state for the CI screenshots, `-SpantherGate pass` skips it, and
/// `-SpantherGateLanguage ru|kk|en` picks the language.
@MainActor
final class StartGate: ObservableObject {
    @Published private(set) var passed = false
    @Published private(set) var camera: CameraAccess
    /// Kept between launches.
    @Published var language: GateLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }

    /// The screen showed the camera as refused. Kept between launches: iOS ends an app whose camera access is changed
    /// in Settings, so a permission given there arrives with the next launch, which then goes on by itself.
    private var waitingForCamera: Bool {
        get { UserDefaults.standard.bool(forKey: Self.waitingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.waitingKey) }
    }
    /// The state was set by a launch argument (Debug): the screen stays as it is.
    private var frozen = false
    private static let languageKey = "StartGate.language"
    private static let waitingKey = "StartGate.waitingForCamera"

    init() {
        language = UserDefaults.standard.string(forKey: Self.languageKey).flatMap { GateLanguage(rawValue: $0) } ?? .device
        camera = CameraAccess.current
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let l = value("-SpantherGateLanguage").flatMap({ GateLanguage(rawValue: $0) }) { language = l }
        if value("-SpantherAutoplay") != nil || value("-SpantherDemoReport") != nil { passed = true }
        if let forced = value("-SpantherGate") {
            frozen = true
            switch forced {
            case "pass": passed = true
            case "ask": camera = .notDetermined
            case "denied": camera = .denied
            case "restricted": camera = .restricted
            case "allowed": camera = .authorized
            default: camera = .unsupported
            }
            return
        }
        #endif
        settle()
    }

    /// Looks at the camera again: the app came back to the front, maybe from Settings.
    func refresh() {
        guard !passed, !frozen else { return }
        camera = CameraAccess.current
        settle()
    }

    /// The main button: on, with the camera allowed (or not needed); the system's question when it was never asked;
    /// Settings while it is refused.
    func proceed() {
        switch camera {
        case .unsupported, .authorized:
            pass()
        case .notDetermined:
            guard !frozen else { return }
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                camera = granted ? .authorized : CameraAccess.current
                if granted { pass() } else { settle() }
            }
        case .denied, .restricted:
            openSettings()
        }
    }

    func openSettings() {
        waitingForCamera = true
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    /// Goes on by itself when the camera was allowed while the screen waited for it; remembers the wait while the
    /// camera is refused.
    private func settle() {
        switch camera {
        case .authorized where waitingForCamera: pass()
        case .denied, .restricted: waitingForCamera = true
        default: break
        }
    }

    private func pass() {
        waitingForCamera = false
        passed = true
    }
}

/// The start screen's words. Statements are plain; the player is addressed informally, as everywhere in the app.
/// What it says about data is what the app does: nothing is sent anywhere by the app, camera frames are never
/// written down, and the results it keeps on the phone leave it only through the Share button.
struct GateCopy {
    let title: String
    let privacyTitle: String
    let privacy: String
    let policy: String
    let cameraTitle: String
    let camera: String
    let unsupported: String
    let askNote: String
    let allowedNote: String
    let proceed: String
    let denied: String
    let restricted: String
    let openSettings: String

    static func of(_ l: GateLanguage) -> GateCopy {
        switch l {
        case .ru: return ru
        case .kk: return kk
        case .en: return en
        }
    }

    static let ru = GateCopy(
        title: "Перед началом",
        privacyTitle: "Конфиденциальность",
        privacy: "SPANTHER не собирает и никуда не передаёт личные данные. Видео с камеры не записывается и не сохраняется: лицо и взгляд обрабатываются только на этом телефоне, в реальном времени. Результаты игр хранятся здесь же, и сама игра никуда их не отправляет: поделиться ими можно только кнопкой «Поделиться».",
        policy: "Политика конфиденциальности",
        cameraTitle: "Камера",
        camera: "В SPANTHER играют движением глаз, поэтому нужна фронтальная камера. Без доступа к ней играть нельзя.",
        unsupported: "Этот iPhone не умеет отслеживать лицо, поэтому здесь можно играть только пальцем. Камера не используется.",
        askNote: "После «Продолжить» iPhone спросит разрешение на камеру.",
        allowedNote: "Камера разрешена.",
        proceed: "Продолжить",
        denied: "Доступ к камере выключен, поэтому дальше пройти нельзя. Открой настройки, включи «Камера» для SPANTHER, и игра продолжится сама.",
        restricted: "Камера ограничена на этом iPhone (Экранное время или профиль устройства). Попроси взрослого разрешить её для SPANTHER в настройках.",
        openSettings: "Открыть настройки")

    static let kk = GateCopy(
        title: "Бастамас бұрын",
        privacyTitle: "Құпиялылық",
        privacy: "SPANTHER жеке деректерді жинамайды және ешқайда жібермейді. Камера бейнесі жазылмайды және сақталмайды: бет пен көзқарас тек осы телефонда, нақты уақытта өңделеді. Ойын нәтижелері де осы телефонда сақталады, ойынның өзі оларды ешқайда жібермейді: оларды тек «Бөлісу» батырмасымен бөлісуге болады.",
        policy: "Құпиялылық саясаты",
        cameraTitle: "Камера",
        camera: "SPANTHER көз қозғалысымен ойналады, сондықтан алдыңғы камера керек. Оған рұқсат болмаса, ойнауға болмайды.",
        unsupported: "Бұл iPhone бетті бақылай алмайды, сондықтан мұнда тек саусақпен ойнауға болады. Камера қолданылмайды.",
        askNote: "«Жалғастыру» басылғанда iPhone камераға рұқсат сұрайды.",
        allowedNote: "Камераға рұқсат берілген.",
        proceed: "Жалғастыру",
        denied: "Камераға рұқсат өшірулі, сондықтан әрі қарай өту мүмкін емес. Баптауларды ашып, SPANTHER үшін «Камера» қосқышын қос, сонда ойын өзі жалғасады.",
        restricted: "Бұл iPhone-да камера шектелген (Экран уақыты немесе құрылғы профилі). Үлкендерден баптауларда SPANTHER үшін камераға рұқсат беруін сұра.",
        openSettings: "Баптауларды ашу")

    static let en = GateCopy(
        title: "Before you start",
        privacyTitle: "Privacy",
        privacy: "SPANTHER does not collect or send personal data anywhere. Camera video is never recorded or saved: your face and gaze are processed only on this phone, in real time. Game results are kept on this phone too, and the game never sends them anywhere by itself: they leave it only with the Share button.",
        policy: "Privacy Policy",
        cameraTitle: "Camera",
        camera: "SPANTHER is played with eye movements, so it needs the front camera. Without camera access you can't play.",
        unsupported: "This iPhone can't track a face, so here you can only play with a finger. The camera is not used.",
        askNote: "After Continue, your iPhone will ask for camera access.",
        allowedNote: "Camera access is on.",
        proceed: "Continue",
        denied: "Camera access is off, so you can't go further. Open Settings, turn on Camera for SPANTHER, and the game will continue by itself.",
        restricted: "The camera is restricted on this iPhone (Screen Time or a device profile). Ask an adult to allow it for SPANTHER in Settings.",
        openSettings: "Open Settings")
}

/// The start screen in the sunlit Steppe Observatory: the sky and the far grass, a brass astrolabe behind, cream
/// plates on gold and sky slabs, one emerald button; the plates and the button spring in one after another. The mark, the title and the language switch on top; what the app does with the
/// camera and why it needs it on two plates; under them the camera's state and the button. While the camera is
/// refused, the warning stays and the button leads to Settings: there is no way on to the menu.
struct StartGateView: View {
    @EnvironmentObject var gate: StartGate
    @State private var shownAt = CACurrentMediaTime()

    private var t: GateCopy { GateCopy.of(gate.language) }
    private var refused: Bool { gate.camera == .denied || gate.camera == .restricted }

    var body: some View {
        ZStack {
            SunlitBackdrop().ignoresSafeArea()
            Astrolabe()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            // The smallest screens (iPhone SE, 4.7") may not fit the longest language: there it scrolls.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                plate(symbol: "lock.shield", title: t.privacyTitle, text: t.privacy, accent: Atlas.gold) {
                    Link(t.policy, destination: MenuView.privacyPolicyURL)
                        .font(Atlas.caption.weight(.semibold))
                        .foregroundStyle(Atlas.ink)
                        .frame(minHeight: 32)
                }
                .kineticEntrance(order: 1)
                plate(symbol: "eye", title: t.cameraTitle, text: gate.camera == .unsupported ? t.unsupported : t.camera,
                      accent: Atlas.sky) {
                    EmptyView()
                }
                .kineticEntrance(order: 2)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 16) {
                status
                Spacer(minLength: 0)
                Button { gate.proceed() } label: {
                    Text(refused ? t.openSettings : t.proceed)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(AtlasPrimaryButton())
                .frame(width: 260)
                .kineticEntrance(order: 3)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(since: shownAt)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("SPANTHER")
                    .font(Atlas.wordmark(12))
                    .tracking(4)
                    .foregroundStyle(Atlas.inkSoft)
                Text(t.title)
                    .font(Atlas.display(26))
                    .foregroundStyle(Atlas.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            languageSwitch
        }
    }

    private var languageSwitch: some View {
        HStack(spacing: 8) {
            ForEach(GateLanguage.allCases) { l in
                let on = l == gate.language
                Button { gate.language = l } label: {
                    Text(l.name)
                        .font(.system(size: 15, weight: on ? .heavy : .semibold, design: .rounded))
                        .foregroundStyle(Atlas.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .atlasChip(fill: on ? Atlas.gold : Atlas.paper)
                }
                .selectedPop(on)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// One plate: the symbol on a disc of the plate's colour, the title, the words, and what goes under them.
    private func plate<Extra: View>(symbol: String, title: String, text: String, accent: Color,
                                    @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Atlas.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(accent))
                    .overlay(Circle().stroke(Atlas.ink, lineWidth: Atlas.line))
                    .accessibilityHidden(true)
                Text(title)
                    .font(Atlas.title)
                    .foregroundStyle(Atlas.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Atlas.ink)
                .fixedSize(horizontal: false, vertical: true)
            extra()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .atlasPlate(padding: 12, accent: accent)
    }

    /// The camera's state beside the button. Refused: the warning, in vermilion, as long as it lasts.
    @ViewBuilder private var status: some View {
        switch gate.camera {
        case .denied:
            warning(t.denied)
        case .restricted:
            warning(t.restricted)
        case .notDetermined:
            note(t.askNote, symbol: "camera")
        case .authorized:
            note(t.allowedNote, symbol: "checkmark.circle")
        case .unsupported:
            EmptyView()
        }
    }

    private func warning(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityHidden(true)
            Text(s)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Atlas.vermilion)
        .padding(10)
        .background(InkSlab(shape: CutPlate(cut: 10), fill: Atlas.paper, depth: 3))
        .accessibilityElement(children: .combine)
    }

    private func note(_ s: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(s).fixedSize(horizontal: false, vertical: true)
        }
        .font(Atlas.caption)
        .foregroundStyle(Atlas.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(InkSlab(shape: CutPlate(cut: 8), fill: Atlas.paper, depth: 3))
    }
}

/// The start screen's backdrop: a brass astrolabe of the Steppe Observatory, half off the lower right corner,
/// drawn once and faint enough to read over. Ink limb and ticks, an amber inlay ring, the rete's ecliptic circle
/// with a few amber stars, and the alidade across the face.
private struct Astrolabe: View {
    var body: some View {
        Canvas { g, size in
            let r = min(size.width, size.height) * 0.62
            let c = CGPoint(x: size.width - r * 0.42, y: size.height - r * 0.3)
            func circle(_ at: CGPoint, _ rr: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: at.x - rr, y: at.y - rr, width: 2 * rr, height: 2 * rr))
            }
            g.stroke(circle(c, r), with: .color(Atlas.ink.opacity(0.1)), lineWidth: 1.5)
            g.stroke(circle(c, r * 0.93), with: .color(Atlas.ink.opacity(0.08)), lineWidth: 1)
            // The limb: a tick every 5 degrees, a longer one every 30.
            var ticks = Path()
            for k in 0..<72 {
                let a = Double(k) * .pi / 36
                ticks.move(to: Atlas.polar(c, k % 6 == 0 ? r * 0.86 : r * 0.9, a))
                ticks.addLine(to: Atlas.polar(c, r * 0.93, a))
            }
            g.stroke(ticks, with: .color(Atlas.ink.opacity(0.1)), lineWidth: 1)
            g.stroke(circle(c, r * 0.8), with: .color(Atlas.amber.opacity(0.45)), lineWidth: 2)
            g.stroke(circle(c, r * 0.62), with: .color(Atlas.ink.opacity(0.07)), lineWidth: 1)
            // The rete: the ecliptic off the centre, and its stars.
            let e = CGPoint(x: c.x - r * 0.12, y: c.y - r * 0.1)
            g.stroke(circle(e, r * 0.5), with: .color(Atlas.amber.opacity(0.28)), lineWidth: 1.2)
            for (k, a) in [-2.2, -1.5, -0.9, 2.6].enumerated() {
                g.fill(Atlas.star(Atlas.polar(e, r * (0.32 + 0.05 * CGFloat(k)), a), 4),
                       with: .color(Atlas.amber.opacity(0.6)))
            }
            // The alidade, and the pin it turns on.
            var bar = Path()
            bar.move(to: Atlas.polar(c, r * 0.93, -2.6))
            bar.addLine(to: Atlas.polar(c, r * 0.93, -2.6 + .pi))
            g.stroke(bar, with: .color(Atlas.ink.opacity(0.12)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            g.fill(circle(c, 5), with: .color(Atlas.ink.opacity(0.18)))
        }
    }
}
