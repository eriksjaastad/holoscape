import type { LoggerService } from '../services/logger';
import type { KeychainService } from '../services/keychain';

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface StreamCallbacks {
  onToken: (token: string) => void;
  onComplete: (fullResponse: string) => void;
  onError: (error: Error) => void;
}

export interface AdapterConfig {
  model?: string;
  temperature?: number;
  maxTokens?: number;
  systemPrompt?: string;
}

export interface AdapterCapabilities {
  streaming: boolean;
  vision: boolean;
  functionCalling: boolean;
  maxContextTokens: number;
}

export type ProviderType = 'openai' | 'anthropic' | 'google' | 'custom';

export interface ConnectionProfile {
  id: string;
  name: string;
  provider: ProviderType;
  keychainKey: string; // Key name in keychain (e.g., 'openai', 'anthropic')
  config: AdapterConfig;
  customConfig?: {
    // For custom endpoints
    baseUrl?: string;
    apiPath?: string;
    headers?: Record<string, string>;
    authType?: 'bearer' | 'x-api-key' | 'custom';
    authHeader?: string;
  };
  isDefault: boolean;
  createdAt: string;
  lastUsedAt?: string;
}

export abstract class BaseAdapter {
  protected keychain: KeychainService;
  protected logger: LoggerService;
  protected config: AdapterConfig;
  protected abortController: AbortController | null = null;

  abstract readonly provider: ProviderType;
  abstract readonly capabilities: AdapterCapabilities;
  abstract readonly defaultModel: string;

  constructor(
    keychain: KeychainService,
    logger: LoggerService,
    config: Partial<AdapterConfig> = {}
  ) {
    this.keychain = keychain;
    this.logger = logger;
    this.config = {
      temperature: 0.7,
      maxTokens: 2048,
      ...config,
    };
  }

  /**
   * Stream a chat completion
   */
  abstract streamChat(messages: ChatMessage[], callbacks: StreamCallbacks): Promise<void>;

  /**
   * Check if the adapter is configured (has API key)
   */
  abstract isConfigured(): Promise<boolean>;

  /**
   * Get the API key from keychain
   */
  protected abstract getApiKey(): Promise<string | null>;

  /**
   * Abort any in-progress request
   */
  abort(): void {
    this.abortController?.abort();
    this.abortController = null;
  }

  /**
   * Update configuration
   */
  setConfig(config: Partial<AdapterConfig>): void {
    this.config = { ...this.config, ...config };
  }

  /**
   * Get current model
   */
  getModel(): string {
    return this.config.model || this.defaultModel;
  }
}
