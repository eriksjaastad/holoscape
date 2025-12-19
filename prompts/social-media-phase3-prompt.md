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

All work in: `/Users/eriksjaastad/projects/hologram/agents/social-media/`

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

  console.log(`✅ Captions generated:`);
  console.log(`   Instagram: ${instagram.characterCount} chars`);
  console.log(`   Twitter: ${twitter.characterCount} chars`);
  console.log(`   Facebook: ${facebook.characterCount} chars`);

  return { instagram, twitter, facebook };
}

export function formatCaptionForDiscord(caption: Caption): string {
  const hashtags = caption.hashtags.length > 0 
    ? `\n${caption.hashtags.join(' ')}`
    : '';
  return `${caption.text}${hashtags}`;
}
```

---

## Step 3: Update Discord Module

Update `src/discord.ts` to include captions:

```typescript
import { readFileSync } from 'fs';
import type { SkinConcept, CaptionSet } from './types.js';
import { formatCaptionForDiscord } from './caption.js';

interface DiscordEmbed {
  title: string;
  description: string;
  color: number;
  fields: Array<{ name: string; value: string; inline?: boolean }>;
  image?: { url: string };
  footer: { text: string };
  timestamp: string;
}

function hexToDecimal(hex: string): number {
  return parseInt(hex.replace('#', ''), 16);
}

