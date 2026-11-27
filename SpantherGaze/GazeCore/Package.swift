// swift-tools-version:5.9
// GazeCore is plain Swift (no UIKit, no ARKit) so it builds and tests on any platform.
// The app target compiles these same sources directly; this package exists for `swift test`.
import PackageDescription

let package = Package(
    name: "GazeCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GazeCore", targets: ["GazeCore"]),
        .library(name: "Feel", targets: ["Feel"]),
    ],
    targets: [
        .target(name: "GazeCore"),
        .testTarget(name: "GazeCoreTests", dependencies: ["GazeCore"]),
        // `swift run GazeReplay <session.csv>`: replays an exported session through the current GazeCore code.
        // Not part of the app, which compiles only Sources/GazeCore.
        .executableTarget(name: "GazeReplay", dependencies: ["GazeCore"]),
        // The sign-in and sync against a real Supabase Auth and PostgREST in Docker: backend/test/e2e.sh.
        .executableTarget(name: "BackendCheck", dependencies: ["GazeCore"]),
        // Feel: the math of the burst (geometry, fracture, cracks, motion, sound synthesis, shader sources).
        // Plain Swift like GazeCore, and it does not import GazeCore; the app compiles both into one module.
        .target(name: "Feel"),
        .testTarget(name: "FeelTests", dependencies: ["Feel"]),
    ]
)
