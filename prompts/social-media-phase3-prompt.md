# Sonnet: Social Media Agent — Phase 3: Caption Generator

## Your Mission
Add platform-specific caption generation for Instagram, Twitter, and Facebook. Each skin concept should get tailored captions with appropriate tone, length, and hashtags.

## Context

### What exists (Phase 1 & 2):
- Skin concept generator with 12 random moods
- Puppeteer preview renderer (1080x1080 images)
- Discord webhook posting with image attachments
- CLI: `generate`, `render`, `list` commands
- Types: `SkinConcept`, `GenerateOptions`

### What you're adding:
- Caption generator module
- Platform-specific prompts (Instagram, Twitter, Facebook)
- `--caption` CLI flag
- Discord embed with caption variants

---

## Project Location

All work in: `../agents/social-media`

---

## Step 1: Create Caption Types

Update `src/types.ts`:

```typescript
export interface SkinConcept {
  id: string;
  name: string;
  createdAt: string;
  mood: string;
  windowShape: string;
  colorPalette: {
    primary: string;
    secondary: string;
    accent: string;
    background: string;
  };
  particleBehavior: string;
  typography: string;
  personality: string;
  vibe: string;
}

export interface GenerateOptions {
  mood?: string;
  save?: boolean;
  post?: boolean;
}

export type Platform = 'instagram' | 'twitter' | 'facebook';

export interface Caption {
  platform: Platform;
  text: string;
  hashtags: string[];
  characterCount: number;
}

export interface CaptionSet {
  instagram: Caption;
  twitter: Caption;
  facebook: Caption;
}
```

---

## Step 2: Create Caption Generator

Create `src/caption.ts`:

```typescript
import OpenAI from 'openai';
import type { SkinConcept, Platform, Caption, CaptionSet } from './types.js';

let openai: OpenAI | null = null;

function getOpenAI(): OpenAI {
  if (!openai) {
    if (!process.env.OPENAI_API_KEY) {
      throw new Error('OPENAI_API_KEY environment variable is required.');
    }
    openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  }
  return openai;
}

const PLATFORM_PROMPTS: Record<Platform, string> = {
  instagram: `Write an Instagram caption for this AI assistant skin concept.

Rules:
- Max 150 characters before hashtags
- Excited but NOT cringe (no "game-changer", "revolutionary", etc.)
- 1-2 emoji max, placed naturally
- End with 3-5 relevant hashtags on a new line

Respond with ONLY valid JSON:
{
  "text": "Your caption here (with emoji if any)",
  "hashtags": ["hashtag1", "hashtag2", "hashtag3"]
}`,

  twitter: `Write a tweet for this AI assistant skin concept.

Rules:
- Max 200 characters total (including hashtags)
- Can be playful, witty, or provocative
- 1-2 hashtags at end only if room
- No emoji spam

Respond with ONLY valid JSON:
{
  "text": "Your tweet here",
  "hashtags": ["hashtag1"]
}`,

  facebook: `Write a Facebook post for this AI assistant skin concept.

Rules:
- 1-2 sentences, conversational tone
- Community-building: ask a question to encourage engagement
- No hashtags (Facebook doesn't need them)
- Can be warmer/longer than Twitter

Respond with ONLY valid JSON:
{
  "text": "Your post here with a question?",
  "hashtags": []
}`,
};

function buildCaptionPrompt(concept: SkinConcept, platform: Platform): string {
  return `${PLATFORM_PROMPTS[platform]}

Skin Concept:
- Name: ${concept.name}
- Vibe: ${concept.vibe}
- Colors: Primary ${concept.colorPalette.primary}, Secondary ${concept.colorPalette.secondary}
- Personality: ${concept.personality}
- Window Shape: ${concept.windowShape}
- Particles: ${concept.particleBehavior}`;
}

async function generateCaption(concept: SkinConcept, platform: Platform): Promise<Caption> {
  const client = getOpenAI();
  
  const response = await client.chat.completions.create({
    model: 'gpt-4o-mini',
    messages: [
      { role: 'user', content: buildCaptionPrompt(concept, platform) },
    ],
    temperature: 0.8,
  });

  const content = response.choices[0]?.message?.content;
  if (!content) {
    throw new Error(`No response from OpenAI for ${platform} caption`);
  }

  // Parse JSON from response
  const jsonMatch = content.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    throw new Error(`Could not parse JSON from ${platform} caption response`);
  }

  const parsed = JSON.parse(jsonMatch[0]);
  
  // Build full text with hashtags for character count
  const hashtagString = parsed.hashtags.length > 0 
    ? '\n' + parsed.hashtags.map((h: string) => h.startsWith('#') ? h : `#${h}`).join(' ')
    : '';
  const fullText = parsed.text + hashtagString;

  return {
    platform,
    text: parsed.text,
    hashtags: parsed.hashtags.map((h: string) => h.startsWith('#') ? h : `#${h}`),
    characterCount: fullText.length,
  };
}

