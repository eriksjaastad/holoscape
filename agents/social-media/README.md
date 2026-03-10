# Social Media Agent - Skin Concept Generator

A standalone CLI tool that generates creative skin concepts for the Hologram AI chat app using OpenAI, and posts them to Discord for review. This agent automates the creation of visually appealing and engaging content for social media, specifically focusing on generating diverse and imaginative skin concepts for the Hologram app.

## What is This?

This is the Social Media Agent, responsible for generating skin concepts (visual themes) for Hologram. Each skin includes:

- **Window shape:** Defines the overall form factor of the Hologram interface.
- **Color palette:** Specifies the colors used throughout the skin.
- **Particle behavior:** Determines the visual effects and animations.
- **Typography style:** Sets the fonts and text formatting.
- **AI personality:** Influences the tone and style of the AI's responses.
- **Overall vibe:** Captures the general aesthetic and feeling of the skin.

The agent leverages OpenAI's language models to generate these concepts based on various inputs, such as mood or theme. It also includes functionality to render preview images and generate platform-specific captions for social media posts.

## Setup

Before using the Social Media Agent, ensure you have the necessary dependencies installed and API keys configured.

1. **Install dependencies:**

   ```bash
   npm install
   ```

   This command installs all required Node.js packages listed in the `package.json` file.

2. **Create `.env` file from example:**

   ```bash
   cp .env.example .env
   ```

   This creates a copy of the `.env.example` file, which contains placeholder environment variables, and renames it to `.env`.

