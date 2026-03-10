# Sonnet: Hologram Phase 2 — Weeks 5-6: Keychain + OpenAI + Security Hardening

## Your Mission
Implement secure API key storage using OS keychain, build a proper OpenAI adapter, and harden all logging/storage to never leak sensitive data.

## Context

### What exists (from Phase 1):
- TypeScript Electron app with Vite build
- Services: Logger, Window, Network, ChatHistory, Orchestrator, Security
- Three.js visualizer with state transitions
- Basic chat UI with offline detection
- OpenAI streaming (from spikes, but in `src/api/openai-stream.ts`)
- `.env` file currently holds API key (insecure, needs to move to keychain)

### What you're adding:
- **Keytar** for OS keychain storage (macOS Keychain, Windows Credential Manager)
- **API key management UI** with masking, rotation, clear
- **Proper OpenAI adapter** using the keychain
- **Enhanced logging** with rotation and sanitization
- **Conversation encryption** at rest
- **Settings panel** with security controls

---

## Project Location

All work in: `..`

---

## Step 1: Install Dependencies

```bash
npm install keytar
npm install --save-dev @types/keytar
```

Note: `keytar` requires native compilation. If issues, may need `electron-rebuild`:
```bash
npm install --save-dev electron-rebuild
npx electron-rebuild
```

---

## Step 2: Create Keychain Service

Create `src/main/services/keychain.ts`:

```typescript
import keytar from 'keytar';
import { Service } from './index.js';
import { LoggerService } from './logger.js';

const SERVICE_NAME = 'hologram-ai';

export interface KeychainEntry {
  provider: string;
  hasKey: boolean;
  createdAt?: string;
}

export class KeychainService implements Service {
  name = 'keychain';
  private logger!: LoggerService;
  private metadata: Map<string, { createdAt: string }> = new Map();

  async initialize(): Promise<void> {
    // Logger will be injected after all services initialize
    console.log('KeychainService initialized');
  }

  setLogger(logger: LoggerService): void {
    this.logger = logger;
  }

  async shutdown(): Promise<void> {
    // Nothing to clean up
  }

  /**
   * Store an API key in the OS keychain
   * NEVER logs the actual key value
   */
  async setKey(provider: string, apiKey: string): Promise<void> {
    if (!apiKey || apiKey.trim() === '') {
      throw new Error('API key cannot be empty');
    }

    await keytar.setPassword(SERVICE_NAME, provider, apiKey);
    
    const now = new Date().toISOString();
    this.metadata.set(provider, { createdAt: now });
    
    this.logger?.info('API key stored', { 
      provider, 
      keyLength: apiKey.length,
      createdAt: now 
    });
  }

  /**
   * Retrieve an API key from the OS keychain
   * Returns null if not found
   */
  async getKey(provider: string): Promise<string | null> {
    const key = await keytar.getPassword(SERVICE_NAME, provider);
    
    if (key) {
      this.logger?.debug('API key retrieved', { provider });
    } else {
      this.logger?.debug('API key not found', { provider });
    }
    
    return key;
  }

  /**
   * Check if a key exists without retrieving it
   */
  async hasKey(provider: string): Promise<boolean> {
    const key = await keytar.getPassword(SERVICE_NAME, provider);
    return key !== null;
  }

  /**
   * Delete an API key from the OS keychain
   */
  async deleteKey(provider: string): Promise<boolean> {
    const deleted = await keytar.deletePassword(SERVICE_NAME, provider);
    
    if (deleted) {
      this.metadata.delete(provider);
      this.logger?.info('API key deleted', { provider });
    }
    
    return deleted;
  }

  /**
   * Delete ALL stored keys (panic button)
   */
  async deleteAllKeys(): Promise<number> {
    const credentials = await keytar.findCredentials(SERVICE_NAME);
    let count = 0;
    
    for (const cred of credentials) {
      await keytar.deletePassword(SERVICE_NAME, cred.account);
      count++;
    }
    
    this.metadata.clear();
    this.logger?.warn('All API keys deleted (panic button)', { count });
    
    return count;
  }

  /**
   * List all stored providers (without exposing keys)
   */
  async listProviders(): Promise<KeychainEntry[]> {
    const credentials = await keytar.findCredentials(SERVICE_NAME);
    
    return credentials.map(cred => ({
      provider: cred.account,
      hasKey: true,
      createdAt: this.metadata.get(cred.account)?.createdAt,
    }));
  }

  /**
   * Rotate a key (delete old, store new)
   */
  async rotateKey(provider: string, newKey: string): Promise<void> {
    await this.deleteKey(provider);
    await this.setKey(provider, newKey);
    this.logger?.info('API key rotated', { provider });
  }
}
```