export async function postToDiscord(
  concept: SkinConcept,
  imagePath?: string,
  captions?: CaptionSet
): Promise<void> {
  const webhookUrl = process.env.DISCORD_WEBHOOK_URL;
  if (!webhookUrl) {
    console.log('⚠️  DISCORD_WEBHOOK_URL not set, skipping Discord post');
    return;
  }

  const fields: Array<{ name: string; value: string; inline?: boolean }> = [
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
      name: '🎨 Colors',
      value: [
        `Primary: \`${concept.colorPalette.primary}\``,
        `Secondary: \`${concept.colorPalette.secondary}\``,
        `Accent: \`${concept.colorPalette.accent}\``,
      ].join(' · '),
      inline: false,
    },
  ];

  // Add caption fields if provided
  if (captions) {
    fields.push(
      {
        name: '📸 Instagram',
        value: formatCaptionForDiscord(captions.instagram),
        inline: false,
      },
      {
        name: '🐦 Twitter',
        value: formatCaptionForDiscord(captions.twitter),
        inline: false,
      },
      {
        name: '📘 Facebook',
        value: formatCaptionForDiscord(captions.facebook),
        inline: false,
      }
    );
  } else {
    // Original personality field when no captions
    fields.push({
      name: '💬 Personality',
      value: concept.personality.slice(0, 200) + (concept.personality.length > 200 ? '...' : ''),
      inline: false,
    });
  }

  const embed: DiscordEmbed = {
    title: `🎨 New Skin: ${concept.name}`,
    description: `**Vibe:** ${concept.vibe}`,
    color: hexToDecimal(concept.colorPalette.primary),
    fields,
    footer: { text: `ID: ${concept.id}` },
    timestamp: concept.createdAt,
  };

  // Add image if provided
  if (imagePath) {
    embed.image = { url: 'attachment://preview.png' };
  }

  // Post with or without image
  if (imagePath) {
    const FormData = (await import('form-data')).default;
    const form = new FormData();
    
    form.append('payload_json', JSON.stringify({ embeds: [embed] }));
    form.append('files[0]', readFileSync(imagePath), {
      filename: 'preview.png',
      contentType: 'image/png',
    });

    const response = await fetch(webhookUrl, {
      method: 'POST',
      body: form as unknown as BodyInit,
      headers: form.getHeaders(),
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(`Discord webhook failed: ${response.status} - ${text}`);
    }
  } else {
    const response = await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ embeds: [embed] }),
    });

    if (!response.ok) {
      throw new Error(`Discord webhook failed: ${response.status}`);
    }
  }

  console.log('📤 Posted to Discord!');
}
```

---

## Step 4: Update CLI

Update `src/index.ts`:

```typescript
import 'dotenv/config';
import { generateSkinConcept, saveConcept } from './skin-generator.js';
import { renderPreview, renderFromFile } from './renderer.js';
import { generateCaptions } from './caption.js';
import { postToDiscord } from './discord.js';
import { readdirSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import type { SkinConcept, CaptionSet } from './types.js';

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  switch (command) {
    case 'generate': {
      // Parse flags
      const moodIndex = args.indexOf('--mood');
      const mood = moodIndex !== -1 ? args[moodIndex + 1] : undefined;

      const noSave = args.includes('--no-save');
      const noPost = args.includes('--no-post');
      const shouldRender = args.includes('--render');
      const shouldCaption = args.includes('--caption');

      try {
        // Generate concept
        const concept = await generateSkinConcept(mood);
        
        if (!noSave) {
          saveConcept(concept);
        }
        
        // Render preview if requested
        let imagePath: string | undefined;
        if (shouldRender) {
          imagePath = await renderPreview(concept);
        }

        // Generate captions if requested
        let captions: CaptionSet | undefined;
        if (shouldCaption) {
          captions = await generateCaptions(concept);
          
          // Save captions alongside concept if saving
          if (!noSave) {
            const captionsPath = imagePath 
              ? imagePath.replace('.png', '-captions.json')
              : join(process.cwd(), 'output', 'concepts', `${concept.id}-captions.json`);
            writeFileSync(captionsPath, JSON.stringify(captions, null, 2));
            console.log(`💾 Captions saved to: ${captionsPath}`);
          }
        }
        
        // Post to Discord
        if (!noPost) {
          await postToDiscord(concept, imagePath, captions);
        }

        console.log('\n📋 Full concept:');
        console.log(JSON.stringify(concept, null, 2));

        if (captions) {
          console.log('\n📝 Captions:');
          console.log(JSON.stringify(captions, null, 2));
        }
      } catch (error) {
        console.error('❌ Error:', error);
        process.exit(1);
      }
      break;
    }

    case 'caption': {
      // Generate captions for an existing concept
      const conceptPath = args[1];
      if (!conceptPath) {
        console.error('Usage: caption <path-to-concept.json>');
        process.exit(1);
      }

      try {
        const content = readFileSync(conceptPath, 'utf-8');
        const concept: SkinConcept = JSON.parse(content);
        const captions = await generateCaptions(concept);
        
        console.log('\n📝 Generated Captions:');
        console.log(JSON.stringify(captions, null, 2));

        // Save captions
        const captionsPath = conceptPath.replace('.json', '-captions.json');
        writeFileSync(captionsPath, JSON.stringify(captions, null, 2));
        console.log(`\n💾 Saved to: ${captionsPath}`);
      } catch (error) {
        console.error('❌ Error:', error);
        process.exit(1);
      }
      break;
    }

    case 'render': {
      const conceptPath = args[1];
      if (!conceptPath) {
        console.error('Usage: render <path-to-concept.json>');
        process.exit(1);
      }

      try {
        const imagePath = await renderFromFile(conceptPath);
        console.log(`✅ Rendered: ${imagePath}`);
      } catch (error) {
        console.error('❌ Error:', error);
        process.exit(1);
      }
      break;
    }

    case 'list': {
      const conceptsDir = join(process.cwd(), 'output', 'concepts');
      try {
        const files = readdirSync(conceptsDir).filter(f => f.endsWith('.json') && !f.includes('captions'));
        console.log(`\n📁 Found ${files.length} concepts:\n`);
        
        for (const file of files.slice(-10)) {
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
  generate                    Generate a new skin concept (random mood)
  generate --mood "X"         Generate with specific mood
  generate --render           Generate + create preview image
  generate --caption          Generate + create platform captions
  generate --render --caption Full package: concept + image + captions
  generate --no-save          Don't save to file
  generate --no-post          Don't post to Discord
  
  render <concept.json>       Render preview from existing concept
  caption <concept.json>      Generate captions for existing concept
  list                        List recent concepts

Examples:
  npm run generate
  npm run generate -- --mood "cyberpunk neon" --render --caption
  npm run caption output/concepts/2025-12-19-zen-harmony.json
      `);
  }
}

main();
```

---

## Step 5: Update package.json Scripts

```json
{
  "scripts": {
    "generate": "tsx src/index.ts generate",
    "render": "tsx src/index.ts render",
    "caption": "tsx src/index.ts caption",
    "list": "tsx src/index.ts list"
  }
}
```

---

## Step 6: Test It

```bash
# Generate with captions only (no image)
npm run generate -- --caption --no-post

# Full package: concept + image + captions
npm run generate -- --mood "steampunk workshop" --render --caption

# Generate captions for existing concept
npm run caption output/concepts/2025-12-19-zen-harmony.json
```

---

## Exit Criteria

- [ ] `npm run generate -- --caption` generates 3 platform captions
- [ ] Captions saved to `-captions.json` file
- [ ] Instagram: ≤150 chars + 3-5 hashtags
- [ ] Twitter: ≤200 chars total
- [ ] Facebook: 1-2 sentences with question
- [ ] Discord embed shows all 3 caption variants
- [ ] `npm run caption <concept.json>` works for existing concepts
- [ ] No AI-generic phrases ("game-changer", "revolutionary")
- [ ] TypeScript compiles with no errors

---

## Expected Discord Output

When you run `generate --render --caption`, Discord should show:

```
🎨 New Skin: Neon Dreams
Vibe: Cyberpunk hacker den

🪟 Window Shape          ✨ Particles
Hexagonal with edges     Fast orbital trails

🎨 Colors
Primary: #00ff88 · Secondary: #ff00ff · Accent: #00ffff

📸 Instagram
Living in the future ✨ This AI skin makes me feel like a hacker in a neon-lit basement.
#AIdesign #hologram #cyberpunk #synthwave #uiux

🐦 Twitter
Just dropped a new Hologram skin that makes my desktop look like Blade Runner. The future is now. #AIart

📘 Facebook
What would your AI assistant look like if it lived in a cyberpunk world? We just made that dream real — what aesthetic would you want next?

[PREVIEW IMAGE]

ID: abc123-def456
```

---

## If You Get Stuck

### Captions too long
- Reduce character limits in prompts
- Add stricter "Max X characters" instruction

### Hashtags have inconsistent format
- The code normalizes them (adds # if missing)

### Captions sound AI-generic
- The banned phrases are in `brand_voice.md`
- Add more banned phrases to the prompt if needed

### Parallel API calls failing
- Could serialize them: `const instagram = await ...; const twitter = await ...;`
- But parallel is faster and usually works

---

## Files Summary

### Created:
- `src/caption.ts` — Caption generation with platform prompts

### Modified:
- `src/types.ts` — Added `Platform`, `Caption`, `CaptionSet` types
- `src/discord.ts` — Added caption fields to embed
- `src/index.ts` — Added `--caption` flag and `caption` command
- `package.json` — Added `caption` script

---

Good luck! 📝

