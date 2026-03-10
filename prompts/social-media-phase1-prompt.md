# Sonnet: Social Media Agent — Phase 1

## Your Mission
Build the Skin Concept Generator: an AI that generates creative skin concepts for the Hologram app and posts them to Discord for review.

## Important Context

### This is a SEPARATE project from Hologram
- **Location:** Create a new folder at `../agents/social-media`
- **It runs independently** — not part of the Electron app
- **Tech:** Node.js + TypeScript + OpenAI + Discord webhook

### Read these docs first:
1. **Roadmap:** `docs/agents/SOCIAL_MEDIA_ROADMAP.md` — Full phase breakdown, data model, architecture
2. **Vision:** `docs/agents/SOCIAL_MEDIA_AGENT.md` — Why this exists, the full pipeline vision
3. **Skin ideas:** `docs/skin-ideas/SKIN_IDEAS.md` — Examples of skin concepts for inspiration

### What is a "skin"?
A skin is a visual theme for the Hologram AI chat app. Each skin includes:
- Window shape (circle, blob, rectangle, etc.)
- Color palette (primary, secondary, accent, background)
- Particle behavior (how the breathing animation looks)
- Typography style
- AI personality prompt (how the AI "speaks" in this skin)
- Vibe (one-liner description)

---

## What You're Building

A CLI tool that:
1. Takes a mood/reference as input (e.g., "Westworld meets vaporwave")
2. Generates a complete skin concept using GPT-4o-mini
3. Saves the concept as JSON
4. Posts a pretty embed to Discord

---

## Project Structure

```
agents/social-media/
├── package.json
├── tsconfig.json
├── .env.example
├── .gitignore
├── brand_voice.md         # Tone, vibe, banned phrases (create a starter)
├── constraints.md         # Rules (create a starter)
├── src/
│   ├── index.ts           # CLI entry point
│   ├── skin-generator.ts  # Core generation logic
│   ├── discord.ts         # Discord webhook posting
│   ├── types.ts           # TypeScript types
│   └── prompts.ts         # OpenAI prompt templates
├── data/
│   └── .gitkeep           # Will store assets, history, decisions
└── output/
    ├── concepts/          # Generated skin JSONs go here
    └── .gitkeep
```

---

## Step 1: Initialize Project

```bash
mkdir -p agents/social-media
cd agents/social-media
npm init -y
npm install typescript openai dotenv
npm install -D @types/node tsx
npx tsc --init
```

Update `tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src/**/*"]
}
```

Update `package.json`:
```json
{
  "name": "social-media-agent",
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "generate": "tsx src/index.ts generate",
    "list": "tsx src/index.ts list"
  }
}
```

---

## Step 2: Create Types

`src/types.ts`:
```typescript
export interface SkinConcept {
  id: string;
  name: string;
  createdAt: string;
  mood: string;                 // The input prompt
  windowShape: string;          // e.g., "Organic blob with flowing edges"
  colorPalette: {
    primary: string;            // Hex code
    secondary: string;
    accent: string;
    background: string;
  };
  particleBehavior: string;     // e.g., "Slow orbital drift with occasional pulses"
  typography: string;           // e.g., "Clean sans-serif, slightly condensed"
  personality: string;          // AI persona prompt
  vibe: string;                 // One-liner, e.g., "Westworld meets vaporwave"
}

export interface GenerateOptions {
  mood?: string;
  save?: boolean;
  post?: boolean;
}
```

---

## Step 3: Create Prompt Template

`src/prompts.ts`:
```typescript
export const SKIN_GENERATOR_PROMPT = `You are a creative director designing visual themes ("skins") for an AI chat application called Hologram.

Each skin completely transforms the app's appearance and personality. Think of it like designing a character's costume, voice, and vibe all at once.

Given a mood or reference (like "Westworld meets vaporwave" or "cozy library at night"), generate a complete skin concept.