---

## Step 3: Create OpenAI Adapter

Create `src/main/adapters/openai.ts`:

```typescript
import { KeychainService } from '../services/keychain.js';
import { LoggerService } from '../services/logger.js';

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
}

const DEFAULT_CONFIG: AdapterConfig = {
  model: 'gpt-4o',
  temperature: 0.7,
  maxTokens: 2048,
};

export class OpenAIAdapter {
  private keychain: KeychainService;
  private logger: LoggerService;
  private config: AdapterConfig;
  private abortController: AbortController | null = null;

  constructor(
    keychain: KeychainService,
    logger: LoggerService,
    config: Partial<AdapterConfig> = {}
  ) {
    this.keychain = keychain;
    this.logger = logger;
    this.config = { ...DEFAULT_CONFIG, ...config };
  }

  /**
   * Send a chat completion request with streaming
   */
  async streamChat(
    messages: ChatMessage[],
    callbacks: StreamCallbacks
  ): Promise<void> {
    const apiKey = await this.keychain.getKey('openai');
    
    if (!apiKey) {
      callbacks.onError(new Error('OpenAI API key not configured'));
      return;
    }

    this.abortController = new AbortController();
    let fullResponse = '';

    try {
      this.logger.debug('OpenAI request starting', {
        model: this.config.model,
        messageCount: messages.length,
      });

      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiKey}`,
        },
        body: JSON.stringify({
          model: this.config.model,
          messages,
          temperature: this.config.temperature,
          max_tokens: this.config.maxTokens,
          stream: true,
        }),
        signal: this.abortController.signal,
      });

      if (!response.ok) {
        const errorText = await response.text();
        // NEVER log the actual error body - might contain key info
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

  /**
   * Abort the current request
   */
  abort(): void {
    this.abortController?.abort();
  }

  /**
   * Check if API key is configured
   */
  async isConfigured(): Promise<boolean> {
    return this.keychain.hasKey('openai');
  }
}
```

---

## Step 4: Enhanced Logger with Rotation

Update `src/main/services/logger.ts`:

```typescript
import { writeFileSync, readFileSync, existsSync, mkdirSync, readdirSync, statSync, unlinkSync } from 'fs';
import { join } from 'path';
import { app } from 'electron';
import { Service } from './index.js';

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

interface LogEntry {
  timestamp: string;
  level: LogLevel;
  message: string;
  context?: Record<string, unknown>;
}

