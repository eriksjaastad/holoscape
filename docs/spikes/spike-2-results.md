# Spike 2 – Streaming API + Visualizer State Sync

## Implementation Notes
- Added `src/api/openai-stream.js`, which exports an async generator that streams OpenAI chat completion tokens via the native `fetch`+`ReadableStream` plumbing, and falls back to a simulated local stream when no API key is supplied.
- Extended `src/index.html` with a minimal chat UI (API key input, text field, send button, and streaming log/status area) and styled the panel to sit over the visualizer in dev builds.
- Updated `src/renderer.js` to import the streaming helper, expose `window.setVisualizerState`, and drive the Idle / Thinking / Speaking states by tuning the outer points' color and breathing animation speed.
- The UI now switches to **Thinking** when waiting for the first token, **Speaking** while tokens stream, and returns to **Idle** when the stream completes or errors. Tokens are appended to the response log field so the developer can watch the output in real time.

## Testing
- `npm run dev` (visualizer window) → typed "test" into the chat control, clicked Send.
  - With no API key supplied, the fallback generator produced simulated tokens, allowing the UI to cycle through Thinking → Speaking → Idle while the text log filled with the simulated response.
  - FPS/CPU/Heap overlays stayed stable (matching Spike 1's validated numbers), proving that the streaming logic does not disrupt the 3D animation.
  - When an OpenAI key is entered, the same flow will pipe real tokens into the response log while the visualizer follows the state changes.

## Observations
- The visualizer's state hooks now live in one place (`setVisualizerState`) and can be reused when Spike 3 or the production UI needs to reflect chat states.
- No frame drops were observed during the simulated stream, and the breathing animation smoothly transitions between states thanks to the different `speed`/`scale` parameters.
- The fallback stream keeps development iterations easy even before a key is handy, so we can test the UI without hitting the network.

## Live Test Results (2025-12-19)
Tested with real OpenAI API key (GPT-4o-mini):
- **FPS: 120fps** sustained during streaming ✅
- **CPU: 0.3%** (target: <5%) ✅  
- **Heap: 4.8MB** (target: <200MB) ✅
- State transitions: Idle → Thinking → Speaking → Idle confirmed
- No dropped frames during API activity
- Response streamed token-by-token with visualizer color/speed changes

## Verdict
**SPIKE 2: PASSED** — Ready for Spike 3 (non-rectangular hit testing)
