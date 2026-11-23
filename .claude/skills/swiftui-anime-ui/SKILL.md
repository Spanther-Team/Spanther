---
name: swiftui-anime-ui
description: High-performance SwiftUI patterns for iOS 17+ (the app targets 17.0 since PR #50) Persona-inspired kinetic anime game interfaces running alongside 60 FPS ARKit tracking. Use when building or changing any Wink Beat screen, HUD, menu, result card or settings panel in SpantherGaze.
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

## 3. Kinetic anime look (Persona-inspired, our own)

Aziz (2026-11-23): the interface should feel like the Persona games and must not look like generic AI output. We take
the energy and the composition techniques, in our own palette and shapes, and copy nothing recognisable.

1.3. Every screen is a composition of layered, tilted slabs with thick ink borders, hard shadows, oversized
numbers and type, and fast snappy motion.

**Composition**
- Layered slabs: 2 to 4 overlapping panels per screen, each tilted 4 to 12 degrees in alternating directions, cut
  corners and a skewed edge (`SlashPanel(cut: 14, skew: 8)` style `Shape`s), never `RoundedRectangle`. Text inside
  a tilted slab can sit level (counter-rotate long text).
- Ink: stroke the same shape with 3 to 4 pt ink `#1D1A17` (`.strokeBorder`), plus a hard offset copy in ink (x 4–6,
  y 4–6) as the shadow. No blur, no soft drop shadows.
- Scale contrast: one hero element per screen at 3 to 5 times the body size (the score on results, the rank letter,
  the combo number, the song title on select). Labels small, numbers huge.
- Type: heavy display type (`.system(size:, weight: .black, design: .default)` or the app's display font), set in
  italics or skewed 8 to 12 degrees, mixing two sizes inside one label (big first word, small rest). Tracking tight
  on numbers, wide on short labels. OFL fonts only.
- Callouts: judgement words (Perfect, Great, Good, Miss) and combo milestones appear as stamps in our own jagged
  burst shape (12 points, irregular radii), slammed in with a scale 1.4 → 1 spring and a 2 to 4 degree wobble.
- Speech-bubble panels for the coach's hints (“Wink when the ring closes”) with an angled tail.
- Transitions: diagonal slash wipes between screens (a skewed ink band sweeps across in 0.22 s, content snaps in
  behind it), staggered slab entrances 0.04 s apart.
- Menus: a vertical stack of tilted command slabs; the focused one grows, shifts right 12 pt and flips to the accent
  fill. Selection pops with the shared spring.
- Results: rank letter stamped huge, score counting up, grade counts on stepped slabs, a slash cut-in band.

**Palette (daylight, agreed decision 2)**
- Cream paper `#FBF4E2` for slabs, ink `#1D1A17` for borders, text and shadows, one hot accent per screen from
  energy `#FF8A1E`, gold `#E8A838`, sky `#388EE8` or emerald `#47A851`. Define them once as statics in
  `WinkBeatPalette`. Left eye sky, right eye emerald, Perfect gold, Miss ink.
- Backgrounds come from the Metal stage (bright sky world), never a flat dark fill.

**What we do not copy (Persona and others)**
- Not the red, black and white scheme as the main look; not ransom-note letters cut from magazines; not star or
  tile patterns, calling cards, masks, top hats or any character, logo, font, icon or menu layout from those games
  (for example the battle command wheel). Not the names of any of their screens.
- No AI-slop tells: no purple or blue gradients, no glassmorphism blur cards, no neon glow, no emoji as icons,
  no evenly spaced rounded cards in a grid, no centred hero text on a gradient.

**Motion**
- One shared spring, `static let snap = Animation.spring(response: 0.28, dampingFraction: 0.72)`, for panels, stamps
  and selections; slams use response 0.22.
- Safety: flashes under 3 per second and never full screen; respect `accessibilityReduceMotion` (swap slams and
  wipes for fades, stop wobbles). Text contrast at least 4.5:1. The audience includes children in a rehab pilot.
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
