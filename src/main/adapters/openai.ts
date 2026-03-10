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

const API_URL = 'https://api.openai.com/v1/chat/completions';

export class OpenAIAdapter extends BaseAdapter {
  readonly provider: ProviderType = 'openai';
  readonly defaultModel = 'gpt-4o';
  readonly capabilities: AdapterCapabilities = {
    streaming: true,
    vision: true,
    functionCalling: true,
    maxContextTokens: 128000,
  };

  constructor(
    keychain: KeychainService,
    logger: LoggerService,
    config: Partial<AdapterConfig> = {}
  ) {
    super(keychain, logger, config);
  }

  protected async getApiKey(): Promise<string | null> {
    return this.keychain.getKey('openai');
  }

  async isConfigured(): Promise<boolean> {
    return this.keychain.hasKey('openai');
  }

  async streamChat(messages: ChatMessage[], callbacks: StreamCallbacks): Promise<void> {
    const apiKey = await this.getApiKey();

    if (!apiKey) {
      callbacks.onError(new Error('OpenAI API key not configured'));
      return;
    }

    this.abortController = new AbortController();
    let fullResponse = '';

    try {
      this.logger.debug('OpenAI request starting', {
        model: this.getModel(),
        messageCount: messages.length,
      });

      const response = await fetch(API_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${apiKey}`,
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
        this.logger.error('OpenAI request failed', {
          status: response.status,
          statusText: response.statusText,
        });
        throw new Error(`OpenAI API error: ${response.status} ${response.statusText}`);
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

      this.logger.debug('OpenAI request complete', {
        responseLength: fullResponse.length,
      });

      callbacks.onComplete(fullResponse);
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') {
        this.logger.info('OpenAI request aborted');
        callbacks.onComplete(fullResponse);
      } else {
        this.logger.error('OpenAI streaming error', {
          message: error instanceof Error ? error.message : 'Unknown error',
        });
        callbacks.onError(error instanceof Error ? error : new Error(String(error)));
      }
    } finally {
      this.abortController = null;
    }
  }
}
