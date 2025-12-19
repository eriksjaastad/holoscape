import OpenAI from 'openai';
import type { SkinConcept, Platform, Caption, CaptionSet } from './types.js';

let openai: OpenAI | null = null;

function getOpenAI(): OpenAI {
  if (!openai) {
    if (!process.env.OPENAI_API_KEY) {
      throw new Error('OPENAI_API_KEY environment variable is required.');
    }
    openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  }
  return openai;
}

const PLATFORM_PROMPTS: Record<Platform, string> = {
  instagram: `Write an Instagram caption for this AI assistant skin concept.

Rules:
- Max 150 characters before hashtags
- Excited but NOT cringe (no "game-changer", "revolutionary", etc.)
- 1-2 emoji max, placed naturally
- End with 3-5 relevant hashtags on a new line

Respond with ONLY valid JSON:
{
  "text": "Your caption here (with emoji if any)",
  "hashtags": ["hashtag1", "hashtag2", "hashtag3"]
}`,

  twitter: `Write a tweet for this AI assistant skin concept.

Rules:
- Max 200 characters total (including hashtags)
- Can be playful, witty, or provocative
- 1-2 hashtags at end only if room
- No emoji spam

Respond with ONLY valid JSON:
{
  "text": "Your tweet here",
  "hashtags": ["hashtag1"]
}`,

  facebook: `Write a Facebook post for this AI assistant skin concept.

Rules:
- 1-2 sentences, conversational tone
- Community-building: ask a question to encourage engagement
- No hashtags (Facebook doesn't need them)
- Can be warmer/longer than Twitter

Respond with ONLY valid JSON:
{
  "text": "Your post here with a question?",
  "hashtags": []
}`,
};

function buildCaptionPrompt(concept: SkinConcept, platform: Platform): string {
  return `${PLATFORM_PROMPTS[platform]}

Skin Concept:
- Name: ${concept.name}
- Vibe: ${concept.vibe}
- Colors: Primary ${concept.colorPalette.primary}, Secondary ${concept.colorPalette.secondary}
- Personality: ${concept.personality}
- Window Shape: ${concept.windowShape}
- Particles: ${concept.particleBehavior}`;
}

async function generateCaption(concept: SkinConcept, platform: Platform): Promise<Caption> {
  const client = getOpenAI();

  const response = await client.chat.completions.create({
    model: 'gpt-4o-mini',
    messages: [{ role: 'user', content: buildCaptionPrompt(concept, platform) }],
    temperature: 0.8,
  });

  const content = response.choices[0]?.message?.content;
  if (!content) {
    throw new Error(`No response from OpenAI for ${platform} caption`);
  }

  // Parse JSON from response
  const jsonMatch = content.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    throw new Error(`Could not parse JSON from ${platform} caption response`);
  }

  const parsed = JSON.parse(jsonMatch[0]);

  // Enforce character limits per platform (before hashtags)
  const limits: Record<Platform, number> = {
    instagram: 150,
    twitter: 180, // Leave room for hashtags (total limit 200)
    facebook: 300, // Flexible, but keep reasonable
  };

  let text = parsed.text;
  if (text.length > limits[platform]) {
    text = text.slice(0, limits[platform] - 3) + '...';
  }

  // Build full text with hashtags for character count
  const hashtagString =
    parsed.hashtags.length > 0
      ? '\n' + parsed.hashtags.map((h: string) => (h.startsWith('#') ? h : `#${h}`)).join(' ')
      : '';
  const fullText = text + hashtagString;

  // Note: Character count doesn't account for emoji being 2 chars on Twitter
  // Most emojis count as 2 characters on Twitter's platform
  return {
    platform,
    text,
    hashtags: parsed.hashtags.map((h: string) => (h.startsWith('#') ? h : `#${h}`)),
    characterCount: fullText.length,
  };
}

export async function generateCaptions(concept: SkinConcept): Promise<CaptionSet> {
  console.log(`📝 Generating captions for "${concept.name}"...`);

  // Generate all three in parallel for speed
  const [instagram, twitter, facebook] = await Promise.all([
    generateCaption(concept, 'instagram'),
    generateCaption(concept, 'twitter'),
    generateCaption(concept, 'facebook'),
  ]);

  console.log(`✅ Captions generated:`);
  console.log(`   Instagram: ${instagram.characterCount} chars`);
  console.log(`   Twitter: ${twitter.characterCount} chars`);
  console.log(`   Facebook: ${facebook.characterCount} chars`);

  return { instagram, twitter, facebook };
}

export function formatCaptionForDiscord(caption: Caption): string {
  const hashtags = caption.hashtags.length > 0 ? `\n${caption.hashtags.join(' ')}` : '';
  return `${caption.text}${hashtags}`;
}
