# Sonnet: Hologram Phase 3 — Weeks 9-10: Connection Manager + Multi-AI Support

## Your Mission
Build an abstraction layer for AI providers, implement a Connection Manager for multiple profiles, add Anthropic and Google adapters, and enable the Orchestrator to dispatch to sub-agents through the Security Layer.

## Context

### What exists (from Phase 2-3):
- `OpenAIAdapter` in `src/main/adapters/openai.ts`
- `KeychainService` for secure API key storage
- `SecurityService` with `executeSecured()` for protected operations
- `OrchestratorService` stub loading personality from config
- IPC infrastructure for typed communication

### What you're building:
- **BaseAdapter** interface — Abstract all AI providers
- **Connection Manager** — Add/remove/switch AI profiles
- **Anthropic Adapter** — Direct connection to Claude
- **Google Adapter** — Direct connection to Gemini
- **Connection UI** — Switch between providers
- **Sub-Agent Dispatch** — Orchestrator routes to specialist agents

---

## Project Location

All work in: `..`

---

## Step 1: Create BaseAdapter Interface

Create `src/main/adapters/base.ts`:

```typescript
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
  abstract streamChat(
    messages: ChatMessage[],
    callbacks: StreamCallbacks
  ): Promise<void>;

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
```

---

## Step 2: Refactor OpenAI Adapter

Update `src/main/adapters/openai.ts`:

```typescript
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
```

---

## Step 3: Create Anthropic Adapter

Create `src/main/adapters/anthropic.ts`:

```typescript
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
      const systemMessage = messages.find(m => m.role === 'system')?.content;
      const chatMessages = messages
        .filter(m => m.role !== 'system')
        .map(m => ({
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
```

---

## Step 4: Create Google Adapter

Create `src/main/adapters/google.ts`:

```typescript
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
      const systemInstruction = messages.find(m => m.role === 'system')?.content;
      const contents = messages
        .filter(m => m.role !== 'system')
        .map(m => ({
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
```

---

## Step 5: Create Connection Manager Service

Create `src/main/services/connection-manager.ts`:

