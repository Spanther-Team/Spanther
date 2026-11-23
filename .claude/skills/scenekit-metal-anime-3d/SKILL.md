---
name: scenekit-metal-anime-3d
description: SceneKit, RealityKit, and custom Metal cel-shading shaders for 60 FPS 3D anime rhythm visuals on iPhone. Use when building the Wink Beat 3D stage, its orbs, rings, ribbons, particles, camera or shaders.
---

# 3D anime stage for Wink Beat

The 3D stage is decoration and feedback. The game (notes, hit zones, judging) lives in `GazeCore` in 2D screen
points and must work with the stage turned off. Shader and math-heavy work: Aziz allows switching to the
stronger model for shaders only; tell him when you do and switch back after.

## 1. Stage setup and cel shading

2.1. Render the stage behind the SwiftUI HUD with SceneKit (default choice: mature `SCNProgram` and shader
modifiers, runs on all A12+ devices) or RealityKit (`RealityView` + `CustomMaterial`, iOS 18 `ShaderGraphMaterial`)
if a later need justifies it. One renderer per screen, never both.

- Host: `SCNView` through `UIViewRepresentable`, `preferredFramesPerSecond = 60`, `antialiasingMode = .multisampling2X`,
  `isPlaying = true` only during play, `rendersContinuously = false` in menus. HUD is a SwiftUI overlay on top.
- The ARKit session stays the app's existing one (`Tracking/`). The stage is NOT an `ARSCNView`; it never shows
  the camera and does not own the session.
- Cel shading (shader modifier on `.lightingModel = .constant` materials, or an `SCNProgram`):
  - `NdotL = max(dot(N, L), 0)`, quantise into 3 bands: `band = floor(NdotL * 3.0) / 2.0` clamped, or `step`
    thresholds at 0.25 and 0.6 for crisper edges. Map bands to 3 tones from the palette, not to grey.
  - Fresnel rim: `rim = pow(1.0 - max(dot(N, V), 0), 3.0)`, then `step(0.6, rim)` for a hard rim in gold or cyan.
  - Outline: inverted hull. A second geometry copy with front-face culling (`cullMode = .front`), vertices pushed
    along the normal by `outlineWidth` in a geometry modifier, constant ink colour `#14102A`. Width in view space
    so it stays the same on screen. Use edge detection in an `SCNTechnique` post pass only if hulls break on a mesh
    (it costs a full-screen pass).
- Keep shaders in `.metal` files (or modifier strings in one Swift file) with a comment block naming inputs and
  units. Low precision (`half`) for colours.

## 2. Pool everything

2.2. All hit orbs, shrinking approach rings, slider ribbons, shockwave rings and star or petal particle emitters
are created during stage initialisation. Never create or destroy heavy `SCNNode`s, geometries, materials or
`SCNParticleSystem`s during play.

- Pool size from the chart: max notes visible at once (lead time times peak note density) plus 25%.
- Reuse by toggling `isHidden`, resetting `transform`, `opacity` and shader uniforms (`setValue(_:forKey:)` on the
  material). Share one geometry and one material per kind; vary colour with a per-node uniform or
  `geometry.firstMaterial` copies made at init.
- Approach ring shrink: drive scale from track time each frame (`avaudio-rhythm-sync`), never with `SCNAction`
  durations, so rings land exactly on the beat after a stall.
- Ribbons: preallocated `SCNGeometry` with a fixed vertex count, update vertices through a `MTLBuffer` or rebuild
  sources from a reused array; no new geometry per frame.
- Particles: a few emitters made at init, fired with `birthRate` bursts or `addParticleSystem` on a pooled node;
  cap `particleCount`. Flashes under 3 per second, never full screen; respect Reduce Motion (fewer particles,
  no camera shake).
- Warm up at init: render one hidden frame with every material so Metal compiles pipelines before the music
  starts (`prepare(_:shouldAbortBlock:)` on the `SCNView`).

## 3. Head parallax, decoupled from hits

2.3. Camera parallax follows `ARFaceAnchor` head rotation, while the calibrated 2D gaze hit plane is computed
independently, so a head tilt never moves a hit.

- Input: head yaw and pitch from the face anchor transform, relative to the pose saved at calibration.
  Smooth with the existing `OneEuro` filter, clamp to about plus or minus 6 degrees, map to a small camera orbit
  (about 2 to 4 degrees) or a lateral offset. No roll.
- The parallax value is visual only. Gaze aim comes from `GazeModel` / `HeadGazeModel` / `GazeLock` in screen
  points, and notes are judged against their 2D screen positions from `GazeCore`.
- Each 3D orb is placed so it projects onto its 2D note position: compute with the un-parallaxed camera
  (`projectPoint` / `unprojectPoint` against a fixed reference camera), then let the parallax move only
  background layers and depth decoration. Option for orbs at depth: put orbs on a plane at the focus depth,
  where parallax motion is zero.
- Test in `GazeCore`: a pure function `parallax(headYaw:headPitch:) -> CameraOffset` and a test that note hit
  positions are unchanged for any head pose.

## 4. Thermal and frame budget

2.4. 3D rendering runs together with 60 FPS front-camera ARKit face tracking, Vision pupils and audio, without
dropping tracking frames.

- Budget per frame (16.6 ms): tracking and Vision take the most; aim for GPU stage under about 5 ms and CPU
  stage work under 2 ms on an iPhone 13 (Aziz's phone). Minimum device A12.
- Low poly: orbs under about 500 triangles, no real-time shadows, one directional light (bands come from the
  shader), no HDR, no SSAO, no bloom pass (fake glow with an additive sprite), at most one post pass.
- Watch `ProcessInfo.thermalState`: at `.serious` drop MSAA, halve particles and freeze parallax; at `.critical`
  hide the stage and keep the 2D game. Log the step changes in the session CSV.
- Lower the stage to 30 FPS only if tracking fps falls under 55 for 2 s; tracking always wins.
- Measure with the in-app fps readout (`TrackingStatus.fps`) plus Instruments (Metal System Trace) before
  claiming a budget is met. CI has no GPU numbers; nothing counts as working until it runs on the phone.

## Checklist before a PR

- [ ] Stage can be turned off and the mode still plays.
- [ ] No node, geometry or material allocation inside the per-frame path.
- [ ] Hit positions do not depend on head pose (test in `GazeCore`).
- [ ] Thermal fallback steps present.
- [ ] Original art only: no characters, logos or stages from existing games or anime.
