# Social Media Agent — Roadmap

**Project:** Automated social media content generation and posting  
**Parent Project:** Hologram (`ROADMAP.md`)  
**Status:** Phase 3 Complete ✅  
**Estimated Total:** 2-3 weeks of focused work (or spread across evenings)  
**Last Updated:** December 19, 2025

---

## What This Agent Actually Is (One Sentence)

A daily loop that **selects from your content library, writes the post package (caption/hashtags/alt text), enforces rules, publishes (or requests approval), then logs results** so tomorrow's pick is smarter.

---

## Architecture: 4 Tiny Services

Think in 4 services (can be cron jobs or scripts):

| Service | When | What It Does | Output |
|---------|------|--------------|--------|
| **Planner** | Daily | Decides *what* to post (topic + asset + angle) | `PostPlan.json` |
| **Composer** | Daily | Writes caption, hashtags, alt text, CTA | `PostPackage.json` |
| **Publisher** | Daily | Posts (or sends approval request) | Posted or queued |
| **Analyst** | Next day | Records metrics, updates preferences | Learning data |

**MVP:** Build Planner + Publisher first. Composer can be "template v1" for a while.

---

## Data Model (Tiny but Powerful)

```typescript
// assets — your content library
interface Asset {
  id: string;
  type: 'image' | 'video' | 'skin_concept';
  path: string;           // Local path or URL
  tags: string[];         // e.g., ['cyberpunk', 'neon']
  topic: string;          // e.g., 'skin', 'milestone', 'tutorial'
  createdAt: string;
}

// post_history — what's been posted
interface PostHistory {
  id: string;
  assetId: string;
  caption: string;
  hashtags: string[];
  postedAt: string;
  status: 'posted' | 'failed' | 'pending';
  platformPostId?: string;  // Instagram post ID, etc.
}

// agent_decisions — why the agent chose what it chose
interface AgentDecision {
  date: string;
  chosenAssetId: string;
  why: string;            // "Not posted in 14 days, matches current theme"
  constraintsChecked: string[];
  finalPostId?: string;
}

// metrics — engagement tracking
interface Metrics {
  postId: string;
  likes: number;
  comments: number;
  shares: number;
  saves: number;
  reach: number;
  fetchedAt: string;
}
```

This is what makes it *agent-y*: it has state and can avoid repeating itself.

---

## Guardrails (So It Doesn't Post Something Dumb)

Create 2 short docs and treat them as law:

### `brand_voice.md`
- Tone: Excited but not cringe, technical but accessible
- Vibe: "Indie dev building something cool"
- Banned phrases: "game-changer", "revolutionary", "AI-powered" (overused)
- Emoji rules: 1-2 per post max, no 🔥 or 💯 spam
- Never: Beg for follows, use engagement bait

### `constraints.md`
- No politics
- No medical claims
- No personal attacks
- No posts too similar to last 7 days
- Caption: 100-200 characters before hashtags
- Hashtags: 5-10 per post (not 30)
- Alt text required for accessibility

### Validator Pass (Before Publishing)
Every post must pass:
- [ ] Not too similar to last N posts
- [ ] Caption length OK
- [ ] Hashtags within rule
- [ ] Matches tone checklist
- [ ] Includes alt text
- [ ] Asset exists + correct format

---

## The Daily Agent Loop

Every day at 9:05am:

```
1. Look at last 14 posts
2. Pick an asset that isn't "too similar"
3. Choose a hook format (rotate: question / contrarian / list / story)
4. Draft caption + hashtags + alt text
5. Run validator
6. Output `ready_to_post`
7. Log decision

Next day:
8. Pull metrics (or enter manually) and update format weights
```

That's enough to call it an intelligent agent.

---

## Quick Summary

| Phase | What | Time | Outcome | Status |
|-------|------|------|---------|--------|
| Phase 1 | Skin concept generator | 2-4 hours | JSON concepts → Discord | ✅ Complete |
| Phase 2 | Screenshot renderer | 4-6 hours | PNG previews → Discord | ✅ Complete |
| Phase 3 | Caption generator | 2-3 hours | Platform-ready captions | ✅ Complete |
| Phase 4 | Manual posting workflow | 2-4 hours | Human approves in Discord | ⬅️ Next |
| Phase 5 | Full automation | 1-2 days | Auto-post with safety rails | Pending |
| Phase 6 | Content calendar + learning | 1 day | Smarter picks over time | Pending |

---

## Phase 0: Setup ✅ COMPLETE
- [x] Document the vision (`docs/agents/SOCIAL_MEDIA_AGENT.md`)
- [x] Add to main roadmap
- [x] Create this roadmap
- [x] Define architecture (4 services)
- [x] Define data model
- [x] Define guardrails

