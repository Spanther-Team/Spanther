# SpantherGaze (iOS)

Native SPANTHER prototype: SwiftUI + SpriteKit + ARKit face tracking. Meteors fall toward Earth; holding your gaze on one bursts it. Gaze time per size comes from `docs/BALANCE.md` (S 0.5 s, M 0.8 s, L 1.2 s, XL 2.0 s) through `SpantherGaze/Resources/balance.json`.

## Status

- `GazeCore` and `Feel` (pure Swift) build and their unit tests pass in CI (`swift test` in `GazeCore/`).
- The app target compiles in GitHub Actions (Xcode 16.4 Release, and the newest Xcode on the runner in Debug), unsigned. Step-by-step Mac instructions (in Russian) are in the root README, the Windows route is in `SIDELOAD.md`.
- First run on a real iPhone: Aziz, iPhone 13, 2026-11-04, installed with Sideloadly, played to level 6. Check error 1.29 cm; tracking ran at 30 fps, not 60. The aim went wild from level 5 on, which led to the gaze model changes below (replayed on that session, not yet confirmed on the phone). Every frame interval in that CSV was 33.3 ms from the first calibration dot, so the camera ran at 30 fps from the start, not after heating up. The CSV and the debug overlay now show the camera format, the formats the phone offers, the thermal state and Low Power Mode, so the next session shows why.
- CI also runs the app in the iOS Simulator (job `simulator-smoke`): a Debug-only bot plays with the launch argument `-SpantherAutoplay eyes|touch|wink|rhythm|pursuit`, the job checks that the app keeps running and that kills spend energy and reloads happen, that red signs are both looked at and passed by, that the wink test, a rhythm track and the warm-up play to the end and their numbers land in the history, and it pushes screenshots, session CSVs and logs to the `ci-screenshots` branch. Face tracking does not exist in the Simulator, so "eyes" there means the bot's gaze.

## Build and run on an iPhone

1. Open `SpantherGaze.xcodeproj` in Xcode 16 or newer.
   If Xcode refuses the project file, run `brew install xcodegen && xcodegen generate` in this folder and open the generated project.
2. Target SpantherGaze → Signing & Capabilities → choose your Team (a free Apple ID works for your own phone). Change the bundle id if Xcode asks.
3. Connect the iPhone (TrueDepth camera or A12 chip and newer), select it, press Run.
4. The first time, press «Продолжить» on the start screen and allow the camera. On the phone, trust the developer in Settings → General → VPN & Device Management.

Unit tests: `cd GazeCore && swift test` (Mac or Linux). Camera code only works on a device; ARKit face tracking does not run in the Simulator.

## How it fits CLAUDE.md

| Module | Files | Notes |
|---|---|---|
| GazeCore | `GazeCore/Sources/GazeCore` | Matrices, coordinate transforms (all in `Transforms.swift`), gaze ray to screen plane, ridge calibration, One Euro, accuracy metrics, balance config, the full game model. No UIKit/ARKit. |
| Tracking | `SpantherGaze/Tracking` | `FaceTracker` runs ARKit off the main thread and picks the fastest video format the phone offers (CLAUDE.md asks for 60 fps; the first iPhone 13 session ran at 30). It reports that format, the thermal state and Low Power Mode to the debug overlay and the CSV. `PupilDetector` protocol with a Vision implementation; MediaPipe can be added behind the same protocol to compare on the same recordings. |
| Screens | `SpantherGaze/Screens` | Menu, 9-dot calibration, 13-dot check (error and jitter in pt, cm and degrees), SpriteKit game, debug overlay. |
| Logging | `SpantherGaze/Logging` | CSV exported only through the Share button: calibration/check samples, every tracked frame of an eye game (`frame`: features, gaze, raw `eyeBlinkLeft/Right`, gaze-hold flag), every meteor outcome, `blink` / `energy` / `reload` events, `tracking` rows (camera format, formats offered, thermal state, Low Power Mode) at the start of a session and on each change, and each frame's processing time (`proc_ms`). |

## Gaze pipeline

