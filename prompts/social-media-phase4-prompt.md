# Sonnet: Social Media Agent — Phase 4: Manual Posting Workflow

## Your Mission
Create a human-in-the-loop approval workflow. The agent generates a complete "Post Package" and sends it to Discord for review. You manually post to social media, but the agent does all the thinking.

## The Key Insight

**Don't fight Instagram APIs yet.** The hard part is:
- Deciding what to post
- Generating the right caption
- Packaging it nicely

You're just the "last mile" button-presser. Auto-posting can be swapped in later.

## Context

### What exists (Phases 1-3):
- Skin concept generator
- Preview image renderer (Puppeteer)
- Caption generator (Instagram, Twitter, Facebook)
- Discord webhook posting

### What you're adding:
- `PostPackage` type — complete bundle for a post
- Decision logger — tracks approvals/rejections
- Approval Discord embed with reaction prompts
- Easy-copy formatting for manual posting

---

## Project Location

All work in: `/Users/eriksjaastad/projects/hologram/agents/social-media/`

---

## Step 1: Create Post Package Types

Update `src/types.ts` — add these types:

```typescript
// ... existing types ...

export type PostStatus = 'pending' | 'approved' | 'rejected' | 'posted';

export interface PostPackage {
  id: string;
  createdAt: string;
  concept: SkinConcept;
  imagePath: string;
  captions: CaptionSet;
  altText: string;
  suggestedTime: string;
  reasoning: string;
  platforms: Platform[];
  status: PostStatus;
  approvedAt?: string;
  rejectedAt?: string;
  rejectedReason?: string;
  postedAt?: string;
}

export interface Decision {
  id: string;
  packageId: string;
  action: 'created' | 'approved' | 'rejected' | 'regenerated' | 'posted';
  timestamp: string;
  reason?: string;
  metadata?: Record<string, unknown>;
}
```

---

## Step 2: Create Decision Logger

Create `src/decision-logger.ts`:

```typescript
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import type { Decision, PostPackage } from './types.js';

const DATA_DIR = join(process.cwd(), 'data');
const DECISIONS_FILE = join(DATA_DIR, 'decisions.json');
const PACKAGES_FILE = join(DATA_DIR, 'packages.json');

function ensureDataDir(): void {
  if (!existsSync(DATA_DIR)) {
    mkdirSync(DATA_DIR, { recursive: true });
  }
}

function loadDecisions(): Decision[] {
  ensureDataDir();
  if (!existsSync(DECISIONS_FILE)) {
    return [];
  }
  return JSON.parse(readFileSync(DECISIONS_FILE, 'utf-8'));
}

function saveDecisions(decisions: Decision[]): void {
  ensureDataDir();
  writeFileSync(DECISIONS_FILE, JSON.stringify(decisions, null, 2));
}

function loadPackages(): PostPackage[] {
  ensureDataDir();
  if (!existsSync(PACKAGES_FILE)) {
    return [];
  }
  return JSON.parse(readFileSync(PACKAGES_FILE, 'utf-8'));
}

function savePackages(packages: PostPackage[]): void {
  ensureDataDir();
  writeFileSync(PACKAGES_FILE, JSON.stringify(packages, null, 2));
}

export function logDecision(
  packageId: string,
  action: Decision['action'],
  reason?: string,
  metadata?: Record<string, unknown>
): Decision {
  const decision: Decision = {
    id: randomUUID(),
    packageId,
    action,
    timestamp: new Date().toISOString(),
    reason,
    metadata,
  };

  const decisions = loadDecisions();
  decisions.push(decision);
  saveDecisions(decisions);

  console.log(`📋 Decision logged: ${action} for package ${packageId.slice(0, 8)}...`);
  return decision;
}

export function savePackage(pkg: PostPackage): void {
  const packages = loadPackages();
  const existingIndex = packages.findIndex(p => p.id === pkg.id);
  
  if (existingIndex >= 0) {
    packages[existingIndex] = pkg;
  } else {
    packages.push(pkg);
  }
  
  savePackages(packages);
}

export function getPackage(id: string): PostPackage | undefined {
  const packages = loadPackages();
  return packages.find(p => p.id === id);
}

export function updatePackageStatus(
  id: string,
  status: PostPackage['status'],
  extra?: Partial<PostPackage>
): PostPackage | undefined {
  const packages = loadPackages();
  const pkg = packages.find(p => p.id === id);
  
  if (!pkg) {
    console.error(`Package ${id} not found`);
    return undefined;
  }

  pkg.status = status;
  if (extra) {
    Object.assign(pkg, extra);
  }

  savePackages(packages);
  return pkg;
}

export function getPendingPackages(): PostPackage[] {
  return loadPackages().filter(p => p.status === 'pending');
}

export function getApprovedPackages(): PostPackage[] {
  return loadPackages().filter(p => p.status === 'approved');
}

export function getDecisionHistory(packageId: string): Decision[] {
  return loadDecisions().filter(d => d.packageId === packageId);
}
```

