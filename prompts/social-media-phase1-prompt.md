# Sonnet: Social Media Agent — Phase 1

## Your Mission
Build the Skin Concept Generator: an AI that generates creative skin concepts for the Hologram app and posts them to Discord for review.

## Important Context

### This is a SEPARATE project from Hologram
- **Location:** Create a new folder at `/Users/eriksjaastad/projects/hologram/agents/social-media/`
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

Create this folder structure:

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

Be creative and specific. Each skin should feel distinct and memorable.`;

export function buildGeneratePrompt(mood: string): string {
  return `${SKIN_GENERATOR_PROMPT}

Generate a skin concept for this mood/reference:
"${mood}"`;
}
```

---

## Step 4: Create Skin Generator

`src/skin-generator.ts`:
```typescript
import OpenAI from 'openai';
import { randomUUID } from 'crypto';
import { writeFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import type { SkinConcept } from './types.js';
import { buildGeneratePrompt } from './prompts.js';

const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
});

// Random moods for when none is provided
const RANDOM_MOODS = [
  'Westworld meets vaporwave',
  'Cozy library at night',
  'Cyberpunk hacker den',
  'Underwater bioluminescence',
  'Art deco jazz club',
  'Scandinavian minimalism',
  'Retro 80s arcade',
  'Japanese zen garden',
  'Steampunk workshop',
  'Northern lights in space',
  'Film noir detective office',
  'Tropical sunset paradise',
];

function getRandomMood(): string {
  return RANDOM_MOODS[Math.floor(Math.random() * RANDOM_MOODS.length)];
}

function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
}

export async function generateSkinConcept(mood?: string): Promise<SkinConcept> {
  const actualMood = mood || getRandomMood();
  console.log(`🎨 Generating skin for mood: "${actualMood}"`);

  const response = await openai.chat.completions.create({
    model: 'gpt-4o-mini',
    messages: [
      { role: 'user', content: buildGeneratePrompt(actualMood) },
    ],
    temperature: 0.9,
  });

  const content = response.choices[0]?.message?.content;
  if (!content) {
    throw new Error('No response from OpenAI');
  }

  // Parse JSON from response
  const jsonMatch = content.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    throw new Error('Could not parse JSON from response');
  }

  const parsed = JSON.parse(jsonMatch[0]);
  
  const concept: SkinConcept = {
    id: randomUUID(),
    createdAt: new Date().toISOString(),
    mood: actualMood,
    name: parsed.name,
    windowShape: parsed.windowShape,
    colorPalette: parsed.colorPalette,
    particleBehavior: parsed.particleBehavior,
    typography: parsed.typography,
    personality: parsed.personality,
    vibe: parsed.vibe,
  };

  console.log(`✅ Generated: "${concept.name}"`);
  return concept;
}

export function saveConcept(concept: SkinConcept): string {
  const outputDir = join(process.cwd(), 'output', 'concepts');
  if (!existsSync(outputDir)) {
    mkdirSync(outputDir, { recursive: true });
  }

  const date = new Date().toISOString().split('T')[0];
  const slug = slugify(concept.name);
  const filename = `${date}-${slug}.json`;
  const filepath = join(outputDir, filename);

  writeFileSync(filepath, JSON.stringify(concept, null, 2));
  console.log(`💾 Saved to: output/concepts/${filename}`);
  
  return filepath;
}
```

---

## Step 5: Create Discord Webhook

