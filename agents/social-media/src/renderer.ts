import puppeteer from 'puppeteer';
import { readFileSync, mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import type { SkinConcept } from './types.js';
import { slugify } from './utils.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

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
  if (!existsSync(templatePath)) {
    throw new Error(`Template not found: ${templatePath}`);
  }
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
  const headless = process.env.PUPPETEER_HEADLESS !== 'false';
  const browser = await puppeteer.launch({
    headless,
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
