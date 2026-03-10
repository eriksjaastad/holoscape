# Social Media Agent

**Status:** Side Project — Build after MVP is functional

**Goal:** An AI agent that generates content and posts to social media automatically, promoting Hologram with minimal human intervention. The agent aims to increase brand awareness, drive traffic to the Hologram website, and engage with the target audience across various social media platforms.

---

## The Vision

Imagine building Hologram while an AI agent works in the background, handling your social media presence:

1. **Generates a skin concept** (using the Skin Generator Agent) based on current trends or specified themes.
2. **Renders it in Hologram** (or mocks it up) to create a visually appealing representation.
3. **Takes a screenshot** of the rendered skin.
4. **Writes a compelling caption** tailored to each social media platform.
5. **Posts to Instagram, Twitter/X, and Facebook** automatically.
6. **Logs the post to Discord** for your review and feedback.

The result? You wake up to engagement and a growing online presence without the daily grind of manual content creation.

---

## Key Performance Indicators (KPIs)

*   **Reach:** Number of unique users who see Hologram's social media content.
*   **Engagement:** Likes, comments, shares, and clicks on social media posts.
*   **Website Traffic:** Number of users who visit the Hologram website from social media links.
*   **Follower Growth:** Increase in the number of followers on each social media platform.
*   **Conversion Rate:** Number of users who take a desired action (e.g., sign up for a newsletter, download a demo) after seeing social media content.

---

## Components

### 1. Skin Generator Agent
**Already documented in:** `docs/skin-ideas/SKIN_IDEAS.md`

- Takes a mood/reference as input: "Westworld meets vaporwave," "Cozy winter cabin," or "Futuristic cityscape."
- Outputs a complete skin concept with:
  - Window shape (e.g., circular, rectangular, abstract)
  - Color palette (hex codes)
  - Particle behavior (e.g., swirling, sparkling, fading)
  - Typography (font family, size, weight)
  - AI personality prompt (for caption generation)

**For Social Media:** Generate 1 skin concept per day for posting, focusing on variety and visual appeal. Consider generating multiple concepts and selecting the best one for posting.

---

### 2. Screenshot Renderer

**Options:**
- **A) Use Hologram directly:** Load a skin, capture the window. This provides the most accurate representation but may be slower.
- **B) Mock renderer:** Three.js headless render to PNG (faster, no Electron needed). This allows for quick rendering without the overhead of running the full Hologram application.

**Implementation (Option B):**
```bash
# Uses Puppeteer or Playwright to render
doppler run -- node scripts/render-skin.js --skin concepts/2025-12-20-vaporwave.json --output preview.png
```

**Considerations:**
*   **Lighting:** Ensure consistent and appealing lighting in all renders.
*   **Background:** Choose a background that complements the skin concept.
*   **Animation:** Explore the possibility of rendering short animated clips instead of static screenshots.

**Output:** 1080x1080 PNG (Instagram square) or 16:9 for Twitter/YouTube.  Consider generating multiple aspect ratios to optimize for each platform.

---

### 3. Caption Generator

**Input:** Skin concept JSON + post context (platform, target audience, current trends).
**Output:** Platform-optimized caption.

**Example prompts:**
```bash
Generate an Instagram caption for this skin concept:
- Name: "Neon Dreams"
- Palette: Hot pink, electric blue
- Vibe: Cyberpunk street hacker

Keep it under 150 characters. Include 3-5 relevant hashtags.
Sound excited but not cringe. Ask a question to encourage engagement.
```

**Platform variations:**
- **Instagram:** Visual focus, relevant hashtags, emoji-friendly, question-based engagement.
- **Twitter/X:** Punchy, can be provocative, link to project, use relevant trending hashtags.
- **Facebook:** Slightly more descriptive, community-building, focus on benefits and features.

**Caption Best Practices:**
*   **Call to Action:** Encourage users to visit the website, follow the page, or leave a comment.
*   **Brand Voice:** Maintain a consistent brand voice across all platforms.
*   **A/B Testing:** Experiment with different caption styles to see what resonates best with the audience.

---

### 4. Social Media Poster

**Technology:**
- Use official APIs where available (Instagram Graph API, Twitter API v2, Facebook Graph API). This is the preferred method for reliability and scalability.
- Fallback: Browser automation (Playwright). Use this only if official APIs lack the necessary functionality.

**Accounts needed:**
- [ ] Instagram: @hologram_app (or similar)
- [ ] Twitter/X: @hologram_ai (or similar)
- [ ] Facebook: Page for Hologram

**Posting strategy:**
- Instagram: 1 post/day, 3-5 stories/week (behind-the-scenes, polls, Q&A).
- Twitter: 1-2 posts/day (can be more experimental, engage in conversations, retweet relevant content).
- Facebook: 2-3 posts/week (focus on community building, share longer-form content, run contests).

**Scheduling:** Implement a scheduling system to plan posts in advance and optimize posting times.

**Implementation:**
```typescript
interface SocialPost {
  platform: 'instagram' | 'twitter' | 'facebook';
  image: string; // Path to image
  caption: string;
  hashtags: string[];
  scheduledFor?: Date;
  altText?: string; // Alt text for images (accessibility)
}

async function postToInstagram(post: SocialPost): Promise<PostResult> {
  // Use Instagram Graph API or Playwright automation
  // Handle errors and retries
}
```

**Error Handling:** Implement robust error handling to catch API errors, network issues, and other potential problems.

---

### 5. Discord Logger

Every action gets logged to a Discord channel for monitoring and quality control:
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
- 🗑️ — Delete the post (and optionally blacklist the skin concept)
- 📌 — Save to favorites (for future inspiration or promotion)

**Additional Logging Information:**
*   Engagement metrics (likes, comments, shares)
*   Error messages
*   API response codes

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

**Workflow Enhancements:**
*   **Content Calendar:** Integrate a content calendar to plan posts around specific themes, events, or product launches.
*   **Feedback Loop:** Use Discord reactions to continuously improve the Skin Generator and Caption Generator.
*   **Performance Monitoring:** Track KPIs and adjust the posting strategy accordingly.

---

## Future Considerations

*   **Integration with other AI agents:** Connect the Social Media Agent with other AI agents, such as a Customer Support Agent, to provide a more comprehensive user experience.
*   **Sentiment Analysis:** Analyze the sentiment of comments and mentions to identify potential issues and opportunities.
*   **Influencer Marketing:** Identify and collaborate with relevant influencers to promote Hologram to a wider audience.
*   **Paid Advertising:** Integrate paid advertising campaigns to boost reach and engagement.
