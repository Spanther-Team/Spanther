import AVFoundation
import AudioToolbox
import QuartzCore

/// The app's one AVAudioEngine (architecture proposal, "Audio and haptics engine"): the meteor game's pad, the wink
/// test's clicks and the pop's sound layers all play through it. Twelve mono voices (AVAudioPlayerNode) with voice
/// stealing feed a submix, then Apple's peak limiter, then the main mixer; the pad's source node joins the main mixer
/// directly. The voices take mono Float32 at 48 kHz whatever the route, so buffers made once stay valid when headphones
/// come and go (the mixer converts). Everything that touches the engine runs on `queue`, never on the main thread.
final class SoundEngine {
    static let shared = SoundEngine()

    /// The voices' sample rate: the pop's sound bank and the clicks are made at it.
    static let sampleRate = 48_000.0
    static let voiceCount = 12

    let queue = DispatchQueue(label: "spanther.sound", qos: .userInteractive)
    /// Mono Float32 at `sampleRate`: every buffer handed to `play` has this format.
    let voiceFormat: AVAudioFormat

    /// Seconds the route adds before a sound is heard: about 0.01 on the speaker, 0.15-0.25 on Bluetooth.
    private(set) var outputLatency = 0.0
    /// What the engine did last, for the debug lines: "off", "running", "paused", "no output", "failed".
    private(set) var state = "off"

    private var engine: AVAudioEngine?
    private var voices: [AVAudioPlayerNode] = []
    /// Host seconds (the CACurrentMediaTime clock) at which each voice's last buffer ends, and when it started.
    private var busyUntil: [Double] = []
    private var startedAt: [Double] = []
    /// Who wants the engine running ("pad", "game", "clicks"); it pauses a little after the last one lets go.
    private var holders: Set<String> = []
    private var pauseWork: DispatchWorkItem?
    private var interruptionObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?

    /// The meteor game's pad (GazeCore `AmbientPad`), made on first use and kept across engine rebuilds.
    private var pad: AmbientPad?
    private var padNode: AVAudioSourceNode?
    private var padWanted = false
    private var padState = "off"