---

## Step 3: Create Post Package Generator

Create `src/package-generator.ts`:

```typescript
import { randomUUID } from 'crypto';
import type { SkinConcept, CaptionSet, PostPackage, Platform } from './types.js';
import { logDecision, savePackage } from './decision-logger.js';

function generateAltText(concept: SkinConcept): string {
  return `Hologram AI skin called "${concept.name}". ${concept.vibe}. Features a ${concept.windowShape.toLowerCase()} window with ${concept.particleBehavior.toLowerCase()}.`;
}

function getSuggestedTime(): string {
  // Best times for engagement (general social media wisdom)
  const bestHours = [9, 12, 17, 19]; // 9am, noon, 5pm, 7pm
  const hour = bestHours[Math.floor(Math.random() * bestHours.length)];
  
  const tomorrow = new Date();
  tomorrow.setDate(tomorrow.getDate() + 1);
  tomorrow.setHours(hour, 0, 0, 0);
  
  return tomorrow.toISOString();
}

function generateReasoning(concept: SkinConcept): string {
  const reasons = [
    `The "${concept.name}" skin has a strong visual identity that should perform well on visual platforms.`,
    `Color palette (${concept.colorPalette.primary}/${concept.colorPalette.secondary}) creates good contrast for feeds.`,
    `The "${concept.vibe}" theme is trending and relatable.`,
    `Window shape "${concept.windowShape}" is unique and eye-catching.`,
  ];
  
  // Pick 2-3 random reasons
  const selected = reasons
    .sort(() => Math.random() - 0.5)
    .slice(0, 2 + Math.floor(Math.random() * 2));
  
  return selected.join(' ');
}

export function createPostPackage(
  concept: SkinConcept,
  imagePath: string,
  captions: CaptionSet,
  platforms: Platform[] = ['instagram', 'twitter', 'facebook']
): PostPackage {
  const pkg: PostPackage = {
    id: randomUUID(),
    createdAt: new Date().toISOString(),
    concept,
    imagePath,
    captions,
    altText: generateAltText(concept),
    suggestedTime: getSuggestedTime(),
    reasoning: generateReasoning(concept),
    platforms,
    status: 'pending',
  };

  // Save and log
  savePackage(pkg);
  logDecision(pkg.id, 'created', undefined, {
    skinName: concept.name,
    platforms,
  });

  console.log(`📦 Post package created: ${pkg.id.slice(0, 8)}...`);
  return pkg;
}
```

---

## Step 4: Create Approval Discord Embed

Create `src/approval-discord.ts`:

```typescript
import { readFileSync } from 'fs';
import type { PostPackage } from './types.js';
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

function formatForCopy(text: string): string {
  // Wrap in code block for easy copy
  return `\`\`\`\n${text}\n\`\`\``;
}

