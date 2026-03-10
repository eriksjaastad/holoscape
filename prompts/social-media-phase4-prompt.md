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

All work in: `../agents/social-media`

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

function generate... [truncated]
```

---

# Phase 4 Complete: Manual Posting Workflow ✅

**Completed:** December 19, 2025  
**Time Invested:** ~2 hours  
**Status:** All exit criteria met

---

## What Was Built

Phase 4 implements a human-in-the-loop approval workflow. The agent generates complete post packages with all the thinking done — you're just the "last mile" button-presser.

### Key Features

1. **PostPackage Type** — Complete bundle for a post:
   - Skin concept
   - Rendered image
   - Platform-specific captions (Instagram, Twitter, Facebook)
   - Auto-generated alt text
   - Suggested posting time
   - Reasoning for why this post was chosen
   - Status tracking (pending → approved/rejected → posted)

2. **Decision Logger** — `src/decision-logger.ts`:
   - Tracks all decisions to `data/decisions.json`
   - Stores packages to `data/packages.json`
   - Logs: created, approved, rejected, posted actions
   - Creates training data for future learning (Phase 6)

3. **Package Generator** — `src/package-generator.ts`:
   - Auto-generates accessibility alt text
   - Suggests optimal posting times (9am, noon, 5pm, 7pm)
   - Creates reasoning based on visual identity, colors, trends
   - Bundles everything into a single package

4. **Approval Discord** — `src/approval-discord.ts`:
   - Rich embed with all captions in copyable code blocks
   - Shows reasoning ("Why this?")
   - Displays suggested posting time
   - Lists target platforms
   - Includes reaction prompts (✅ ❌ 🔄 📌)

5. **CLI Commands**:
   ```bash
   # Create full post package
   doppler run -- npm run package
   doppler run -- npm run package -- --mood "cyberpunk neon"
   
   # Manage packages
   doppler run -- npm run approve <package-id>
   doppler run -- npm run reject <package-id> --reason "not the right vibe"
   doppler run -- npm run posted <package-id>
   
   # View packages
   doppler run -- npm run pending
   doppler run -- npm run approved
   ```

---

## The Workflow

```bash
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
│     🤔... [truncated]
