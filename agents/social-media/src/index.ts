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
} from './decision-logger.js';
import { slugify } from './utils.js';
import { readdirSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import type { SkinConcept, CaptionSet } from './types.js';

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  switch (command) {
    case 'generate': {
      // Parse --mood flag
      const moodIndex = args.indexOf('--mood');
      const mood = moodIndex !== -1 ? args[moodIndex + 1] : undefined;

      // Parse flags
      const noSave = args.includes('--no-save');
      const noPost = args.includes('--no-post');
      const shouldRender = args.includes('--render');
      const shouldCaption = args.includes('--caption');

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

        // Generate captions if requested
        let captions: CaptionSet | undefined;
        if (shouldCaption) {
          captions = await generateCaptions(concept);

          // Save captions alongside concept if saving
          if (!noSave) {
            const date = new Date().toISOString().split('T')[0];
            const slug = slugify(concept.name);
            const captionsPath = join(
              process.cwd(),
              'output',
              'concepts',
              `${date}-${slug}-captions.json`
            );
            writeFileSync(captionsPath, JSON.stringify(captions, null, 2));
            console.log(`💾 Captions saved`);
          }
        }

        // Post to Discord
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
        console.log(
          `    Approved: ${pkg.approvedAt ? new Date(pkg.approvedAt).toLocaleString() : 'unknown'}`
        );
        console.log(`    Platforms: ${pkg.platforms.join(', ')}\n`);
      }
      break;
    }

    case 'caption': {
      // Generate captions for an existing concept
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

        // Save captions
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
        const files = readdirSync(conceptsDir).filter(
          (f) => f.endsWith('.json') && !f.includes('captions')
        );
        console.log(`\n📁 Found ${files.length} concepts:\n`);

        for (const file of files.slice(-10)) {
          // Show last 10
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
  npm run generate
  npm run generate -- --mood "underwater bioluminescence" --render
  npm run generate -- --mood "cyberpunk neon" --render --caption
  npm run caption output/concepts/2025-12-19-zen-harmony.json
  
  npm run package
  npm run package -- --mood "cyberpunk neon"
  npm run approve abc12345-def6-7890
  npm run posted abc12345-def6-7890
      `);
  }
}

main();
