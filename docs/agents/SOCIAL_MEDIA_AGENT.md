# Social Media Agent

**Status:** Side Project — Build after MVP is functional

**Goal:** An AI agent that generates content and posts to social media automatically, promoting Hologram with minimal human intervention.

---

## The Vision

While you're building Hologram, an agent runs in the background:
1. **Generates a skin concept** (using the Skin Generator Agent)
2. **Renders it in Hologram** (or mocks it up)
3. **Takes a screenshot**
4. **Writes a compelling caption**
5. **Posts to Instagram, Twitter/X, and Facebook**
6. **Logs the post to Discord** for your review

You wake up to engagement you didn't have to create manually.

---

## Components

### 1. Skin Generator Agent
**Already documented in:** `docs/skin-ideas/SKIN_IDEAS.md`

- Takes a mood/reference as input: "Westworld meets vaporwave"
- Outputs a complete skin concept with:
  - Window shape
  - Color palette (hex codes)
  - Particle behavior
  - Typography
  - AI personality prompt

**For Social Media:** Generate 1 skin concept per day for posting.

---

### 2. Screenshot Renderer

**Options:**
- **A) Use Hologram directly:** Load a skin, capture the window
- **B) Mock renderer:** Three.js headless render to PNG (faster, no Electron needed)

**Implementation (Option B):**
```bash
# Uses Puppeteer or Playwright to render
node scripts/render-skin.js --skin concepts/2025-12-20-vaporwave.json --output preview.png
```

**Output:** 1080x1080 PNG (Instagram square) or 16:9 for Twitter/YouTube

---

### 3. Caption Generator

**Input:** Skin concept JSON + post context
**Output:** Platform-optimized caption

**Example prompts:**
```
Generate an Instagram caption for this skin concept:
- Name: "Neon Dreams"
- Palette: Hot pink, electric blue
- Vibe: Cyberpunk street hacker

Keep it under 150 characters. Include 3-5 relevant hashtags.
Sound excited but not cringe.
```

**Platform variations:**
- **Instagram:** Visual focus, hashtags, emoji-friendly
- **Twitter/X:** Punchy, can be provocative, link to project
- **Facebook:** Slightly more descriptive, community-building

---

### 4. Social Media Poster

**Technology:** 
- Use official APIs where available
- Fallback: Browser automation (Playwright)

**Accounts needed:**
- [ ] Instagram: @hologram_app (or similar)
- [ ] Twitter/X: @hologram_ai (or similar)
- [ ] Facebook: Page for Hologram

**Posting strategy:**
- Instagram: 1 post/day, 3-5 stories/week
- Twitter: 1-2 posts/day (can be more experimental)
- Facebook: 2-3 posts/week

**Implementation:**
```typescript
interface SocialPost {
  platform: 'instagram' | 'twitter' | 'facebook';
  image: string; // Path to image
  caption: string;
  hashtags: string[];
  scheduledFor?: Date;
}

async function postToInstagram(post: SocialPost): Promise<PostResult> {
  // Use Instagram Graph API or Playwright automation
}
```

---

### 5. Discord Logger

Every action gets logged to a Discord channel:
```
🎨 New skin generated: "Neon Dreams"
📸 Screenshot captured: preview.png
📱 Posted to Instagram: https://instagram.com/p/...
🐦 Posted to Twitter: https://twitter.com/...
⏱️ Total time: 45 seconds
```

**You can react to control:**
- 👍 — Nice, keep this style
- 👎 — Don't do this again
- 🗑️ — Delete the post
- 📌 — Save to favorites

---

## Workflow

```
┌─────────────────┐
│ Cron: Daily 9am │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Skin Generator  │ → concepts/2025-12-20-vaporwave.json
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Screenshot      │ → previews/2025-12-20-vaporwave.png
│ Renderer        │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Caption         │ → "Imagine your AI in this skin..."
│ Generator       │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│ Post to Instagram, Twitter, Facebook │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────┐
│ Log to Discord  │ → "Posted! Here's the link..."
└─────────────────┘
```

---

## Content Ideas Beyond Skins

The agent can also post:

### Development Progress
- "Week 3 complete — GPU shaders are in! FPS went from 60 to 120 🔥"
- Screenshot of metrics overlay