---

## Phase 1: Skin Concept Generator ✅ COMPLETE
**Goal:** AI generates skin concepts and posts them to Discord for review.  
**Completed:** December 19, 2025  
**Location:** `/Users/eriksjaastad/projects/hologram/agents/social-media/`

### Tasks
- [x] **Create project structure:**
  ```
  agents/social-media/
  ├── package.json
  ├── tsconfig.json
  ├── .env
  ├── brand_voice.md         # Tone, vibe, banned phrases
  ├── constraints.md         # Rules the agent must follow
  ├── src/
  │   ├── index.ts           # CLI entry point
  │   ├── planner.ts         # Decides what to post (Service 1)
  │   ├── composer.ts        # Writes captions (Service 2)
  │   ├── publisher.ts       # Posts or queues (Service 3)
  │   ├── validator.ts       # Checks guardrails
  │   ├── discord.ts         # Discord webhook
  │   └── types.ts           # Shared types
  ├── data/
  │   ├── assets.json        # Content library
  │   ├── post_history.json  # What's been posted
  │   └── decisions.json     # Agent decision log
  └── output/
      ├── concepts/          # Generated skin concepts
      └── previews/          # Rendered images
  ```

- [x] **Create guardrail docs:**
  - [x] `brand_voice.md` — Tone, vibe, banned phrases, emoji rules
  - [x] `constraints.md` — No politics, caption length, hashtag limits, etc.

- [x] **Install dependencies:**
  ```bash
  npm init -y
  npm install typescript openai dotenv
  npm install -D @types/node tsx
  ```

- [x] **Create skin concept type** — `src/types.ts`:
  ```typescript
  export interface SkinConcept {
    id: string;
    name: string;
    createdAt: string;
    mood: string;           // Input prompt
    windowShape: string;
    colorPalette: {
      primary: string;      // Hex
      secondary: string;
      accent: string;
      background: string;
    };
    particleBehavior: string;
    typography: string;
    personality: string;    // AI persona prompt
    vibe: string;           // One-liner description
  }
  ```

- [x] **Create skin generator** — `src/skin-generator.ts`:
  - [x] Takes mood/reference as input (e.g., "Westworld meets vaporwave")
  - [x] Calls OpenAI (GPT-4o-mini) with structured output prompt
  - [x] Returns `SkinConcept` object
  - [x] Saves to `output/concepts/YYYY-MM-DD-{slug}.json`
  - [x] Includes 12 preset random moods

- [x] **Create Discord poster** — `src/discord.ts`:
  - [x] Send embed with skin concept details
  - [x] Color from primary palette
  - [x] Format: Name, Vibe, Colors, Shape, Personality preview
  - [x] Graceful fallback if webhook not configured

- [x] **Create CLI** — `src/index.ts`:
  ```bash
  # Generate with random mood
  npx tsx src/index.ts generate
  
  # Generate with specific mood
  npx tsx src/index.ts generate --mood "Westworld meets vaporwave"
  
  # List recent concepts
  npx tsx src/index.ts list
  ```

- [x] **Create `.env`:**
  ```env
  OPENAI_API_KEY=sk-...
  DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
  ```

### Exit Criteria
- [x] Run `npm run generate` → concept generated successfully
- [x] Concept JSON saved to `output/concepts/` folder
- [x] Discord embed shows: name, vibe, colors, shape, personality
- [x] Can generate with custom mood via `--mood` flag
- [x] Can skip Discord posting with `--no-post` flag
- [x] TypeScript compiles with no errors

### What Was Built
- **CLI Tool:** `npm run generate`, `npm run list`
- **First Generated Skin:** "Zen Harmony" (Japanese zen garden theme)
- **Documentation:** README.md, QUICKSTART.md, PHASE_1_COMPLETE.md
- **Guardrails:** brand_voice.md, constraints.md
- **Tech Stack:** Node.js + TypeScript + OpenAI (GPT-4o-mini) + Discord webhooks

---

## Phase 2: Screenshot Renderer ✅ COMPLETE
**Goal:** Render skin concepts as visual previews using HTML/CSS + Puppeteer.  
**Completed:** December 19, 2025

Create a stylized "movie poster" preview for each skin concept. This is a mock renderer — it simulates the Hologram visualizer without needing the actual app running. This approach is faster to build, runs anywhere (CI, cloud), and can produce eye-catching marketing visuals.

### Tasks
- [x] **Install Puppeteer:**
  ```bash
  npm install puppeteer form-data
  npm install -D @types/form-data
  ```