```typescript
import Store from 'electron-store';
import { randomUUID } from 'crypto';
import { ipcMain, BrowserWindow } from 'electron';
import type { Service } from './index';
import type { LoggerService } from './logger';
import type { KeychainService } from './keychain';
import {
  BaseAdapter,
  ConnectionProfile,
  ProviderType,
  AdapterConfig,
} from '../adapters/base';
import { OpenAIAdapter } from '../adapters/openai';
import { AnthropicAdapter } from '../adapters/anthropic';
import { GoogleAdapter } from '../adapters/google';

interface ConnectionManagerStore {
  profiles: ConnectionProfile[];
  defaultProfileId: string | null;
}

export class ConnectionManagerService implements Service {
  name = 'connection-manager';
  private store: Store<ConnectionManagerStore>;
  private logger!: LoggerService;
  private keychain!: KeychainService;
  private adapters: Map<string, BaseAdapter> = new Map();
  private activeAdapterId: string | null = null;

  constructor() {
    this.store = new Store<ConnectionManagerStore>({
      name: 'connections',
      defaults: {
        profiles: [],
        defaultProfileId: null,
      },
    });
  }

  setDependencies(logger: LoggerService, keychain: KeychainService): void {
    this.logger = logger;
    this.keychain = keychain;
  }

  async initialize(): Promise<void> {
    this.registerIpcHandlers();
    
    // Create adapters for existing profiles
    const profiles = this.getProfiles();
    for (const profile of profiles) {
      this.createAdapterForProfile(profile);
    }

    // Set active adapter to default if available
    const defaultId = this.store.get('defaultProfileId');
    if (defaultId && this.adapters.has(defaultId)) {
      this.activeAdapterId = defaultId;
    }

    console.log('ConnectionManagerService initialized', {
      profileCount: profiles.length,
    });
  }

  async shutdown(): Promise<void> {
    // Abort any pending requests
    for (const adapter of this.adapters.values()) {
      adapter.abort();
    }
    this.adapters.clear();
  }

  private registerIpcHandlers(): void {
    ipcMain.handle('connection:list', () => {
      return this.getProfiles();
    });

    ipcMain.handle('connection:add', async (_, profile: Omit<ConnectionProfile, 'id' | 'createdAt'>) => {
      return this.addProfile(profile);
    });

    ipcMain.handle('connection:remove', async (_, { id }: { id: string }) => {
      return this.removeProfile(id);
    });

    ipcMain.handle('connection:set-default', async (_, { id }: { id: string }) => {
      return this.setDefault(id);
    });

    ipcMain.handle('connection:switch', async (_, { id }: { id: string }) => {
      return this.switchTo(id);
    });

    ipcMain.handle('connection:test', async (_, { id }: { id: string }) => {
      return this.testConnection(id);
    });

    ipcMain.handle('connection:get-active', () => {
      return this.getActiveProfile();
    });

    ipcMain.handle('connection:update', async (_, { id, updates }: { id: string; updates: Partial<ConnectionProfile> }) => {
      return this.updateProfile(id, updates);
    });
  }

  /**
   * Get all connection profiles
   */
  getProfiles(): ConnectionProfile[] {
    return this.store.get('profiles') || [];
  }

  /**
   * Add a new connection profile
   */
  async addProfile(
    profile: Omit<ConnectionProfile, 'id' | 'createdAt'>
  ): Promise<ConnectionProfile> {
    const newProfile: ConnectionProfile = {
      ...profile,
      id: randomUUID(),
      createdAt: new Date().toISOString(),
    };

    const profiles = this.getProfiles();
    
    // If this is the first profile or marked as default, make it default
    if (profiles.length === 0 || profile.isDefault) {
      newProfile.isDefault = true;
      // Unset any existing default
      for (const p of profiles) {
        p.isDefault = false;
      }
      this.store.set('defaultProfileId', newProfile.id);
    }

    profiles.push(newProfile);
    this.store.set('profiles', profiles);

    // Create adapter for this profile
    this.createAdapterForProfile(newProfile);

    this.logger?.info('Connection profile added', {
      id: newProfile.id,
      name: newProfile.name,
      provider: newProfile.provider,
    });

    this.notifyProfilesChanged();
    return newProfile;
  }

  /**
   * Remove a connection profile
   */
  async removeProfile(id: string): Promise<boolean> {
    const profiles = this.getProfiles();
    const index = profiles.findIndex(p => p.id === id);
    
    if (index === -1) {
      return false;
    }

    const removed = profiles[index];
    profiles.splice(index, 1);

    // If we removed the default, set a new default
    if (removed.isDefault && profiles.length > 0) {
      profiles[0].isDefault = true;
      this.store.set('defaultProfileId', profiles[0].id);
    }

    this.store.set('profiles', profiles);

    // Remove adapter
    const adapter = this.adapters.get(id);
    if (adapter) {
      adapter.abort();
      this.adapters.delete(id);
    }

    // If this was active, switch to default
    if (this.activeAdapterId === id) {
      this.activeAdapterId = this.store.get('defaultProfileId');
    }

    this.logger?.info('Connection profile removed', {
      id,
      name: removed.name,
    });

    this.notifyProfilesChanged();
    return true;
  }

  /**
   * Update a connection profile
   */
  async updateProfile(id: string, updates: Partial<ConnectionProfile>): Promise<ConnectionProfile | null> {
    const profiles = this.getProfiles();
    const profile = profiles.find(p => p.id === id);
    
    if (!profile) {
      return null;
    }

    // Apply updates
    Object.assign(profile, updates);
    this.store.set('profiles', profiles);

    // Recreate adapter if config changed
    if (updates.config) {
      this.createAdapterForProfile(profile);
    }

    this.logger?.info('Connection profile updated', {
      id,
      name: profile.name,
    });

    this.notifyProfilesChanged();
    return profile;
  }

  /**
   * Set default profile
   */
  async setDefault(id: string): Promise<boolean> {
    const profiles = this.getProfiles();
    const profile = profiles.find(p => p.id === id);
    
    if (!profile) {
      return false;
    }

    for (const p of profiles) {
      p.isDefault = p.id === id;
    }

    this.store.set('profiles', profiles);
    this.store.set('defaultProfileId', id);

    this.logger?.info('Default connection set', {
      id,
      name: profile.name,
    });

    this.notifyProfilesChanged();
    return true;
  }

  /**
   * Switch active connection
   */
  async switchTo(id: string): Promise<boolean> {
    if (!this.adapters.has(id)) {
      return false;
    }

    // Abort current adapter's pending request
    if (this.activeAdapterId && this.adapters.has(this.activeAdapterId)) {
      this.adapters.get(this.activeAdapterId)!.abort();
    }

    this.activeAdapterId = id;

    // Update last used
    const profiles = this.getProfiles();
    const profile = profiles.find(p => p.id === id);
    if (profile) {
      profile.lastUsedAt = new Date().toISOString();
      this.store.set('profiles', profiles);
    }

    this.logger?.info('Switched connection', {
      id,
      name: profile?.name,
    });

    this.notifyActiveChanged(id);
    return true;
  }

  /**
   * Test a connection
   */
  async testConnection(id: string): Promise<{ success: boolean; latencyMs?: number; error?: string }> {
    const adapter = this.adapters.get(id);
    if (!adapter) {
      return { success: false, error: 'Connection not found' };
    }

    const isConfigured = await adapter.isConfigured();
    if (!isConfigured) {
      return { success: false, error: 'API key not configured' };
    }

    const startTime = Date.now();
    
    return new Promise((resolve) => {
      adapter.streamChat(
        [{ role: 'user', content: 'Say "OK" and nothing else.' }],
        {
          onToken: () => {},
          onComplete: () => {
            resolve({
              success: true,
              latencyMs: Date.now() - startTime,
            });
          },
          onError: (error) => {
            resolve({
              success: false,
              error: error.message,
            });
          },
        }
      );
    });
  }

  /**
   * Get active adapter
   */
  getActiveAdapter(): BaseAdapter | null {
    if (!this.activeAdapterId) {
      return null;
    }
    return this.adapters.get(this.activeAdapterId) || null;
  }

  /**
   * Get active profile
   */
  getActiveProfile(): ConnectionProfile | null {
    if (!this.activeAdapterId) {
      return null;
    }
    return this.getProfiles().find(p => p.id === this.activeAdapterId) || null;
  }

  /**
   * Get adapter by ID
   */
  getAdapter(id: string): BaseAdapter | null {
    return this.adapters.get(id) || null;
  }

  private createAdapterForProfile(profile: ConnectionProfile): void {
    let adapter: BaseAdapter;

    switch (profile.provider) {
      case 'openai':
        adapter = new OpenAIAdapter(this.keychain, this.logger, profile.config);
        break;
      case 'anthropic':
        adapter = new AnthropicAdapter(this.keychain, this.logger, profile.config);
        break;
      case 'google':
        adapter = new GoogleAdapter(this.keychain, this.logger, profile.config);
        break;
      case 'custom':
        // Custom adapters can be added later
        this.logger?.warn('Custom adapters not yet implemented', { profileId: profile.id });
        return;
      default:
        this.logger?.error('Unknown provider', { provider: profile.provider });
        return;
    }

    this.adapters.set(profile.id, adapter);
  }

  private notifyProfilesChanged(): void {
    const win = BrowserWindow.getAllWindows()[0];
    if (win) {
      win.webContents.send('connection:profiles-changed', {
        profiles: this.getProfiles(),
      });
    }
  }

  private notifyActiveChanged(id: string): void {
    const win = BrowserWindow.getAllWindows()[0];
    if (win) {
      win.webContents.send('connection:active-changed', {
        profileId: id,
        profile: this.getActiveProfile(),
      });
    }
  }
}
```

