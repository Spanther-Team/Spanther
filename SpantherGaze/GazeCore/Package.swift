// swift-tools-version:5.9
// GazeCore and Feel are plain Swift (no UIKit, no ARKit) so they build and test on any platform.
// The app target compiles these same sources directly; this package exists for `swift test`.
import PackageDescription

let package = Package(
    name: "GazeCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "GazeCore", targets: ["GazeCore"]), .library(name: "Feel", targets: ["Feel"])],
    targets: [
        .target(name: "GazeCore"),
        .testTarget(name: "GazeCoreTests", dependencies: ["GazeCore"]),
        // The pop's kernels (fracture, motion, sound synthesis), plain Swift like GazeCore and unaware of it. The app
        // compiles Sources/Feel directly too, into the same module as GazeCore.
        .target(name: "Feel"),
        .testTarget(name: "FeelTests", dependencies: ["Feel"]),
        // `swift run GazeReplay <session.csv>`: replays an exported session through the current GazeCore code.
        // Not part of the app, which compiles only Sources/GazeCore and Sources/Feel.
        .executableTarget(name: "GazeReplay", dependencies: ["GazeCore"]),
    ]
)
