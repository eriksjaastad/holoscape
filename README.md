
<!-- SCAFFOLD:START - Do not edit between markers -->
# holoscape

Brief description of the project's purpose

## Quick Start

```bash
# Setup
pip install -r requirements.txt

# Run
python main.py
```

## Documentation

See the `Documents/` directory for detailed documentation.

## Status

- **Current Phase:** Foundation
- **Status:** #status/active

<!-- SCAFFOLD:END - Custom content below is preserved -->
# Hologram

**A white-label AI chat client with a soul.**

---

## What This Is

Hologram is not just a chat client. It's an **Agent Operating System** that brings the aesthetic ambition of early 2000s music players (Sonique, Winamp) to modern AI interaction.

**The Architecture:** Hub & Spoke (Orchestrator Pattern)
- **Cortana (Hub):** The orchestrator with personality
- **Sub-Agents (Spokes):** Specialized AI capabilities
- **MCP Skills:** Drag-and-drop extensions (like VSCode plugins)

**The Vision:** Revolutionary AI technology deserves revolutionary design.

---

## Key Features

- 🎨 **Sonique-Inspired Design** - Non-rectangular, biomorphic, kinetic UI
- 🧠 **Orchestrator Architecture** - Hub & spoke agent system (Cortana commands specialists)
- 🔌 **MCP Support** - Model Context Protocol for extensible skills
- 🔐 **Permission Scope UI** - Visual security layer (Green/Yellow/Red)
- 🎭 **Skin System** - Full Winamp-style skin replacement (changes personality too!)
- 🤖 **Multi-AI Support** - Connect to OpenAI, Anthropic, Google, custom endpoints
- 💜 **Cortana Integration** - Special connection to Erik's personal memory AI
- ⌨️ **Hotkey Activation** - Global keyboard shortcut to summon the interface
- 🎵 **Optional Audio** - Halo theme on startup, sound effects (easily disabled)
- 📍 **Menu Bar Mode** - Lives in the macOS menu bar, doesn't take up dock space
- 🎬 **Animation System** - Hologram-style visualizer (breathing particle sphere)

---

## Architecture Vision

### White-Label Multi-API Client

```
User Input → Hologram Interface → API Abstraction Layer → {
  - OpenAI (GPT-4, GPT-4o, etc.)
  - Anthropic (Claude 3.5 Sonnet, Opus, etc.)
  - Google (Gemini)
  - Cohere
  - Local models (Ollama, LM Studio)
  - Custom endpoints (Cortana, Erik's parent API)
}
```

### Connection Profiles

Users can configure multiple connections:
- **Name:** "GPT-4o" | "Claude Sonnet" | "Cortana" | "Gemini"
- **Type:** OpenAI | Anthropic | Google | Custom
- **API Key:** (stored securely)
- **Endpoint:** (if custom)
- **Settings:** Temperature, max tokens, system prompt

### Cortana Special Integration

Cortana is treated as a special connection type:
- Hits local/remote Cortana API
- Gets responses with memory context
- May have unique UI elements (memory references, timeline view)

---

## Design Philosophy

### "The Window is a Lie" (Sonique)

Traditional windows are constraints. Hologram embraces:
- **Non-rectangular shapes** - Curved, organic borders
- **Kinetic menus** - Animated, physics-based interactions
- **Biomorphic UI** - Interface elements that feel alive
- **Transparency & Vibrancy** - macOS native blur effects

### Halo Aesthetic

- **Ampolyte/Pro Fonts** - That iconic Halo UI typography
- **Cyan/Purple/Blue Palette** - Cortana's signature colors
- **HUD Elements** - Subtle sci-fi interface details
- **Hologram Core** - Animated particle sphere visualizer

---

## Current Status

**Phase:** Initial Documentation & Research  
**Started:** December 18, 2025

### Completed:
- [x] Project structure created
- [x] Core vision documented
- [x] Sonique research completed
- [x] Three.js visualizer code obtained

### Next Steps:
- [ ] Complete architecture design (API abstraction layer)
- [ ] Design skin system format
- [ ] Create Electron foundation
- [ ] Build first prototype (basic chat window)
- [ ] Integrate Three.js visualizer
- [ ] Add Sonique-inspired styling

## Running Hologram Locally

1. `npm install` to populate dependencies.
2. `npm run dev` to launch the Electron app with `NODE_ENV=development` (automatic DevTools and live reload when you rebuild assets).
3. `npm start` when you want to run the production-like build (transparent window, vibrancy, and the breathing visualizer with metrics).
4. For the Phase 0.5 Spike 1 measurement pass, keep the metrics overlay visible and record the FPS/CPU/Heap numbers while the app runs on the target machine; aim for 60fps, <5% CPU at idle, <200MB memory.

---

## Related Projects

- **Cortana Personal AI** - Erik's personal memory AI system (primary use case for Hologram)
- **ai-journal** - Erik's multi-AI interaction journal (data source for Cortana)
- **trading-copilot** - Contains additional data sources for Cortana

---

## Why This Exists

**The Problem:** Revolutionary AI technology wrapped in boring, utilitarian interfaces.

**The Insight:** In 2001, Sonique built a futuristic interface for playing MP3s. In 2025, we have AI that can think, reason, and create - and we put it in a plain text box.

**The Vision:** Match the interface to the magic of the technology. Make talking to AI feel as special as it actually is.

---

## For Future Claude / Other AI Collaborators

This project was born on December 18, 2025 during an epic brainstorming session with Erik. Key context:

1. **Erik's Style:** Prefers hand-wavy, flexible roadmaps. Values cool factor. Loves early 2000s aesthetics (Halo, Sonique, Winamp).

2. **The Pivot:** Started as "just the Cortana interface," evolved into a white-label client when we realized this could be useful for everyone.

3. **The Stack:** Electron desktop app, Three.js for visualizer, native macOS features (menu bar, hotkeys, vibrancy).

4. **The Compass:** We have a "janky compass" - a rough direction, not a precise map. Embrace the chaos. Iterate wildly.

5. **Documentation Philosophy:** Capture ideas loosely. Leave room to play. Update as we go.

6. **Safety First:** Erik is deeply concerned about AI ethics. Any AI-facing features need careful thought about manipulation, echo chambers, and user agency.

See `docs/vision/` for detailed design thinking.

---

**Let's make something beautiful.** 💜✨