### Name Candidates (from Name Generator Bot)
- "Thinking about names... Aether? Imago? 618? Vote in stories!"
- Poll in Instagram stories

### Behind-the-Scenes
- "Here's what 5,000 particles look like at 0.1% CPU"
- GIF of the breathing animation

### Milestones
- "Phase 0.5 complete! All spikes passed. Moving to Phase 1A."
- Screenshot of checked-off roadmap

### Skin Tutorials (Future)
- "How to create your own Hologram skin — thread 🧵"
- Step-by-step with screenshots

---

## Technical Implementation

### Directory Structure
```
hologram/
└── agents/
    └── social-media/
        ├── index.ts           # Main orchestrator
        ├── skin-generator.ts  # Generates skin concepts
        ├── renderer.ts        # Screenshots
        ├── caption.ts         # Writes captions
        ├── poster.ts          # Posts to platforms
        ├── discord.ts         # Logs to Discord
        ├── scheduler.ts       # Cron job management
        └── config.ts          # API keys, posting schedule
```

### Dependencies
```bash
npm install puppeteer         # Browser automation
npm install @playwright/test  # Alternative to Puppeteer
npm install node-cron         # Scheduling
npm install discord.js        # Discord webhook
npm install sharp             # Image processing
npm install openai            # Caption generation
```

### Environment Variables
```env
# Discord
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...

# Instagram (via Meta Graph API or automation)
INSTAGRAM_ACCESS_TOKEN=...
INSTAGRAM_BUSINESS_ACCOUNT_ID=...

# Twitter/X
TWITTER_API_KEY=...
TWITTER_API_SECRET=...
TWITTER_ACCESS_TOKEN=...
TWITTER_ACCESS_TOKEN_SECRET=...

# OpenAI (for caption generation)
OPENAI_API_KEY=...
```

---

## Phase Plan

### Phase 1: Skin Generator Only
- [ ] Create `agents/social-media/skin-generator.ts`
- [ ] Generate 1 concept → JSON file
- [ ] Log to Discord
- [ ] Manual review

### Phase 2: Add Screenshot Renderer
- [ ] Headless Three.js render or Playwright capture
- [ ] Generate 1080x1080 PNG
- [ ] Log to Discord with image

### Phase 3: Add Caption Generator
- [ ] GPT-4o-mini for captions
- [ ] Platform-specific templates
- [ ] Log draft to Discord for review

### Phase 4: Manual Posting Workflow
- [ ] Agent generates skin + screenshot + caption
- [ ] Posts to Discord: "Ready to post! React ✅ to approve"
- [ ] On approval, human copies to social media

### Phase 5: Automated Posting
- [ ] Instagram Graph API integration
- [ ] Twitter API integration
- [ ] Facebook Page API integration
- [ ] Full automation with human-in-the-loop via Discord

### Phase 6: Scheduled Content Calendar
- [ ] Daily skin posts
- [ ] Weekly milestone updates
- [ ] Engagement tracking
- [ ] A/B testing captions

---

## Safety Rails

### Human-in-the-Loop (Phase 4-5)
- All posts go to Discord first
- 30-minute delay before auto-posting
- Any 👎 reaction cancels the post
- Daily post limit (max 3 per platform)

### Content Guardrails
- No controversial topics in captions
- No engagement bait ("Like if you agree!")
- Professional but not corporate
- Genuine enthusiasm, not hype

### Rate Limiting
- Respect API rate limits
- No more than 1 post/hour per platform
- Backoff on errors

---

## Success Metrics

- [ ] Agent runs daily without crashes
- [ ] Instagram followers grow week-over-week
- [ ] Engagement rate > 3%
- [ ] Time saved: ~30 min/day vs. manual posting
- [ ] At least 1 post goes viral (> 1000 likes)

---

## Related Docs

- `docs/skin-ideas/SKIN_IDEAS.md` — Skin Generator Agent concept
- `ROADMAP.md` → Side Tools → Name Generator Bot
- `ROADMAP.md` → Phase 7+ → Social media agents

---

*Last updated: December 20, 2025*
*Status: Documented, not yet implemented*

