import 'dotenv/config';
import { generateSkinConcept, saveConcept } from './skin-generator.js';
import { renderPreview, renderFromFile } from './renderer.js';
import { generateCaptions } from './caption.js';
import { postToDiscord } from './discord.js';
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
  
  render <concept.json>       Render preview from existing concept
  caption <concept.json>      Generate captions for existing concept
  list                        List recent concepts

Examples:
  npm run generate
  npm run generate -- --mood "underwater bioluminescence" --render
  npm run generate -- --mood "cyberpunk neon" --render --caption
  npm run caption output/concepts/2025-12-19-zen-harmony.json
      `);
  }
}

main();