// Patterns that should NEVER appear in logs
const SENSITIVE_PATTERNS = [
  /sk-[a-zA-Z0-9]{20,}/g,           // OpenAI keys
  /sk-proj-[a-zA-Z0-9-_]{20,}/g,    // OpenAI project keys
  /anthropic-[a-zA-Z0-9]{20,}/g,    // Anthropic keys
  /AIza[a-zA-Z0-9_-]{35}/g,         // Google API keys
  /api[_-]?key["\s:=]+["']?[a-zA-Z0-9_-]{20,}/gi,
  /password["\s:=]+["']?[^\s"']+/gi,
  /secret["\s:=]+["']?[^\s"']+/gi,
  /token["\s:=]+["']?[a-zA-Z0-9_-]{20,}/gi,
  /bearer\s+[a-zA-Z0-9_-]{20,}/gi,
  /authorization["\s:=]+["']?[^\s"']+/gi,
];

const MAX_LOG_SIZE = 10 * 1024 * 1024; // 10MB
const MAX_LOG_AGE_DAYS = 7;
const MAX_LOG_FILES = 10;

export class LoggerService implements Service {
  name = 'logger';
  private logLevel: LogLevel = 'info';
  private logDir: string;
  private currentLogFile: string;
  private logBuffer: LogEntry[] = [];
  private flushInterval: NodeJS.Timeout | null = null;

  constructor() {
    this.logDir = join(app.getPath('userData'), 'logs');
    this.currentLogFile = this.getLogFileName();
  }

  async initialize(): Promise<void> {
    if (!existsSync(this.logDir)) {
      mkdirSync(this.logDir, { recursive: true });
    }

    // Clean old logs on startup
    await this.cleanOldLogs();

    // Flush logs every 5 seconds
    this.flushInterval = setInterval(() => this.flush(), 5000);

    this.info('Logger initialized', { logDir: this.logDir });
  }

  async shutdown(): Promise<void> {
    if (this.flushInterval) {
      clearInterval(this.flushInterval);
    }
    await this.flush();
  }

  setLevel(level: LogLevel): void {
    this.logLevel = level;
  }

  debug(message: string, context?: Record<string, unknown>): void {
    this.log('debug', message, context);
  }

  info(message: string, context?: Record<string, unknown>): void {
    this.log('info', message, context);
  }

  warn(message: string, context?: Record<string, unknown>): void {
    this.log('warn', message, context);
  }

  error(message: string, context?: Record<string, unknown>): void {
    this.log('error', message, context);
  }

  private log(level: LogLevel, message: string, context?: Record<string, unknown>): void {
    const levels: LogLevel[] = ['debug', 'info', 'warn', 'error'];
    if (levels.indexOf(level) < levels.indexOf(this.logLevel)) {
      return;
    }

    const entry: LogEntry = {
      timestamp: new Date().toISOString(),
      level,
      message: this.sanitize(message),
      context: context ? this.sanitizeContext(context) : undefined,
    };

    this.logBuffer.push(entry);

    // Also log to console in development
    if (process.env.NODE_ENV !== 'production') {
      const prefix = `[${entry.timestamp}] [${level.toUpperCase()}]`;
      const contextStr = context ? ` ${JSON.stringify(entry.context)}` : '';
      console.log(`${prefix} ${entry.message}${contextStr}`);
    }

    // Check if we need to rotate
    this.checkRotation();
  }

  private sanitize(text: string): string {
    let result = text;
    for (const pattern of SENSITIVE_PATTERNS) {
      result = result.replace(pattern, '[REDACTED]');
    }
    return result;
  }

  private sanitizeContext(context: Record<string, unknown>): Record<string, unknown> {
    const result: Record<string, unknown> = {};
    
    for (const [key, value] of Object.entries(context)) {
      // Redact keys that look sensitive
      const lowerKey = key.toLowerCase();
      if (
        lowerKey.includes('key') ||
        lowerKey.includes('secret') ||
        lowerKey.includes('password') ||
        lowerKey.includes('token') ||
        lowerKey.includes('authorization')
      ) {
        result[key] = '[REDACTED]';
        continue;
      }

      // Sanitize string values
      if (typeof value === 'string') {
        result[key] = this.sanitize(value);
      } else if (typeof value === 'object' && value !== null) {
        result[key] = this.sanitizeContext(value as Record<string, unknown>);
      } else {
        result[key] = value;
      }
    }

    return result;
  }

  private getLogFileName(): string {
    const date = new Date().toISOString().split('T')[0];
    return join(this.logDir, `hologram-${date}.log`);
  }

  private async flush(): Promise<void> {
    if (this.logBuffer.length === 0) return;

    const entries = this.logBuffer.splice(0, this.logBuffer.length);
    const content = entries.map(e => JSON.stringify(e)).join('\n') + '\n';

    try {
      const logFile = this.getLogFileName();
      if (logFile !== this.currentLogFile) {
        this.currentLogFile = logFile;
      }

      const existingContent = existsSync(this.currentLogFile)
        ? readFileSync(this.currentLogFile, 'utf-8')
        : '';

      writeFileSync(this.currentLogFile, existingContent + content);
    } catch (error) {
      console.error('Failed to write logs:', error);
    }
  }

  private checkRotation(): void {
    try {
      if (!existsSync(this.currentLogFile)) return;

      const stats = statSync(this.currentLogFile);
      if (stats.size > MAX_LOG_SIZE) {
        // Rename current log with timestamp
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const rotatedName = this.currentLogFile.replace('.log', `-${timestamp}.log`);
        const content = readFileSync(this.currentLogFile, 'utf-8');
        writeFileSync(rotatedName, content);
        writeFileSync(this.currentLogFile, '');
        this.info('Log file rotated', { rotatedTo: rotatedName });
      }
    } catch (error) {
      console.error('Log rotation check failed:', error);
    }
  }

  private async cleanOldLogs(): Promise<void> {
    try {
      const files = readdirSync(this.logDir)
        .filter(f => f.endsWith('.log'))
        .map(f => ({
          name: f,
          path: join(this.logDir, f),
          mtime: statSync(join(this.logDir, f)).mtime,
        }))
        .sort((a, b) => b.mtime.getTime() - a.mtime.getTime());

      const cutoffDate = new Date();
      cutoffDate.setDate(cutoffDate.getDate() - MAX_LOG_AGE_DAYS);

      let deleted = 0;

      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        // Delete if too old OR if we have too many files
        if (file.mtime < cutoffDate || i >= MAX_LOG_FILES) {
          unlinkSync(file.path);
          deleted++;
        }
      }

      if (deleted > 0) {
        console.log(`Cleaned ${deleted} old log files`);
      }
    } catch (error) {
      console.error('Failed to clean old logs:', error);
    }
  }

  /**
   * Clear all logs (user-triggered)
   */
  async clearAllLogs(): Promise<number> {
    try {
      const files = readdirSync(this.logDir).filter(f => f.endsWith('.log'));
      
      for (const file of files) {
        unlinkSync(join(this.logDir, file));
      }

      this.logBuffer = [];
      console.log(`Cleared ${files.length} log files`);
      
      return files.length;
    } catch (error) {
      console.error('Failed to clear logs:', error);
      return 0;
    }
  }

  /**
   * Get log directory path (for UI)
   */
  getLogDir(): string {
    return this.logDir;
  }
}
```

---

## Step 5: Enhanced Chat History with Encryption

Update `src/main/services/chat-history.ts`:

```typescript
import Store from 'electron-store';
import { createCipheriv, createDecipheriv, randomBytes, scryptSync } from 'crypto';
import { Service } from './index.js';
import { LoggerService } from './logger.js';
import { KeychainService } from './keychain.js';

export interface ChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: string;
  connectionId?: string;
}

