import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { app } from 'electron';
import type { Service } from './index';
import { createLogger } from './logger';

const log = createLogger('Orchestrator');

interface PersonalityConfig {
  name: string;
  systemPrompt: string;
  temperature: number;
  maxTokens: number;
}

const DEFAULT_PERSONALITY: PersonalityConfig = {
  name: 'Hologram',
  systemPrompt: 'You are Hologram, a helpful AI assistant.',
  temperature: 0.7,
  maxTokens: 2048,
};

export class OrchestratorService implements Service {
  name = 'orchestrator';
  private personality: PersonalityConfig = DEFAULT_PERSONALITY;

  private loadPersonality(): PersonalityConfig {
    const paths = [
      join(process.cwd(), 'config', 'personality.json'),
      join(app.getAppPath(), 'config', 'personality.json'),
    ];

    for (const configPath of paths) {
      if (existsSync(configPath)) {
        try {
          const content = readFileSync(configPath, 'utf-8');
          const parsed = JSON.parse(content) as PersonalityConfig;
          log.info('Personality loaded', { path: configPath, name: parsed.name });
          return parsed;
        } catch (error) {
          log.warn('Failed to parse personality config', { path: configPath, error });
        }
      }
    }

    log.warn('No personality config found, using defaults');
    return DEFAULT_PERSONALITY;
  }

  getSystemPrompt(): string {
    return this.personality.systemPrompt;
  }

  getTemperature(): number {
    return this.personality.temperature;
  }

  getMaxTokens(): number {
    return this.personality.maxTokens;
  }

  async initialize(): Promise<void> {
    this.personality = this.loadPersonality();
    log.info('Orchestrator initialized', { personality: this.personality.name });
  }

  async shutdown(): Promise<void> {
    log.info('Orchestrator shutdown');
  }
}
