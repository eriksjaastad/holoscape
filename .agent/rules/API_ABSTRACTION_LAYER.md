# API Abstraction Layer

**Multi-AI Support Architecture**

---

## Overview

Hologram needs to connect to multiple AI services with different APIs, authentication methods, and response formats. The API Abstraction Layer normalizes these differences so the UI can work with any provider seamlessly. This layer provides a unified interface for interacting with various AI models, simplifying integration and enabling users to easily switch between providers. It handles authentication, request formatting, response parsing, and error handling, abstracting away the complexities of each individual AI service.

---

## Core Requirements

1. **Unified Interface** - All AI services expose the same methods to the UI, allowing for consistent interaction regardless of the underlying provider.
2. **Connection Profiles** - Users can configure multiple AI connections with different settings and credentials, enabling them to easily switch between providers or use multiple providers simultaneously.
3. **Secure Storage** - API keys and other sensitive credentials are encrypted at rest to protect user data.
4. **Streaming Support** - Real-time token streaming is supported for all providers, providing a more interactive and responsive user experience.
5. **Error Handling** - Graceful fallbacks and clear error messages are provided to handle errors and prevent application crashes.
6. **Parent API Option** - Support for Erik's parent API as a connection type, allowing users to leverage existing infrastructure.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────┐
│           Hologram UI Layer                 │
│  (Chat window, visualizer, settings)        │
└───────────────┬─────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────┐
│      Unified Chat Interface                 │
│  sendMessage(text, connection, options)     │
│  streamResponse(callback)                   │
│  getHistory(connection)                   │
└───────────────┬─────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────┐
│      API Abstraction Layer                  │
│  ┌─────────────────────────────────┐        │
│  │  Connection Manager             │        │
│  │  - Load profiles                │        │
│  │  - Validate credentials         │        │
│  │  - Route requests               │        │
│  └─────────────────────────────────┘        │
│                                              │
│  ┌─────────────────────────────────┐        │
│  │  Provider Adapters              │        │
│  │  - OpenAI Adapter               │        │
│  │  - Anthropic Adapter            │        │
│  │  - Google Adapter               │        │
│  │  - Custom/Cortana Adapter       │        │
│  └─────────────────────────────────┘        │
└───────────────┬─────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────┐
│      External AI Services                   │
│  OpenAI | Anthropic | Google | Cortana      │
└─────────────────────────────────────────────┘
```

---

## Components

*   **Connection Manager:** Responsible for loading, storing, and managing connection profiles. It validates credentials and routes requests to the appropriate provider adapter.
*   **Provider Adapters:** Implement the specific logic for interacting with each AI service. They handle authentication, request formatting, response parsing, and error handling. Each adapter exposes a consistent interface to the API Abstraction Layer.

---

## Connection Profile Schema

Each connection is stored as a JSON object with the following schema:

```json
{
  "id": "uuid-v4",
  "name": "GPT-4o",
  "type": "openai",
  "enabled": true,
  "config": {
    "api_key": "sk-...",  // Encrypted in storage
    "model": "gpt-4o",
    "endpoint": "https://api.openai.com/v1",  // Optional override
    "temperature": 0.7,
    "max_tokens": 2000,
    "system_prompt": "You are a helpful assistant."
  },
  "created_at": "2025-12-18T12:00:00Z",
  "last_used": "2025-12-18T14:30:00Z"
}
```

*   `id`: Unique identifier for the connection.
*   `name`: User-friendly name for the connection.
*   `type`: Type of AI service (e.g., "openai", "anthropic", "google", "custom", "parent_api").
*   `enabled`: Whether the connection is enabled.
*   `config`: Configuration settings specific to the AI service.
*   `created_at`: Timestamp of when the connection was created.
*   `last_used`: Timestamp of when the connection was last used.

### Special Types:

**OpenAI:**
```json
{
  "type": "openai",
  "config": {
    "api_key": "sk-...",
    "model": "gpt-4o" | "gpt-4" | "gpt-3.5-turbo"
  }
}
```

**Anthropic:**
```json
{
  "type": "anthropic",
  "config": {
    "api_key": "sk-ant-...",
    "model": "claude-3-5-sonnet-20241022" | "claude-3-opus-20240229"
  }
}
```

**Google:**
```json
{
  "type": "google",
  "config": {
    "api_key": "AIza...",
    "model": "gemini-2.0-flash-exp" | "gemini-1.5-pro"
  }
}
```

**Cortana (Custom):**
```json
{
  "type": "custom",
  "config": {
    "endpoint": "http://localhost:8000/cortana/query",
    "auth_type": "bearer" | "api_key" | "none",
    "api_key": "optional-if-needed"
  }
}
```

**Parent API:**
```json
{
  "type": "parent_api",
  "config": {
    "endpoint": "https://erik-parent-api.example.com",
    "api_key": "parent-key-...",
    "target_model": "gpt-4o"  // Which underlying model to use
  }
}
```

---

## Provider Adapter Interface

Each adapter implements a class that extends `BaseAdapter` and provides the following methods:

```javascript
class BaseAdapter {
  constructor(config) {
    this.config = config;
  }

