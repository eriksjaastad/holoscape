# Social Media Agent - Skin Concept Generator

A standalone CLI tool that generates creative skin concepts for the Hologram AI chat app using OpenAI, and posts them to Discord for review.

## What is This?

This is Phase 1 of the Social Media Agent - it generates skin concepts (visual themes) for Hologram. Each skin includes:
- Window shape
- Color palette
- Particle behavior
- Typography style
- AI personality
- Overall vibe

## Setup

1. Install dependencies:
```bash
npm install
```

2. Create `.env` file from example:
```bash
cp .env.example .env
```

3. Add your API keys to `.env`:
- `OPENAI_API_KEY` - Get from https://platform.openai.com/api-keys
- `DISCORD_WEBHOOK_URL` - Optional, for posting to Discord

## Usage

### Generate a random skin concept:
```bash
npm run generate
```

### Generate with a specific mood:
```bash
npm run generate -- --mood "underwater bioluminescence"
```

### Generate with preview image:
```bash
npm run generate -- --render
npm run generate -- --mood "cyberpunk neon" --render
```

### Generate with captions:
```bash
npm run generate -- --caption
npm run generate -- --mood "steampunk workshop" --caption
```

### Generate full package (concept + image + captions):
```bash
npm run generate -- --render --caption
```

### Generate captions for existing concept:
```bash
npm run caption output/concepts/2025-12-19-zen-harmony.json
```

### Render existing concept:
```bash
npm run render output/concepts/2025-12-19-zen-harmony.json
```

### Generate without posting to Discord:
```bash
npm run generate -- --no-post
```

### Generate without saving to file:
```bash
npm run generate -- --no-save
```

### List recent concepts:
```bash
npm run list
```

## Output

- **Concepts:** JSON files saved to `output/concepts/`
- **Previews:** PNG images (1080x1080) saved to `output/previews/`
- **Captions:** Platform-specific captions saved to `*-captions.json`
- **Format:** `YYYY-MM-DD-skin-name.json`, `.png`, and `-captions.json`
- **Discord:** Post (if webhook configured)

## Project Structure

```
agents/social-media/
├── src/
│   ├── index.ts           # CLI entry point
│   ├── skin-generator.ts  # OpenAI generation logic
│   ├── renderer.ts        # Puppeteer screenshot renderer
│   ├── discord.ts         # Discord webhook posting
│   ├── types.ts           # TypeScript interfaces
│   ├── prompts.ts         # OpenAI prompt templates
│   └── templates/
│       └── preview.html   # 1080x1080 preview template
├── output/
│   ├── concepts/          # Generated skin JSONs
│   └── previews/          # Rendered PNG images
├── data/                  # For future assets/history
├── brand_voice.md         # Content guidelines
└── constraints.md         # Content rules
```

## Next Steps

**Phases 1, 2 & 3 Complete!** ✅

This tool now generates:
- ✅ Creative skin concepts (Phase 1)
- ✅ Beautiful 1080x1080 preview images (Phase 2)
- ✅ Platform-specific captions for Instagram, Twitter, Facebook (Phase 3)

Next phases will add:
- **Phase 4:** Manual posting workflow with Discord approval
- **Phase 5:** Full automation with safety rails
- **Phase 6:** Learning and content calendar

See `docs/agents/SOCIAL_MEDIA_ROADMAP.md` for the full plan.

