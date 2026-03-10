# Quick Start Guide: Holoscape Social Media Agent

This guide will help you quickly set up and use the Holoscape Social Media Agent to generate creative skin concepts for Holoscape, complete with descriptions and optional preview images.

## Prerequisites

*   **Node.js and npm:** Ensure you have Node.js and npm (Node Package Manager) installed on your system.  A recent version of Node.js (v18 or higher) is recommended.
*   **OpenAI API Key:** You'll need an OpenAI API key to use the AI-powered generation features.  You can obtain one from the [OpenAI platform](https://platform.openai.com/api-keys).
*   **(Optional) Doppler:** While not strictly required, Doppler is highly recommended for managing your OpenAI API key and Discord webhook URL securely.  If you don't use Doppler, you'll need to manage these environment variables manually.  See the [Doppler Secrets Management](Documents/reference/DOPPLER_SECRETS_MANAGEMENT.md) documentation for more information.
*   **(Optional) Discord Account and Server:** If you want to automatically post generated concepts to a Discord channel, you'll need a Discord account and a server where you have administrative privileges to create webhooks.

## Setup (First Time)

1.  **Navigate to the project directory:**

    Open your terminal and navigate to the `agents/social-media` directory within your Holoscape project:

    ```bash
    cd agents/social-media
    ```

2.  **Install dependencies:**

    Install the necessary npm packages:

    ```bash
    npm install
    ```

3.  **Configure environment variables:**

    The agent uses environment variables for configuration, including your OpenAI API key and (optionally) a Discord webhook URL.  The recommended way to manage these is with Doppler.

    **Using Doppler (Recommended):**

    If you're using Doppler, ensure you have Doppler installed and configured for your project. Then, run the following command to access your environment variables:

    ```bash
    doppler run -- npm run generate # Or any other command
    ```

    Doppler will automatically inject the necessary environment variables into the process.

    **Without Doppler (Manual):**

    a.  **Create a `.env` file:**

        Copy the example environment file:

        ```bash
        cp .env.example .env
        ```

    b.  **Edit the `.env` file:**

        Open the `.env` file in a text editor and add your OpenAI API key:

        ```
        OPENAI_API_KEY=sk-your-key-here
        ```

        Replace `sk-your-key-here` with your actual OpenAI API key.

    c.  **(Optional) Add Discord webhook URL:**

        If you want to post generated concepts to a Discord channel, add the webhook URL to the `.env` file:

        ```
        DISCORD_WEBHOOK_URL=your_discord_webhook_url
        ```

        Replace `your_discord_webhook_url` with the actual URL of your Discord webhook.

4.  **Obtain Discord Webhook URL (Optional):**

    If you want to use Discord integration:

    a.  Go to your Discord server.

    b.  Navigate to **Server Settings** → **Integrations** → **Webhooks**.

    c.  Click **Create Webhook**.

    d.  Configure the webhook (name, channel, etc.).

    e.  Copy the **Webhook URL** and paste it into your `.env` file as `DISCORD_WEBHOOK_URL`.

## Usage

The `npm run` command is used to execute various tasks.  When using Doppler, prefix the command with `doppler run --`.

### Generate a skin concept (random mood):

```bash
doppler run -- npm run generate
```

This command generates a skin concept with a randomly selected mood.

### Generate with a specific mood:

```bash
doppler run -- npm run generate -- --mood "underwater bioluminescence"
doppler run -- npm run generate -- --mood "film noir detective office"
doppler run -- npm run generate -- --mood "cozy library at night"
```

Use the `--mood` option to specify a particular mood for the skin concept.  You can use any descriptive phrase.

### Generate with a preview image:

```bash
doppler run -- npm run generate -- --render
doppler run -- npm run generate -- --mood "cyberpunk neon" --render
```

The `--render` option generates a preview image of the skin concept.  This requires additional processing time.

### Render an existing concept:

```bash
doppler run -- npm run render output/concepts/2025-12-19-zen-harmony.json
```

You can render a preview image for an existing skin concept by specifying the path to its JSON file.

### Generate without posting to Discord:

```bash
doppler run -- npm run generate -- --no-post
```

The `--no-post` option prevents the generated concept from being posted to Discord, even if a webhook URL is configured.

### List all generated concepts:

```bash
doppler run -- npm run list
```