`src/discord.ts`:
```typescript
import type { SkinConcept } from './types.js';

interface DiscordEmbed {
  title: string;
  description: string;
  color: number;
  fields: Array<{ name: string; value: string; inline?: boolean }>;
  footer: { text: string };
  timestamp: string;
}

function hexToDecimal(hex: string): number {
  return parseInt(hex.replace('#', ''), 16);
}

export async function postToDiscord(concept: SkinConcept): Promise<void> {
  const webhookUrl = process.env.DISCORD_WEBHOOK_URL;
  if (!webhookUrl) {
    console.log('⚠️  DISCORD_WEBHOOK_URL not set, skipping Discord post');
    return;
  }

  const embed: DiscordEmbed = {
    title: `🎨 New Skin: ${concept.name}`,
    description: `**Vibe:** ${concept.vibe}`,
    color: hexToDecimal(concept.colorPalette.primary),
    fields: [
      {
        name: '🪟 Window Shape',
        value: concept.windowShape,
        inline: true,
      },
      {
        name: '✨ Particles',
        value: concept.particleBehavior,
        inline: true,
      },
      {
        name: '🎨 Color Palette',
        value: [
          `Primary: \`${concept.colorPalette.primary}\``,
          `Secondary: \`${concept.colorPalette.secondary}\``,
          `Accent: \`${concept.colorPalette.accent}\``,
          `Background: \`${concept.colorPalette.background}\``,
        ].join('\n'),
        inline: false,
      },
      {
        name: '🔤 Typography',
        value: concept.typography,
        inline: true,
      },
      {
        name: '💬 AI Personality',
        value: concept.personality,
        inline: false,
      },
      {
        name: '💡 Generated from mood',
        value: `"${concept.mood}"`,
        inline: false,
      },
    ],
    footer: { text: `ID: ${concept.id}` },
    timestamp: concept.createdAt,
  };

  const response = await fetch(webhookUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ embeds: [embed] }),
  });

  if (!response.ok) {
    throw new Error(`Discord webhook failed: ${response.status}`);
  }

  console.log('📤 Posted to Discord!');
}
```

---

## Step 6: Create CLI

`src/index.ts`:
```typescript
import 'dotenv/config';
import { generateSkinConcept, saveConcept } from './skin-generator.js';
import { postToDiscord } from './discord.js';
import { readdirSync, readFileSync } from 'fs';
import { join } from 'path';
import type { SkinConcept } from './types.js';

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  switch (command) {
    case 'generate': {
      // Parse --mood flag
      const moodIndex = args.indexOf('--mood');
      const mood = moodIndex !== -1 ? args[moodIndex + 1] : undefined;

      // Parse flags
      const noSave = args.includes('--no-save');
      const noPost = args.includes('--no-post');

      try {
        const concept = await generateSkinConcept(mood);
        
        if (!noSave) {
          saveConcept(concept);
        }
        
        if (!noPost) {
          await postToDiscord(concept);
        }

        console.log('\n📋 Full concept:');
        console.log(JSON.stringify(concept, null, 2));
      } catch (error) {
        console.error('❌ Error:', error);
        process.exit(1);
      }
      break;
    }

    case 'list': {
      const conceptsDir = join(process.cwd(), 'output', 'concepts');
      try {
        const files = readdirSync(conceptsDir).filter(f => f.endsWith('.json'));
        console.log(`\n📁 Found ${files.length} concepts:\n`);
        
        for (const file of files.slice(-10)) { // Show last 10
          const content = readFileSync(join(conceptsDir, file), 'utf-8');
          const concept: SkinConcept = JSON.parse(content);
          console.log(`  • ${concept.name} — "${concept.vibe}"`);
          console.log(`    ${file}\n`);
        }
      } catch {
        console.log('No concepts found yet. Run `npm run generate` first!');
      }
      break;
    }

    default:
      console.log(`
Social Media Agent - Skin Concept Generator

Commands:
  generate              Generate a new skin concept (random mood)
  generate --mood "X"   Generate with specific mood
  generate --no-save    Don't save to file
  generate --no-post    Don't post to Discord
  list                  List recent concepts

Examples:
  npm run generate
  npm run generate -- --mood "cyberpunk hacker den"
  npm run generate -- --no-post
      `);
  }
}

main();
```

---

## Step 7: Create Config Files

`.env.example`:
```env
OPENAI_API_KEY=sk-your-key-here
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/your-webhook-here
```

`.gitignore`:
```
node_modules/
dist/
.env
output/concepts/*.json
```

`brand_voice.md`:
```markdown
# Brand Voice

## Tone
- Excited but not cringe
- Technical but accessible
- "Indie dev building something cool"

## Vibe
- Creative, experimental
- Passionate about visual design
- Making AI feel human

## Banned Phrases
- "game-changer"
- "revolutionary"
- "AI-powered" (overused)
- "next-generation"

## Emoji Rules
- 1-2 per post max
- No 🔥 or 💯 spam
- Prefer: 🎨 ✨ 🌀 💜

## Never
- Beg for follows
- Use engagement bait
- Sound corporate
```

`constraints.md`:
```markdown
# Content Constraints

## Topics
- No politics
- No medical claims
- No personal attacks
- No controversial opinions

## Format Rules
- Caption: 100-200 characters before hashtags
- Hashtags: 5-10 per post (not 30)
- Alt text required for accessibility

## Repetition Rules
- Don't post similar content within 7 days
- Rotate through different skin styles
- Vary hook formats (question, statement, story)
```

---

## Step 8: Test It

1. Copy your OpenAI API key to `.env`:
```bash
cp .env.example .env
# Edit .env with your key
```

2. Create a Discord webhook:
   - Go to your Discord server → Settings → Integrations → Webhooks
   - Create webhook, copy URL to `.env`

3. Run it:
```bash
npm run generate
# Or with a specific mood:
npm run generate -- --mood "underwater bioluminescence"
```

---

## Exit Criteria

- [ ] `npm run generate` creates a skin concept
- [ ] Concept JSON saved to `output/concepts/`
- [ ] Discord embed appears with: name, vibe, colors, shape, personality, mood
- [ ] `npm run list` shows recent concepts
- [ ] Can generate with `--mood "X"` flag
- [ ] Can skip Discord with `--no-post`

---

## If You Get Stuck

### OpenAI errors
- Check API key is valid
- Check you have credits
- Try `gpt-4o-mini` if `gpt-4o` fails

### Discord webhook errors
- Verify webhook URL is correct
- Check Discord server permissions
- Try posting a simple message first

### JSON parse errors
- The LLM sometimes adds text around JSON
- The regex `content.match(/\{[\s\S]*\}/)` should handle this
- If not, add more explicit "respond with ONLY JSON" in prompt

### Questions for Opus
If truly stuck, format your question like:
```
## BLOCKED: [Brief description]
**What I tried:** [List]
**Error:** [Exact message]
**Question:** [What you need to know]
```

---

## Next Steps (Phase 2)
Once this works, Phase 2 adds a screenshot renderer using Puppeteer to create preview images. But that's for later — get the concept generator working first!

Good luck! 🎨

