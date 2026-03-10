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