interface EncryptedData {
  iv: string;
  encrypted: string;
}

const MAX_MESSAGES = 100;
const MAX_STORAGE_SIZE = 10 * 1024 * 1024; // 10MB
const ENCRYPTION_KEY_NAME = 'hologram-encryption';

export class ChatHistoryService implements Service {
  name = 'chat-history';
  private store: Store;
  private logger!: LoggerService;
  private keychain!: KeychainService;
  private encryptionKey: Buffer | null = null;

  constructor() {
    this.store = new Store({
      name: 'chat-history',
      encryptionKey: undefined, // We handle encryption ourselves
    });
  }

  async initialize(): Promise<void> {
    console.log('ChatHistoryService initialized');
  }

  setDependencies(logger: LoggerService, keychain: KeychainService): void {
    this.logger = logger;
    this.keychain = keychain;
  }

  async shutdown(): Promise<void> {
    // Clear encryption key from memory
    this.encryptionKey = null;
  }

  /**
   * Get or create the encryption key
   */
  private async getEncryptionKey(): Promise<Buffer> {
    if (this.encryptionKey) {
      return this.encryptionKey;
    }

    // Try to get existing key from keychain
    let keyMaterial = await this.keychain.getKey(ENCRYPTION_KEY_NAME);
    
    if (!keyMaterial) {
      // Generate new key material and store it
      keyMaterial = randomBytes(32).toString('hex');
      await this.keychain.setKey(ENCRYPTION_KEY_NAME, keyMaterial);
      this.logger?.info('Generated new encryption key');
    }

    // Derive actual key using scrypt
    this.encryptionKey = scryptSync(keyMaterial, 'hologram-salt', 32);
    return this.encryptionKey;
  }

  /**
   * Encrypt a message
   */
  private async encrypt(text: string): Promise<EncryptedData> {
    const key = await this.getEncryptionKey();
    const iv = randomBytes(16);
    const cipher = createCipheriv('aes-256-gcm', key, iv);
    
    let encrypted = cipher.update(text, 'utf8', 'hex');
    encrypted += cipher.final('hex');
    const authTag = cipher.getAuthTag();
    
    return {
      iv: iv.toString('hex'),
      encrypted: encrypted + authTag.toString('hex'),
    };
  }

  /**
   * Decrypt a message
   */
  private async decrypt(data: EncryptedData): Promise<string> {
    const key = await this.getEncryptionKey();
    const iv = Buffer.from(data.iv, 'hex');
    
    // Extract auth tag (last 32 hex chars = 16 bytes)
    const encrypted = data.encrypted.slice(0, -32);
    const authTag = Buffer.from(data.encrypted.slice(-32), 'hex');
    
    const decipher = createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(authTag);
    
    let decrypted = decipher.update(encrypted, 'hex', 'utf8');
    decrypted += decipher.final('utf8');
    
    return decrypted;
  }

  /**
   * Add a message to history
   */
  async addMessage(message: Omit<ChatMessage, 'id' | 'timestamp'>): Promise<ChatMessage> {
    const fullMessage: ChatMessage = {
      ...message,
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
    };

    const messages = await this.getMessages();
    messages.push(fullMessage);

    // Enforce size limits
    await this.enforceLimit(messages);

    // Encrypt and store
    const encrypted = await this.encrypt(JSON.stringify(messages));
    this.store.set('messages', encrypted);

    this.logger?.debug('Message added to history', { 
      messageId: fullMessage.id,
      role: fullMessage.role,
    });

    return fullMessage;
  }

