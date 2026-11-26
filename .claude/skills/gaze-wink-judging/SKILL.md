---
name: gaze-wink-judging
description: Gaze aim, target lock, wink versus blink handling and hit judging for the Wink Beat rhythm mode (WinkBeatEyes, WinkBeatPlay, GazeLock, WinkDetector in GazeCore). Use when changing hit zones, timing windows, wink or long-blink rules, slider follow, spinner hops, scoring, combo, energy, ranks, or kids' difficulty.
---

# Gaze and wink judging for Wink Beat

All judging is plain Swift in `SpantherGaze/GazeCore/Sources/GazeCore` (no UIKit, SwiftUI, ARKit or Metal), so it runs
in the Linux tests and in `GazeReplay`. The app feeds it frames and draws what it decides. Files:
`WinkBeatEyes.swift` (blink-safe aim, closures), `WinkBeatPlay.swift` (judge, score, energy, rank),
`WinkBeatMap.swift` (objects, validation, slider paths), `WinkBeatBot.swift` (scripted player), plus the shared
`Wink.swift` (`WinkDetector`) and `Lock.swift` (`GazeLock`). Read their interfaces once; do not rescan the repo.

## 1. Inputs, one clock each

- Aim: calibrated gaze in screen points from the app's gaze model. Never the head pose alone, never the stage's
  parallax camera (`metal-anime-stage`).
- Eyes: ARKit `eyeBlinkLeft` / `eyeBlinkRight` (0 open, 1 closed) per frame.
- Time: track time from the audio clock (`avaudio-rhythm-sync`). Feed `WinkBeatEyes` and `WinkBeatPlay` the same
  clock; convert frame timestamps to track time before calling them.
- Positions: the map's 0...1 field through `WinkBeatField` to screen points. The judge never sees 3D coordinates.

## 2. Blinks play below Hard, never move the aim (WinkBeatEyes)

- Since 2026-11-26 (Aziz's first phone CSV: he closes both eyes on the beat, his one-eye winks came out half
  closed and wrong-eyed, Hard ended every run in 6 s): on Easy and Normal (`WinkBeatDifficulty.blinksPlay`) any
  closure plays any object, and the eye colours are off (`WinkBeatPlay.side(_:)` is `.any`). The eyes send a
  two-eye closure as `.beatBlink` the moment the detector decides it (`WinkBeatEyesConfig.blinksPlay`), with the
  aim from before the onset; nothing follows it. A blink starts the play only with the aim on the start disc.
  Hard keeps everything below: winks only, eye colours, blinks never hit. Easy and Normal never fail in the first
  `noFailSec = 30` after the first object (the bar stops at `noFailFloor = 0.2`).
- Two eyes crossing within the pair window (`WinkConfig.pairWindowSec = 0.025`, measured on Aziz's phone: blinks
  0–17 ms, the other eye after a wink 33–50 ms) is a blink: on Hard `.blink`, never sent to the judge.
- A wink is judged with the aim from `preOnsetSec = 0.1` before its onset: the tracked gaze slides while the lid
  comes down. The onset (first eye crossing) is the judged moment even though the side is known later.
- While any eye is not open, and `settleSec = 0.1` after, the output aim holds the last good point, so a blink in a
  slider or spinner does not count as looking away.
- Both eyes held closed `longBlinkSec = 0.3` or more is a `.longBlink` (plays `any` objects where the level accepts
  long blinks and blinks do not already play). A child who cannot wink must always have a way to play Easy:
  never remove both paths. Misses wait `goodSec + decideSec` (0.08 s, the detector's decision), plus
  `longBlinkSec` where only long blinks play.
- Change these numbers only with a phone CSV replayed with `swift run -c release GazeReplay <csv>`, and cite it.

## 3. Aim, zones and the lock

- No visible reticle in play. `GazeLock` locks the nearest object in reach (`WinkBeatPlay.lockTargets(at:)`); a wink
  plays the locked object when its window holds the wink, else the earliest aimed one.
- Lock assist below Hard (`lockAssist`): only the object due next can be locked, from `assistPt` (2.8 cm, 170 pt at
  60 pt/cm), and a closure in its window plays the locked object whatever the aim does during the closure. On every
  level an aim up to `edgeSlackPt = 160` past the screen edge counts as on the edge (`onField`): the tracked aim
  overshot the upper circles by about 100 pt on the phone. Hits teach the aim adapter through `onPlayed`.
- Zone: `WinkBeatRules.make`: difficulty base 90 / 70 / 55 pt plus the calibration's measured error (capped at 90),
  never below the balance floor (calibration miss + 1.5 x spread, `BalanceConfig.zoneFloor`).
- A wink in a window with the aim off every object uses nothing up (`offTarget`), so the player can still hit it.
  Wrong eye on a side object: `wrongEye`, nothing used up. Winks outside every window: `stray`.
- Head parallax, 3D depth and camera motion must never change any of these numbers.

## 4. Windows, grades, score

- Grades after the learned delay (`latencySec`, starts 0.08, learned at 0.15 per hit, clamped −0.05...0.3):

  | Difficulty | Perfect | Great | Good |
  | --- | --- | --- | --- |
  | easy | 120 ms | 200 ms | 300 ms |
  | normal | 90 ms | 160 ms | 240 ms |
  | hard | 80 ms | 140 ms | 210 ms |

- Points 300 / 100 / 50 / 0. Score adds `points × min(combo, 100) / 25` on top; slider ticks and spinner progress add
  10, each spinner lap beyond the asked hops adds 100. Accuracy = points / (300 × objects judged). Combo counts
  objects and breaks only on a Miss.
- Ranks: SS 100%, S ≥ 95% with no miss, A ≥ 90%, B ≥ 80%, C ≥ 70%, D below.
- Energy: starts full; drains 0 / 0.012 / 0.02 per second; +0.05 / 0.03 / 0.01 per grade; a miss costs
  0.06 / 0.12 / 0.16. Normal and hard fail at zero; easy never fails.

## 5. Sliders and spinners

- Slider: the head is judged like a circle (`.head` event). Then the aim follows the orb (`WinkBeatPlay.orb`) within
  1.5 zones. Followed ≥ 85%: the head's grade (head missed → Good); ≥ 60%: one grade lower (head missed → Good);
  less: Miss. Ticks on each beat between head and end. No holding a wink: a closed eye cannot aim.
- Spinner: no wink. The ring is cut into 8 sectors around its centre; the aim stands on a sector once it is
  0.3 radius from the centre. Hops to a neighbour (or one skipped) count signed; only new net progress scores, so
  jitter on a sector edge earns nothing. Hops asked: duration × 2 / 2.5 / 3 per second. Progress ≥ 1 Perfect,
  ≥ 0.66 Great, ≥ 0.33 Good, else Miss. Eyes cannot circle smoothly without a target; hops are natural saccades.
- No hold notes (agreed decision 4).

## 6. Results

- Show grade counts, max combo, accuracy, rank, per-eye winks (`closuresLeft`, `closuresRight`, `longBlinks`),
  mean and spread of offsets, off-target count. Game metrics only; never present them as medical or diagnostic.

## Tests and evidence

- Every rule change gets a test in `WinkBeatTests.swift` with fixed samples, and a `WinkBeatBot.run` check when it
  changes play (the realistic bot must stay ≥ 80 / 75 / 70% on the test level, no blink may play an object on Hard,
  and the both-eye blinker with the aim 100 pt high must stay ≥ 75% on Normal).
- Nothing counts as working until Aziz plays it on his phone; ask for the session CSV and replay it.
