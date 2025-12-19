import type { ChatMessageInput } from '@shared/ipc-types';

const API_URL = 'https://api.openai.com/v1/chat/completions';
const DEFAULT_MODEL = 'gpt-4o-mini';

type OpenAIStreamChunk = {
  choices?: Array<{
    delta?: {
      content?: string;
    };
  }>;
};

async function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function* simulateResponse(
  messages: ChatMessageInput[]
): AsyncGenerator<string, void, undefined> {
  const promptSummary = messages.map((m) => m.content.trim()).join(' | ');
  const payload = `Simulated response to: ${promptSummary || 'your message'}.`;
  const tokens = payload.split(' ');

  for (const token of tokens) {
    yield `${token} `;
    await sleep(120);
  }
}

export interface StreamOptions {
  apiKey?: string;
  messages: ChatMessageInput[];
  model?: string;
}

export async function* streamChatCompletion({
  apiKey,
  messages,
  model = DEFAULT_MODEL,
}: StreamOptions): AsyncGenerator<string, void, undefined> {
  if (!Array.isArray(messages) || messages.length === 0) {
    throw new Error('OpenAI streaming requires at least one message.');
  }

  if (!apiKey) {
    yield* simulateResponse(messages);
    return;
  }

  const response = await fetch(API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      messages,
      stream: true,
    }),
  });

  if (!response.ok) {
    let errorMessage = 'OpenAI streaming request failed.';
    try {
      const errorPayload = await response.json();
      if (errorPayload?.error?.message) {
        errorMessage = errorPayload.error.message;
      }
    } catch (err) {
      console.warn('Failed to parse OpenAI error payload', err);
    }
    throw new Error(errorMessage);
  }

  const reader = response.body?.getReader();
  if (!reader) {
    throw new Error('Unable to read response stream.');
  }

  const decoder = new TextDecoder();
  let buffer = '';

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) {
        break;
      }

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';

      for (let line of lines) {
        line = line.trim();
        if (!line) {
          continue;
        }
        if (line === 'data: [DONE]') {
          return;
        }
        if (!line.startsWith('data:')) {
          continue;
        }

        const jsonString = line.replace(/^data:\s*/, '');
        let parsed: OpenAIStreamChunk;
        try {
          parsed = JSON.parse(jsonString) as OpenAIStreamChunk;
        } catch (err) {
          console.warn('Failed to parse OpenAI stream chunk', err);
          continue;
        }

        const token = parsed?.choices?.[0]?.delta?.content;
        if (token) {
          yield token;
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}