---

## Step 6: Create Sub-Agent Types

Create `src/shared/agent-types.ts`:

```typescript
export type AgentRole = 
  | 'orchestrator'  // Main coordinator (Cortana-like)
  | 'coder'         // Code generation/review
  | 'researcher'    // Web search and research
  | 'writer'        // Content writing
  | 'analyst';      // Data analysis

export interface SubAgent {
  id: string;
  name: string;
  role: AgentRole;
  connectionId: string;  // Which AI connection to use
  systemPrompt: string;
  capabilities: string[];
  enabled: boolean;
}

export interface AgentDispatchRequest {
  targetAgent: AgentRole;
  task: string;
  context?: Record<string, unknown>;
}

export interface AgentDispatchResult {
  success: boolean;
  agentId: string;
  response?: string;
  error?: string;
}
```

---

## Step 7: Update Orchestrator Service

Update `src/main/services/orchestrator.ts`:

```typescript
import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { ipcMain, BrowserWindow } from 'electron';
import type { Service } from './index';
import type { LoggerService } from './logger';
import type { SecurityService } from './security';
import type { ConnectionManagerService } from './connection-manager';
import type { SubAgent, AgentRole, AgentDispatchResult } from '@shared/agent-types';
import type { ChatMessage } from '../adapters/base';

interface PersonalityConfig {
  name: string;
  systemPrompt: string;
  subAgents: SubAgent[];
}

export class OrchestratorService implements Service {
  name = 'orchestrator';
  private logger!: LoggerService;
  private security!: SecurityService;
  private connectionManager!: ConnectionManagerService;
  private personality: PersonalityConfig | null = null;
  private subAgents: Map<string, SubAgent> = new Map();

  setDependencies(
    logger: LoggerService,
    security: SecurityService,
    connectionManager: ConnectionManagerService
  ): void {
    this.logger = logger;
    this.security = security;
    this.connectionManager = connectionManager;
  }

  async initialize(): Promise<void> {
    await this.loadPersonality();
    this.registerIpcHandlers();
    console.log('OrchestratorService initialized');
  }

  async shutdown(): Promise<void> {
    this.logger?.info('OrchestratorService shutdown');
  }

  private async loadPersonality(): Promise<void> {
    const configPath = join(process.cwd(), 'config', 'personality.json');

    if (existsSync(configPath)) {
      try {
        const content = readFileSync(configPath, 'utf-8');
        this.personality = JSON.parse(content);
        
        // Load sub-agents
        if (this.personality?.subAgents) {
          for (const agent of this.personality.subAgents) {
            this.subAgents.set(agent.id, agent);
          }
        }

        this.logger?.info('Personality loaded', {
          name: this.personality?.name,
          subAgentCount: this.subAgents.size,
        });
      } catch (error) {
        this.logger?.error('Failed to load personality', {
          error: error instanceof Error ? error.message : 'Unknown',
        });
      }
    }
  }

  private registerIpcHandlers(): void {
    ipcMain.handle('orchestrator:get-personality', () => {
      return this.personality;
    });

    ipcMain.handle('orchestrator:list-agents', () => {
      return Array.from(this.subAgents.values());
    });

    ipcMain.handle('orchestrator:dispatch', async (_, request) => {
      return this.dispatch(request.targetAgent, request.task, request.context);
    });

    ipcMain.handle('orchestrator:add-agent', async (_, agent: SubAgent) => {
      return this.addSubAgent(agent);
    });

    ipcMain.handle('orchestrator:remove-agent', async (_, { id }: { id: string }) => {
      return this.removeSubAgent(id);
    });
  }

  /**
   * Dispatch a task to a sub-agent
   * This goes through the security layer
   */
  async dispatch(
    targetRole: AgentRole,
    task: string,
    context?: Record<string, unknown>
  ): Promise<AgentDispatchResult> {
    // Find an agent with the target role
    const agent = Array.from(this.subAgents.values()).find(
      a => a.role === targetRole && a.enabled
    );

    if (!agent) {
      return {
        success: false,
        agentId: '',
        error: `No enabled agent found for role: ${targetRole}`,
      };
    }

    // Get the connection for this agent
    const adapter = this.connectionManager.getAdapter(agent.connectionId);
    if (!adapter) {
      return {
        success: false,
        agentId: agent.id,
        error: `Connection not found: ${agent.connectionId}`,
      };
    }

    // Execute through security layer
    const result = await this.security.executeSecured(
      'chat:send',
      `Dispatch to ${agent.name}: ${task.slice(0, 50)}...`,
      {
        connectionId: agent.connectionId,
        userInitiated: false, // Sub-agent requests are not user-initiated
      },
      async () => {
        return new Promise<string>((resolve, reject) => {
          const messages: ChatMessage[] = [
            { role: 'system', content: agent.systemPrompt },
            { role: 'user', content: task },
          ];

          // Add context if provided
          if (context) {
            messages[1].content += `\n\nContext: ${JSON.stringify(context)}`;
          }

          let fullResponse = '';

          adapter.streamChat(messages, {
            onToken: (token) => {
              fullResponse += token;
              // Optionally notify UI of progress
              this.notifyDispatchProgress(agent.id, token);
            },
            onComplete: (response) => {
              resolve(response);
            },
            onError: (error) => {
              reject(error);
            },
          });
        });
      }
    );

    if (result.success) {
      this.logger?.info('Sub-agent dispatch complete', {
        agentId: agent.id,
        role: targetRole,
        responseLength: result.result?.length,
      });

      return {
        success: true,
        agentId: agent.id,
        response: result.result,
      };
    } else {
      this.logger?.warn('Sub-agent dispatch failed', {
        agentId: agent.id,
        error: result.error,
      });

      return {
        success: false,
        agentId: agent.id,
        error: result.error,
      };
    }
  }

  /**
   * Add a sub-agent
   */
  async addSubAgent(agent: SubAgent): Promise<boolean> {
    if (this.subAgents.has(agent.id)) {
      return false;
    }

    this.subAgents.set(agent.id, agent);
    this.logger?.info('Sub-agent added', {
      id: agent.id,
      name: agent.name,
      role: agent.role,
    });

    return true;
  }

  /**
   * Remove a sub-agent
   */
  async removeSubAgent(id: string): Promise<boolean> {
    if (!this.subAgents.has(id)) {
      return false;
    }

    this.subAgents.delete(id);
    this.logger?.info('Sub-agent removed', { id });

    return true;
  }

  /**
   * Get system prompt for orchestrator
   */
  getSystemPrompt(): string {
    return this.personality?.systemPrompt || 'You are a helpful AI assistant.';
  }

  /**
   * Get personality name
   */
  getName(): string {
    return this.personality?.name || 'Assistant';
  }

  private notifyDispatchProgress(agentId: string, token: string): void {
    const win = BrowserWindow.getAllWindows()[0];
    if (win) {
      win.webContents.send('orchestrator:dispatch-progress', {
        agentId,
        token,
      });
    }
  }
}
```

