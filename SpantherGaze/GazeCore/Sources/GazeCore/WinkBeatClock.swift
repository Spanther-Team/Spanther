import Foundation

/// Wink Beat's track time from the audio clock (skill `avaudio-rhythm-sync`, section 2). The app reads the music
/// player's newest render (how many seconds of the track had been handed to the output, and the host time of that
/// render) and the route's delays; this turns them into the track time the player hears, on the host clock that
/// ARKit frames and touches use (`CACurrentMediaTime`). Plain Swift so a fake clock can test it.
public struct WinkBeatClock: Sendable {
    /// One reading of the player: `renderedSec` of track had been handed to the output at host time `host` (s).
    public struct Reading: Equatable, Sendable {
        public var renderedSec: Double
        public var host: Double
        public init(renderedSec: Double, host: Double) {
            self.renderedSec = renderedSec
            self.host = host
        }
    }

    /// The route's output latency and IO buffer (s), from `AVAudioSession`.
    public var outputLatency: Double
    public var ioBuffer: Double
    /// This device's sync offset for the route (s; positive: the sound is heard later than the route reports).
    public var userOffset: Double
    /// A step bigger than this (s) is taken at once (a seek, a stall, a new route) instead of being held back.
    public var resyncSec = 0.03

    private var anchor: Reading?
    private var lastHeard: Double?

    public init(outputLatency: Double = 0, ioBuffer: Double = 0, userOffset: Double = 0) {
        self.outputLatency = outputLatency
        self.ioBuffer = ioBuffer
        self.userOffset = userOffset
    }

    /// Seconds between a sample being rendered and being heard.
    public var delay: Double { outputLatency + ioBuffer + userOffset }

    /// The heard track time at `hostNow`, from the newest reading (`nil` keeps the last one, which is extrapolated
    /// with host time between the audio's render cycles). Nil until there has been a reading. It never steps back
    /// by less than `resyncSec`: such jitter holds the last value; a bigger step back is a resync and is taken.
    public mutating func heard(reading: Reading?, hostNow: Double) -> Double? {
        if let reading { anchor = reading }
        guard let raw = trackTime(host: hostNow) else { return nil }
        var t = raw
        if let last = lastHeard, raw < last, last - raw <= resyncSec { t = last }
        lastHeard = t
        return t
    }

    /// The heard track time of an event at host time `host` (a wink's camera frame, a touch), from the newest
    /// reading, without the hold against stepping back: events are placed where they happened.
    public func trackTime(host: Double) -> Double? {
        guard let a = anchor else { return nil }
        return a.renderedSec + (host - a.host) - delay
    }

    /// Forgets the readings: the music stopped, jumped or moved to a new engine.
    public mutating func reset() {
        anchor = nil
        lastHeard = nil
    }
}