This command lists all the generated skin concept JSON files in the `output/concepts/` directory.

## What Gets Generated

Each skin concept includes the following attributes:

*   **Name:** A creative 1-3 word name for the skin.
*   **Window Shape:** A geometric description of the Holoscape window shape (e.g., blob, circle, hexagon).
*   **Color Palette:** Primary, secondary, accent, and background colors represented as hex codes.
*   **Particle Behavior:** A description of how the breathing animation looks.
*   **Typography:** A description of the font style.
*   **AI Personality:** A 2-3 sentence description of how the AI speaks in this skin.
*   **Vibe:** A one-liner that captures the essence of the skin.

When the `--render` flag is used, the following is also generated:

*   **Preview Image:** A 1080x1080 PNG image in a "movie poster" style, visualizing the skin concept.
    *   Features a glowing orb with colors from the palette.
    *   Designed to be visually appealing and suitable for social media.

## Output

*   **JSON files:** Saved to `output/concepts/`
*   **Preview images:** Saved to `output/previews/`
*   **File format:** `YYYY-MM-DD-skin-name.json` and `.png`
*   **Discord post:** If a Discord webhook is configured and `--no-post` is not used, a message containing the skin concept details and the preview image (if generated) will be posted to the specified Discord channel.

## Example Moods to Try

Here are some example moods you can use with the `--mood` option:

*   "Westworld meets vaporwave"
*   "Cyberpunk hacker den"
*   "Art deco jazz club"
*   "Scandinavian minimalism"
*   "Retro 80s arcade"
*   "Japanese zen garden"
*   "Steampunk workshop"
*   "Northern lights in space"
*   "Tropical sunset paradise"
*   "Glitch art aesthetic"
*   "Biomechanical horror"
*   "Ancient Egyptian tomb"

Feel free to experiment and create your own unique moods!

## Troubleshooting

### "OPENAI\_API\_KEY environment variable is required"

*   **Cause:** The `OPENAI_API_KEY` environment variable is not set or is empty.
*   **Solution:**
    *   Ensure you have created the `.env` file (if not using Doppler).
    *   Verify that you have added your actual OpenAI API key to the `.env` file.
    *   Make sure there are no extra spaces or quotes around the key in the `.env` file.
    *   If using Doppler, ensure Doppler is running and configured correctly for your project.

### "Discord webhook failed"

*   **Cause:** There is an issue with the Discord webhook configuration.
*   **Solution:**
    *   Double-check that your webhook URL is correct in the `.env` file.
    *   Verify that the webhook still exists in your Discord server and hasn't been deleted.
    *   Test the webhook manually in Discord to ensure it's working.
    *   Try generating a concept without posting to Discord using the `--no-post` option: `npm run generate -- --no-post`.  If this works, the issue is definitely with the Discord webhook.

### "Could not parse JSON from response"

*   **Cause:** The OpenAI API returned a response that is not valid JSON.  This can happen if the AI generates extra text or if there is an error on the OpenAI side.
*   **Solution:**
    *   This is a rare occurrence. Try running the command again.
    *   If the issue persists, check your OpenAI API usage and credits on the OpenAI platform.
    *   Try a simpler mood to see if that resolves the issue.

## Next Steps

**Phases 1 & 2 Complete!** ✅

Congratulations! You've successfully set up and used the Holoscape Social Media Agent.

Explore the following resources to learn more:

*   `PHASE_1_COMPLETE.md`: Details about Phase 1 of the agent's development.
*   `PHASE_2_COMPLETE.md`: Details about Phase 2 of the agent's development.
*   `docs/agents/SOCIAL_MEDIA_ROADMAP.md`: The full 6-phase roadmap for the agent.
*   `docs/agents/SOCIAL_MEDIA_AGENT.md`: The overall vision for the Social Media Agent.
*   `docs/skin-ideas/SKIN_IDEAS.md`: Inspiration for new skin concepts.

Phase 3 will add caption generation for social media platforms!

## Related Documentation

*   [Doppler Secrets Management](Documents/reference/DOPPLER_SECRETS_MANAGEMENT.md) - Secrets management with Doppler.
*   [Discord Webhooks Per Project](patterns/discord-webhooks-per-project.md) - Discord integration details.
*   [[case_studies]] - Examples of using the agent in different scenarios.
*   [[project_planning]] - Project planning and roadmap information.