---

## Step 8: Update IPC Types

Add to `src/shared/ipc-types.ts`:

```typescript
// Add imports at top
import type { ConnectionProfile } from '../main/adapters/base';
import type { SubAgent, AgentRole, AgentDispatchResult } from './agent-types';

// Add to IPCInvokeChannels
'connection:add': {
  request: Omit<ConnectionProfile, 'id' | 'createdAt'>;
  response: ConnectionProfile;
};
'connection:remove': {
  request: { id: string };
  response: boolean;
};
'connection:set-default': {
  request: { id: string };
  response: boolean;
};
'connection:switch': {
  request: { id: string };
  response: boolean;
};
'connection:get-active': {
  request: void;
  response: ConnectionProfile | null;
};
'connection:update': {
  request: { id: string; updates: Partial<ConnectionProfile> };
  response: ConnectionProfile | null;
};
'orchestrator:get-personality': {
  request: void;
  response: { name: string; systemPrompt: string } | null;
};
'orchestrator:list-agents': {
  request: void;
  response: SubAgent[];
};
'orchestrator:dispatch': {
  request: { targetAgent: AgentRole; task: string; context?: Record<string, unknown> };
  response: AgentDispatchResult;
};
'orchestrator:add-agent': {
  request: SubAgent;
  response: boolean;
};
'orchestrator:remove-agent': {
  request: { id: string };
  response: boolean;
};

// Add to IPCEventChannels
'connection:profiles-changed': {
  profiles: ConnectionProfile[];
};
'connection:active-changed': {
  profileId: string;
  profile: ConnectionProfile | null;
};
'orchestrator:dispatch-progress': {
  agentId: string;
  token: string;
};
```

