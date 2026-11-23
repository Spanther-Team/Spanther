---
name: gaze-wink-judging
description: Gaze aim, target lock, wink versus blink detection and hit judging for the Wink Beat rhythm mode, built on GazeCore's WinkDetector, GazeLock and RhythmJudge. Use when changing hit zones, timing windows, wink thresholds, hold or slider judging, scoring, combo, or kids' difficulty.
---

# Gaze and wink hit judging for Wink Beat

All judging is plain Swift in `SpantherGaze/GazeCore/Sources/GazeCore` (no UIKit, SwiftUI, ARKit or SceneKit), so it
runs in the Linux tests and in `GazeReplay`. The app only feeds it samples and draws what it decides.
Read the interfaces of `Wink.swift`, `Lock.swift`, `Rhythm.swift`, `HeadGaze.swift` and `Balance.swift` once before
changing them; do not rescan the repo.

## 1. Inputs, one clock each

- Aim: calibrated gaze in screen points from `GazeModel` (head-frame model with check-dot fallback). Never the head
  pose alone, never the 3D stage's parallax camera (see `scenekit-metal-anime-3d`).
- Eyes: ARKit `eyeBlinkLeft` / `eyeBlinkRight` (0 open, 1 closed) with the ARKit frame timestamp (host clock).
- Track time: from the audio clock (`avaudio-rhythm-sync`). Convert each wink's `onset` (host) to track time with
  the session mapping at judging time, not with the frame time when it was processed.
- Note positions: `RhythmNote.x / y` in the 0..1 play field, mapped to screen points once per layout. The judge sees
  screen points; it never sees 3D coordinates.

## 2. Wink versus blink (WinkDetector)

- Keep the existing rules and their measured numbers in `WinkConfig`: thresholds ride on each eye's open level
  (lids drop when looking down), hysteresis between close and open, `pairWindowSec = 0.025` (natural blinks cross
  within 0 to 17 ms; in Aziz's wink test the other eye followed a wink 33 to 50 ms later), `minClosedSec = 0.05`.
- The judged moment is `onset` (first eye crossing), even though the side is known only at `decided`. Visual hit
  feedback may wait until `decided`; the score uses `onset`.
- Change a threshold only with evidence from a phone CSV, replayed with
  `swift run -c release GazeReplay <csv>`, and put the source of the number in the doc comment.
- Easy level accepts both-eye closures on `any` notes (`acceptBlink`), for children who cannot wink one eye.
  Never remove that path.

## 3. Aim and target lock (GazeLock)

- No visible reticle in rhythm play: a cursor slightly off the true gaze pulls the eyes after it. The note in reach
  lights up and holds the lock (`GazeLock`, release at 1.4 x reach, switch at 0.6, 0.35 s grace when the face is lost).
- Hit zone per level from `RhythmRules.level(_:measuredErrorPt:scale:zoneFloorPt:)`: base 90 / 70 / 55 pt plus the
  calibration's measured error (capped at 90), never below the balance zone floor
  (`BalanceConfig.zoneFloor`, calibration miss + 1.5 x spread). Zones of at least about 2 cm on the phone.
- A closure plays the locked note if one is locked; otherwise the nearest note in reach. A closure with the aim off
  every zone counts `offTarget`, not a hit.
- Head parallax, 3D depth and camera motion must not change any of these numbers. Test: same samples with different
  head poses give the same judgements.

## 4. Timing windows and judgement

- Windows (`RhythmRules`): perfect 90 ms, good 160 ms, ok 240 ms, applied to
  `wink track time - (note.time + learned latency)`. These are wider than finger rhythm games on purpose: a wink
  is slower and less precise than a key press.
- The judge learns the player's usual delay (`latencySec`, start 0.08 s) from hits and carries it to the next track;
  the per-route audio offset from `avaudio-rhythm-sync` is applied before it. Log both.
- One closure plays at most one note; one note takes at most one closure. Closures far from any note count `stray`;
  wrong eye on a side note counts `wrongEye` and sets `lastRejected` so the screen can say why.
- Kids' difficulty is data (wider windows, bigger zones, slower lead, blinks allowed), not a code fork.

## 5. New note kinds (hold and slider)

Only after tap notes are confirmed on the phone. Proposed rules, to agree with Aziz first:
- Hold: the eye closes in the start window and stays closed; release in the end window or after it gives the full
  judgement, early release gives the start judgement minus one grade. Long closures are tiring: holds at most
  about 1 s, none on easy.
- Slider: the gaze follows a path while the note moves (a pursuit, like the Pursuit mode). Score is the share of
  path time the aim stayed inside the moving zone, with the start wink judged as a tap. Reuse `Pursuit.swift`
  ideas, not its code paths, if they diverge.

## 6. Score, combo, results

- Score from judgement only (e.g. 300 / 100 / 50 / 0); combo breaks on miss, `offTarget` and `wrongEye` on a played
  note, not on stray closures. Streak milestones reuse `Streak.swift`.
- Results show per-eye counts (`closuresLeft`, `closuresRight`), mean and spread of offsets, off-target rate. These
  are game metrics; never present them as a medical or diagnostic measure.

## Tests and evidence

- Every rule change has a test in `RhythmTests.swift` / `WinkTests.swift` / `LockTests.swift` with fixed samples,
  plus a `WinkBot` run when it changes play.
- Nothing counts as working until Aziz plays it on his phone; ask for the session CSV and replay it.
