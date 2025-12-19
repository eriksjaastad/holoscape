import OpenAI from 'openai';
import { randomUUID } from 'crypto';
import { writeFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import type { SkinConcept } from './types.js';
import { buildGeneratePrompt } from './prompts.js';
import { slugify } from './utils.js';

let openai: OpenAI | null = null;

function getOpenAI(): OpenAI {
  if (!openai) {
    if (!process.env.OPENAI_API_KEY) {
      throw new Error(
        'OPENAI_API_KEY environment variable is required. Please set it in your .env file.'
      );
    }
    openai = new OpenAI({
      apiKey: process.env.OPENAI_API_KEY,
    });
  }
  return openai;
}

// Random moods for when none is provided
const RANDOM_MOODS = [
  'Westworld meets vaporwave',
  'Cozy library at night',
  'Cyberpunk hacker den',
  'Underwater bioluminescence',
  'Art deco jazz club',
  'Scandinavian minimalism',
  'Retro 80s arcade',
  'Japanese zen garden',
  'Steampunk workshop',
  'Northern lights in space',
  'Film noir detective office',
  'Tropical sunset paradise',
];

function getRandomMood(): string {
  return RANDOM_MOODS[Math.floor(Math.random() * RANDOM_MOODS.length)];
}

export async function generateSkinConcept(mood?: string): Promise<SkinConcept> {
  const actualMood = mood || getRandomMood();
  console.log(`🎨 Generating skin for mood: "${actualMood}"`);

  const client = getOpenAI();
  const response = await client.chat.completions.create({
    model: 'gpt-4o-mini',
    messages: [{ role: 'user', content: buildGeneratePrompt(actualMood) }],
    temperature: 0.9,
  });

  const content = response.choices[0]?.message?.content;
  if (!content) {
    throw new Error('No response from OpenAI');
  }

  // Parse JSON from response
  const jsonMatch = content.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    throw new Error('Could not parse JSON from response');
  }

  const parsed = JSON.parse(jsonMatch[0]);

  const concept: SkinConcept = {
    id: randomUUID(),
    createdAt: new Date().toISOString(),
    mood: actualMood,
    name: parsed.name,
    windowShape: parsed.windowShape,
    colorPalette: parsed.colorPalette,
    particleBehavior: parsed.particleBehavior,
    typography: parsed.typography,
    personality: parsed.personality,
    vibe: parsed.vibe,
  };

  console.log(`✅ Generated: "${concept.name}"`);
  return concept;
}

export function saveConcept(concept: SkinConcept): string {
  const outputDir = join(process.cwd(), 'output', 'concepts');
  if (!existsSync(outputDir)) {
    mkdirSync(outputDir, { recursive: true });
  }

  const date = new Date().toISOString().split('T')[0];
  const slug = slugify(concept.name);
  const filename = `${date}-${slug}.json`;
  const filepath = join(outputDir, filename);

  writeFileSync(filepath, JSON.stringify(concept, null, 2));
  console.log(`💾 Saved to: output/concepts/${filename}`);

  return filepath;
}
