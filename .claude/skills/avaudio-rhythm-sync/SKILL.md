---
name: avaudio-rhythm-sync
description: Sample-accurate rhythm game audio clock, beatmap parsing, and latency compensation using AVAudioEngine. Use when touching Wink Beat music playback, note timing, approach animation timing, hit windows, calibration of audio offset, or beatmap loading.
---

# Audio clock and sync for Wink Beat

Today `RhythmSession` plays music with `AVAudioPlayer.play(atTime:)` and maps host time to track time through
`startHost`. Wink Beat moves the music onto the app's one `AVAudioEngine` (`Audio/SoundEngine.swift`) with an
`AVAudioPlayerNode`, and takes track time from the audio clock. Judging stays in `GazeCore.RhythmJudge`.

## 1. Forbidden clocks

3.1. Never drive note spawning, approach ring animation or hit windows with `Timer`, `DispatchQueue.asyncAfter`,
`SKAction` / `SCNAction` durations, or accumulated frame deltas (`CACurrentMediaTime` differences added up).
They drift against the audio and jump after a stall. Every frame computes positions from the current track time.

## 2. Audio clock

3.2. Use `AVAudioEngine` with an `AVAudioPlayerNode` attached to the shared engine, and derive track time from the
node's sample clock.

- Load the whole track into an `AVAudioPCMBuffer` (or schedule the `AVAudioFile` segment) in the engine's output
  format before play; no decoding on the render path.
- Start at a known host time: `let startHostTime = AVAudioTime.hostTime(forSeconds: hostNow + leadIn)` and
  `player.play(at: AVAudioTime(hostTime: startHostTime))` (or `scheduleBuffer(_:at:)`). Lead in at least 0.5 s
  for the first frames, plus the visual approach time.
- Track time each frame:
  ```swift
  guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
        let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
  let rendered = Double(playerTime.sampleTime) / playerTime.sampleRate   // s of track handed to the output
  ```
  `lastRenderTime` updates once per IO buffer, so between buffers extrapolate with host time:
  `rendered + (hostNow - hostTimeOf(nodeTime))`, where `hostTimeOf` uses `AVAudioTime.seconds(forHostTime:)`
  on `nodeTime.hostTime`. Clamp so track time never goes backwards; if the jump exceeds 30 ms, resync instead of
  smoothing.
- Heard time (what the player's ear gets) is later than rendered:
  `heard = rendered - outputLatency - ioBufferDuration` (both from `AVAudioSession.sharedInstance()`), minus the
  user offset (section 3). Use `heard` for visuals and judging.
- Wink onsets come with ARKit frame timestamps (host clock, same as `CACurrentMediaTime`). Convert a wink's host
  time to track time with the same mapping (`trackTime(host:)`), anchored to the latest audio clock reading, not
  to the frame when it was processed. Also subtract the camera-to-frame delay already measured by the wink
  tracking if one exists.
- Recompute `outputLatency` and `ioBufferDuration` on `AVAudioSession.routeChangeNotification` (AirPods add
  150 to 250 ms) and on `AVAudioEngineConfigurationChange`; pause and offer a resume on route change mid-track.
- Interruptions (calls, Siri): pause, keep the track position, restart with a fresh lead in. The existing
  `SoundEngine` interruption observer is the place to hook in.
- Session category stays as `SoundEngine` sets it; do not set a second category from the rhythm code.
- Do not lower `preferredIOBufferDuration` below about 5 ms; the camera and Vision need the CPU.

## 3. User offset calibration

- A per-device offset in ms (`audioOffsetMs`), saved per output route type (speaker, wired, Bluetooth), default 0.
- Calibration screen: a steady click track (8 to 16 beats); the player winks on the beat; the median of the
  (wink track time minus beat time) after dropping the first 2 is the offset. Show it as `+12 ms` with
  `.monospacedDigit()` and let the player nudge it in 5 ms steps.
- Visual offset is separate from input offset only if testing shows a need; start with one value.
- `RhythmJudge` already learns how late winks land; keep that, apply the device offset before it, and log both
  in the session CSV so replays (`swift run -c release GazeReplay <csv>`) reproduce the timing.

## 4. Beatmaps

- Beatmap is plain JSON in `Resources`, parsed by a `Codable` type in `GazeCore` (extends today's `RhythmTrack`
  / `RhythmNote`): times in seconds of track time as floats (or ms as integers), never in frames; positions in a
  normalised 0..1 play field, mapped to screen points at layout time.
- Fields: format version, track file, BPM and first beat offset (for the metronome and grid), notes with time,
  side (left, right, any), kind (tap, hold with end time, slider with path points), level tags.
- Validate on load (sorted times, ends after starts, inside the field); on error fall back to `ChartGenerator`
  and log it. Parse in `GazeCore` with tests on Linux.
- Only CC0 or own music and original charts. Never import maps, music or files from other rhythm games.

## 5. Judging and visuals from one time

- Each frame: `t = heardTrackTime()`. A note's approach progress is `(t - (note.time - lead)) / lead`. Rings,
  orbs and HUD read this; nothing keeps its own timer.
- Windows (`RhythmRules`: perfect 90 ms, good 160 ms, ok 240 ms) are applied to wink track time minus note time.
  Kids' windows are a level setting, not a code fork.
- Tests in `GazeCore`: host-to-track mapping with a fake clock (latency, buffer, offset, route change jump), and
  beatmap parse and validation.

## Checklist before a PR

- [ ] No `Timer`, `asyncAfter` or action durations in the timing path.
- [ ] Track time from `lastRenderTime` / `playerTime(forNodeTime:)` with latency, buffer and offset applied.
- [ ] Route change and interruption handled.
- [ ] Offsets logged to CSV; GazeReplay still runs.
- [ ] Not claimed in sync until Aziz plays it on the phone with speaker and with headphones.
