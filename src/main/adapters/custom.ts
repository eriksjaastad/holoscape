import {
  BaseAdapter,
  ChatMessage,
  StreamCallbacks,
  AdapterConfig,
  AdapterCapabilities,
  ProviderType,
} from './base';
import type { KeychainService } from '../services/keychain';
import type { LoggerService } from '../services/logger';

export interface CustomEndpointConfig extends AdapterConfig {
  baseUrl: string;
  apiPath?: string; // defaults to /v1/chat/completions
  headers?: Record<string, string>;
  authType?: 'bearer' | 'x-api-key' | 'custom';
  authHeader?: string; // custom header name for auth
}

export class CustomAdapter extends BaseAdapter {
  readonly provider: ProviderType = 'custom';
  readonly defaultModel = 'default';
  readonly capabilities: AdapterCapabilities = {
    streaming: true,
    vision: false, // unknown
    functionCalling: false, // unknown
    maxContextTokens: 8192, // conservative default
  };

  private customConfig: CustomEndpointConfig;
  private keychainKey: string;

  constructor(
    keychain: KeychainService,
    logger: LoggerService,
    config: Partial<CustomEndpointConfig> = {},
    keychainKey: string = 'custom'
  ) {
    super(keychain, logger, config);
    this.keychainKey = keychainKey;
    this.customConfig = {
      baseUrl: '',
      apiPath: '/v1/chat/completions',
      authType: 'bearer',
      ...config,
    };
  }

  protected async getApiKey(): Promise<string | null> {
    return this.keychain.getKey(this.keychainKey);
  }

  async isConfigured(): Promise<boolean> {
    const hasKey = await this.keychain.hasKey(this.keychainKey);
    const hasUrl = !!this.customConfig.baseUrl;
    return hasKey && hasUrl;
  }

  private buildAuthHeader(apiKey: string): Record<string, string> {
    switch (this.customConfig.authType) {
      case 'bearer':
        return { Authorization: `Bearer ${apiKey}` };
      case 'x-api-key':
        return { 'x-api-key': apiKey };
      case 'custom':
        return this.customConfig.authHeader ? { [this.customConfig.authHeader]: apiKey } : {};
      default:
        return { Authorization: `Bearer ${apiKey}` };
    }
  }

  async streamChat(messages: ChatMessage[], callbacks: StreamCallbacks): Promise<void> {
    const apiKey = await this.getApiKey();

    if (!apiKey) {
      callbacks.onError(new Error('API key not configured for custom endpoint'));
      return;
    }

    if (!this.customConfig.baseUrl) {
      callbacks.onError(new Error('Base URL not configured for custom endpoint'));
      return;
    }

    this.abortController = new AbortController();
    let fullResponse = '';

    try {
      const url = `${this.customConfig.baseUrl}${this.customConfig.apiPath}`;

      this.logger.debug('Custom endpoint request starting', {
        url: this.customConfig.baseUrl, // Don't log full URL with path
        model: this.getModel(),
        messageCount: messages.length,
      });

      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...this.buildAuthHeader(apiKey),
          ...this.customConfig.headers,
        },
        body: JSON.stringify({
          model: this.getModel(),
          messages,
          temperature: this.config.temperature,
          max_tokens: this.config.maxTokens,
          stream: true,
        }),
        signal: this.abortController.signal,
      });

      if (!response.ok) {
        this.logger.error('Custom endpoint request failed', {
          status: response.status,
          statusText: response.statusText,
        });
        throw new Error(`Custom API error: ${response.status} ${response.statusText}`);
      }

      const reader = response.body?.getReader();
      if (!reader) {
        throw new Error('No response body');
      }

      const decoder = new TextDecoder();
      let buffer = '';

      // OpenAI-compatible SSE format
      // eslint-disable-next-line no-constant-condition
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
          if (line.startsWith('data: ')) {
            const data = line.slice(6);
            if (data === '[DONE]') continue;

            try {
              const parsed = JSON.parse(data);
              const token = parsed.choices?.[0]?.delta?.content;
              if (token) {
                fullResponse += token;
                callbacks.onToken(token);
              }
            } catch {
              // Skip malformed JSON
            }
          }
        }
      }

      this.logger.debug('Custom endpoint request complete', {
        responseLength: fullResponse.length,
      });

      callbacks.onComplete(fullResponse);
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') {
        this.logger.info('Custom endpoint request aborted');
        callbacks.onComplete(fullResponse);
      } else {
        this.logger.error('Custom endpoint streaming error', {
          message: error instanceof Error ? error.message : 'Unknown error',
        });
        callbacks.onError(error instanceof Error ? error : new Error(String(error)));
      }
    } finally {
      this.abortController = null;
    }
  }

  /**
   * Update custom endpoint configuration
   */
  setCustomConfig(config: Partial<CustomEndpointConfig>): void {
    this.customConfig = { ...this.customConfig, ...config };
  }
}