3. **Add your API keys to `.env`:**

   Edit the `.env` file and add your API keys:

   - `OPENAI_API_KEY`: Your OpenAI API key. Get it from [https://platform.openai.com/api-keys](https://platform.openai.com/api-keys). This key is required for generating skin concepts and captions.
   - `DISCORD_WEBHOOK_URL`: (Optional) Your Discord webhook URL. This is used for posting generated concepts to a Discord channel for review.  Create a webhook in your Discord server settings.

   Example `.env` file:

   ```
   OPENAI_API_KEY=sk-your-openai-api-key
   DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/your-webhook-url
   ```

   **Important:** Keep your API keys secure and do not commit them to version control.

## Usage

The Social Media Agent is a CLI tool that can be run using `npm` scripts.  The primary script is `generate`, which controls the entire process of concept creation, rendering, captioning, and posting.  All commands should be prefixed with `doppler run --` if you are using Doppler for secrets management.

### Generate a random skin concept:

```bash
doppler run -- npm run generate
```

This command generates a skin concept with a randomly chosen mood or theme.

### Generate with a specific mood:

```bash
doppler run -- npm run generate -- --mood "underwater bioluminescence"
```

This command generates a skin concept based on the specified mood.  The `--mood` argument allows you to influence the generated concept.

### Generate with preview image:

```bash
doppler run -- npm run generate -- --render
doppler run -- npm run generate -- --mood "cyberpunk neon" --render
```

The `--render` flag generates a 1080x1080 preview image of the skin concept.

### Generate with captions:

```bash
doppler run -- npm run generate -- --caption
doppler run -- npm run generate -- --mood "steampunk workshop" --caption
```

The `--caption` flag generates platform-specific captions for the skin concept.

### Generate full package (concept + image + captions):

```bash
doppler run -- npm run generate -- --render --caption
```

This command generates a skin concept, renders a preview image, and generates captions.

### Generate captions for existing concept:

```bash
doppler run -- npm run caption output/concepts/2025-12-19-zen-harmony.json
```

This command generates captions for an existing skin concept JSON file.

### Render existing concept:

```bash
doppler run -- npm run render output/concepts/2025-12-19-zen-harmony.json
```

This command renders a preview image for an existing skin concept JSON file.

### Generate without posting to Discord:

```bash
doppler run -- npm run generate -- --no-post
```

The `--no-post` flag prevents the generated concept from being posted to Discord, even if a webhook URL is configured.

### Generate without saving to file:

```bash
doppler run -- npm run generate -- --no-save
```

The `--no-save` flag prevents the generated concept, image, and captions from being saved to files.  This is useful for testing or when you only need to post to Discord.

### List recent concepts:

```bash
doppler run -- npm run list
```

This command lists the most recently generated skin concepts.

## Output

The Social Media Agent generates several output files:

- **Concepts:** JSON files containing the skin concept data.  These are saved to `output/concepts/`.
- **Previews:** PNG images (1080x1080) of the skin concept.  These are saved to `output/previews/`.
- **Captions:** JSON files containing platform-specific captions for the skin concept. These are saved alongside the concept file with a `-captions.json` suffix.
- **Format:** The files are named using the format `YYYY-MM-DD-skin-name.json`, `.png`, and `-captions.json`.  For example: `2025-12-19-zen-harmony.json`, `2025-12-19-zen-harmony.png`, and `2025-12-19-zen-harmony-captions.json`.
- **Discord:** If a Discord webhook URL is configured, the agent will post a message to the specified channel with the skin concept details, preview image, and captions.

## Project Structure

```bash
agents/social-media/
├── src/
│   ├── index.ts           # CLI entry point - Handles command-line arguments and orchestrates the generation process.
│   ├── skin-generator.ts  # OpenAI generation logic - Contains the code responsible for generating skin concepts using OpenAI.
│   ├── renderer.ts        # Puppeteer screenshot renderer - Uses Puppeteer to render preview images of the skin concepts.
│   ├── discord.ts         # Discord webhook posting - Handles posting generated concepts to a Discord channel using a webhook.
│   ├── types.ts           # TypeScript interfaces - Defines the TypeScript interfaces used throughout the project.
│   ├── prompts.ts         # OpenAI prompt templates - Contains the prompt templates used to guide OpenAI's generation process.
│   └── templates/
│       └── preview.html   # 1080x1080 preview template - HTML template used by Puppeteer to render the preview images.
├── output/
│   ├── concepts/          # Generated skin JSONs - Stores the generated skin concept JSON files.
│   └── previews/          # Rendered PNG images - Stores the rendered PNG images of the skin concepts.
├── data/                  # For future assets/history - Reserved for future use, potentially for storing assets or historical data.
├── brand_voice.md         # Content guidelines - Contains guidelines for maintaining a consistent brand voice in the generated content.
└── constraints.md         # Content rules - Defines rules and constraints for the generated content to ensure quality and relevance.
```

## Next Steps

**Phases 1, 2 & 3 Complete!** ✅

This tool now generates:

- ✅ Creative skin concepts (Phase 1)
- ✅ Beautiful 1080x1080 preview images (Phase 2)
- ✅ Platform-specific captions for Instagram, Twitter, Facebook (Phase 3)

Next phases will add:

- **Phase 4:** Manual posting workflow with Discord approval - Implement a workflow where generated content is first reviewed and approved in Discord before being posted to social media.
- **Phase 5:** Full automation with safety rails - Automate the entire process of generating, posting, and monitoring social media content, with built-in safety mechanisms to prevent errors or inappropriate content.
- **Phase 6:** Learning and content calendar - Integrate machine learning to learn from past performance and optimize content generation, and implement a content calendar to schedule posts in advance.

See `docs/agents/SOCIAL_MEDIA_ROADMAP.md` for the full plan.

## Related Documentation

- [Doppler Secrets Management](Documents/reference/DOPPLER_SECRETS_MANAGEMENT.md) - secrets management
- [[PROJECT_STRUCTURE_STANDARDS]] - project structure
- [Automation Reliability](patterns/automation-reliability.md) - automation
- [Discord Webhooks Per Project](patterns/discord-webhooks-per-project.md) - Discord
- [Tiered AI Sprint Planning](patterns/tiered-ai-sprint-planning.md) - prompt engineering