1. ARKit gives the face pose, both eye transforms and `lookAtPoint`. Two rays per eye (through `lookAtPoint`, and along the eye's own axis) are intersected with the screen plane (camera z = 0).
2. Feature vector: both ray hits, quadratic terms on the `lookAtPoint` hit, and Vision pupil offsets when "Зрачки через Vision" is on. A pupil result stays usable for 0.3 s; with none, the pupil features count as the calibration average. Head pose is not a feature: the hits already move with the head and the phone, and as separate features the pose terms made the aim follow the phone when it moved (see `GazeFeatures.vector`).
3. 9 dots, about 1 s of samples each. The player is told they may move their head a little, which lowered error in the study cited in `docs/eye-tracking-options.md`.
4. Ridge regression maps features to screen points; a One Euro filter smooths the result. Each feature is clamped to its calibrated range plus 25%, so the quadratic terms cannot throw the aim thousands of points away.
5. When the `lookAtPoint` hit is further outside its calibrated range than the range itself, the player is looking away from the screen: the aim hides (`notLooking`) instead of flying off, and the filter restarts.
6. 13 new dots measure mean error and jitter. The hit zone is drawn radius + that error, clamped to 30–115 pt.
7. The aim adapter (`GazeAdapter` in `GazeCore/Adapt.swift`) adds a small correction to the ridge prediction, before the filter, so the aim stays on target when the phone is held at another tilt than at calibration. See below.

## Head-frame gaze model (the phone moved or tilted)

Added after the warm-up of 16 November 2026 (iPhone 13), where the figure of eight scored 24%. In that session's CSV the phone's tilt drifted 14 degrees in a minute and the ridge model's vertical aim moved about 85 pt per degree of it: the model reads the rays' hits on the screen, a hit is the head's own direction plus the eyes' turn, and the calibration's gain (ARKit sees about a half of the eyes' turn across and a third up and down) scales the head's part up too.

- `HeadGazeModel` (`GazeCore/HeadGaze.swift`) is fitted inside the head instead: a linear map from the eyes' measured direction in face space (the `lookAtPoint` ray, two angles) to the direction they must really have to see each calibration dot from where the eyes were. A frame is answered by geometry: the corrected direction, turned by the head's rotation, cast from between the eyes onto the screen's plane. No pupils and no squares in it.
- Both models are fitted at every calibration. The head-frame one plays unless its mean miss on the 13 check dots is more than 1.25 times the ridge model's (`GazeModel.choose`). The other model's aim is written on every frame (`alt_x_pt`, `alt_y_pt`) next to the playing model's own (`raw_x_pt`, `raw_y_pt`), and a `model` row says which one plays and both misses, so one session compares them. Sample rows also carry the point between the eyes and the look angles (`eye_*_m`, `look_*_rad`), enough to fit the model again offline.
- Under the head-frame model the aim adapter starts with no assumed follow of the head (`followPitch` and `followYaw` 0); it still learns a bias and slopes from labels.
- Warm-up only: while the model's own aim travels with the dot (`FollowGate`: correlation and travel over the last 1.2 s), the dot teaches the adapter like a meteor being burned. So the warm-up's score now includes that help; the probe gets none. `pursuit_end` rows count the frames taught (`taught`).
- Warm-up: after 0.5 s without a face the dot and the minute wait, with a hint, and go on with the first frame that has the face.
- Not confirmed on a phone yet. It is checked on simulated geometry only (`HeadGazeTests`: nods, turns, nearer, further, the phone moved aside), because older CSVs do not hold the eyes' position.

## Aim adapter (the phone held differently)

In the first iPhone sessions the aim slid when the phone's tilt changed after calibration. The ridge model is fitted at one grip, and the lookAt hits and pupil offsets it reads shift a little with the head's angle to the camera. The model itself is unchanged; on top of it:

- correction = b + B · (head pitch and yaw − the calibration's mean pose), per screen axis. `b` takes a slow drift, `B` how the aim moves with tilt, so a new tilt is corrected before the next label.
- `B` starts from physics, not from zero: the raw aim follows a turn of the head against the phone by a share of that turn projected on the screen (calibration distance × angle × 60 pt/cm). Aziz's rhythm session of 7 November showed a share of 1.25–1.6 for pitch (36–47 pt per degree at 27 cm) and about 0.7 for yaw; the defaults are 1.0 and 0.5, and labels refine them. Labels almost never come at different tilts, because players hold still while they aim, so a `B` learned from labels alone stayed near zero and the tilt went uncorrected.
- It is learned from moments when the game knows where the player looks: the 13 check dots (a warm start), the rhythm start star and every rhythm note winked in its window (the median raw aim over the 0.3 s before the eye closed), and the meteor being burned in the eye game (each frame at 1/20 of a label's weight).
- Labels lose half their weight every 15 s, a prior keeps the bias at zero and the tilt terms at their starting values until there is evidence, a label further than 180 pt from both the corrected and the raw aim is left out, and the correction is capped at 300 pt.
- Menu toggle «Подстройка прицела под наклон» turns it off to compare. The debug overlay shows the correction, labels learned and left out; the CSV has `label` rows and the correction on every frame (`corr_x_pt`, `corr_y_pt`).
- `GazeReplay` replays it on a session (prequential: each label is predicted before it is learned) and prints the mean distance to the labels without and with the adapter, by source and by head pitch, and a sweep over the starting pitch and yaw shares. On Aziz's rhythm session the rhythm notes were 1.19 cm from the raw aim, 0.47 cm from the aim corrected by the adapter as it was before the starting slope, and 0.36 cm with it.

## Replaying a session (CLAUDE.md rule 7)

Export the CSV on the phone (menu, «Экспорт CSV последней сессии»), then run the current GazeCore code over it:

```
cd GazeCore && swift run GazeReplay ~/Downloads/spanther-2026-11-05_01-13-16.csv
```

It refits the calibration for each feature set and prints the check error, how often the aim leaves the screen in each level, how often the player counted as looking away, and the blink detector's blinks and reloads next to the ones the app logged. For files recorded after 4 November 2026 it also prints the camera format, thermal state and frame processing time. Use it to compare tracking changes on the same recording instead of a new attempt. Session CSVs are face data: keep them out of the repository (rule 5).

## Gameplay (all from balance.json)

- Progress drains to zero over 1 s when the gaze leaves; tracking dropouts under 150 ms freeze it; after 1 s without a face the game pauses with "Посмотри на экран".
- The meteor being looked at slows down by 40% on levels 1–3 and 20% later.
- 10 levels of 45 s on the S-curve from BALANCE.md, 5 Earth shields, no game-over screen: running out of shields restarts the level a little easier.
- Kill ratio at the end of a level: 80% or more advances, under 50% repeats easier, in between repeats at the same difficulty (BALANCE.md does not say; this is my default).
- "Играть пальцем" uses the same rules with a finger on the meteor.
- Energy pool of 10; a kill costs S 1, M 2, L 3, XL 5. A meteor you cannot afford gets a red ring, the aim on it turns red, and it makes no progress. Three blinks within 2 s (or three taps on the energy bar in touch mode) refill the pool. `BlinkDetector` in `GazeCore/Energy.swift` reads ARKit `eyeBlinkLeft/Right`; while the lids close the gaze point is held so the aim does not dip.

## Small targets, red signs, music and the warm-up

Added on 10 November 2026 for a demonstration at a rehabilitation centre. All four are switches or a button in the app, and all numbers are game results: nothing here is a validated measure of anyone's attention.

- «Мелкие цели» (settings, on by default): `targetScale` 0.7 in `balance.json` makes every meteor, red sign and rhythm star 30% smaller, with its dial and mark, and multiplies the hit zone by the same 0.7. The zone has a floor: it never gets smaller than `minZonePerError` (1.25) times the miss the calibration measured on its check screen, because a zone smaller than the tracker's own error cannot be hit on purpose. With a miss above about 41 pt (0.7 cm) the floor is what decides for the smallest meteor. The calibration result says which zone applies.
- «Красные знаки» (settings, on by default; `decoys` in `balance.json`): about every 8 s a red "no entry" sign drifts in like a meteor. A look that rests on it for 0.25 s (`errorDwellSec`) is an error: the sign fades, a quiet line says «На красный знак не смотрим», and the counter in the top row goes up. Nothing flashes, shakes or buzzes. Frames inside a blink do not count toward the 0.25 s. This is a go/no-go style distractor, not the antisaccade test of the eye-movement literature (that one asks for a look to the opposite side of a sudden target and times it).
- Music: `GazeCore/Ambient.swift` makes a pad from sine tones with a few overtones (a D major chord set that changes every 14 s, three single notes now and then, a 2.2 kHz low-pass, no percussion), played by `Audio/AmbientPlayer.swift` through `AVAudioEngine` on its own queue. It fades in over 2.5 s when the meteor game starts and out over 1.2 s on pause, on the menu and in the background. The speaker button in the game and «Музыка в метеоритах» in the settings switch it. It stays silent while another app plays music.
- «Разминка» (menu): for 60 s one dot glides along a horizontal line, a vertical one and a figure of eight (20 s each, `GazeCore/Pursuit.swift`). Every tracked frame the distance from the gaze to the dot is counted; the result is the share of frames within 60 pt plus the calibration's miss (clamped to 30 to 115 pt), with the second around each change of path left out. The session CSV keeps every frame (`pursuit_frame`), so another radius can be replayed on the same run.
- The summary after every play shows the same four numbers in the same order: gaze held, timing deviation in the rhythm (ms), looks at red signs, and each eye's winks that played a note. A game that does not measure one shows a dash. «Таблица CSV» at the bottom shares that play as one row with the date, the time, the game and the numbers; «Занятия» keeps sharing the table of all plays.

## Wink test (groundwork for the rhythm mode)

Menu, «Тест подмигиваний». A click sounds every second and the screen lights the eye to wink on it: 20 left, 20 right, then 20 alternating, about 72 s. The result screen shows, per eye, how many cues the detector caught on the asked eye, the mean timing offset and its spread, how many hits land within ±100, ±180 and ±250 ms once that offset is removed, and how far the other eye squinted. «Отправить CSV» exports the session. `WinkDetector` in `GazeCore/Wink.swift` reads the same ARKit `eyeBlinkLeft/Right` values as the reload blinks: an eye is closed at 0.6 or its open level + 0.3, and both eyes closing within 25 ms (or 1.5 frames at a lower frame rate) is a blink, not a wink. Natural blinks close both eyes within 0–17 ms; in Aziz's wink test the other eye often followed a wink 2–3 frames later (33–50 ms), and those stay winks. `GazeReplay` reads the test's `wink_frame`, `cue` and `wink` rows and replays the detector at close thresholds 0.5, 0.6 and 0.7 on the same run.

## Rhythm mode

Menu, the «Ритм» plate. An original rhythm game drawn as a star atlas on warm paper (light paper also lights the face for the camera). Stars appear to the beat; a dial hand goes round each one and reaches the red mark at 12 o'clock on its beat. The player looks at the star and closes an eye then. Notes hit in a row join into a constellation, and the results screen shows it as a plate.

- Start: «Посмотри на звезду и подмигни». The wink on the start star (or a tap) starts the music 1 s later and gives the aim adapter its first label at the current grip.
- No visible aim. A cursor that sits a little off the spot the player looks at pulls the eyes after it, and both drift off together. Instead the star the aim is near lights up (a warm wash under it, and the star grows a little) and holds the aim: `GazeLock` in `GazeCore/Lock.swift` locks the nearest star within the level's hit zone, keeps it until the aim is 1.4 zones away, another star in reach is clearly closer, or the aim has been gone for 0.35 s. A wink plays the locked star, even where an earlier note's window holds the wink too. `GazeReplay` replays the lock over a recorded play: on Aziz's of 7 November it was on the note he winked at in 24 of 24 winks, and it changed 54 times over 25 notes, so the light barely flickers. The aim is drawn only with «Отладка» on.
- Levels: easy plays the strongest accents, at least 1 s apart, and also takes an ordinary blink, for players who cannot wink yet. Normal plays more notes with either eye. Hard plays all accents up to 2 notes/s, and a note on the left half of the screen needs the left eye, on the right half the right eye.
- Judging (`RhythmJudge` in `GazeCore/Rhythm.swift`): windows ±90 / ±160 / ±240 ms («Точно», «Хорошо», «Есть»), on the onset of the closure minus the player's delay. The aim must be within 90 / 70 / 55 pt + the check error (up to 90) of the note. The delay starts at 0.12 s, is seeded by the wink test and learned in play.
- By finger: the hand button next to «Играть». A tap plays the note under the finger as a wink of that side's eye. It is the only way on iPhones without face tracking.
- Tracks: three CC0 tracks composed for the game by `Tools/compose_tracks.py` («Орбита» 88 BPM, «Звёздная пыль» 104, «Метеоритный дождь» 124, about 1–1.5 min). The script writes the `.m4a` files into `SpantherGaze/Resources` and `tracks.json`: tempo, first beat and an accent list (beat, strength 1–3) from the score, which the notes follow. To use another song, put the file in Resources and give its tempo and first beat in `tracks.json`; without accents the notes follow a fixed pattern on the beats. `RhythmTests.testBundledTracks` checks the bundled tracks.
- CSV rows: `rhythm_start`, `note_hit` and `note_miss` (judgement, timing offset, aim distance, eye, the locked note), `rhythm_end`, `label` and `rhythm_frame` (with the locked note in `locked`: its index, -1 for the start star).

## Sunlit look (since 2026-11-16)

`Screens/Atlas.swift` holds the look of every screen but the wink test: Aziz's palette (emerald 47A851, sky 388EE8, sandstone gold E8A838, cream FBF4E2, ink 1D1A17 in 2 pt outlines, amber energy FF8A1E for the gaze; vermilion only for danger), heavy rounded type for titles and callouts, tabular digits (`Atlas.metric`) for every number a clinician or parent reads. Shapes are cel style: flat fills on hard ink shadows (`InkSlab`), slanted buttons and chips (`Slant`), plates with two corners cut (`CutPlate`) laid on a colour slab. Motion uses one spring (`Atlas.snap`, response 0.28, damping 0.72): screens spring in from the right (`RootView`), cards land one after another (`kineticEntrance`), the chosen item pops (`selectedPop`), numbers roll (`rolling`, `RollUp`). Reduce Motion turns the movement into fades. The menus stand on `SunlitBackdrop` (sky, a cel sun, a thin strip of far grass). The general techniques (cel shading, ink lines, angled panels, fast springs) are used; nothing is taken from any particular game.

The probe's 90 seconds keep their frozen look v1 (`ProbeLook`: the old paper, ink, amber and serif type) and no screen transition runs into the probe, so session 1 and session 30 show the same stimulus; only its end screen has the new look.

### Streaks and celebrations

Every game keeps a streak (GazeCore `Streak`, tested in `StreakTests`): meteors count stones burnt in a row and break on a stone that reaches Earth or a look at a red sign; rhythm follows the judge's combo (a miss breaks it); the warm-up counts two seconds on the dot as one lock and breaks after 0.4 s off it (`FollowStreak`). `Screens/Celebration.swift` shows it: an angled ink counter «×7 подряд» that kicks on each lock, and at 5, 10, 15, 20 and every 5 after, a banner in Russian (×5 · ФОКУС!, ×10 · ВЗГЛЯД МАСТЕРА!, ×15 · ГЛАЗ БЕРКУТА!, ×20 · ВЗГЛЯД ПАНТЕРЫ!), cel fireworks from a pool of four at the lock's place (about 130 pt across, nothing flashes, off with Reduce Motion), an arpeggio up the pop's pentatonic scale (`Audio/StreakChimes.swift`) and rising haptic taps (`Haptics.milestone`). The rhythm game has no chime, so the beat stays clear. The probe keeps no streak: its end screen alone gets three fireworks, the chime and the haptics, after the 90 seconds.

### Victory screen

After every meteor, rhythm and warm-up play `Screens/VictoryView.swift` comes before the report (on the menu, and over the rhythm results): fireworks, a rank stamp that slams down (GazeCore `VictoryRank`: S from 90% of the play's main share, or 80% with 15 in a row; A from 65% or 10 in a row; never less than B), the stars it brings (S 3, A 2, B 1) and the Steppe Observatory they build: eight landmarks open one by one (Каменный круг, Солнечные часы, Юрта звездочёта, Астролябия, Башня ветров, Лунное зеркало, Купол, Большой телескоп) and the panther cub gets four gifts (шарф, звезда, шапка исследователя, подзорная труба). The share is meteors burned, the rhythm accuracy, or the warm-up's time near the dot (`SessionSummary.victoryShare`). Each child's stars are kept on the phone (`ObservatoryStore`, UserDefaults) and deleted with the child's plays. The cub is drawn simply in code (`PantherCub`); an illustrator's sheet can replace it. The probe has no rank: its end screen shows the cub and the fireworks only.

## Living garden and distractions

The rhythm mode's star atlas look (ink on paper, one vermilion, serif titles) was the look of every screen from 2026-11-09 to 2026-11-16. The menu shows the SPANTHER mark (its hold ring draws itself in at launch), the two games as plates with small animated vignettes, and the switches.

- The meteors: ink-outlined rocks with engraved hatching that warm to vermilion while they burn, a dial round each like a rhythm note's, and Earth as an engraved globe edge. No aim is drawn (only with «Отладка»): the meteor being looked at gets a warm light under it, the way the rhythm mode lights its notes.
- The living garden (`GazeCore/Garden.swift`, drawn by `Screens/LivingBackground.swift`): lianas hang from the top edge and sway, two branching trees grow from the bottom corners with node dots where they fork, spores drift up, and light pulses run down the lianas. One seed for every screen, so the garden stays put while the screens change in front of it. The lianas in the middle third end above the notes. The look is original; the reference screenshots Aziz sent were for mood only.
- Distractions (rhythm play only, `DistractionPlan`): a firefly crossing, a flower opening at a liana's tip, a seed spinning down, a surge up a branch, a liana swinging. About every 7.5 s on easy, 4.5 s on normal and 2.8 s on hard; below hard they keep to the margins outside the note area, on hard some cross it. They are the same on every play of a track and level, and each one is a `distraction` CSV row (kind and where it began), so a replay can see whether the gaze went to it.
- Wink hints: a closure that lands in a note's window but cannot play it says why under the note («одним глазом» for a blink on normal and hard, only when it came on the beat; «левым глазом» / «правым глазом» for the wrong eye on hard). On 7 November Aziz closed both eyes on 15 of 34 closures in an easy play, which counts there and was silently ignored on the other levels. CSV: `note_reject` rows.

## Night vision

Menu switch «Ночное зрение», for a dark room. ARKit's face tracking needs some light (an Apple engineer on the developer forums: it does not work in total darkness), and in a dark room the only light on the face is the screen's. So night vision:

- turns the screen to full brightness on every screen but the menu, and gives the player's brightness back on the menu and when the app leaves the screen;
- runs the camera at its slowest offered frame rate (30 fps on the iPhone 13) so each frame can be exposed twice as long, and lets the exposure aim one stop brighter (with low light boost where the camera has it);
- drops the Vision pupils, which are not found in the dark: the model calibrates and plays on `eyes` features. Switching it asks for a new calibration.

Every tracked frame now logs ARKit's light estimate (`light_lm`, about 1000 in a lit room), and `tracking` rows say whether night vision was on (`night`). The calibration screen warns when the face is not found in the dark or the light is low.

## Sessions and the report

Menu, the «Занятия» button at the top. For the specialist and the parent: game results only, no face data and no diagnosis, and the screens say so.

- Child code: the specialist gives each child a code (for example К-07) instead of a name. Every play is saved under the code set when it started. The code is kept between launches.
- A meteor play is one visit to the game screen. When it closes, the menu shows its summary: the four numbers (see above), then meteors burned of those that left the play, the mean time from a meteor's appearance to the first look at it (by finger, the first touch), slips per meteor (the gaze left long enough for the burn to drain to zero), the highest level, the time on screen, and the check error of the calibration before it. A rhythm play is saved when its track ends: accuracy, notes played, perfect ones, the best combo, and winks that played no note. A warm-up is saved when its minute ends.
- History: the plays of the code, newest first, and for each game the first and the last of the plays that compare (same control, the same target size, and for the rhythm the same level). «Таблица» shares one CSV of all plays, laid out for a Russian spreadsheet (semicolons, decimal commas, UTF-8 with a byte order mark). Delete removes the code's plays from the phone.
- Storage: `Application Support/sessions.json` (`App/SessionStore.swift`), written when a play ends and when the app leaves the screen mid-play. The numbers come from `GazeCore/SessionReport.swift`, tested in `SessionReportTests`.
- CI: the bots' meteor play, rhythm track and warm-up must show up in `sessions.json` with their numbers, and `-SpantherDemoReport summary|history|settings` (Debug only) opens the report or the settings with made-up plays for the screenshots.

## Clinician build (phase 1 of the clinical architecture proposal)

- **Who is playing** (menu, the person button): the children's emblem tiles. Face ID or the device passcode opens the clinician's side: children (centre code, nickname, emblem, birth year), courses (25, 30 or any number of sessions, at the centre or at home), procedure marks, session tags and voiding, the charts and the export. A parent PIN, set by the clinician, opens a summary in plain words. Records are append-only logs per child (`GazeCore/Clinic.swift`, `ClinicStore.swift`) with complete file protection; the plays of `sessions.json` move into them once.
- **The probe** (`App/ProbeSession.swift`, `Screens/ProbeView.swift`): «Начать занятие» runs the frozen 90-second probe of `GazeCore/Probe.swift` (a new form from a fresh seed, one whose zone order this child has not seen, the same difficulty), laid out in degrees at the eyes' distance, scored by `ProbeRun`, with one fixed look and one fixed sound (feedback set 1). The quality gate (calibration error, distance, tracked frames, frame rate, a full run) decides whether the session goes on the trend; a failed one is kept and drawn hollow. The session's raw CSV is stored next to the child's log.
- **Charts and export** (`Screens/CourseCharts.swift`, `App/ClinicExport.swift`): one Swift Chart per metric over the course's sessions with the baseline band, the Theil-Sen trend and its 90% interval and the procedure marks; the course card compares the last three sessions with the first three in units and in MDC. The measurement error is the centre's own preliminary estimate until the test-retest study, so no change is coloured yet. Export: per-course PDF, the Excel table (semicolons, decimal commas) and a zip of the raw CSVs with a data dictionary (`GazeCore/ZipArchive.swift`).
- **The pop** (`GazeCore/Sources/Feel`, `Screens/StoneNode.swift`, `Screens/SceneArt.swift`, `Audio/`): sky-stones baked with Core Graphics (three tones, an ink line), engraved rings that align over the hold, cracks that grow from the gaze point along the edges the stone will burst on (Voronoi pre-fracture at hold start, off the main thread), a 60 ms squash, shards under a small integrator, dust and motes into a jar. Four sound layers (crack, pop, modal chime on a D major pentatonic ladder, crumble) synthesised at the start of a play and played on the app's one `AVAudioEngine` (12 voices, a peak limiter; the pad and the wink test's clicks moved onto it), and one `CHHapticEngine` with charge, crack and thud players.
- **Tracking and rendering**: ARKit runs the smallest 60 fps format; the face's square is copied into a buffer of our own pool for Vision through a latest-only mailbox, so the ARFrame is let go at once; signposts mark the frame, the crop and Vision. The meteor screen is one opaque SpriteKit view that draws the garden itself (baked layers and a wind shader).

## Start screen and the session's one calibration

- **Start screen** (`App/StartGate.swift`), at every launch, after the force update screen and before anything else: what the app does with the camera and data, the privacy policy link, and why the camera is needed, in Russian, Kazakh and English (switch on top, first match of the iPhone's languages, kept between launches). «Продолжить» asks for the camera when it was never asked. While the camera is refused or restricted the warning stays, the button opens Settings and nothing leads on to the menu; iOS ends the app when the camera permission changes in Settings, so the next launch, or the return to the front, goes on by itself. Face tracking (and so the camera) starts only behind this screen. An iPhone without face tracking passes with a finger-only note. The system's own camera question (`NSCameraUsageDescription`) stays in Russian.
- **One calibration per session** (`AppModel.calibration`, a `SessionCalibration`): made right after the start screen and shared by the meteors, the rhythm mode, the warm-up and the probe. The modes no longer calibrate on their own; they ask only when there is none (the first one was left with «Назад»). «Перекалибровать» on the menu and «Калибровка» in the meteors' pause make a new one; leaving it before its check dots end, or a fit that fails, keeps the old one with what the aim had learned and its CSV. Another child on «Кто играет?» drops the calibration and starts the new child's own one at once; the probe runs only on the playing child's calibration. Night vision drops it too, since the model then reads other features.
- **Kept between launches** (`StoredCalibration`, UserDefaults key `keptCalibration`): iOS ends an app it has sent to the background whenever it wants the memory, so coming back is often a new launch. The calibration's fitted numbers (both models' weights, the check's misses and report, the grip; no camera frame) are kept on the phone, and a launch plays on them again when they are the same child's, with the same night vision setting, on the same screen and build, and less than 12 hours old (`AppModel.restoreKeptCalibration`). The aim adapter starts afresh and learns again in play. Another child or night vision forgets them; a new calibration replaces them.
- Debug launch arguments: `-SpantherGate pass|ask|denied|restricted|allowed|unsupported` (`pass` skips the screen, the others hold it in that state for screenshots) and `-SpantherGateLanguage ru|kk|en`. `-SpantherAutoplay` and `-SpantherDemoReport` skip the screen and the session's calibration. CI shoots the screen in each state (`gate-*.jpg`, `gate-denied-kk-se.jpg` on the iPhone SE).

## Unverified on device

- The start screen and the one calibration: the camera question from the button, the way back from Settings, the first calibration right after the screen, and whether the menu's recalibration is found when the player moves. Simulator screenshots only. The Kazakh copy needs a native speaker's read.

- The whole clinician build: the probe on a real face, the quality gate's thresholds on real sessions, Face ID, the export files opened on a computer.
- The pop: its look on the phone, the lock-to-sound latency (goal: 20 ms or less), the bank's build time and memory (about 8 MB), whether 7 of 10 children prefer it.
- The face crop: whether it lands on the face in every way the phone is held (the debug overlay's vision line and the pupil share in the CSV tell), and whether the smallest 60 fps format keeps the pupils good enough.
- The garden inside SpriteKit: its frame rate cost and whether the baked layers look like the menu's garden.

- The report screens: seen only in Simulator screenshots so far.
- Small targets, red signs, the warm-up and the new menu: Simulator only so far. Whether a child can still hit a 30% smaller meteor with their calibration, whether 0.25 s is a fair threshold for a look at a red sign, and whether 60 pt plus the miss is a fair radius for the warm-up all need a phone and real players.
- The music: nobody has heard it on a phone. Its level and spectrum were measured from the rendered samples (about -22 dBFS RMS, almost nothing above 2 kHz), and the engine's start is checked in the Simulator only where the runner has a sound device.

- Night vision: whether the screen's light is enough for ARKit in a dark room, the accuracy without pupils, and the 120 lm threshold of the "dark" hint.
- The garden's cost on the frame rate, and whether the distractions are fair for children. It is drawn in its own layer at 30 fps and rasterised off the main thread: at 60 fps on the main thread it slowed the CI simulator a lot (a screenshot took 4 to 9 s instead of 2.6), and on the phone the main thread also receives every tracking frame. Check `track fps` in «Отладка» on the menu, the meteors and the rhythm play.
- The portrait axis mapping in `Transforms.cameraPlaneToPortrait` and the Vision image orientation `.leftMirrored` are best guesses. Calibration absorbs axis mix-ups, but check them in the debug overlay.
- 60 pt per cm is assumed for cm figures (current iPhones are 60–64).
- Blink thresholds (0.6 closed, 0.35 open, 50–500 ms) are starting values and need tuning on real faces, children's especially.
- Winks: whether ARKit's `eyeBlinkLeft` is the player's left eye, how much the other eye closes during a wink, and the delay from a click to the wink onset. The wink test measures all three.
- The aim adapter's numbers (15 s half-life, 180 pt gate, 300 pt cap, the starting tilt shares 1.0 and 0.5, the meteor label weight) are starting values. Compare the toggle on and off on the same session with `GazeReplay`.
- The rhythm lock's numbers (release at 1.4 hit zones, switch at 0.6, 0.35 s grace) are starting values, and whether players find the notes without a visible aim needs a try on the phone.
- Rhythm mode: the music's start against the camera clock (`AVAudioPlayer.play(atTime:)` minus the route's output latency; Bluetooth headphones add 0.15–0.25 s), the judging windows and the note density for children.