  async sendMessage(messages, options) {
    // Abstract method to send a message to the AI service.
    // `messages` is an array of message objects (e.g., { role: "user", content: "Hello" }).
    // `options` is an object containing additional options (e.g., temperature, max_tokens).
    // Returns: { id: string, content: string, model: string, usage: { prompt_tokens: number, completion_tokens: number, total_tokens: number } }
    throw new Error("sendMessage method must be implemented.");
  }

  async streamResponse(messages, options, callback) {
    // Abstract method to stream a response from the AI service.
    // `messages` is an array of message objects.
    // `options` is an object containing additional options.
    // `callback` is a function that is called with each token received from the AI service.
    // Returns: void
    throw new Error("streamResponse method must be implemented.");
  }

  async getHistory(options) {
    // Abstract method to retrieve the chat history from the AI service.
    // `options` is an object containing additional options (e.g., number of messages to retrieve).
    // Returns: An array of message objects.
    throw new Error("getHistory method must be implemented.");
  }
}
```

**Example OpenAI Adapter:**

```javascript
class OpenAIAdapter extends BaseAdapter {
  constructor(config) {
    super(config);
    this.openai = new OpenAI({ apiKey: config.api_key });
  }

  async sendMessage(messages, options) {
    const completion = await this.openai.chat.completions.create({
      model: this.config.model,
      messages: messages,
      temperature: options.temperature || this.config.temperature,
      max_tokens: options.max_tokens || this.config.max_tokens,
    });

    return {
      id: completion.id,
      content: completion.choices[0].message.content,
      model: completion.model,
      usage: completion.usage
    };
  }

  async streamResponse(messages, options, callback) {
    const stream = await this.openai.chat.completions.create({
      model: this.config.model,
      messages: messages,
      temperature: options.temperature || this.config.temperature,
      max_tokens: options.max_tokens || this.config.max_tokens,
      stream: true,
    });

    for await (const part of stream) {
      callback(part.choices[0]?.delta?.content || "");
    }
  }

  async getHistory(options) {
    // Implement logic to retrieve chat history from OpenAI (if supported)
    console.warn("getHistory not implemented for OpenAI");
    return [];
  }
}
```

---

## Security Considerations

*   **API Key Encryption:** API keys should be encrypted at rest using a strong encryption algorithm.
*   **Input Sanitization:** Input from the UI should be sanitized to prevent injection attacks.
*   **Rate Limiting:** Rate limiting should be implemented to prevent abuse of the AI services.
*   **Secure Communication:** All communication with AI services should be encrypted using HTTPS.

---

## Future Enhancements

*   **Automatic Provider Selection:** Implement logic to automatically select the best provider based on factors such as cost, performance, and availability.
*   **Load Balancing:** Distribute requests across multiple providers to improve performance and reliability.
*   **Caching:** Cache responses from AI services to reduce latency and cost.
*   **Fine-tuning Support:** Allow users to fine-tune AI models using their own data.
*   **Plugin Architecture:** Enable developers to create custom provider adapters and extend the functionality of the API Abstraction Layer.
