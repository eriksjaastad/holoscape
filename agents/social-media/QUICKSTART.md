# Quick Start Guide

## Setup (First Time)

1. **Navigate to the project:**
   ```bash
   cd agents/social-media
   ```

2. **Install dependencies:**
   ```bash
   npm install
   ```

3. **Create your `.env` file:**
   ```bash
   cp .env.example .env
   ```

4. **Add your OpenAI API key to `.env`:**
   - Get your key from: https://platform.openai.com/api-keys
   - Edit `.env` and replace `sk-your-key-here` with your actual key

5. **(Optional) Add Discord webhook:**
   - Go to your Discord server → Settings → Integrations → Webhooks
   - Create a webhook, copy the URL
   - Add it to `.env` as `DISCORD_WEBHOOK_URL`

## Usage

### Generate a skin concept (random mood):
```bash
npm run generate
```

### Generate with a specific mood:
```bash
npm run generate -- --mood "underwater bioluminescence"
npm run generate -- --mood "film noir detective office"
npm run generate -- --mood "cozy library at night"
```

### Generate with preview image:
```bash
npm run generate -- --render
npm run generate -- --mood "cyberpunk neon" --render
```

### Render an existing concept:
```bash
npm run render output/concepts/2025-12-19-zen-harmony.json
```

### Generate without posting to Discord:
```bash
npm run generate -- --no-post
```

### List all generated concepts:
```bash
npm run list
```

## What Gets Generated

Each skin concept includes:
- **Name:** Creative 1-3 word name
- **Window Shape:** Geometric description (blob, circle, hexagon, etc.)
- **Color Palette:** Primary, secondary, accent, and background colors (hex codes)
- **Particle Behavior:** How the breathing animation looks
- **Typography:** Font style description
- **AI Personality:** How the AI speaks in this skin (2-3 sentences)
- **Vibe:** One-liner that captures the essence

**With `--render` flag:**
- **Preview Image:** 1080x1080 PNG "movie poster" style visualization
- Beautiful glowing orb with colors from the palette
- Professional design ready for social media

## Output

- JSON files saved to: `output/concepts/`
- Preview images saved to: `output/previews/`
- Format: `YYYY-MM-DD-skin-name.json` and `.png`
- Discord post (if webhook configured)

## Example Moods to Try

From the built-in list:
- "Westworld meets vaporwave"
- "Cyberpunk hacker den"
- "Art deco jazz club"
- "Scandinavian minimalism"
- "Retro 80s arcade"
- "Japanese zen garden"
- "Steampunk workshop"
- "Northern lights in space"
- "Tropical sunset paradise"

Or make up your own!

## Troubleshooting

### "OPENAI_API_KEY environment variable is required"
- Make sure you created `.env` file
- Make sure you added your actual API key
- Make sure there's no extra spaces or quotes around the key

### "Discord webhook failed"
- Check that your webhook URL is correct
- Check that the webhook hasn't been deleted
- Try posting without Discord: `npm run generate -- --no-post`

### "Could not parse JSON from response"
- This is rare - the AI sometimes adds extra text
- Try running again
- If it persists, check your OpenAI credits

## Next Steps

**Phases 1 & 2 Complete!** ✅

Once this is working, check out:
- `PHASE_1_COMPLETE.md` for Phase 1 details
- `PHASE_2_COMPLETE.md` for Phase 2 details
- `docs/agents/SOCIAL_MEDIA_ROADMAP.md` for the full 6-phase plan
- `docs/agents/SOCIAL_MEDIA_AGENT.md` for the vision
- `docs/skin-ideas/SKIN_IDEAS.md` for inspiration

Phase 3 will add caption generation for social media platforms!