export async function postApprovalRequest(pkg: PostPackage): Promise<void> {
  const webhookUrl = process.env.DISCORD_WEBHOOK_URL;
  if (!webhookUrl) {
    console.log('⚠️  DISCORD_WEBHOOK_URL not set, skipping Discord post');
    return;
  }

  const instagramCaption = formatCaptionForDiscord(pkg.captions.instagram);
  const twitterCaption = formatCaptionForDiscord(pkg.captions.twitter);
  const facebookCaption = formatCaptionForDiscord(pkg.captions.facebook);

  const embed: DiscordEmbed = {
    title: `📬 Post Ready: ${pkg.concept.name}`,
    description: `**Vibe:** ${pkg.concept.vibe}\n\n**React to approve:**\n✅ Approve  ❌ Reject  🔄 Regenerate  📌 Save for later`,
    color: hexToDecimal(pkg.concept.colorPalette.primary),
    fields: [
      {
        name: '📸 Instagram Caption (copy this)',
        value: formatForCopy(instagramCaption),
        inline: false,
      },
      {
        name: '🐦 Twitter Caption',
        value: formatForCopy(twitterCaption),
        inline: false,
      },
      {
        name: '📘 Facebook Caption',
        value: formatForCopy(facebookCaption),
        inline: false,
      },
      {
        name: '🖼️ Alt Text',
        value: formatForCopy(pkg.altText),
        inline: false,
      },
      {
        name: '🤔 Why this?',
        value: pkg.reasoning,
        inline: false,
      },
      {
        name: '📅 Suggested Time',
        value: new Date(pkg.suggestedTime).toLocaleString(),
        inline: true,
      },
      {
        name: '📱 Platforms',
        value: pkg.platforms.join(', '),
        inline: true,
      },
    ],
    image: { url: 'attachment://preview.png' },
    footer: { text: `Package ID: ${pkg.id}` },
    timestamp: pkg.createdAt,
  };

  // Post with image attachment
  const FormData = (await import('form-data')).default;
  const form = new FormData();
  
  form.append('payload_json', JSON.stringify({ embeds: [embed] }));
  form.append('files[0]', readFileSync(pkg.imagePath), {
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

  console.log('📤 Approval request posted to Discord!');
  console.log(`   React ✅ to approve, ❌ to reject`);
}
```

---

## Step 5: Update CLI

Update `src/index.ts` — add new commands:

```typescript
import 'dotenv/config';
import { generateSkinConcept, saveConcept } from './skin-generator.js';
import { renderPreview, renderFromFile } from './renderer.js';
import { generateCaptions } from './caption.js';
import { postToDiscord } from './discord.js';
import { createPostPackage } from './package-generator.js';
import { postApprovalRequest } from './approval-discord.js';
import { 
  logDecision, 
  updatePackageStatus, 
  getPendingPackages,
  getApprovedPackages,
  getPackage,
} from './decision-logger.js';
import { readdirSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import type { SkinConcept, CaptionSet, Platform } from './types.js';

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
      const shouldCaption = args.includes('--caption');

      try {
        const concept = await generateSkinConcept(mood);
        
        if (!noSave) {
          saveConcept(concept);
        }
        
        let imagePath: string | undefined;
        if (shouldRender) {
          imagePath = await renderPreview(concept);
        }

        let captions: CaptionSet | undefined;
        if (shouldCaption) {
          captions = await generateCaptions(concept);
          
          if (!noSave) {
            const date = new Date().toISOString().split('T')[0];
            const slug = concept.name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
            const captionsPath = join(process.cwd(), 'output', 'concepts', `${date}-${slug}-captions.json`);
            writeFileSync(captionsPath, JSON.stringify(captions, null, 2));
            console.log(`💾 Captions saved`);
          }
        }
        
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

    // NEW: Create full post package and request approval
    case 'package': {
      const moodIndex = args.indexOf('--mood');
      const mood = moodIndex !== -1 ? args[moodIndex + 1] : undefined;

      try {
        console.log('📦 Creating full post package...\n');

        // Generate everything
        const concept = await generateSkinConcept(mood);
        saveConcept(concept);

        const imagePath = await renderPreview(concept);
        const captions = await generateCaptions(concept);

        // Create package
        const pkg = createPostPackage(concept, imagePath, captions);

        // Post approval request to Discord
        await postApprovalRequest(pkg);

        console.log('\n✅ Post package ready for approval!');
        console.log(`   Package ID: ${pkg.id}`);
        console.log(`   Check Discord for the approval request.`);
      } catch (error) {
        console.error('❌ Error:', error);
        process.exit(1);
      }
      break;
    }

    // NEW: Approve a package
    case 'approve': {
      const packageId = args[1];
      if (!packageId) {
        console.error('Usage: approve <package-id>');
        process.exit(1);
      }

      const pkg = updatePackageStatus(packageId, 'approved', {
        approvedAt: new Date().toISOString(),
      });

      if (pkg) {
        logDecision(packageId, 'approved');
        console.log(`✅ Package ${packageId.slice(0, 8)}... approved!`);
        console.log(`   Now manually post to: ${pkg.platforms.join(', ')}`);
      }
      break;
    }

    // NEW: Reject a package
    case 'reject': {
      const packageId = args[1];
      const reasonIndex = args.indexOf('--reason');
      const reason = reasonIndex !== -1 ? args[reasonIndex + 1] : undefined;

      if (!packageId) {
        console.error('Usage: reject <package-id> [--reason "why"]');
        process.exit(1);
      }

      const pkg = updatePackageStatus(packageId, 'rejected', {
        rejectedAt: new Date().toISOString(),
        rejectedReason: reason,
      });

      if (pkg) {
        logDecision(packageId, 'rejected', reason);
        console.log(`❌ Package ${packageId.slice(0, 8)}... rejected.`);
        if (reason) {
          console.log(`   Reason: ${reason}`);
        }
      }
      break;
    }

    // NEW: Mark as posted
    case 'posted': {
      const packageId = args[1];
      if (!packageId) {
        console.error('Usage: posted <package-id>');
        process.exit(1);
      }

      const pkg = updatePackageStatus(packageId, 'posted', {
        postedAt: new Date().toISOString(),
      });

      if (pkg) {
        logDecision(packageId, 'posted');
        console.log(`📸 Package ${packageId.slice(0, 8)}... marked as posted!`);
      }
      break;
    }

    // NEW: List pending packages
    case 'pending': {
      const pending = getPendingPackages();
      console.log(`\n📬 Pending packages: ${pending.length}\n`);
      
      for (const pkg of pending) {
        console.log(`  • ${pkg.concept.name}`);
        console.log(`    ID: ${pkg.id}`);
        console.log(`    Created: ${new Date(pkg.createdAt).toLocaleString()}`);
        console.log(`    Platforms: ${pkg.platforms.join(', ')}\n`);
      }
      break;
    }

    // NEW: List approved packages
    case 'approved': {
      const approved = getApprovedPackages();
      console.log(`\n✅ Approved packages: ${approved.length}\n`);
      
      for (const pkg of approved) {
        console.log(`  • ${pkg.concept.name}`);
        console.log(`    ID: ${pkg.id}`);
        console.log(`    Approved: ${pkg.approvedAt ? new Date(pkg.approvedAt).toLocaleString() : 'unknown'}`);
        console.log(`    Platforms: ${pkg.platforms.join(', ')}\n`);
      }
      break;
    }

    case 'caption': {
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
  
  package                     Create full post package + request approval
  package --mood "X"          Package with specific mood
  
  approve <package-id>        Approve a pending package
  reject <package-id>         Reject a pending package
  reject <id> --reason "why"  Reject with reason
  posted <package-id>         Mark package as manually posted
  
  pending                     List pending packages
  approved                    List approved packages
  
  render <concept.json>       Render preview from existing concept
  caption <concept.json>      Generate captions for existing concept
  list                        List recent concepts

Examples:
  npm run package
  npm run package -- --mood "cyberpunk neon"
  npm run approve abc12345-def6-7890
  npm run posted abc12345-def6-7890
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
    "caption": "tsx src/index.ts caption",
    "list": "tsx src/index.ts list",
    "package": "tsx src/index.ts package",
    "approve": "tsx src/index.ts approve",
    "reject": "tsx src/index.ts reject",
    "posted": "tsx src/index.ts posted",
    "pending": "tsx src/index.ts pending",
    "approved": "tsx src/index.ts approved"
  }
}
```

---

## Step 7: Test the Workflow

```bash
# Create a full post package
npm run package

# Check Discord for approval request
# React ✅ in Discord, then run:
npm run approve <package-id>

# After manually posting to Instagram:
npm run posted <package-id>

# Check pending packages
npm run pending

# Check approved packages
npm run approved
```

---

## The Workflow

```
┌─────────────────────────────────────────────────────────────┐
│  1. Run: npm run package --mood "underwater temple"         │
│     → Generates concept, image, captions                    │
│     → Creates PostPackage with reasoning                    │
│     → Saves to data/packages.json                           │
│     → Posts approval request to Discord                     │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  2. Discord shows:                                          │
│     📬 Post Ready: Mystic Depths                            │
│     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━             │
│     📸 Instagram Caption (copy this):                       │
│     ```                                                     │
│     Dive into the depths with Mystic Depths 🌊              │
│     #hologram #AIart #underwater                            │
│     ```                                                     │
│     🤔 Why this?                                            │
│     Strong visual identity, trending theme...               │
│     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━             │
│     React: ✅ Approve  ❌ Reject  🔄 Regenerate              │
│     [PREVIEW IMAGE]                                         │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  3. You react ✅ in Discord                                 │
│  4. Run: npm run approve <package-id>                       │
│     → Status updated to "approved"                          │
│     → Logged in data/decisions.json                         │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  5. Copy caption from Discord                               │
│  6. Open Instagram, paste caption, upload image             │
│  7. Run: npm run posted <package-id>                        │
│     → Status updated to "posted"                            │
│     → Logged with timestamp                                 │
└─────────────────────────────────────────────────────────────┘
```

---

## Data Files

After running, you'll have:

```
data/
├── packages.json     # All post packages with status
└── decisions.json    # Full decision history (training data)
```

---

## Exit Criteria

- [ ] `npm run package` creates full PostPackage
- [ ] Discord shows: image, captions in code blocks, reasoning, platforms
- [ ] `npm run approve <id>` marks as approved
- [ ] `npm run reject <id>` marks as rejected
- [ ] `npm run posted <id>` marks as posted
- [ ] `npm run pending` shows pending packages
- [ ] `npm run approved` shows approved packages
- [ ] Decisions logged to `data/decisions.json`
- [ ] Packages stored in `data/packages.json`
- [ ] Captions are easy to copy (code block format)
- [ ] TypeScript compiles with no errors

---

## Files Summary

### Created:
- `src/decision-logger.ts` — Log decisions, manage packages
- `src/package-generator.ts` — Create PostPackage with reasoning
- `src/approval-discord.ts` — Discord embed for approval workflow

### Modified:
- `src/types.ts` — Added `PostPackage`, `Decision`, `PostStatus`
- `src/index.ts` — Added 6 new commands (package, approve, reject, posted, pending, approved)
- `package.json` — Added 6 new scripts

---

## If You Get Stuck

### Package not saving
- Check `data/` directory exists
- Check file permissions

### Discord embed too long
- Discord has a 6000 char limit per embed
- May need to truncate long captions

### Package ID not found
- Use full UUID or at least first 8 chars
- Check `npm run pending` to see IDs

---

## Why This Works

It *feels* like an agent because:
- All thinking (concept, design, caption, timing) is done
- You're just the button-presser
- Decision log becomes training data
- Swapping in auto-post later is a simple plugin

Good luck! 📬

