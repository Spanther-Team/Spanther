---
name: beatmap-authoring
description: Beatmap format, validation and authoring for Wink Beat, extending GazeCore's RhythmTrack and tracks.json, plus the chart generator for CC0 music. Use when adding a song, writing or generating charts, changing the beatmap JSON, or adding hold and slider notes.
---

# Beatmaps for Wink Beat

Charts live in `SpantherGaze/SpantherGaze/Resources/tracks.json` and are decoded by `RhythmTrack` in
`GazeCore/Sources/GazeCore/Rhythm.swift`. Generation is `ChartGenerator`. Timing at play time is in
`avaudio-rhythm-sync`; judging is in `gaze-wink-judging`.

## 1. Format

Keep one JSON array of tracks, backward compatible: every new field is optional, and today's files still decode.

```json
{
  "id": "orbit", "title": "...", "author": "...", "license": "CC0",
  "file": "orbit.m4a", "bpm": 120, "firstBeatSec": 0.52, "beats": 96,
  "phraseBeats": 8,
  "accents": [[0, 3], [2, 2], [3.5, 1]],
  "format": 2,
  "notes": {
    "easy":  [{"time": 0.52, "x": 0.3, "y": 0.5, "side": "any"}],
    "hard":  [{"time": 1.02, "x": 0.6, "y": 0.4, "side": "left", "kind": "hold", "end": 1.52},
              {"time": 2.02, "x": 0.4, "y": 0.6, "side": "right", "kind": "slider",
               "path": [[0.4, 0.6], [0.55, 0.45], [0.7, 0.6]], "end": 3.02}]
  }
}
```

- Times are seconds of track time as heard (0 = first sample of the file), as doubles. Never frames, never beats
  in the stored notes (beats are only in `accents`).
- Positions are the 0..1 play field (x left to right, y top to bottom), mapped to screen points at layout time.
  Keep notes inside 0.08..0.92 so zones stay on screen and clear of the HUD.
- `side`: `any`, `left`, `right`. `kind` (new, default `tap`): `tap`, `hold` (needs `end`), `slider` (needs `end`
  and `path` of at least 2 points). Add `format: 2` when a file uses new kinds.
- Add the new fields to `RhythmNote` as optionals with defaults so `RhythmNote(time:x:y:side:)` keeps working.

## 2. Validation (in GazeCore, tested on Linux)

A `RhythmTrack.validate() -> [ChartIssue]` (or similar) checks, per level:
- notes sorted by time, all inside `0 ..< endSec`, positions inside the field;
- gaps at least the level's `minGapSec` (easy 1.0 s, normal 0.55, hard 0.4) and density at most `maxPerSec`
  (0.8 / 1.3 / 2.0 per second): winking faster than about twice a second is hard for anyone and slower for kids;
- hold and slider: `end > time`, holds at most about 1 s, none on easy; nothing starts before the previous
  hold or slider ends;
- consecutive notes far enough apart that zones (from `RhythmRules`) do not overlap, or the lock cannot tell them apart;
- the same eye not asked more than about 4 times in a row on normal (fatigue), and left and right balanced
  over a track.
On a failed level, log the issues and fall back to `ChartGenerator` for that level; never crash.

## 3. Generated charts

- `ChartGenerator` writes notes from `accents` (strength 3 / 2 / 1 for easy / normal / hard) or the beat grid,
  taking a new direction each phrase, with each level's `step` between notes. Keep it deterministic (seeded `Rng`)
  so tests and replays reproduce charts.
- Extend it for sides (alternate eyes on phrases, `any` on easy) and, later, holds on long accents.
- A hand-made level in `notes` always wins over generation.

## 4. Adding a song

1. Music: CC0 or the team's own, with author and license in the entry. Never music, charts or files from other
   rhythm games.
2. Export AAC `.m4a`, 44.1 or 48 kHz, trimmed, with a clean first beat; put it in `Resources`.
3. Find `bpm` and `firstBeatSec` (beat tracking offline, or tap along in a DAW); check against a metronome
   overlay that the grid stays on the beat to the end. Variable tempo songs need hand-made notes.
4. Write `accents` for the melody, or hand-made notes per level.
5. Run the validation tests, then play it in the Simulator with the bot (`WinkBot`) and on the phone.
6. Credit the track wherever the existing tracks are credited.

## 5. Tooling (optional, later)

- A small `swift run` tool in `GazeCore` (next to `GazeReplay`) that prints a chart's per-level stats and issues,
  and can write a generated chart out as hand-made notes for editing.
- No in-app editor until Aziz asks for one.