---

## Step 9: Update Main Process

Update `src/main/index.ts`:

```typescript
import { ConnectionManagerService } from './services/connection-manager';

// After existing service registrations
const connectionManagerService = new ConnectionManagerService();
registry.register(connectionManagerService);

// In app.whenReady(), after services initialize:
connectionManagerService.setDependencies(loggerService, keychainService);
orchestratorService.setDependencies(loggerService, securityService, connectionManagerService);

// Update chat:send to use connection manager
ipcMain.handle('chat:send', async (event, { message, connectionId }) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) {
    return { success: false, error: 'Window not found' };
  }

  // Get adapter from connection manager (or use active)
  const adapter = connectionId 
    ? connectionManagerService.getAdapter(connectionId)
    : connectionManagerService.getActiveAdapter();

  if (!adapter) {
    return { success: false, error: 'No active connection. Please add a connection in Settings.' };
  }

  // ... rest of chat handling using adapter instead of openaiAdapter
});
```

---

## Step 10: Create Connection Switcher UI

Create `src/renderer/connection-switcher.ts`:

```typescript
import type { ConnectionProfile } from '@shared/ipc-types';

let activeProfileId: string | null = null;

export async function initConnectionSwitcher(): Promise<void> {
  await loadProfiles();
  setupEventListeners();
}

async function loadProfiles(): Promise<void> {
  const container = document.getElementById('connection-switcher');
  if (!container) return;

  const profiles = await window.hologram.invoke('connection:list');
  const active = await window.hologram.invoke('connection:get-active');
  activeProfileId = active?.id || null;

  renderProfiles(container, profiles);
}

function renderProfiles(container: HTMLElement, profiles: ConnectionProfile[]): void {
  container.innerHTML = `
    <div class="connection-header">
      <span class="connection-label">Connection</span>
      <button class="add-connection-btn" id="add-connection-btn">+</button>
    </div>
    <div class="connection-list" id="connection-list">
      ${profiles.length === 0 
        ? '<div class="no-connections">No connections. Click + to add one.</div>'
        : profiles.map(p => renderProfile(p)).join('')
      }
    </div>
    <div id="connection-form" class="connection-form hidden">
      <h4>Add Connection</h4>
      <select id="provider-select">
        <option value="openai">OpenAI</option>
        <option value="anthropic">Anthropic</option>
        <option value="google">Google</option>
      </select>
      <input type="text" id="connection-name" placeholder="Connection name" />
      <input type="password" id="connection-key" placeholder="API key" />
      <div class="form-actions">
        <button id="cancel-connection">Cancel</button>
        <button id="save-connection">Save</button>
      </div>
    </div>
  `;

  // Add click handlers for each profile
  profiles.forEach(p => {
    const el = container.querySelector(`[data-profile-id="${p.id}"]`);
    el?.addEventListener('click', () => switchConnection(p.id));
  });

  // Add/Cancel/Save handlers
  document.getElementById('add-connection-btn')?.addEventListener('click', showAddForm);
  document.getElementById('cancel-connection')?.addEventListener('click', hideAddForm);
  document.getElementById('save-connection')?.addEventListener('click', saveConnection);
}

function renderProfile(profile: ConnectionProfile): string {
  const isActive = profile.id === activeProfileId;
  const providerIcon = {
    openai: '🤖',
    anthropic: '🧠',
    google: '✨',
    custom: '🔧',
  }[profile.provider];

  return `
    <div class="connection-item ${isActive ? 'active' : ''}" data-profile-id="${profile.id}">
      <span class="provider-icon">${providerIcon}</span>
      <span class="connection-name">${profile.name}</span>
      ${profile.isDefault ? '<span class="default-badge">Default</span>' : ''}
    </div>
  `;
}

function showAddForm(): void {
  document.getElementById('connection-form')?.classList.remove('hidden');
}

function hideAddForm(): void {
  document.getElementById('connection-form')?.classList.add('hidden');
  // Clear inputs
  (document.getElementById('connection-name') as HTMLInputElement).value = '';
  (document.getElementById('connection-key') as HTMLInputElement).value = '';
}

async function saveConnection(): Promise<void> {
  const provider = (document.getElementById('provider-select') as HTMLSelectElement).value as 'openai' | 'anthropic' | 'google';
  const name = (document.getElementById('connection-name') as HTMLInputElement).value.trim();
  const key = (document.getElementById('connection-key') as HTMLInputElement).value.trim();

  if (!name || !key) {
    alert('Please fill in all fields');
    return;
  }

  try {
    // Store API key in keychain
    await window.hologram.keychain.setKey(provider, key);

    // Add connection profile
    await window.hologram.invoke('connection:add', {
      name,
      provider,
      keychainKey: provider,
      config: {},
      isDefault: false,
    });

    hideAddForm();
    await loadProfiles();
  } catch (error) {
    console.error('Failed to save connection:', error);
    alert('Failed to save connection');
  }
}

async function switchConnection(id: string): Promise<void> {
  const success = await window.hologram.invoke('connection:switch', { id });
  if (success) {
    activeProfileId = id;
    await loadProfiles();
  }
}

function setupEventListeners(): void {
  // Listen for profile changes
  window.hologram.on('connection:profiles-changed', () => {
    loadProfiles();
  });

  window.hologram.on('connection:active-changed', ({ profileId }) => {
    activeProfileId = profileId;
    loadProfiles();
  });
}
```

