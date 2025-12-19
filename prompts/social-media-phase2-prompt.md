# Sonnet: Social Media Agent — Phase 2

## Your Mission
Build a screenshot renderer that creates stylized preview images of skin concepts using HTML/CSS + Puppeteer.

## Context

### Phase 1 is complete
The skin concept generator is working. It creates JSON files like:
```json
{
  "id": "abc123",
  "name": "Neon Dreams",
  "mood": "cyberpunk hacker den",
  "windowShape": "Hexagonal with glowing edges",
  "colorPalette": {
    "primary": "#00ff88",
    "secondary": "#ff00ff",
    "accent": "#00ffff",
    "background": "#0a0a0a"
  },
  "particleBehavior": "Fast orbital with trailing glow",
  "typography": "Monospace, condensed, terminal-style",
  "personality": "Speaks in short, cryptic phrases...",
  "vibe": "Cyberpunk hacker den"
}
```

### What you're building
A "movie poster" style preview image for each skin concept:
- 1080x1080 PNG (Instagram square)
- Gradient background using skin colors
- Centered visualization (CSS animation frozen or static)
- Skin name and vibe as text overlay
- Professional, eye-catching design

### Read these docs:
1. `docs/agents/SOCIAL_MEDIA_ROADMAP.md` — Phase 2 tasks
2. `docs/agents/SOCIAL_MEDIA_AGENT.md` — Full vision
3. `agents/social-media/` — Existing Phase 1 code

---

## Project Location

All work happens in: `/Users/eriksjaastad/projects/hologram/agents/social-media/`

---

## Step 1: Install Puppeteer

```bash
cd agents/social-media
npm install puppeteer
```

---

## Step 2: Create Preview Template

Create `src/templates/preview.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    
    body {
      width: 1080px;
      height: 1080px;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      font-family: system-ui, -apple-system, sans-serif;
      overflow: hidden;
    }
    
    .background {
      position: absolute;
      inset: 0;
      background: linear-gradient(
        135deg,
        {{BACKGROUND}} 0%,
        {{PRIMARY}}22 50%,
        {{BACKGROUND}} 100%
      );
    }
    
    .glow {
      position: absolute;
      width: 600px;
      height: 600px;
      border-radius: 50%;
      background: radial-gradient(
        circle,
        {{PRIMARY}}44 0%,
        {{SECONDARY}}22 40%,
        transparent 70%
      );
      filter: blur(60px);
    }
    
    .orb-container {
      position: relative;
      width: 400px;
      height: 400px;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    
    .orb {
      width: 300px;
      height: 300px;
      border-radius: 50%;
      background: radial-gradient(
        circle at 30% 30%,
        {{PRIMARY}} 0%,
        {{SECONDARY}} 50%,
        {{PRIMARY}}88 100%
      );
      box-shadow:
        0 0 60px {{PRIMARY}}88,
        0 0 120px {{SECONDARY}}44,
        inset 0 0 60px {{ACCENT}}44;
      position: relative;
    }
    
    .orb::before {
      content: '';
      position: absolute;
      inset: 20px;
      border-radius: 50%;
      background: radial-gradient(
        circle at 40% 40%,
        {{ACCENT}}66 0%,
        transparent 60%
      );
    }
    
    .particles {
      position: absolute;
      inset: -50px;
      background-image: 
        radial-gradient(2px 2px at 20% 30%, {{ACCENT}} 50%, transparent),
        radial-gradient(2px 2px at 40% 70%, {{PRIMARY}} 50%, transparent),
        radial-gradient(2px 2px at 60% 20%, {{SECONDARY}} 50%, transparent),
        radial-gradient(2px 2px at 80% 60%, {{ACCENT}} 50%, transparent),
        radial-gradient(2px 2px at 30% 80%, {{PRIMARY}} 50%, transparent),
        radial-gradient(2px 2px at 70% 40%, {{SECONDARY}} 50%, transparent),
        radial-gradient(1px 1px at 10% 50%, {{ACCENT}}88 50%, transparent),
        radial-gradient(1px 1px at 90% 30%, {{PRIMARY}}88 50%, transparent),
        radial-gradient(1px 1px at 50% 90%, {{SECONDARY}}88 50%, transparent);
      opacity: 0.8;
    }
    
    .ring {
      position: absolute;
      width: 380px;
      height: 380px;
      border: 1px solid {{PRIMARY}}44;
      border-radius: 50%;
    }
    
    .ring-outer {
      position: absolute;
      width: 450px;
      height: 450px;
      border: 1px solid {{SECONDARY}}22;
      border-radius: 50%;
    }
    
    .text-container {
      position: absolute;
      bottom: 120px;
      text-align: center;
      z-index: 10;
    }
    
    .name {
      font-size: 48px;
      font-weight: 700;
      color: {{PRIMARY}};
      text-transform: uppercase;
      letter-spacing: 8px;
      text-shadow: 0 0 30px {{PRIMARY}}88;
      margin-bottom: 16px;
    }
    
    .vibe {
      font-size: 20px;
      font-weight: 400;
      color: {{SECONDARY}};
      letter-spacing: 2px;
      opacity: 0.9;
    }
    
    .logo {
      position: absolute;
      top: 60px;
      font-size: 14px;
      font-weight: 600;
      color: {{ACCENT}};
      letter-spacing: 4px;
      text-transform: uppercase;
      opacity: 0.6;
    }
  </style>
</head>
<body>
  <div class="background"></div>
  <div class="glow"></div>
  
  <div class="logo">HOLOGRAM</div>
  
  <div class="orb-container">
    <div class="ring-outer"></div>
    <div class="ring"></div>
    <div class="orb"></div>
    <div class="particles"></div>
  </div>
  
  <div class="text-container">
    <div class="name">{{NAME}}</div>
    <div class="vibe">{{VIBE}}</div>
  </div>
</body>
</html>
```