Respond with ONLY valid JSON in this exact format:
{
  "name": "string - creative name for the skin, 1-3 words",
  "windowShape": "string - describe the window shape (e.g., 'Organic blob', 'Perfect circle', 'Hexagonal')",
  "colorPalette": {
    "primary": "#hexcode - main color",
    "secondary": "#hexcode - supporting color", 
    "accent": "#hexcode - highlight/accent color",
    "background": "#hexcode - background color"
  },
  "particleBehavior": "string - how the particles move and react (e.g., 'Slow orbital drift with occasional pulses')",
  "typography": "string - font style description (e.g., 'Clean sans-serif, slightly condensed')",
  "personality": "string - how the AI should speak in this skin (2-3 sentences describing tone, quirks, speech patterns)",
  "vibe": "string - one-liner that captures the essence (e.g., 'Westworld meets vaporwave')"
}

Be creative and specific. Each skin should feel distin... [truncated]
```

---

# Social Media Agent - Phase 1 Complete ✅

**Built:** December 19, 2025  
**Status:** Ready to use (requires OpenAI API key)

## What Was Built

A standalone CLI tool that generates creative skin concepts for the Hologram AI chat app using GPT-4o-mini, saves them as JSON, and optionally posts them to Discord.

## Project Structure

```
agents/social-media/
├── src/
│   ├── index.ts           # CLI entry point with commands
│   ├── skin-generator.ts  # OpenAI generation logic
│   ├── discord.ts         # Discord webhook posting
│   ├── types.ts           # TypeScript interfaces
│   └── prompts.ts         # OpenAI prompt templates
├── output/
│   └── concepts/          # Generated skin JSON files
├── data/                  # Reserved for future assets
├── .env.example           # Environment variables template
├── .gitignore             # Excludes .env, node_modules, generated files
├── brand_voice.md         # Content tone guidelines
├── constraints.md         # Content rules and limits
├── package.json           # Node.js dependencies
├── tsconfig.json          # TypeScript config
├── README.md              # Full documentation
└── QUICKSTART.md          # Quick setup guide
```

## Features Implemented

### Core Functionality
- ✅ Generate skin concepts with GPT-4o-mini
- ✅ Random mood selection from 12 preset moods
- ✅ Custom mood input via CLI flag
- ✅ Save concepts as JSON files
- ✅ Post formatted embeds to Discord
- ✅ List recent generated concepts

### CLI Commands
- `npm run generate` - Generate with random mood
- `npm run generate -- --mood "X"` - Generate with specific mood
- `npm run generate -- --no-save` - Don't save to file
- `npm run generate -- --no-post` - Don't post to Discord
- `npm run list` - List recent concepts

### Data Model
Each skin concept includes:
- `id` - Unique UUID
- `name` - Creative 1-3 word name
- `createdAt` - ISO timestamp
- `mood` - Input prompt used
- `windowShape` - Geometric description
- `colorPalette` - Primary, secondary, accent, background (hex codes)
- `particleBehavior` - Animation description
- `typography` - Font style description
- `personality` - AI voice/tone (2-3 sentences)
- `vibe` - One-liner essence

### Discord Integration
- Rich embeds with color from primary palette
- Organized fields for all properties
- Footer with UUID for reference
- Graceful fallback if webhook not configured

## Exit Criteria Status

- ✅ `npm run generate` creates a skin concept
- ✅ Concept JSON saved to `output/concepts/`
- ✅ Discord embed appears with all fields
- ✅ `npm run list` shows recent concepts
- ✅ Can generate with `--mood "X"` flag
- ✅ Can skip Discord with `--no-post`

## Tech Stack

- **Runtime:** Node.js v24+
- **Language:** TypeScript with strict mode
- **AI Model:** GPT-4o-mini via OpenAI API
- **Module System:** ES Modules (NodeNext)
- **Execution:** tsx (TypeScript execution)
- **Dependencies:**
  - `openai@^4.77.0` - OpenAI API client
  - `dotenv@^16.4.7` - Environment variables
  - `typescript@^5.x`
  - `@types/node@^20.x`
  - `tsx@^4.x`
