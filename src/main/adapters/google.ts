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

const API_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';

export class GoogleAdapter extends BaseAdapter {
  readonly provider: ProviderType = 'google';
  readonly defaultModel = 'gemini-1.5-pro';
  readonly capabilities: AdapterCapabilities = {
    streaming: true,
    vision: true,
    functionCalling: true,
    maxContextTokens: 1000000, // Gemini 1.5 Pro
  };

  constructor(
    keychain: KeychainService,
    logger: LoggerService,
    config: Partial<AdapterConfig> = {}
  ) {
    super(keychain, logger, config);
  }

  protected async getApiKey(): Promise<string | null> {
    return this.keychain.getKey('google');
  }

  async isConfigured(): Promise<boolean> {
    return this.keychain.hasKey('google');
  }

  async streamChat(messages: ChatMessage[], callbacks: StreamCallbacks): Promise<void> {
    const apiKey = await this.getApiKey();

    if (!apiKey) {
      callbacks.onError(new Error('Google API key not configured'));
      return;
    }

    this.abortController = new AbortController();
    let fullResponse = '';

    try {
      // Convert to Gemini format
      const systemInstruction = messages.find((m) => m.role === 'system')?.content;
      const contents = messages
        .filter((m) => m.role !== 'system')
        .map((m) => ({
          role: m.role === 'assistant' ? 'model' : 'user',
          parts: [{ text: m.content }],
        }));

      const model = this.getModel();
      const url = `${API_BASE}/${model}:streamGenerateContent?key=${apiKey}`;

      this.logger.debug('Google request starting', {
        model,
        messageCount: contents.length,
      });

      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          contents,
          systemInstruction: systemInstruction
            ? { parts: [{ text: systemInstruction }] }
            : undefined,
          generationConfig: {
            temperature: this.config.temperature,
            maxOutputTokens: this.config.maxTokens,
          },
        }),
        signal: this.abortController.signal,
      });

      if (!response.ok) {
        this.logger.error('Google request failed', {
          status: response.status,
          statusText: response.statusText,
        });
        throw new Error(`Google API error: ${response.status} ${response.statusText}`);
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

        // Google returns newline-delimited JSON
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
          if (!line.trim()) continue;

          try {
            const parsed = JSON.parse(line);
            const token = parsed.candidates?.[0]?.content?.parts?.[0]?.text;
            if (token) {
              fullResponse += token;
              callbacks.onToken(token);
            }
          } catch {
            // Skip malformed JSON
          }
        }
      }

      this.logger.debug('Google request complete', {
        responseLength: fullResponse.length,
      });

      callbacks.onComplete(fullResponse);
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') {
        this.logger.info('Google request aborted');
        callbacks.onComplete(fullResponse);
      } else {
        this.logger.error('Google streaming error', {
          message: error instanceof Error ? error.message : 'Unknown error',
        });
        callbacks.onError(error instanceof Error ? error : new Error(String(error)));
      }
    } finally {
      this.abortController = null;
    }
  }
}
