# Spike 1 – Performance Measurement

## Test Hardware
- Apple Silicon MacBook Pro on macOS 25.1.0; development build launched with `NODE_ENV=development electron .`

## Measurement Results
- **FPS:** 119.8 fps (steady-state after >60 seconds)
- **CPU (%):** 0.1% (measured while the bubble animation ran for a minute)
- **Memory (heap):** ~4.1 MB (shown in the metrics overlay)

## Pass / Fail
- **60 fps target:** ✅ Pass (120 fps sustained)
- **<5% CPU target:** ✅ Pass (0.1% idle)
- **<200 MB heap target:** ✅ Pass (4.1 MB heap usage)

## Screenshot
See `docs/milestones/` for visual proof of metrics overlay showing 120fps / 0.1% CPU / 4.1MB heap.

## Notes & Observations
- The renderer now sees the `window.hologram.captureProcessMetrics()` bridge, and the metrics overlay correctly reports FPS, CPU, and heap after the earlier sandbox compatibility tweaks.
- The update confirmed the breathing animation keeps 120 fps without perceptible jank, CPU stays near idle, and heap usage is minimal.
- No additional bottlenecks were observed in this spike, but we can revisit GPU loads if we increase particle counts later.

## Recommended Follow-up
- Spike 2 (streaming + state sync) can now reuse this validated rendering foundation.
- Continue monitoring metrics if we add heavier visual effects; logging overlays in dev builds would help catch regressions early.

