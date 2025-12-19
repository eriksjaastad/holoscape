import { readFileSync } from 'fs';
import type { SkinConcept, CaptionSet } from './types.js';
import { formatCaptionForDiscord } from './caption.js';

interface DiscordEmbed {
  title: string;
  description: string;
  color: number;
  fields: Array<{ name: string; value: string; inline?: boolean }>;
  footer: { text: string };
  timestamp: string;
  image?: { url: string };
}

function hexToDecimal(hex: string): number {
  return parseInt(hex.replace('#', ''), 16);
}

export async function postToDiscord(
  concept: SkinConcept,
  imagePath?: string,
  captions?: CaptionSet
): Promise<void> {
  const webhookUrl = process.env.DISCORD_WEBHOOK_URL;
  if (!webhookUrl) {
    console.log('⚠️  DISCORD_WEBHOOK_URL not set, skipping Discord post');
    return;
  }

  const fields: Array<{ name: string; value: string; inline?: boolean }> = [
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
  ];

  // Add caption fields if provided
  if (captions) {
    fields.push(
      {
        name: '📸 Instagram',
        value: formatCaptionForDiscord(captions.instagram),
        inline: false,
      },
      {
        name: '🐦 Twitter',
        value: formatCaptionForDiscord(captions.twitter),
        inline: false,
      },
      {
        name: '📘 Facebook',
        value: formatCaptionForDiscord(captions.facebook),
        inline: false,
      }
    );
  } else {
    // Original personality field when no captions
    fields.push({
      name: '💬 Personality',
      value: concept.personality.slice(0, 200) + (concept.personality.length > 200 ? '...' : ''),
      inline: false,
    });
  }

  const embed: DiscordEmbed = {
    title: `🎨 New Skin: ${concept.name}`,
    description: `**Vibe:** ${concept.vibe}`,
    color: hexToDecimal(concept.colorPalette.primary),
    fields,
    footer: { text: `ID: ${concept.id}` },
    timestamp: concept.createdAt,
    image: imagePath ? { url: 'attachment://preview.png' } : undefined,
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
