import SwiftUI

@main
struct SpantherGazeApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var updateGate = UpdateGate()
    @StateObject private var startGate = StartGate()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                // While the App Store has a newer version, the app opens only the update screen.
                if let version = updateGate.requiredVersion {
                    UpdateRequiredView(version: version)
                } else if !startGate.passed {
                    // Privacy and the camera first, at every launch. Face tracking starts only behind it, so the
                    // system's camera question comes from the start screen's button and nowhere else.
                    StartGateView()
                } else {
                    RootView()
                        .environmentObject(app)
                        .environmentObject(app.status)
                        .onAppear {
                            app.startTracking()
                            UIApplication.shared.isIdleTimerDisabled = true
                            // The session's one calibration, before the menu.
                            app.openSession()
                        }
                }
            }
            .environmentObject(updateGate)
            .environmentObject(startGate)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onAppear { updateGate.check() }
            .onChange(of: updateGate.requiredVersion) { version in
                // Locked mid-play: the camera and the music stop behind the update screen.
                guard version != nil else { return }
                app.scenePhaseChanged(active: false)
                app.tracker.stop()
            }
        }
        .onChange(of: scenePhase) { phase in
            app.scenePhaseChanged(active: phase == .active && updateGate.requiredVersion == nil)
            if phase == .active {
                updateGate.check()
                // Back from Settings with the camera allowed: the start screen goes on by itself.
                startGate.refresh()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    /// Its language is the whole app's (`Loc`).
    @EnvironmentObject var startGate: StartGate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background
            Group {
                switch app.route {
                case .menu: MenuView()
                case .plan: PlanView()
                case .calibration: CalibrationView(kind: .calibration)
                case .check: CalibrationView(kind: .check)
                case .result: ResultView()
                case .game: GameView()
                case .winkTest: WinkTestView()
                case .rhythm: RhythmView()
                case .pursuit: PursuitView()
                case .clinic: ClinicView()
                case .probe: ProbeView()
                case .syncCheck: SyncCheckView(bot: app.autoplay == "sync")
                case .winkBeat:
                    if let w = app.winkBeat { WinkBeatView(session: w) }
                case .arcade:
                    if let a = app.arcade { ArcadeView(session: a) }
                }
            }
            .transition(screenTransition)
            // A new language builds the screens again, so that every text is asked for in it (the garden behind
            // them keeps growing).
            .id(startGate.language)
            .environment(\.locale, Loc.locale)
            if app.restReminder { RestReminderCard().transition(.opacity) }
            if app.showDebug { DebugOverlay().allowsHitTesting(false) }
        }
        // A new menu screen springs in from the right; the old one fades under it. Never into the probe: its 90
        // seconds start with the screen and must start on a still page.
        .animation(app.route == .probe ? nil : Atlas.snap, value: app.route)
        // Ink on paper everywhere but the wink test, which keeps the old dark look.
        .preferredColorScheme(app.route == .winkTest ? .dark : .light)
    }

    /// The menu, the result and the clinic spring in. The play screens fill the whole display and size their play
    /// when they appear, and a screen that slides or scales in is laid out in the safe area until it lands (on the
    /// phone the meteors kept 734 x 372 of 852 x 393 pt), so they only fade in, at their full size.
    private var screenTransition: AnyTransition {
        if reduceMotion { return .opacity }
        switch app.route {
        case .menu, .plan, .result, .clinic:
            return .asymmetric(insertion: .offset(x: 90).combined(with: .scale(scale: 0.97)).combined(with: .opacity),
                               removal: .opacity)
        default:
            return .opacity
        }
    }

    /// The sunlit sky with the living garden behind the menu, the clinic and the calibration result; a plain cream
    /// page where the eyes must not wander (calibration, check) or where the screen draws its own world (rhythm,
    /// warm-up, and the meteors, whose SpriteKit scene bakes it in: one renderer for the screen). The probe keeps its
    /// own frozen paper.
    @ViewBuilder private var background: some View {
        switch app.route {
        case .winkTest:
            Palette.space.ignoresSafeArea()
        case .probe:
            ProbeLook.paper.ignoresSafeArea()
        case .calibration, .check, .rhythm, .pursuit, .game, .syncCheck, .winkBeat, .arcade:
            Atlas.paper.ignoresSafeArea()
        case .menu, .plan, .result, .clinic:
            ZStack {
                SunlitBackdrop()
                LivingBackground(growFrom: app.launchTime)
            }
            .ignoresSafeArea()
        }
    }
}

/// The old dark palette, still used by the wink test and the debug overlay.
enum Palette {
    static let space = Color(red: 0.027, green: 0.043, blue: 0.11)
    static let panel = Color(red: 0.067, green: 0.10, blue: 0.23)
    static let gaze = Color(red: 0.44, green: 0.94, blue: 0.88)
    static let fire = Color(red: 1.0, green: 0.70, blue: 0.28)
    static let dim = Color(red: 0.60, green: 0.64, blue: 0.78)
    static let hot = Color(red: 1.0, green: 0.35, blue: 0.21)
}