- [x] **Create preview template** — `src/templates/preview.html`:
  - [x] 1080x1080 canvas (Instagram square)
  - [x] Gradient background using skin colors
  - [x] Centered glowing orb with particle effects
  - [x] Skin name and vibe text overlay
  - [x] Stylized like a movie poster
  - [x] "HOLOGRAM" branding

- [x] **Create renderer** — `src/renderer.ts`:
  - [x] Load template
  - [x] Inject skin colors and text
  - [x] Screenshot with Puppeteer
  - [x] Save to `output/previews/YYYY-MM-DD-{slug}.png`

- [x] **Update CLI:**
  ```bash
  # Generate concept + render preview
  npm run generate -- --render
  
  # Render existing concept
  npm run render output/concepts/2025-12-19-zen-harmony.json
  ```

- [x] **Update Discord post:**
  - [x] Attach preview image to embed
  - [x] Show thumbnail in Discord
  - [x] Use FormData for multipart uploads
  - [x] Condensed embed fields for better layout

### Exit Criteria
- [x] Run `generate --render` → Preview image created
- [x] Image is 1080x1080, looks professional
- [x] Colors match the skin concept
- [x] Can render existing concepts via `render` command
- [x] Discord can attach images (tested locally)
- [x] TypeScript compiles with no errors

### What Was Built
- **Renderer:** Puppeteer-based screenshot system
- **Template:** HTML/CSS with glowing orb, rings, particles
- **Examples Generated:** 
  - "Zen Harmony" (soft greens/beiges, 435KB)
  - "Deep Glow" (underwater blues/cyans, 335KB)
- **Discord Update:** Image attachment support via FormData
- **CLI:** `npm run render` command + `--render` flag
- **Documentation:** PHASE_2_COMPLETE.md with screenshots
- **Tech Stack:** Puppeteer + form-data + HTML/CSS templates

---

## Phase 3: Caption Generator ✅ COMPLETE
**Goal:** Generate platform-specific captions for each skin.  
**Completed:** December 19, 2025

### Tasks
- [x] **Create caption generator** — `src/caption.ts`:
  - [x] Takes `SkinConcept` + platform as input
  - [x] Returns caption + hashtags
  - [x] Parallel generation for all 3 platforms

- [x] **Platform templates:**
  ```typescript
  const PLATFORM_PROMPTS = {
    instagram: `
      Write an Instagram caption for this AI assistant skin concept.
      - Max 150 characters before hashtags
      - Excited but not cringe
      - End with 3-5 relevant hashtags
      - Include 1-2 emoji max
    `,
    twitter: `
      Write a tweet for this AI assistant skin concept.
      - Max 200 characters
      - Can be playful or provocative
      - No hashtags in main text (add 1-2 at end if room)
    `,
    facebook: `
      Write a Facebook post for this AI assistant skin concept.
      - 1-2 sentences
      - Community-building tone
      - Ask a question to encourage engagement
    `
  };
  ```

- [x] **Update CLI:**
  ```bash
  # Generate full package
  npm run generate -- --render --caption
  
  # Generate captions for existing concept
  npm run caption output/concepts/2025-12-19-zen-harmony.json
  ```

- [x] **Update Discord post:**
  - [x] Show all 3 caption variants
  - [x] Format as separate fields in embed
  - [x] Replace personality field when captions present

### Exit Criteria
- [x] Discord shows: image + 3 caption variants (IG, Twitter, FB)
- [x] Captions feel natural, not AI-generic
- [x] Hashtags are relevant and normalized
- [x] Instagram: ≤150 chars + 3-5 hashtags
- [x] Twitter: ≤200 chars total
- [x] Facebook: 1-2 sentences with engagement question
- [x] `npm run caption <concept.json>` works
- [x] TypeScript compiles with no errors

### What Was Built
- **Caption Generator:** Platform-specific prompts + GPT-4o-mini
- **3 Platforms:** Instagram, Twitter, Facebook
- **Examples Generated:**
  - "Zen Harmony" captions (142, 157, 231 chars)
  - "Cog & Steam" captions (122, 196, 228 chars)
- **CLI:** `npm run caption` command + `--caption` flag
- **Discord:** Shows all caption variants with emoji indicators
- **Documentation:** PHASE_3_COMPLETE.md with examples
- **Tech Stack:** OpenAI parallel generation, hashtag normalization

---

## Phase 4: Manual Posting Workflow (2-4 hours) ⬅️ NEXT
**Goal:** The smartest MVP — auto-generate, human posts manually.