    private init() {
        voiceFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        // A call or an alarm stops the engine; when it is over the engine comes back if someone still holds it.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.queue.async { self?.startIfHeld() }
        }
    }

    // MARK: Holding the engine

    /// Keeps the engine running for `who` (true) or lets go (false). It starts at once and pauses 1.5 s after the last
    /// holder lets go, long enough for the pad's fade and a last pop to ring out. Any thread.
    func hold(_ who: String, _ on: Bool) {
        queue.async { [weak self] in self?.holdOnQueue(who, on) }
    }

    private func holdOnQueue(_ who: String, _ on: Bool) {
        if on {
            holders.insert(who)
            pauseWork?.cancel()
            pauseWork = nil
            startIfHeld()
            return
        }
        holders.remove(who)
        guard holders.isEmpty else { return }
        pauseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.holders.isEmpty, let engine = self.engine, engine.isRunning else { return }
            engine.pause()
            self.state = "paused"
        }
        pauseWork = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Builds the engine if needed and starts it while someone holds it. On `queue`.
    private func startIfHeld() {
        guard !holders.isEmpty else { return }
        if engine == nil { build() }
        guard let engine else { return }
        guard !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            state = "running"
            // The voices stay "playing" with nothing scheduled, so a buffer scheduled for now starts on the next cycle.
            for v in voices { v.play() }
        } catch {
            state = "failed"
        }
    }

    /// One engine: voices → submix → peak limiter → main mixer, and the pad's source node into the main mixer.
    private func build() {
        let session = AVAudioSession.sharedInstance()
        // Playback, so the sounds play with the ring/silent switch off; mixing, so another app's audio is not stopped.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        outputLatency = session.outputLatency
        let engine = AVAudioEngine()
        // Without an output (a Simulator on a machine with no sound card) connecting a node raises an exception Swift
        // cannot catch, so the output's format is checked first.
        let out = engine.outputNode.outputFormat(forBus: 0)
        guard out.sampleRate >= 8000, out.channelCount > 0,
              let stereo = AVAudioFormat(standardFormatWithSampleRate: out.sampleRate, channels: 2),
              let padFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else {
            state = "no output"
            return
        }
        let submix = AVAudioMixerNode()
        engine.attach(submix)
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(limiter)
        engine.connect(submix, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
        var made: [AVAudioPlayerNode] = []
        for _ in 0..<Self.voiceCount {
            let v = AVAudioPlayerNode()
            engine.attach(v)
            engine.connect(v, to: submix, format: voiceFormat)
            made.append(v)
        }
        if let pad {
            let node = Self.sourceNode(for: pad, format: padFormat)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: padFormat)
            padNode = node
        }
        engine.prepare()
        // When the output changes (headphones, a speaker) the engine stops by itself: build a new one.
        if let old = configObserver { NotificationCenter.default.removeObserver(old) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.rebuild() }
        }
        self.engine = engine
        voices = made
        busyUntil = Array(repeating: 0, count: made.count)
        startedAt = Array(repeating: 0, count: made.count)
    }

    private func rebuild() {
        engine?.stop()
        engine = nil
        voices = []
        padNode = nil
        // The music player went with the engine; its screen hears of the new output and starts again.
        music = nil
        musicFormat = nil
        setMusicSnapshot(nil, start: nil)
        startIfHeld()
    }

    // MARK: Music (Wink Beat)

    /// Wink Beat's music player (skill `avaudio-rhythm-sync`): one whole track, or the sync check's clicks, as one
    /// buffer on its own player node into the main mixer, so the node's sample clock is the track's clock. Made when
    /// music first plays. On `queue`.
    private var music: AVAudioPlayerNode?
    private var musicFormat: AVAudioFormat?
    /// What the screens read every frame from the main thread: the playing node and its planned start (host s).
    private let musicLock = NSLock()
    private var musicNode: AVAudioPlayerNode?
    private var musicStartHost: Double?

    private func setMusicSnapshot(_ node: AVAudioPlayerNode?, start: Double?) {
        musicLock.lock()
        musicNode = node
        musicStartHost = start
        musicLock.unlock()
    }

    /// Mono Float32 samples at `sampleRate` as a buffer for `playMusic` (the sync check's clicks).
    func musicBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in ch[0].update(from: src.baseAddress!, count: samples.count) }
        return b
    }

    /// A whole audio file decoded into memory in its processing format, so nothing decodes while it plays. A track
    /// takes a moment: call it off the main thread.
    static func musicBuffer(contentsOf url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do { try file.read(into: b) } catch { return nil }
        return b
    }

    /// Plays `buffer` from its first sample at host time `startHost` (the `CACurrentMediaTime` clock), replacing
    /// what the music player had. The caller holds the engine (`hold("music", true)`). Any thread.
    func playMusic(_ buffer: AVAudioPCMBuffer, startHost: Double) {
        queue.async { [weak self] in self?.playMusicOnQueue(buffer, startHost: startHost) }
    }

    private func playMusicOnQueue(_ buffer: AVAudioPCMBuffer, startHost: Double) {
        startIfHeld()
        guard let engine, engine.isRunning else {
            // No output (a Simulator without a sound card): the screens keep time on the planned start.
            setMusicSnapshot(nil, start: startHost)
            return
        }
        if music == nil || musicFormat != buffer.format {
            if let old = music {
                old.stop()
                engine.detach(old)
            }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            music = node
            musicFormat = buffer.format
        }
        guard let node = music else { return }
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: startHost)))
        setMusicSnapshot(node, start: startHost)
    }

    /// Stops the music player. Any thread.
    func stopMusic() {
        queue.async { [weak self] in
            self?.music?.stop()
            self?.setMusicSnapshot(nil, start: nil)
        }
    }

    /// The music player's newest render for `WinkBeatClock`: seconds of track handed to the output, and that
    /// render's host time. Nil while no music plays, before its start, and on a Simulator without sound (the caller
    /// then keeps time on its planned start). Any thread.
    func musicReading() -> WinkBeatClock.Reading? {
        musicLock.lock()
        let node = musicNode, start = musicStartHost
        musicLock.unlock()
        guard let node, let start, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              nodeTime.isHostTimeValid, let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        let host = AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
        // Renders from before the start say nothing about where the track is.
        guard host >= start - 0.002 else { return nil }
        return .init(renderedSec: Double(playerTime.sampleTime) / playerTime.sampleRate, host: host)
    }

    /// Whether sound can be heard now (the engine runs), for the screens' warnings.
    var isRunning: Bool { queue.sync { engine?.isRunning ?? false } }

    private static func sourceNode(for pad: AmbientPad, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            pad.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
    }

    // MARK: Playing buffers

    /// A buffer in `voiceFormat` holding `samples` (mono, made at `sampleRate`). Nil for no samples. Any thread.
    func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let b = AVAudioPCMBuffer(pcmFormat: voiceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        let out = channels[0]
        for i in 0..<samples.count { out[i] = samples[i] }
        return b
    }

    /// Plays `buffer` (in `voiceFormat`) on a free voice, or steals the one that started longest ago. `hostTime`: when
    /// it should start, on the CACurrentMediaTime clock (nil or past: on the next render cycle). `pan` −1...1. On
    /// `queue` only.
    func play(_ buffer: AVAudioPCMBuffer, at hostTime: Double? = nil, pan: Float = 0, volume: Float = 1) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let engine, engine.isRunning, !voices.isEmpty else { return }
        let now = CACurrentMediaTime()
        let start = max(now, hostTime ?? now)
        var pick = -1
        for i in voices.indices where busyUntil[i] <= now {
            pick = i
            break
        }
        if pick < 0 {
            pick = 0
            for i in voices.indices where startedAt[i] < startedAt[pick] { pick = i }
            voices[pick].stop()
            voices[pick].play()
        }
        let voice = voices[pick]
        voice.pan = max(-1, min(1, pan))
        voice.volume = max(0, min(1, volume))
        if let hostTime, hostTime > now + 0.002 {
            voice.scheduleBuffer(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: hostTime)),
                                 options: [], completionHandler: nil)
        } else {
            voice.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }
        startedAt[pick] = start
        busyUntil[pick] = start + Double(buffer.frameLength) / buffer.format.sampleRate + 0.02
    }

    /// Stops every voice at once (the wink test's stop). The pad is not touched. Any thread.
    func stopVoices() {
        queue.async { [weak self] in
            guard let self else { return }
            for (i, v) in self.voices.enumerated() {
                v.stop()
                if self.engine?.isRunning == true { v.play() }
                self.busyUntil[i] = 0
            }
        }
    }

    // MARK: The pad

    /// The meteor game's pad on or off; it fades in and out by itself. While another app plays music the pad stays
    /// silent: the player's own music is left as it is. Any thread.
    func setPadPlaying(_ on: Bool) {
        queue.async { [weak self] in self?.padOnQueue(on) }
    }

    private func padOnQueue(_ on: Bool) {
        guard on != padWanted else { return }
        padWanted = on
        guard on else {
            pad?.setPlaying(false)
            holdOnQueue("pad", false)
            return
        }
        if AVAudioSession.sharedInstance().isOtherAudioPlaying {
            padState = "other audio"
            return
        }
        if pad == nil {
            pad = AmbientPad(sampleRate: Self.sampleRate)
            // An engine built before the pad existed gets it now.
            if let engine, let pad, let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) {
                let node = Self.sourceNode(for: pad, format: format)
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                padNode = node
            }
        }
        holdOnQueue("pad", true)
        pad?.setPlaying(true)
        padState = state == "running" ? "playing" : state
    }

    /// One line for the debug file of the Simulator run: what the pad's engine did and how much sound the pad made.
    func padDebugLine() -> String {
        queue.sync {
            let frames = pad?.renderedFrames ?? 0
            let peak = pad?.peak ?? 0
            return String(format: "ambient %@, %.0f Hz, %ld frames, peak %.3f", padState, Self.sampleRate, frames,
                          Double(peak))
        }
    }

    /// The engine's state for the debug overlay.
    func debugLine() -> String {
        queue.sync { "sound \(state), \(holders.sorted().joined(separator: "+")), latency \(Int(outputLatency * 1000)) ms" }
    }
}
