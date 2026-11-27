# Stage preview

A look at the arcades' 3D scenes without a phone or a Mac: GazeCore writes one frame of each scene as JSON and
three.js draws it close to the Metal stage (toon bands, shadows, ink outlines, the see-through pond). Composition,
sizes and colours only; the real shading is `SpantherGaze/Arcade/ToonShaders.metal`.

```
cd SpantherGaze/GazeCore
STAGE_DUMP=../tools/stage-preview swift test --filter StageDumpTests   # writes moles.json and pond.json
cd ../tools/stage-preview
npm install three@0.187 && python3 -m http.server 8766 &
node shot.cjs            # moles.png and pond.png (needs Playwright with Chromium)
```

The JSON files and PNGs are not committed.
