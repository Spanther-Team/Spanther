---
name: swiftui-anime-ui
description: High-performance SwiftUI patterns for iOS 17+ anime-styled game interfaces running alongside 60 FPS ARKit tracking. Use when building or changing any Wink Beat screen, HUD, menu, result card or settings panel in SpantherGaze.
---

# SwiftUI anime UI for Wink Beat

Scope: SwiftUI views in `SpantherGaze/SpantherGaze/Screens` and their state holders in `SpantherGaze/SpantherGaze/App`.
Gameplay rules stay in plain Swift in `GazeCore` (no SwiftUI, no ARKit) so they keep running in the Linux tests.
For general SwiftUI rules also load `swiftui-expert-skill`; for actor and Sendable questions load `swift-concurrency`.

## 1. State: Observation, not Combine

1.1. New game UI state uses `@Observable` (Observation framework), never `ObservableObject` + `@Published`.
An `ObservableObject` sends `objectWillChange` for any property, so every view holding it redraws on every
ARKit frame. `@Observable` tracks reads per property, so a view only redraws when a value it read changes.

- Hold an `@Observable` model in the owning view with `@State private var model = WinkBeatModel()`;
  pass it down as a plain `let` (or `@Bindable` when a child needs bindings). Inject shared ones with
  `.environment(model)` and read with `@Environment(WinkBeatModel.self)`.
- Mark the model `@MainActor`. Tracking callbacks arrive off the main thread (ARSession delegate queue):
  hop once per frame with `Task { @MainActor in ... }` or the existing main-queue dispatch, never per property.
- Split state by update rate: a `WinkBeatHUD` model for per-frame values (gaze point, combo, accuracy,
  energy), and a separate session model for slow values (phase, track, level, results). A menu that reads
  only `phase` must not see per-frame writes.
- Put `@ObservationIgnored` on caches, buffers and anything a view never reads (e.g. the raw frame queue).
- Write only on change: `if hud.combo != newCombo { hud.combo = newCombo }`. Observation does not dedupe.
- Existing `ObservableObject` types (`TrackingStatus`, `RhythmSession`) are not migrated as a side effect of
  UI work; migrate one only in its own PR, with the views that read it.

## 2. Keep 60 Hz values in leaf views

1.2. Fast HUD values live in small leaf views or in `Canvas` / `TimelineView` layers. Parent containers
(the screen, the stage `ZStack`, the menu) must never read a per-frame property in their `body`.

- One leaf view per value: `ComboCounter`, `AccuracyBar`, `EnergyMeter`, `GazeCursor`. Each reads its single
  property from the HUD model. Check with `Self._printChanges()` in a debug build: the parent must not print
  while playing.
- Live gaze cursor, approach previews and particle sparks: draw in one `Canvas` inside
  `TimelineView(.animation)`; read the latest value from the model inside the closure. No `ForEach` of
  per-frame views, no `.position` animated per frame on many views.
- Pause the timeline when not playing: `TimelineView(.animation(paused: !isPlaying))`.
- Never use `GeometryReader` inside a fast leaf; measure layout once in the parent and pass sizes in.
- No `AnyView`, no `.id(UUID())`, no formatters created in `body`. Keep `NumberFormatter` / `FormatStyle`
  as static lets.
- `.drawingGroup()` only on a static decorative layer that is expensive to composite, never on text that
  changes every frame.
- Hit timing and judging never depend on SwiftUI redraws: the view shows what the judge decided
  (see `avaudio-rhythm-sync`).

## 3. Kinetic anime look

1.3. Layouts use sharp angled `Shape` containers, thick dark ink borders, high-contrast gradients and fast
springs.

- Shapes: custom `Shape` types with cut corners and skew (e.g. `SlashPanel(cut: 14, skew: 8)`), not
  `RoundedRectangle`. Angle labels and cards by 4 to 8 degrees with `.rotationEffect`, keep the text inside
  readable (counter-rotate if a block is long).
- Ink border: stroke the same shape with `lineWidth: 3` to `4`, colour ink `#14102A`, `.strokeBorder` so it
  stays inside the frame. Hard drop shadow: an offset copy of the shape in ink (x 4, y 4), no blur.
- Wink Beat palette (define once as `Color` statics in one file, e.g. `WinkBeatPalette`):
  - twilight indigo `#1E1B4B` to `#312E81` (backgrounds)
  - cyan `#22D3EE` (left eye, info)
  - sakura magenta `#EC4899` (right eye, combo)
  - sunlit gold `#FBBF24` (perfect, rewards)
  - ink `#14102A`, paper `#FFF7ED` (text on dark)
  Use `LinearGradient` with 2 stops at a steep angle; no more than two accent colours per panel.
  Note: the brand rules say "no neon" for the app as a whole. Keep these accents saturated but not glowing
  (no blur halos, no `shadow(radius:)` glow), and confirm with Aziz before reusing them outside Wink Beat.
- Motion: one shared spring, `static let snap = Animation.spring(response: 0.28, dampingFraction: 0.72)`.
  Use it for panel entrances, selection pops and judgement stamps. Stagger lists by 0.04 s per item.
- Heavy type: `.font(.system(size:, weight: .heavy, design: .rounded))` or the app's display font; tracking
  slightly wide on short labels.
- Safety: flashes under 3 per second and never full screen; respect `accessibilityReduceMotion` (swap springs
  for fades, stop shakes); contrast at least 4.5:1 for text. The audience includes children in a rehab pilot.
- Originality: general techniques only. No names, logos, colour schemes, sounds or layouts recognisable from
  any existing rhythm game or anime.
- All visible text through `L("…")` (Russian key, `Resources/strings.json`, RU/KK/EN). `LocalizerTests`
  fails on unlisted strings.

## 4. Numbers never jitter

1.4. Every score, timer, combo counter, percentage and audio offset label uses `.monospacedDigit()`.

- Give counters a fixed minimum width for their maximum digits so the layout does not shift
  (`.frame(minWidth:, alignment: .trailing)`).
- Rolling numbers: `.contentTransition(.numericText(value: Double(score)))` with the `snap` animation;
  off when Reduce Motion is on.
- Offsets show sign and unit: `+12 ms`, `-8 ms`.

## Checklist before a PR

- [ ] No `ObservableObject` / `@Published` in new code.
- [ ] Parent views do not print in `_printChanges()` during play.
- [ ] All numbers use `.monospacedDigit()`.
- [ ] Reduce Motion path checked; no flashing above 3 Hz.
- [ ] Strings added to `strings.json` in RU/KK/EN.
- [ ] Nothing claimed to work on the phone until Aziz runs it (CLAUDE.md rule).