  /**
   * Get all messages
   */
  async getMessages(): Promise<ChatMessage[]> {
    const encrypted = this.store.get('messages') as EncryptedData | undefined;
    
    if (!encrypted) {
      return [];
    }

    try {
      const decrypted = await this.decrypt(encrypted);
      return JSON.parse(decrypted);
    } catch (error) {
      this.logger?.error('Failed to decrypt messages', {
        error: error instanceof Error ? error.message : 'Unknown',
      });
      return [];
    }
  }

  /**
   * Enforce message count and size limits
   */
  private async enforceLimit(messages: ChatMessage[]): Promise<void> {
    // Remove oldest messages if over count limit
    while (messages.length > MAX_MESSAGES) {
      const removed = messages.shift();
      this.logger?.debug('Removed old message', { messageId: removed?.id });
    }

    // Check size and remove more if needed
    let size = JSON.stringify(messages).length;
    while (size > MAX_STORAGE_SIZE && messages.length > 0) {
      messages.shift();
      size = JSON.stringify(messages).length;
    }
  }

  /**
   * Clear all history (user-triggered)
   */
  async clearHistory(): Promise<void> {
    this.store.delete('messages');
    this.logger?.info('Chat history cleared');
  }

  /**
   * Get message count
   */
  async getMessageCount(): Promise<number> {
    const messages = await this.getMessages();
    return messages.length;
  }

  /**
   * Get storage size in bytes
   */
  getStorageSize(): number {
    const encrypted = this.store.get('messages') as EncryptedData | undefined;
    if (!encrypted) return 0;
    return JSON.stringify(encrypted).length;
  }
}
```

---

## Step 6: Add IPC Channels

Update `src/shared/ipc-types.ts` — add these channels:

```typescript
// Add to IPCInvokeChannels
export interface IPCInvokeChannels {
  // ... existing channels ...
  
  // Keychain
  'keychain:set': { provider: string; key: string };
  'keychain:get': { provider: string };
  'keychain:delete': { provider: string };
  'keychain:delete-all': void;
  'keychain:list': void;
  'keychain:has': { provider: string };
  
  // Chat
  'chat:send': { message: string; connectionId?: string };
  'chat:get-history': void;
  'chat:clear-history': void;
  
  // Settings
  'settings:clear-logs': void;
  'settings:get-log-dir': void;
}

export interface IPCInvokeResponses {
  // ... existing responses ...
  
  // Keychain
  'keychain:set': void;
  'keychain:get': string | null;
  'keychain:delete': boolean;
  'keychain:delete-all': number;
  'keychain:list': Array<{ provider: string; hasKey: boolean; createdAt?: string }>;
  'keychain:has': boolean;
  
  // Chat
  'chat:send': void;
  'chat:get-history': ChatMessage[];
  'chat:clear-history': void;
  
  // Settings
  'settings:clear-logs': number;
  'settings:get-log-dir': string;
}

// Add to IPCEventChannels
export interface IPCEventChannels {
  // ... existing channels ...
  
  'chat:token': { token: string };
  'chat:complete': { fullResponse: string };
  'chat:error': { message: string };
}
```

---

## Step 7: Register IPC Handlers

Update `src/main/index.ts` — add handlers:

```typescript
import { KeychainService } from './services/keychain.js';
import { OpenAIAdapter } from './adapters/openai.js';

// In the service registration section:
const keychainService = new KeychainService();
registry.register(keychainService);

// After services initialize:
keychainService.setLogger(loggerService);
chatHistoryService.setDependencies(loggerService, keychainService);

// Create OpenAI adapter
const openaiAdapter = new OpenAIAdapter(keychainService, loggerService);

// Keychain IPC handlers
ipcMain.handle('keychain:set', async (_, { provider, key }) => {
  await keychainService.setKey(provider, key);
});

ipcMain.handle('keychain:get', async (_, { provider }) => {
  return keychainService.getKey(provider);
});

ipcMain.handle('keychain:delete', async (_, { provider }) => {
  return keychainService.deleteKey(provider);
});

ipcMain.handle('keychain:delete-all', async () => {
  return keychainService.deleteAllKeys();
});

ipcMain.handle('keychain:list', async () => {
  return keychainService.listProviders();
});

ipcMain.handle('keychain:has', async (_, { provider }) => {
  return keychainService.hasKey(provider);
});

// Chat IPC handlers
ipcMain.handle('chat:send', async (event, { message }) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) return;

  // Add user message to history
  await chatHistoryService.addMessage({
    role: 'user',
    content: message,
  });

  // Get conversation history for context
  const history = await chatHistoryService.getMessages();
  const messages = history.map(m => ({
    role: m.role as 'user' | 'assistant' | 'system',
    content: m.content,
  }));

  // Stream response
  await openaiAdapter.streamChat(messages, {
    onToken: (token) => {
      win.webContents.send('chat:token', { token });
    },
    onComplete: async (fullResponse) => {
      // Add assistant message to history
      await chatHistoryService.addMessage({
        role: 'assistant',
        content: fullResponse,
      });
      win.webContents.send('chat:complete', { fullResponse });
    },
    onError: (error) => {
      win.webContents.send('chat:error', { message: error.message });
    },
  });
});

