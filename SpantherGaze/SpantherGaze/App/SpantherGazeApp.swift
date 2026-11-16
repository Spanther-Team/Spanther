import SwiftUI

@main
struct SpantherGazeApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var updateGate = UpdateGate()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                // While the App Store has a newer version, the app opens only the update screen.
                if let version = updateGate.requiredVersion {
                    UpdateRequiredView(version: version)
                } else {
                    RootView()
                        .environmentObject(app)
                        .environmentObject(app.status)
                        .onAppear {
                            app.startTracking()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                }
            }
            .environmentObject(updateGate)
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
            if phase == .active { updateGate.check() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            background
            switch app.route {
            case .menu: MenuView()
            case .calibration: CalibrationView(kind: .calibration)
            case .check: CalibrationView(kind: .check)
            case .result: ResultView()
            case .game: GameView()
            case .winkTest: WinkTestView()
            case .rhythm: RhythmView()
            case .pursuit: PursuitView()
            case .clinic: ClinicView()
            case .probe: ProbeView()
            }
            if app.showDebug { DebugOverlay().allowsHitTesting(false) }
        }
        // Ink on paper everywhere but the wink test, which keeps the old dark look.
        .preferredColorScheme(app.route == .winkTest ? .dark : .light)
    }

    /// Paper with the living garden behind the menu and the calibration result; plain paper where the eyes must not
    /// wander (calibration, check) or where the screen draws its own garden (rhythm, and the meteors, whose SpriteKit
    /// scene bakes it in: one renderer for the screen).
    @ViewBuilder private var background: some View {
        switch app.route {
        case .winkTest:
            Palette.space.ignoresSafeArea()
        case .calibration, .check, .rhythm, .pursuit, .game, .probe:
            Atlas.paper.ignoresSafeArea()
        case .menu, .result, .clinic:
            ZStack {
                Atlas.paper
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