---

## Step 11: Add Connection Switcher Styles

Add to `src/renderer/styles.css`:

```css
/* Connection Switcher */
#connection-switcher {
  padding: 12px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.connection-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

.connection-label {
  font-size: 0.8rem;
  color: rgba(255, 255, 255, 0.6);
  text-transform: uppercase;
  letter-spacing: 1px;
}

.add-connection-btn {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  border: 1px solid #7efbff;
  background: transparent;
  color: #7efbff;
  font-size: 1.2rem;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
}

.add-connection-btn:hover {
  background: rgba(126, 251, 255, 0.2);
}

.connection-list {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.connection-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  border-radius: 8px;
  cursor: pointer;
  transition: all 0.2s;
}

.connection-item:hover {
  background: rgba(255, 255, 255, 0.05);
}

.connection-item.active {
  background: rgba(126, 251, 255, 0.15);
  border-left: 3px solid #7efbff;
}

.provider-icon {
  font-size: 1.2rem;
}

.connection-name {
  flex: 1;
  color: #fff;
}

.default-badge {
  font-size: 0.7rem;
  padding: 2px 6px;
  border-radius: 4px;
  background: rgba(77, 253, 209, 0.2);
  color: #4dfdd1;
}

.no-connections {
  text-align: center;
  padding: 16px;
  color: rgba(255, 255, 255, 0.4);
  font-size: 0.85rem;
}

.connection-form {
  margin-top: 12px;
  padding: 12px;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 8px;
}

.connection-form.hidden {
  display: none;
}

.connection-form h4 {
  margin: 0 0 12px 0;
  color: #7efbff;
}

.connection-form select,
.connection-form input {
  width: 100%;
  padding: 8px;
  margin-bottom: 8px;
  background: rgba(0, 0, 0, 0.3);
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 4px;
  color: #fff;
}

.form-actions {
  display: flex;
  gap: 8px;
  justify-content: flex-end;
}

.form-actions button {
  padding: 6px 12px;
  border-radius: 4px;
  cursor: pointer;
}

#cancel-connection {
  background: transparent;
  border: 1px solid rgba(255, 255, 255, 0.3);
  color: #fff;
}

#save-connection {
  background: #7efbff;
  border: none;
  color: #0d0d1a;
}
```