ipcMain.handle('chat:get-history', async () => {
  return chatHistoryService.getMessages();
});

ipcMain.handle('chat:clear-history', async () => {
  await chatHistoryService.clearHistory();
});

// Settings IPC handlers
ipcMain.handle('settings:clear-logs', async () => {
  return loggerService.clearAllLogs();
});

ipcMain.handle('settings:get-log-dir', () => {
  return loggerService.getLogDir();
});
```

---

## Step 8: Update Preload

Update `src/preload/index.ts` — expose new methods:

```typescript
contextBridge.exposeInMainWorld('hologram', {
  // ... existing methods ...
  
  // Keychain
  keychain: {
    setKey: (provider: string, key: string) => 
      ipcRenderer.invoke('keychain:set', { provider, key }),
    getKey: (provider: string) => 
      ipcRenderer.invoke('keychain:get', { provider }),
    deleteKey: (provider: string) => 
      ipcRenderer.invoke('keychain:delete', { provider }),
    deleteAllKeys: () => 
      ipcRenderer.invoke('keychain:delete-all'),
    listProviders: () => 
      ipcRenderer.invoke('keychain:list'),
    hasKey: (provider: string) => 
      ipcRenderer.invoke('keychain:has', { provider }),
  },
  
  // Chat
  chat: {
    send: (message: string) => 
      ipcRenderer.invoke('chat:send', { message }),
    getHistory: () => 
      ipcRenderer.invoke('chat:get-history'),
    clearHistory: () => 
      ipcRenderer.invoke('chat:clear-history'),
    onToken: (callback: (token: string) => void) => {
      const handler = (_: unknown, data: { token: string }) => callback(data.token);
      ipcRenderer.on('chat:token', handler);
      return () => ipcRenderer.removeListener('chat:token', handler);
    },
    onComplete: (callback: (fullResponse: string) => void) => {
      const handler = (_: unknown, data: { fullResponse: string }) => callback(data.fullResponse);
      ipcRenderer.on('chat:complete', handler);
      return () => ipcRenderer.removeListener('chat:complete', handler);
    },
    onError: (callback: (message: string) => void) => {
      const handler = (_: unknown, data: { message: string }) => callback(data.message);
      ipcRenderer.on('chat:error', handler);
      return () => ipcRenderer.removeListener('chat:error', handler);
    },
  },
  
  // Settings
  settings: {
    clearLogs: () => ipcRenderer.invoke('settings:clear-logs'),
    getLogDir: () => ipcRenderer.invoke('settings:get-log-dir'),
  },
});
```

---

## Step 9: Settings Panel UI

Create `src/renderer/settings.ts`:

```typescript
export async function initSettings(): Promise<void> {
  const settingsPanel = document.getElementById('settings-panel');
  if (!settingsPanel) return;

  // Check if OpenAI key is configured
  const hasKey = await window.hologram.keychain.hasKey('openai');
  updateKeyStatus(hasKey);

  // API Key input
  const keyInput = document.getElementById('api-key-input') as HTMLInputElement;
  const saveKeyBtn = document.getElementById('save-key-btn');
  const rotateKeyBtn = document.getElementById('rotate-key-btn');
  const deleteKeyBtn = document.getElementById('delete-key-btn');

  saveKeyBtn?.addEventListener('click', async () => {
    const key = keyInput.value.trim();
    if (!key) {
      showStatus('Please enter an API key', 'error');
      return;
    }

    try {
      await window.hologram.keychain.setKey('openai', key);
      keyInput.value = '';
      updateKeyStatus(true);
      showStatus('API key saved securely', 'success');
    } catch (error) {
      showStatus('Failed to save key', 'error');
    }
  });

  rotateKeyBtn?.addEventListener('click', async () => {
    const key = keyInput.value.trim();
    if (!key) {
      showStatus('Please enter a new API key', 'error');
      return;
    }

    try {
      await window.hologram.keychain.deleteKey('openai');
      await window.hologram.keychain.setKey('openai', key);
      keyInput.value = '';
      showStatus('API key rotated', 'success');
    } catch (error) {
      showStatus('Failed to rotate key', 'error');
    }
  });

  deleteKeyBtn?.addEventListener('click', async () => {
    if (!confirm('Delete your OpenAI API key?')) return;

    try {
      await window.hologram.keychain.deleteKey('openai');
      updateKeyStatus(false);
      showStatus('API key deleted', 'success');
    } catch (error) {
      showStatus('Failed to delete key', 'error');
    }
  });

  // Panic button
  const panicBtn = document.getElementById('panic-btn');
  panicBtn?.addEventListener('click', async () => {
    if (!confirm('DELETE ALL API KEYS? This cannot be undone.')) return;
    if (!confirm('Are you absolutely sure?')) return;

    try {
      const count = await window.hologram.keychain.deleteAllKeys();
      await window.hologram.chat.clearHistory();
      await window.hologram.settings.clearLogs();
      updateKeyStatus(false);
      showStatus(`Deleted ${count} keys, cleared history and logs`, 'success');
    } catch (error) {
      showStatus('Panic wipe failed', 'error');
    }
  });

  // Clear history button
  const clearHistoryBtn = document.getElementById('clear-history-btn');
  clearHistoryBtn?.addEventListener('click', async () => {
    if (!confirm('Clear all chat history?')) return;

    try {
      await window.hologram.chat.clearHistory();
      showStatus('Chat history cleared', 'success');
    } catch (error) {
      showStatus('Failed to clear history', 'error');
    }
  });

  // Clear logs button
  const clearLogsBtn = document.getElementById('clear-logs-btn');
  clearLogsBtn?.addEventListener('click', async () => {
    if (!confirm('Clear all logs?')) return;

    try {
      const count = await window.hologram.settings.clearLogs();
      showStatus(`Cleared ${count} log files`, 'success');
    } catch (error) {
      showStatus('Failed to clear logs', 'error');
    }
  });
}