**Template placeholders:**
- `{{PRIMARY}}` — Primary color hex
- `{{SECONDARY}}` — Secondary color hex
- `{{ACCENT}}` — Accent color hex
- `{{BACKGROUND}}` — Background color hex
- `{{NAME}}` — Skin name
- `{{VIBE}}` — Skin vibe text

---

## Step 3: Create Renderer

Create `src/renderer.ts`:

```typescript
import puppeteer from 'puppeteer';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import type { SkinConcept } from './types.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
}

function injectTemplate(template: string, concept: SkinConcept): string {
  return template
    .replace(/\{\{PRIMARY\}\}/g, concept.colorPalette.primary)
    .replace(/\{\{SECONDARY\}\}/g, concept.colorPalette.secondary)
    .replace(/\{\{ACCENT\}\}/g, concept.colorPalette.accent)
    .replace(/\{\{BACKGROUND\}\}/g, concept.colorPalette.background)
    .replace(/\{\{NAME\}\}/g, concept.name)
    .replace(/\{\{VIBE\}\}/g, concept.vibe);
}

export async function renderPreview(concept: SkinConcept): Promise<string> {
  console.log(`📸 Rendering preview for "${concept.name}"...`);

  // Load template
  const templatePath = join(__dirname, 'templates', 'preview.html');
  const template = readFileSync(templatePath, 'utf-8');
  const html = injectTemplate(template, concept);

  // Ensure output directory exists
  const outputDir = join(process.cwd(), 'output', 'previews');
  if (!existsSync(outputDir)) {
    mkdirSync(outputDir, { recursive: true });
  }

  // Generate filename
  const date = new Date().toISOString().split('T')[0];
  const slug = slugify(concept.name);
  const filename = `${date}-${slug}.png`;
  const filepath = join(outputDir, filename);

  // Launch browser and screenshot
  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });

  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1080, height: 1080 });
    await page.setContent(html, { waitUntil: 'networkidle0' });
    
    await page.screenshot({
      path: filepath,
      type: 'png',
    });

    console.log(`✅ Preview saved: output/previews/${filename}`);
    return filepath;
  } finally {
    await browser.close();
  }
}

export async function renderFromFile(conceptPath: string): Promise<string> {
  const content = readFileSync(conceptPath, 'utf-8');
  const concept: SkinConcept = JSON.parse(content);
  return renderPreview(concept);
}
```

---

## Step 4: Update Discord to Attach Image

Update `src/discord.ts` to accept an optional image path:

```typescript
import { readFileSync } from 'fs';
import { basename } from 'path';
import type { SkinConcept } from './types.js';

// ... (keep existing DiscordEmbed interface and hexToDecimal)

export async function postToDiscord(
  concept: SkinConcept,
  imagePath?: string
): Promise<void> {
  const webhookUrl = process.env.DISCORD_WEBHOOK_URL;
  if (!webhookUrl) {
    console.log('⚠️  DISCORD_WEBHOOK_URL not set, skipping Discord post');
    return;
  }

  const embed = {
    title: `🎨 New Skin: ${concept.name}`,
    description: `**Vibe:** ${concept.vibe}`,
    color: hexToDecimal(concept.colorPalette.primary),
    fields: [
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
      {
        name: '💬 Personality',
        value: concept.personality.slice(0, 200) + (concept.personality.length > 200 ? '...' : ''),
        inline: false,
      },
    ],
    image: imagePath ? { url: 'attachment://preview.png' } : undefined,
    footer: { text: `ID: ${concept.id}` },
    timestamp: concept.createdAt,
  };

  // If we have an image, use FormData to upload
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
    // No image, simple JSON post
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

**Note:** You'll need to install `form-data`:
```bash
npm install form-data
npm install -D @types/form-data
```

---

## Step 5: Update CLI

Update `src/index.ts` to add the `--render` flag:

```typescript
import 'dotenv/config';
import { generateSkinConcept, saveConcept } from './skin-generator.js';
import { renderPreview, renderFromFile } from './renderer.js';
import { postToDiscord } from './discord.js';
import { readdirSync, readFileSync } from 'fs';
import { join } from 'path';
import type { SkinConcept } from './types.js';

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  switch (command) {
    case 'generate': {
      const moodIndex = args.indexOf('--mood');
      const mood = moodIndex !== -1 ? args[moodIndex + 1] : undefined;

      const noSave = args.includes('--no-save');
      const noPost = args.includes('--no-post');
      const shouldRender = args.includes('--render');

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
        
        // Post to Discord
        if (!noPost) {
          await postToDiscord(concept, imagePath);
        }

        console.log('\n📋 Full concept:');
        console.log(JSON.stringify(concept, null, 2));
      } catch (error) {
        console.error('❌ Error:', error);
        process.exit(1);
      }
      break;
    }

    case 'render': {
      // Render an existing concept file
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
        const files = readdirSync(conceptsDir).filter(f => f.endsWith('.json'));
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
  generate --no-save          Don't save to file
  generate --no-post          Don't post to Discord
  render <concept.json>       Render preview from existing concept
  list                        List recent concepts

Examples:
  npm run generate
  npm run generate -- --mood "underwater bioluminescence" --render
  npm run render output/concepts/2025-12-20-neon-dreams.json
      `);
  }
}

main();
```

---

## Step 6: Update package.json Scripts

```json
{
  "scripts": {
    "generate": "tsx src/index.ts generate",
    "render": "tsx src/index.ts render",
    "list": "tsx src/index.ts list"
  }
}
```

---

## Step 7: Create templates Directory

```bash
mkdir -p src/templates
```

Then create the `preview.html` file from Step 2.

---

## Exit Criteria

- [ ] `npm run generate -- --render` creates a concept + preview image
- [ ] Preview saved to `output/previews/YYYY-MM-DD-{slug}.png`
- [ ] Image is 1080x1080
- [ ] Colors match the skin concept's palette
- [ ] Discord embed shows the preview image as attachment
- [ ] `npm run render output/concepts/some-concept.json` works for existing concepts
- [ ] TypeScript compiles with no errors

---

## If You Get Stuck

### Puppeteer won't launch
- On macOS, try: `npm install puppeteer` (it downloads Chromium)
- Check for errors about missing dependencies
- Try adding `headless: 'new'` instead of `headless: true`

### Discord image not showing
- Check that `form-data` is installed
- Verify the image file exists before posting
- Check Discord webhook URL is correct
- Look at the response body for error details

### Template looks wrong
- Open the generated HTML directly in a browser to debug
- Check color hex codes are valid (include `#`)
- Verify template placeholders are being replaced

### Questions for Opus
If truly stuck, format your question like:
```
## BLOCKED: [Brief description]
**What I tried:** [List]
**Error:** [Exact message]
**Question:** [What you need to know]
```

---

## What You'll Have After This Phase

1. **Preview images** that look like movie posters for each skin
2. **Discord embeds** with the image attached
3. **Reusable template** that can be tweaked for different styles
4. **CLI commands** for generating with or without renders

Next phase will add caption generation for Instagram/Twitter/Facebook.

Good luck! 📸

