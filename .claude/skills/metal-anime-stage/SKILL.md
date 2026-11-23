---
name: metal-anime-stage
description: The custom Metal renderer for Wink Beat's 3D anime stage (toon world, play layer of SDF rings, orbs, sliders and spinner petals, hit effects, bloom, speed lines) at 60 FPS next to front-camera ARKit tracking. Use when building or changing anything Wink Beat draws behind its SwiftUI HUD, or its shaders, frame budget or thermal steps.
---

# Metal stage for Wink Beat

Agreed with Aziz on 2026-11-23: a custom Metal renderer, not SceneKit (deprecated by Apple in 2025), RealityKit or
Unity. Reason: the play field is rings and orbs that shaders draw cheaply, and heat is the hard limit while the camera
tracks. The game (objects, zones, judging) lives in `GazeCore` (`WinkBeatMap`, `WinkBeatPlay`) in 2D screen points;
the stage only draws what the judge decided and must be switchable off with the mode still playable.
Shader and math-heavy work: Aziz allows the stronger model for shaders only; tell him when you switch and switch back.

## 1. Host and frame loop

- One `MTKView` (through `UIViewRepresentable`) behind the SwiftUI HUD. `preferredFramesPerSecond = 60` even on
  120 Hz screens, `isPaused = true` outside play and results, `framebufferOnly = true`, `colorPixelFormat = .bgra8Unorm_srgb`.
- Three frames in flight: a `DispatchSemaphore(value: 3)` and ring buffers for uniforms and instance data. No buffer,
  texture or pipeline is created inside `draw(in:)`.
- Every position comes from the track clock (`avaudio-rhythm-sync`): approach ring scale, slider orb, petal glow and
  beat pulses are functions of `t`, never accumulated deltas or timers.
- Build all `MTLRenderPipelineState`s when the song loads and draw one warm-up frame with every pipeline before the
  music starts, so no shader compiles mid-song.
- The ARKit session stays the app's existing one (`Tracking/`). The stage never shows the camera or owns the session.

## 2. Layers, back to front

1. **World (true 3D, toon):** sky dome (vertical gradient in the daylight palette plus soft cel clouds as billboards),
   low-poly floating islands and shards. Toon shading in 3 bands (`step` on N·L at 0.25 and 0.6, mapped to three
   palette tones, never grey), a hard rim (`step(0.6, pow(1 - N·V, 3))`), ink outlines by inverted hull (front-face
   culling, vertices pushed along the normal by a view-space width, ink `#1D1A17`). Pulses to the beat track.
   Head parallax moves only this layer: yaw and pitch from the face anchor relative to the calibration pose, smoothed
   with `OneEuro`, clamped to about ±6°, mapped to a 2–4° camera orbit.
2. **Play (screen plane, zero parallax):** instanced quads with signed-distance shaders: hit circle, approach ring,
   slider body (a triangle strip along `WinkBeatPath` samples with an SDF edge in the fragment shader), slider orb and
   ticks, spinner ring with 8 petals, lock highlight. Positions are the judge's screen points, so a head tilt never
   moves a target. Anti-aliasing comes from the SDF (`fwidth`), so no MSAA is needed.
3. **Effects:** hit bursts (pooled particles, CPU-updated instance ring buffer, at most about 400 alive), shockwave
   rings, judgement stamps, speed lines (one full-screen shader, only at combo milestones), slash wipes.
4. **Bloom:** half-resolution, only the effects layer: threshold, two separable blur passes, add. Off at "serious".
5. **HUD:** SwiftUI on top (`swiftui-anime-ui`).

## 3. Look

- Daylight anime on the app's sunlit palette (agreed decision 2): emerald `#47A851`, sky `#388EE8`, gold `#E8A838`,
  cream `#FBF4E2`, ink `#1D1A17`, energy `#FF8A1E`. A bright screen also lights the face for tracking in dim rooms.
- Glow only as soft light around a hit and the locked object; never neon outlines, never a dark background with
  glowing edges.
- Original shapes only: no stages, effects, skins or icons recognisable from any existing rhythm game or anime.
- Safety: flashes under 3 per second, never full screen; Reduce Motion turns off speed lines, shakes and parallax.

## 4. Frame budget and heat

- Per 16.7 ms frame on an iPhone 13: GPU stage under 5 ms, CPU stage work under 2 ms; tracking and Vision keep the
  rest. Minimum device A12.
- Cheap by design: no real-time shadows, one directional light (bands come from the shader), meshes under about
  2 000 triangles in total, about 10 draw calls, bloom at half resolution.
- Thermal steps from `ProcessInfo.thermalState`: `.serious` turns off bloom and parallax and halves particles;
  `.critical` hides the world layer and keeps the play layer flat. Drop to 30 FPS only if tracking falls under 55 fps
  for 2 s. Tracking always wins.
- Log fps, GPU frame time (`MTLCommandBuffer.gpuEndTime - gpuStartTime`) and thermal state to the session CSV.
  Nothing counts as within budget until Aziz's 10-minute CSV shows it; CI has no GPU numbers.

## 5. Code layout

- `SpantherGaze/WinkBeat/Stage/` for Swift and `.metal` files. Each shader file starts with a comment naming its
  inputs, their units and coordinate spaces.
- `half` for colours, `float` for positions. Uniform structs shared through one bridging header file.
- Pure math that can be tested (parallax mapping, layout of the field, burst timing) goes in `GazeCore` with tests.

## Checklist before a PR

- [ ] The mode plays with the stage off.
- [ ] No allocation, pipeline creation or texture load inside `draw(in:)`.
- [ ] Every animated value is a function of track time.
- [ ] Hit positions do not depend on head pose (test in `GazeCore`).
- [ ] Thermal steps and the CSV perf columns present.
- [ ] Original art only; Reduce Motion path checked.
