---
name: beatmap-authoring
description: Wink Beat map format (winkbeat-<id>.json with circles, sliders, spinners), validation, and making maps from a song with tools/winkbeat/make_map.py. Use when adding a song, generating or hand-tuning charts, or changing the map JSON or its rules.
---

# Maps for Wink Beat

One JSON file per song in `SpantherGaze/SpantherGaze/Resources/winkbeat-<id>.json`, decoded by `WinkBeatMap` in
`GazeCore/Sources/GazeCore/WinkBeatMap.swift`. The old rhythm mode's `tracks.json` stays as it is. Timing at play
time is in `avaudio-rhythm-sync`; judging is in `gaze-wink-judging`.

## 1. Format

```json
{
  "format": 1, "id": "198", "title": "198 km", "author": "honeythehustl3r", "license": "Used with the artist's permission. Artist: Dainal Sovetkhanov (honeythehustl3r)",
  "audio": "winkbeat-198.m4a", "bpm": 99, "firstBeatSec": 0.091, "durationSec": 106.71,
  "charts": {
    "easy":   [{"kind": "circle", "time": 2.515, "x": 0.5, "y": 0.24, "side": "any"}],
    "normal": [{"kind": "slider", "time": 14.03, "end": 15.25, "x": 0.3, "y": 0.5, "side": "left",
                "path": [[0.42, 0.38], [0.55, 0.45]]},
               {"kind": "spinner", "time": 65.55, "end": 68.27}],
    "hard":   [{"kind": "slider", "time": 20.1, "end": 21.3, "x": 0.6, "y": 0.4, "side": "right",
                "path": [[0.7, 0.3], [0.78, 0.4]], "repeats": 1}]
  }
}
```

- Times are seconds of track time as heard (0 = first sample of the file), doubles. Never frames or beats.
- Positions on the 0...1 field (x left to right, y top to bottom), inside 0.08...0.92. Spinners sit in the centre.
- `kind`: `circle`, `slider` (needs `end` and `path`, the points after the head; optional `repeats`), `spinner`
  (needs `end`, at least 1 s, side `any`). No `hold` (agreed decision 4).
- `side`: `any`, `left`, `right`. Easy uses `any` only.
- New fields must be optional with defaults so existing files still decode; bump `format` only for breaking changes.

## 2. Validation (`WinkBeatMap.validate`, tested on Linux)

Per difficulty, on the reference field (844 x 390 pt):
- sorted, inside the track; next start at least `minGapSec` after the previous end (1.0 / 0.55 / 0.4 s);
- winks in any 5 s window at most `maxWinksPerSec × 5` (0.85 / 1.3 / 2.0 per second);
- slider orb speed at most 0.45 / 0.6 / 0.8 screen widths per second (eyes follow well up to there);
- objects on screen together (within `leadSec`) at least two base zones apart from heads and slider tails;
- same eye at most 4 times in a row on normal and hard, and left and right within 35–65% over the chart.
`WinkBeatTests.testBundledMapIsPlayable` must pass for every shipped map, and the realistic bot must win it.

## 3. Making a map from a song

1. Music: the team's own or CC0, with author and license in the file. Never music, maps or files from other rhythm
   games, and no names or looks from them.
2. `pip install librosa`, then
   `python3 SpantherGaze/tools/winkbeat/make_map.py song.mp3 --id <id> --title "<title>" --audio winkbeat-<id>.m4a --out SpantherGaze/SpantherGaze/Resources/winkbeat-<id>.json`.
   It fits BPM and first beat (an integer BPM wins within 0.05), finds the downbeat from the low end, measures bars,
   picks the strongest half beats under each level's budget and rules, turns long gaps into sliders, puts a spinner
   on quiet bars mid-song, places objects on a flowing path with no zone overlaps, and assigns eyes.
3. Encode the audio: `ffmpeg -i song.mp3 -map_metadata -1 -c:a aac -b:a 192k winkbeat-<id>.m4a`. Check the m4a decodes
   with zero lag against the source (cross-correlate the first seconds), or the first beat is off.
4. Run the Linux tests, look at the bot's accuracy per level, then play it on the phone and tune by hand in the JSON
   (hand edits win; do not regenerate over them without asking).
5. Steady-tempo songs map well automatically; songs with tempo changes need hand work.

## 4. Later

- A per-song "beat track" (kick, snare and energy over time) for the stage's pulses, written by the same script.
- No in-app editor until Aziz asks for one.
