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

const API_URL = 'https://api.anthropic.com/v1/messages';
const ANTHROPIC_VERSION = '2023-06-01';

export class AnthropicAdapter extends BaseAdapter {
  readonly provider: ProviderType = 'anthropic';
  readonly defaultModel = 'claude-sonnet-4-20250514';
  readonly capabilities: AdapterCapabilities = {
    streaming: true,
    vision: true,
    functionCalling: true,
    maxContextTokens: 200000,
  };

  constructor(
    keychain: KeychainService,
    logger: LoggerService,
    config: Partial<AdapterConfig> = {}
  ) {
    super(keychain, logger, config);
  }

  protected async getApiKey(): Promise<string | null> {
    return this.keychain.getKey('anthropic');
  }

  async isConfigured(): Promise<boolean> {
    return this.keychain.hasKey('anthropic');
  }

  async streamChat(messages: ChatMessage[], callbacks: StreamCallbacks): Promise<void> {
    const apiKey = await this.getApiKey();

    if (!apiKey) {
      callbacks.onError(new Error('Anthropic API key not configured'));
      return;
    }

    this.abortController = new AbortController();
    let fullResponse = '';

    try {
      // Anthropic uses a different message format
      // System message is separate, not in messages array
      const systemMessage = messages.find((m) => m.role === 'system')?.content;
      const chatMessages = messages
        .filter((m) => m.role !== 'system')
        .map((m) => ({
          role: m.role as 'user' | 'assistant',
          content: m.content,
        }));

      this.logger.debug('Anthropic request starting', {
        model: this.getModel(),
        messageCount: chatMessages.length,
      });

      const response = await fetch(API_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': ANTHROPIC_VERSION,
        },
        body: JSON.stringify({
          model: this.getModel(),
          max_tokens: this.config.maxTokens,
          system: systemMessage || this.config.systemPrompt,
          messages: chatMessages,
          stream: true,
        }),
        signal: this.abortController.signal,
      });

      if (!response.ok) {
        this.logger.error('Anthropic request failed', {
          status: response.status,
          statusText: response.statusText,
        });
        throw new Error(`Anthropic API error: ${response.status} ${response.statusText}`);
      }

      const reader = response.body?.getReader();
      if (!reader) {
        throw new Error('No response body');
      }

      const decoder = new TextDecoder();
      let buffer = '';

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

            try {
              const parsed = JSON.parse(data);

              // Anthropic streaming format
              if (parsed.type === 'content_block_delta') {
                const token = parsed.delta?.text;
                if (token) {
                  fullResponse += token;
                  callbacks.onToken(token);
                }
              } else if (parsed.type === 'message_stop') {
                // Stream complete
                break;
              } else if (parsed.type === 'error') {
                throw new Error(parsed.error?.message || 'Anthropic stream error');
              }
            } catch (e) {
              if (e instanceof SyntaxError) {
                // Skip malformed JSON
                continue;
              }
              throw e;
            }
          }
        }
      }

      this.logger.debug('Anthropic request complete', {
        responseLength: fullResponse.length,
      });

      callbacks.onComplete(fullResponse);
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') {
        this.logger.info('Anthropic request aborted');
        callbacks.onComplete(fullResponse);
      } else {
        this.logger.error('Anthropic streaming error', {
          message: error instanceof Error ? error.message : 'Unknown error',
        });
        callbacks.onError(error instanceof Error ? error : new Error(String(error)));
      }
    } finally {
      this.abortController = null;
    }
  }
}
