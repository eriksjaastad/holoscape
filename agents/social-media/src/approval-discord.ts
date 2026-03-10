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
