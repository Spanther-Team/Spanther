import AVFoundation

/// The calm music of the meteor game: GazeCore's `AmbientPad`, played by the app's one engine (SoundEngine). The pad
/// fades in and out by itself, sample by sample; this class only says when music is wanted. The engine pauses a
/// little after nobody needs it any more, so a faded pad costs no battery.
final class AmbientPlayer {
    private let sound = SoundEngine.shared

    /// True: fade in (starting the engine if needed). False: fade out. Any thread.
    func setPlaying(_ on: Bool) {
        sound.setPadPlaying(on)
    }

    /// One line for the debug file of the Simulator run: what the engine did and how much sound the pad made.
    func debugLine() -> String {
        sound.padDebugLine()
    }
}