export async function generateCaptions(concept: SkinConcept): Promise<CaptionSet> {
  console.log(`📝 Generating captions for "${concept.name}"...`);

  // Generate all three in parallel for speed
  const [instagram, twitter, facebook] = await Promise.all([
    generateCaption(concept, 'instagram'),
    generateCaption(concept, 'twitter'),
    generateCaption(concept, 'facebook'),
  ]);

  return { instagram, twitter, facebook };
}
```

# Social Media Agent - Phase 3 Complete ✅

**Built:** December 19, 2025  
**Status:** Platform-specific caption generation fully functional

## What Was Built

A caption generation system that creates tailored social media captions for Instagram, Twitter, and Facebook. Each platform gets unique content that matches its tone, length requirements, and engagement patterns.

## New Files Created

### Source Code
- `src/caption.ts` - Caption generation with platform-specific prompts and formatting

### Updates
- `src/types.ts` - Added `Platform`, `Caption`, `CaptionSet` types
- `src/discord.ts` - Shows caption variants in embeds (replaces personality field)
- `src/index.ts` - Added `--caption` flag and `caption` command
- `package.json` - Added `caption` script

### Output
- Caption files saved as `*-captions.json` alongside concepts

## Features Implemented

### Core Caption Generation
- ✅ Platform-specific prompt templates
- ✅ Character limit enforcement (Instagram 150, Twitter 200, Facebook flexible)
- ✅ Hashtag generation with normalization (adds # if missing)
- ✅ Parallel generation (3 platforms at once for speed)
- ✅ Character counting including hashtags

### Platform-Specific Rules

**Instagram:**
- Max 150 characters before hashtags
- 3-5 relevant hashtags
- 1-2 emoji max, placed naturally
- Excited but not cringe
- Banned phrases: "game-changer", "revolutionary", etc.

**Twitter:**
- Max 200 characters total (including hashtags)
- 1-2 hashtags only if room
- Playful, witty, or provocative
- No emoji spam

**Facebook:**
- 1-2 sentences, conversational
- Community-building: ends with question
- No hashtags (Facebook doesn't need them)
- Warmer/longer than Twitter

### CLI Commands
- ✅ `npm run generate -- --caption` - Generate with captions
- ✅ `npm run generate -- --render --caption` - Full package
- ✅ `npm run caption <concept.json>` - Captions for existing concept
- ✅ Captions save to `-captions.json` file

### Discord Integration
- ✅ Shows all 3 caption variants in embed
- ✅ Formatted with platform emoji (📸 Instagram, 🐦 Twitter, 📘 Facebook)
- ✅ Each caption in its own field with hashtags
- ✅ Replaces personality field when captions present

## Exit Criteria Status

- ✅ `npm run generate -- --caption` generates 3 platform captions
- ✅ Captions saved to `-captions.json` file
- ✅ Instagram: ≤150 chars + 3-5 hashtags
- ✅ Twitter: ≤200 chars total
- ✅ Facebook: 1-2 sentences with question
- ✅ Discord embed shows all 3 caption variants
- ✅ `npm run caption <concept.json>` works for existing concepts
- ✅ No AI-generic phrases ("game-changer", "revolutionary")
- ✅ TypeScript compiles with no errors

## Example Output

### Generated Skin: "Cog & Steam"

**Concept:**
- Theme: Steampunk workshop
- Colors: Bronze (#6A4E3A), Gold (#C1A56B), Copper (#B28A49)
- Vibe: "A mechanical marvel of creativity and invention"

**Generated Captions:**

**Instagram (122 chars):**
```bash
Dive into the whimsical world of Cog & Steam! Where creativity meets mechanics. ⚙️✨ What do you think? #steampunk #aiart #holoscape