function updateKeyStatus(hasKey: boolean): void {
  const statusEl = document.getElementById('key-status');
  const rotateBtn = document.getElementById('rotate-key-btn');
  const deleteBtn = document.getElementById('delete-key-btn');

  if (statusEl) {
    statusEl.textContent = hasKey ? '✅ API key configured' : '❌ No API key';
    statusEl.className = hasKey ? 'status-ok' : 'status-missing';
  }

  if (rotateBtn) rotateBtn.style.display = hasKey ? 'inline-block' : 'none';
  if (deleteBtn) deleteBtn.style.display = hasKey ? 'inline-block' : 'none';
}

function showStatus(message: string, type: 'success' | 'error'): void {
  const statusEl = document.getElementById('settings-status');
  if (statusEl) {
    statusEl.textContent = message;
    statusEl.className = `status-message status-${type}`;
    setTimeout(() => {
      statusEl.textContent = '';
    }, 3000);
  }
}
```

---

## Step 10: Update HTML with Settings Panel

Add to `src/renderer/index.html` inside the body:

```html
<!-- Settings Panel (toggled via menu) -->
<div id="settings-panel" class="settings-panel hidden">
  <h2>Settings</h2>
  
  <section class="settings-section">
    <h3>🔑 API Keys</h3>
    <p id="key-status" class="status-missing">Checking...</p>
    
    <div class="key-input-group">
      <input 
        type="password" 
        id="api-key-input" 
        placeholder="Enter OpenAI API key (sk-...)"
        autocomplete="off"
      />
      <button id="save-key-btn">Save</button>
      <button id="rotate-key-btn" style="display: none;">Rotate</button>
      <button id="delete-key-btn" class="danger" style="display: none;">Delete</button>
    </div>
  </section>
  
  <section class="settings-section">
    <h3>💬 Chat History</h3>
    <button id="clear-history-btn">Clear History</button>
  </section>
  
  <section class="settings-section">
    <h3>📋 Logs</h3>
    <button id="clear-logs-btn">Clear Logs</button>
  </section>
  
  <section class="settings-section danger-zone">
    <h3>🚨 Danger Zone</h3>
    <button id="panic-btn" class="danger">
      Delete All Keys + Clear Everything
    </button>
    <p class="help-text">This will delete all API keys, chat history, and logs. Cannot be undone.</p>
  </section>
  
  <p id="settings-status" class="status-message"></p>
</div>
```

---

## Step 11: Add Settings Styles

Add to `src/renderer/styles.css`:

```css
/* Settings Panel */
.settings-panel {
  position: fixed;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  background: rgba(20, 20, 30, 0.95);
  border: 1px solid rgba(126, 251, 255, 0.3);
  border-radius: 12px;
  padding: 24px;
  width: 400px;
  max-height: 80vh;
  overflow-y: auto;
  z-index: 1000;
  backdrop-filter: blur(10px);
}

.settings-panel.hidden {
  display: none;
}