---

## Step 12: Update Personality Config

Update `config/personality.json`:

```json
{
  "name": "Hologram",
  "systemPrompt": "You are Hologram, a helpful AI assistant with a calm, knowledgeable demeanor. You can delegate specialized tasks to sub-agents when appropriate.",
  "subAgents": [
    {
      "id": "coder-claude",
      "name": "Claude Coder",
      "role": "coder",
      "connectionId": "",
      "systemPrompt": "You are a senior software engineer. Write clean, well-documented code. Explain your reasoning. Follow best practices for the language being used.",
      "capabilities": ["code-generation", "code-review", "debugging", "refactoring"],
      "enabled": false
    },
    {
      "id": "researcher",
      "name": "Research Agent",
      "role": "researcher",
      "connectionId": "",
      "systemPrompt": "You are a research assistant. Gather information, verify facts, and present findings clearly with sources.",
      "capabilities": ["web-search", "summarization", "fact-checking"],
      "enabled": false
    }
  ]
}
```

---

## Step 13: Update Preload

Add to `src/preload/index.ts`:

```typescript
// Add to HologramAPI interface
connection: {
  list: () => invoke('connection:list'),
  add: (profile: Omit<ConnectionProfile, 'id' | 'createdAt'>) => 
    invoke('connection:add', profile),
  remove: (id: string) => invoke('connection:remove', { id }),
  setDefault: (id: string) => invoke('connection:set-default', { id }),
  switchTo: (id: string) => invoke('connection:switch', { id }),
  test: (id: string) => invoke('connection:test', { id }),
  getActive: () => invoke('connection:get-active'),
  update: (id: string, updates: Partial<ConnectionProfile>) => 
    invoke('connection:update', { id, updates }),
},
orchestrator: {
  getPersonality: () => invoke('orchestrator:get-personality'),
  listAgents: () => invoke('orchestrator:list-agents'),
  dispatch: (targetAgent: AgentRole, task: string, context?: Record<string, unknown>) =>
    invoke('orchestrator:dispatch', { targetAgent, task, context }),
  addAgent: (agent: SubAgent) => invoke('orchestrator:add-agent', agent),
  removeAgent: (id: string) => invoke('orchestrator:remove-agent', { id }),
},
```