> **Key insight:** Don't fight Instagram APIs yet. The thinking + selection + packaging is the hard part. You manually post for now, swap in auto-post later.

### The Post Package
Agent sends you a single Discord message with:
- 📸 Image/video preview (attached or link)
- 📝 Caption (with copy button)
- #️⃣ Hashtags (separately for easy copy)
- 📅 Suggested time
- 🤔 "Why it chose this" (from decision log)
- ✅ / ❌ reaction prompts

### Tasks
- [ ] **Create PostPackage type:**
  ```typescript
  interface PostPackage {
    id: string;
    asset: Asset;
    caption: string;
    hashtags: string[];
    altText: string;
    suggestedTime: string;
    reasoning: string;
    platforms: ('instagram' | 'twitter' | 'facebook')[];
    status: 'pending' | 'approved' | 'rejected' | 'posted';
  }
  ```

- [ ] **Create approval Discord embed:**
  - [ ] Preview image attached
  - [ ] Caption in code block (easy copy)
  - [ ] Hashtags in separate code block
  - [ ] "Why this?" field shows reasoning
  - [ ] Reaction prompts:
    - ✅ = Approved (log it, you'll post manually)
    - ❌ = Rejected (log reason)
    - 🔄 = Regenerate caption
    - 📌 = Save for later

- [ ] **Create decision logger** — `src/logger.ts`:
  - [ ] Log to `data/decisions.json`
  - [ ] Track: what was chosen, why, approval status
  - [ ] This becomes training data for Phase 6

- [ ] **Manual posting workflow:**
  ```
  1. Agent generates PostPackage
  2. Posts to Discord with all details
  3. You react ✅ and copy caption
  4. You post manually to Instagram
  5. You react 📸 to confirm posted
  6. Agent logs "posted" status
  ```

### Why This Works
It *feels* like an agent because the thinking + selection + packaging is done. You're just the "last mile" button-presser. Swapping in auto-post later becomes a plug-in.

### Exit Criteria
- [ ] Agent generates full PostPackage
- [ ] Discord shows: image, caption, hashtags, reasoning
- [ ] React ✅ → Logged as approved
- [ ] React ❌ → Logged as rejected with optional reason
- [ ] You can easily copy caption and post manually

---

## Phase 5: Full Automation (1-2 days)
**Goal:** Auto-post to social media with safety rails.

### Tasks
- [ ] **Set up social media accounts:**
  - [ ] Instagram: Create business account
  - [ ] Twitter/X: Create developer account, get API keys
  - [ ] Facebook: Create page, get access token

- [ ] **Install social media SDKs:**
  ```bash
  npm install twitter-api-v2
  # Instagram via Graph API or automation
  ```

- [ ] **Create posters:**
  - [ ] `src/posters/twitter.ts` — Twitter API v2
  - [ ] `src/posters/instagram.ts` — Graph API or Playwright automation
  - [ ] `src/posters/facebook.ts` — Graph API

- [ ] **Create scheduler** — `src/scheduler.ts`:
  - [ ] Run via cron or node-cron
  - [ ] Check approved queue
  - [ ] Post with rate limiting (1 per platform per hour max)
  - [ ] Log results to Discord

- [ ] **Safety rails:**
  - [ ] 30-minute delay after approval before posting
  - [ ] Daily limit: 3 posts per platform
  - [ ] Automatic pause if any post fails
  - [ ] All actions logged to Discord

- [ ] **Environment variables:**
  ```env
  # Twitter
  TWITTER_API_KEY=...
  TWITTER_API_SECRET=...
  TWITTER_ACCESS_TOKEN=...
  TWITTER_ACCESS_SECRET=...
  
  # Instagram (Meta Graph API)
  INSTAGRAM_ACCESS_TOKEN=...
  INSTAGRAM_BUSINESS_ID=...
  
  # Facebook
  FACEBOOK_PAGE_ID=...
  FACEBOOK_ACCESS_TOKEN=...
  ```

### Exit Criteria
- [ ] Approve in Discord → 30 min later → Posts appear on all platforms
- [ ] Discord logs success with links
- [ ] Rate limits respected
- [ ] Can pause/resume via Discord command

---

## Phase 6: Content Calendar + Learning (1 day)
**Goal:** Variety in content + the agent gets smarter over time.

### The Analyst Service (Service 4)
This is what makes it truly agent-y: it learns from what worked.

```typescript
interface AnalystReport {
  postId: string;
  metrics: Metrics;
  formatUsed: 'question' | 'contrarian' | 'list' | 'story';
  hookWorked: boolean;      // Based on engagement threshold
  timeOfDayScore: number;   // How did posting time affect reach?
  topicScore: number;       // How did topic perform vs. average?
}
```

### Tasks
- [ ] **Create Analyst service** — `src/analyst.ts`:
  - [ ] Runs daily (after new posts have had 24h)
  - [ ] Fetches metrics from platforms (or you enter manually)
  - [ ] Updates `data/metrics.json`
  - [ ] Calculates: which formats work, which topics, which times
  - [ ] Logs insights to Discord: "Story hooks got 2x engagement this week"

- [ ] **Create format rotation:**
  Rotate through hook formats so content doesn't feel repetitive:
  | Format | Example |
  |--------|---------|
  | Question | "What if your AI looked like this?" |
  | Contrarian | "Most AI apps look boring. Not this one." |
  | List | "3 things that make this skin unique" |
  | Story | "I designed this skin after watching Westworld..." |

- [ ] **Content calendar:**
  | Day | Type | Example |
  |-----|------|---------|
  | Mon | Skin concept | "New skin: Neon Dreams" |
  | Tue | Dev progress | "Week 3 complete!" |
  | Wed | Skin concept | "New skin: Steamwork" |
  | Thu | Behind-the-scenes | "5000 particles at 0.1% CPU" |
  | Fri | Skin concept | "New skin: Foundation" |
  | Sat | Milestone | "Phase 1B complete!" |
  | Sun | Community | Poll, question, or rest |

- [ ] **Update Planner to use learnings:**
  - [ ] Weight asset selection by past performance
  - [ ] Prefer formats that have worked
  - [ ] Avoid topics that underperformed
  - [ ] Log "why" with confidence score

### Exit Criteria
- [ ] Analyst runs daily and logs insights
- [ ] Planner considers past performance
- [ ] Format rotation is working
- [ ] Weekly Discord summary: "Top post was X with Y engagement"
- [ ] Not just skins — milestones, progress, polls
- [ ] Discord shows weekly calendar

---

## Future Ideas (Post-MVP)

- [ ] **A/B testing:** Generate 2 captions, post the winner based on engagement
- [ ] **Engagement tracking:** Log likes/comments, optimize posting times
- [ ] **User-submitted moods:** Discord command to suggest skin moods
- [ ] **Skin voting:** Post 3 concepts, community votes on which to build
- [ ] **Tutorial generation:** Auto-generate "How to create this skin" threads
- [ ] **Cross-promotion:** Auto-retweet/share between platforms

---

## Future Upgrades (Post-MVP)

These are ideas for later, once the core pipeline is running smoothly.

### Hologram Integration (Real Screenshots)
**What:** Instead of the mock HTML/CSS renderer, actually launch Hologram, apply the skin, and screenshot the real app.

**Why wait:**
- Requires skin loading system (Phase 5 of main Hologram roadmap)
- Mock renderer works great for marketing now
- Real screenshots become valuable once skins are actually usable

**When:** After Hologram has skin loading implemented. Could replace or supplement the mock renderer.

### Other Future Ideas
- **Video previews:** Short animated loops of the visualizer (GIF or MP4)
- **A/B caption testing:** Post variants, track which performs better
- **Auto-response bot:** Reply to comments using the skin's personality
- **Cross-posting optimization:** Learn which content works on which platform

---

## Quick Start Commands

```bash
# Initialize the project
cd agents/social-media
npm install
cp .env.example .env
# Fill in API keys

# Phase 1: Generate a concept
npx tsx src/index.ts generate --mood "cyberpunk hacker den"

# Phase 2: Generate with preview
npx tsx src/index.ts generate --mood "cozy library" --render

# Phase 3: Full package
npx tsx src/index.ts generate --render --caption

# Phase 5: Start scheduler
npx tsx src/index.ts serve
```

---

## Dependencies Summary

```json
{
  "dependencies": {
    "openai": "^4.x",
    "discord.js": "^14.x",
    "puppeteer": "^21.x",
    "twitter-api-v2": "^1.x",
    "node-cron": "^3.x",
    "dotenv": "^16.x",
    "better-sqlite3": "^9.x"
  },
  "devDependencies": {
    "typescript": "^5.x",
    "@types/node": "^20.x",
    "tsx": "^4.x"
  }
}
```

---

## Related Documents

- `docs/agents/SOCIAL_MEDIA_AGENT.md` — Full vision document
- `docs/skin-ideas/SKIN_IDEAS.md` — Skin concepts and generator idea
- `ROADMAP.md` → Side Tools — Reference in main project

---

*Last updated: December 19, 2025*  
*Status: Phase 3 Complete ✅, Ready for Phase 4*

