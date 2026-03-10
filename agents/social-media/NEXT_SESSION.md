# Social Media Agent — Quick Reference

**Last Updated:** December 19, 2025
**Current Status:** Phase 4 Complete ✅ (needs manual testing)
**Location:** `agents/social-media/`

---

## 🚨 START HERE TOMORROW/SUNDAY

This section outlines the steps to manually test Phase 4 of the Social Media Agent.  Ensure you have the necessary environment variables configured (see below).

### Step 1: Test Phase 4 (15 minutes)

1.  **Navigate to the project directory:**

    ```bash
    cd agents/social-media/
    ```

2.  **Generate a complete post package:** This command triggers the entire workflow, creating a skin concept, rendering a preview image, generating platform-specific captions, and creating a package awaiting approval.

    ```bash
    doppler run -- npm run package
    ```

3.  **Check Discord:** The `package` script posts a message to the configured Discord channel. Verify the following elements are present and accurate:

    *   Preview image (1080x1080 PNG)
    *   Instagram/Twitter/Facebook captions (formatted in code blocks for easy copy/paste)
    *   Alt text for the image
    *   "Why this?" reasoning (explanation of the concept)
    *   Suggested posting time

4.  **Get Package ID:**  Locate the Package ID in the footer of the Discord message. It will look similar to: `abc12345-def6-7890-....`  Copy this ID.

5.  **Test Approval:** Approve the generated package using the following command, replacing `<package-id>` with the actual ID.

    ```bash
    doppler run -- npm run approve <package-id>
    ```

6.  **Verify Package Status:** Confirm the package's status by running the following commands:

    ```bash
    doppler run -- npm run pending    # Should be empty now
    doppler run -- npm run approved   # Should show your package
    ```

7.  **(Optional) Test Rejection:** Generate another package to test the rejection workflow.

    ```bash
    doppler run -- npm run package    # Generate another
    doppler run -- npm run reject <new-package-id> --reason "not the right vibe"
    ```

**If it works:** Phase 4 is done! 🎉  Proceed to documentation updates and final cleanup.
**If it breaks:** See troubleshooting below or check the error message in the console and Discord.  Consult the detailed Phase 4 documentation (`PHASE_4_COMPLETE.md`).

---

## What's Been Built (Phases 1-4)

This table summarizes the features implemented in each phase of the Social Media Agent.

| Phase | What                                       | Status                 |
|-------|--------------------------------------------|------------------------|
| Phase 1 | Skin concept generator                     | ✅ Complete & tested   |
| Phase 2 | Preview image renderer (1080x1080 PNG)    | ✅ Complete & tested   |
| Phase 3 | Platform captions (IG/Twitter/Facebook)    | ✅ Complete & tested   |
| Phase 4 | Manual posting workflow + approval system | ✅ Built, needs manual test |

---

## All Available Commands

This section lists all available `npm` commands and their usage.  Remember to prefix each command with `doppler run --` to ensure the environment variables are loaded.

```bash
# Generate content (Phases 1-3)
doppler run -- npm run generate                         # Random concept
doppler run -- npm run generate -- --mood "cyberpunk"   # Specific mood
doppler run -- npm run generate -- --render             # + preview image
doppler run -- npm run generate -- --caption            # + platform captions
doppler run -- npm run generate -- --render --caption   # Full package

# Create post package (Phase 4)
doppler run -- npm run package                          # Full workflow
doppler run -- npm run package -- --mood "zen garden"   # With specific mood

# Manage packages (Phase 4)
doppler run -- npm run pending                 # List packages awaiting approval
doppler run -- npm run approved                # List approved packages
doppler run -- npm run approve <package-id>    # Approve a package
doppler run -- npm run reject <package-id> --reason "reason for rejection"     # Reject (optional: --reason "why")
doppler run -- npm run posted <package-id>     # Mark as posted after manual posting

# Utilities
doppler run -- npm run list                    # List recent concepts
doppler run -- npm run render <concept.json>   # Render existing concept
doppler run -- npm run caption <concept.json>  # Generate captions for existing
```

**Command Breakdown:**

*   `generate`: Generates a new skin concept.  Options include specifying a `--mood` and generating a `--render`ed image and/or `--caption`s.
*   `package`: Creates a complete post package, including concept, image, captions, and approval request.
*   `pending`: Lists packages awaiting approval.
*   `approved`: Lists approved packages.
*   `approve`: Approves a specific package.
*   `reject`: Rejects a specific package.  The `--reason` flag is highly recommended for providing context.
*   `posted`: Marks a package as posted after it has been manually posted to social media.
*   `list`: Lists recently generated concepts.
*   `render`: Renders an image for an existing concept (specified by its JSON file).
*   `caption`: Generates captions for an existing concept (specified by its JSON file).

---

## File Locations

This section provides an overview of the project's file structure.

```bash
agents/social-media/
├── src/
│   ├── index.ts              # CLI entry point
│   ├── skin-generator.ts     # Phase 1: Concept generation
│   ├── renderer.ts           # Phase 2: Image rendering
│   ├── caption.ts            # Phase 3: Caption generation
│   ├── package-generator.ts  # Phase 4: PostPackage creation
│   ├── approval-discord.ts   # Phase 4: Approval embeds
│   ├── decision-logger.ts    # Phase 4: Decision tracking
│   ├── discord.ts            # Discord webhook posting
│   ├── prompts.ts            # OpenAI prompts
│   ├── types.ts              # TypeScript types
│   └── utils.ts              # Shared utilities
├── output/
│   ├── concepts/             # Generated JSON concepts
│   └── previews/             # Rendered PNG images
├── data/                     # Phase 4: Decision logs
│   ├── packages.json         # All post packages
│   └── decisions.json        # Decision history
├── .env                      # API keys (OPENAI_API_KEY, DISCORD_WEBHOOK_URL)
├── package.json
└── PHASE_4_COMPLETE.md       # Detailed Phase 4 docs
```

**Key Directories:**

*   `src/`: Contains the source code for all phases of the project.
*   `output/`: Stores generated concepts and preview images.
*   `data/`: Stores data related to post packages and approval decisions.

---

## Environment Variables Required

The following environment variables are required for the Social Media Agent to function correctly.  These should be stored in a `.env` file in the root directory of the project.

```bash
# In .env file:
OPENAI_API_KEY=sk-...                           # From main Hologram .env (OpenAI API Key)
DISCORD_WEBHOOK_URL=https://discord.com/...     # From Discord server settings (Discord Webhook URL)
```

**Instructions:**

1.  Obtain an OpenAI API key from the OpenAI website.  This key is likely already configured in the main Hologram `.env` file.
2.  Create a Discord webhook URL in your desired Discord server.  This URL will be used to send approval requests and notifications.  See Discord documentation for instructions on creating webhooks.
3.  Create a `.env` file in the `agents/social-media/` directory.
4.  Add the `OPENAI_API_KEY` and `DISCORD_WEBHOOK_URL` to the `.env` file, replacing the placeholders with your actual keys.