---

## Step 14: Initialize in Main

Update `src/renderer/main.ts`:

```typescript
import { initConnectionSwitcher } from './connection-switcher';

// Add to initialization
initConnectionSwitcher();
```

---

## Step 15: Add Container to HTML

Add to `src/renderer/index.html`:

```html
<!-- In sidebar or panel area -->
<div id="connection-switcher"></div>
```

---

## Exit Criteria

- [ ] `BaseAdapter` interface defined with abstract methods
- [ ] `OpenAIAdapter` refactored to extend `BaseAdapter`
- [ ] `AnthropicAdapter` implemented with streaming
- [ ] `GoogleAdapter` implemented with streaming
- [ ] `ConnectionManagerService` manages profiles
- [ ] Connection profiles persisted in electron-store
- [ ] Connection switching works (abort previous, start new)
- [ ] Connection test endpoint works
- [ ] Connection switcher UI shows all profiles
- [ ] Can add new connections from UI
- [ ] Sub-agents defined in `personality.json`
- [ ] `OrchestratorService.dispatch()` routes to sub-agents
- [ ] Sub-agent dispatch goes through `SecurityService`
- [ ] IPC channels for connection management
- [ ] IPC channels for orchestrator
- [ ] TypeScript compiles with no errors
- [ ] Lint passes

---

## Security Verification

- [ ] All API connections are direct (no relay server)
- [ ] API keys stored in keychain by provider
- [ ] Connection profiles don't store keys (only `keychainKey` reference)
- [ ] Sub-agent dispatch goes through `executeSecured()`
- [ ] Sub-agent requests marked as `userInitiated: false`

---

## Files Summary

### Created:
- `src/main/adapters/base.ts` — Abstract adapter interface
- `src/main/adapters/anthropic.ts` — Claude adapter
- `src/main/adapters/google.ts` — Gemini adapter
- `src/main/services/connection-manager.ts` — Profile management
- `src/shared/agent-types.ts` — Sub-agent types
- `src/renderer/connection-switcher.ts` — Connection UI

### Modified:
- `src/main/adapters/openai.ts` — Extends BaseAdapter
- `src/main/services/orchestrator.ts` — Sub-agent dispatch
- `src/shared/ipc-types.ts` — Connection + orchestrator channels
- `src/preload/index.ts` — Expose new APIs
- `src/renderer/main.ts` — Initialize connection switcher
- `src/renderer/styles.css` — Connection switcher styles
- `src/renderer/index.html` — Connection switcher container
- `config/personality.json` — Sub-agent definitions

---

Good luck! 🔌

## Related Documentation

- [Doppler Secrets Management](Documents/reference/DOPPLER_SECRETS_MANAGEMENT.md) - secrets management
- [[api_design_patterns]] - API design
- [Tiered AI Sprint Planning](patterns/tiered-ai-sprint-planning.md) - prompt engineering
- [AI Model Cost Comparison](Documents/reference/MODEL_COST_COMPARISON.md) - AI models
- [[cortana_architecture]] - Cortana AI
- [AI Team Orchestration](patterns/ai-team-orchestration.md) - orchestration
- [[portfolio_content]] - portfolio/career
- [[research_methodology]] - research
- [Safety Systems](patterns/safety-systems.md) - security
- [[cortana-personal-ai/README]] - Cortana AI