.settings-panel h2 {
  margin: 0 0 20px 0;
  color: #7efbff;
  font-size: 1.5rem;
}

.settings-section {
  margin-bottom: 24px;
  padding-bottom: 24px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.settings-section:last-of-type {
  border-bottom: none;
}

.settings-section h3 {
  margin: 0 0 12px 0;
  color: #fff;
  font-size: 1rem;
}

.key-input-group {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}

.key-input-group input {
  flex: 1;
  min-width: 200px;
  padding: 8px 12px;
  background: rgba(0, 0, 0, 0.3);
  border: 1px solid rgba(126, 251, 255, 0.3);
  border-radius: 6px;
  color: #fff;
  font-family: monospace;
}

.key-input-group input:focus {
  outline: none;
  border-color: #7efbff;
}

.settings-panel button {
  padding: 8px 16px;
  background: rgba(126, 251, 255, 0.2);
  border: 1px solid #7efbff;
  border-radius: 6px;
  color: #7efbff;
  cursor: pointer;
  transition: all 0.2s;
}

.settings-panel button:hover {
  background: rgba(126, 251, 255, 0.3);
}

.settings-panel button.danger {
  background: rgba(255, 102, 102, 0.2);
  border-color: #ff6666;
  color: #ff6666;
}

.settings-panel button.danger:hover {
  background: rgba(255, 102, 102, 0.3);
}

.danger-zone {
  background: rgba(255, 0, 0, 0.05);
  border-radius: 8px;
  padding: 16px;
  margin: 0 -16px;
}

.status-ok {
  color: #4dfdd1;
}

.status-missing {
  color: #ffcc66;
}

.status-message {
  margin-top: 12px;
  padding: 8px;
  border-radius: 4px;
  text-align: center;
}

.status-success {
  background: rgba(77, 253, 209, 0.2);
  color: #4dfdd1;
}

.status-error {
  background: rgba(255, 102, 102, 0.2);
  color: #ff6666;
}

.help-text {
  margin-top: 8px;
  font-size: 0.8rem;
  color: rgba(255, 255, 255, 0.5);
}
```

---

## Exit Criteria

- [ ] `keytar` installed and working
- [ ] API keys stored in OS keychain (not .env)
- [ ] Settings panel shows key status
- [ ] Can save, rotate, delete API keys
- [ ] Panic button deletes all keys + clears history + logs
- [ ] OpenAI adapter uses keychain for auth
- [ ] Chat messages stream correctly
- [ ] Chat history is encrypted at rest
- [ ] Logs rotate at 10MB
- [ ] Logs auto-purge after 7 days
- [ ] Clear History button works
- [ ] Clear Logs button works
- [ ] No API keys appear in logs (test by checking log files)
- [ ] `npm run build` succeeds
- [ ] `npm run lint` passes

---

## Security Verification

After implementing, manually verify:

1. **Open log files** in `~/Library/Application Support/hologram/logs/` — search for "sk-" — should find nothing
2. **Check electron-store** file — messages should be encrypted (gibberish, not readable JSON)
3. **Open Keychain Access** (macOS) — search "hologram" — should see your stored keys
4. **Trigger an API error** (bad key) — check logs don't contain the key

---

## Files Summary

### Created:
- `src/main/services/keychain.ts` — OS keychain wrapper
- `src/main/adapters/openai.ts` — Proper OpenAI adapter
- `src/renderer/settings.ts` — Settings panel logic

### Modified:
- `src/main/services/logger.ts` — Add rotation + cleanup
- `src/main/services/chat-history.ts` — Add encryption
- `src/shared/ipc-types.ts` — New channels
- `src/main/index.ts` — Register services + handlers
- `src/preload/index.ts` — Expose new APIs
- `src/renderer/index.html` — Settings panel HTML
- `src/renderer/styles.css` — Settings styles

---

## If You Get Stuck

### keytar fails to build
```bash
npm install --save-dev electron-rebuild
npx electron-rebuild
```

### Encryption errors
- Make sure `hologram-encryption` key exists in keychain
- Delete it and let the app regenerate: `npm run start`

### Settings panel not showing
- Check menu.ts sends 'preferences:open' event
- Check renderer listens for it and toggles `.hidden` class

Good luck! 🔐

## Related Documentation

- [Doppler Secrets Management](Documents/reference/DOPPLER_SECRETS_MANAGEMENT.md) - secrets management
- [AI Model Cost Comparison](Documents/reference/MODEL_COST_COMPARISON.md) - AI models
- [AI Team Orchestration](patterns/ai-team-orchestration.md) - orchestration
- [Safety Systems](patterns/safety-systems.md) - security
