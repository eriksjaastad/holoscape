# Sonnet: Hologram Phase 3 — Weeks 11-12: Custom Endpoints + File Agent

## Your Mission
Build a Custom Endpoint adapter for self-hosted/OpenAI-compatible APIs, implement a secure File Agent with sandboxing and audit logging, add a conversation history manager, and enable multi-agent workflows.

## Context

### What exists (from Week 9-10):
- `BaseAdapter` abstract class in `src/main/adapters/base.ts`
- `ConnectionManagerService` with profile CRUD
- `OrchestratorService` with sub-agent dispatch through SecurityService
- `SecurityService` with `executeSecured()` for protected operations
- Sub-agent types: `AgentRole`, `SubAgent`, `AgentDispatchResult`

### What you're building:
- **Custom Endpoint Adapter** — Connect to any OpenAI-compatible API
- **File Agent** — Secure local file operations with sandboxing
- **Conversation History Manager** — Context window management
- **Multi-Agent Workflows** — Orchestrator chains sub-agent calls

---

## Project Location

All work in: `..`

---

## Step 1: Create Custom Endpoint Adapter

Create `src/main/adapters/custom.ts`:

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
        return this.customConfig.authHeader
          ? { [this.customConfig.authHeader]: apiKey }
          : {};
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
```

---

## Step 2: Update ConnectionManager for Custom Endpoints

Update `src/main/services/connection-manager.ts`:

```typescript
// Add import
import { CustomAdapter, CustomEndpointConfig } from '../adapters/custom';

// Update ConnectionProfile interface (in base.ts or here)
export interface ConnectionProfile {
  // ... existing fields
  customConfig?: CustomEndpointConfig; // Add this for custom endpoints
}

// Update createAdapterForProfile
case 'custom':
  if (!profile.customConfig?.baseUrl) {
    this.logger?.warn('Custom adapter missing baseUrl', { profileId: profile.id });
    return;
  }
  adapter = new CustomAdapter(
    this.keychain,
    this.logger,
    { ...profile.config, ...profile.customConfig },
    profile.keychainKey
  );
  break;
```

---

## Step 3: Create File Agent Service

Create `src/main/services/file-agent.ts`:

```typescript
import { readFile, writeFile, rename, unlink, mkdir, stat, readdir } from 'fs/promises';
import { existsSync, appendFileSync } from 'fs';
import { join, dirname, basename, extname, resolve, relative } from 'path';
import { homedir } from 'os';
import { randomUUID } from 'crypto';
import { ipcMain } from 'electron';
import type { Service } from './index';
import type { LoggerService } from './logger';
import type { SecurityService } from './security';

// File operation types
export type FileOperation = 'read' | 'write' | 'move' | 'delete' | 'list';

export interface FileOperationRequest {
  operation: FileOperation;
  sourcePath: string;
  destinationPath?: string; // For move operations
  content?: string; // For write operations
  encoding?: BufferEncoding;
}

export interface FileOperationResult {
  success: boolean;
  operation: FileOperation;
  sourcePath: string;
  destinationPath?: string;
  content?: string;
  error?: string;
  auditId: string;
}

export interface FileAuditEntry {
  id: string;
  timestamp: string;
  operation: FileOperation;
  sourcePath: string;
  destinationPath?: string;
  success: boolean;
  error?: string;
  fileSize?: number;
  initiatedBy: 'user' | 'agent';
  agentId?: string;
}

// Security configuration
const DEFAULT_ALLOWED_EXTENSIONS = [
  '.txt', '.md', '.json', '.yaml', '.yml', '.xml',
  '.js', '.ts', '.jsx', '.tsx', '.css', '.html',
  '.py', '.rb', '.go', '.rs', '.java', '.c', '.cpp', '.h',
  '.sh', '.bash', '.zsh',
  '.log', '.csv',
  '.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp',
];

const FORBIDDEN_PATHS = [
  /^\/etc\//,
  /^\/usr\//,
  /^\/System\//,
  /^\/bin\//,
  /^\/sbin\//,
  /^\/var\//,
  /^\/private\//,
  /\.ssh/,
  /\.gnupg/,
  /\.aws/,
  /node_modules/,
  /\.git\//,
];

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB

export class FileAgentService implements Service {
  name = 'file-agent';
  private logger!: LoggerService;
  private security!: SecurityService;
  private auditLogPath: string;
  private allowedDirectories: string[] = [];
  private allowedExtensions: string[] = DEFAULT_ALLOWED_EXTENSIONS;

  constructor() {
    // Audit log in app data directory
    this.auditLogPath = join(homedir(), '.hologram', 'file-audit.log');
  }

  setDependencies(logger: LoggerService, security: SecurityService): void {
    this.logger = logger;
    this.security = security;
  }

  async initialize(): Promise<void> {
    // Ensure audit log directory exists
    const auditDir = dirname(this.auditLogPath);
    if (!existsSync(auditDir)) {
      await mkdir(auditDir, { recursive: true });
    }

    // Set default allowed directories
    this.allowedDirectories = [
      join(homedir(), 'Documents'),
      join(homedir(), 'Downloads'),
      join(homedir(), 'Desktop'),
      join(homedir(), '.hologram', 'workspace'),
    ];

    this.registerIpcHandlers();
    this.logger?.info('FileAgentService initialized', {
      allowedDirs: this.allowedDirectories.length,
    });
  }

  async shutdown(): Promise<void> {
    this.logger?.info('FileAgentService shutdown');
  }

  private registerIpcHandlers(): void {
    ipcMain.handle('file-agent:execute', async (_, request: FileOperationRequest & { agentId?: string }) => {
      return this.execute(request, request.agentId);
    });

    ipcMain.handle('file-agent:get-allowed-dirs', () => {
      return this.allowedDirectories;
    });

    ipcMain.handle('file-agent:add-allowed-dir', async (_, { dir }: { dir: string }) => {
      return this.addAllowedDirectory(dir);
    });

    ipcMain.handle('file-agent:get-audit-log', async (_, { limit }: { limit?: number }) => {
      return this.getAuditLog(limit);
    });
  }

  /**
   * Execute a file operation through the security layer
   */
  async execute(
    request: FileOperationRequest,
    agentId?: string
  ): Promise<FileOperationResult> {
    const auditId = randomUUID();

    // Validate paths before security check
    const pathValidation = this.validatePaths(request);
    if (!pathValidation.valid) {
      const result: FileOperationResult = {
        success: false,
        operation: request.operation,
        sourcePath: request.sourcePath,
        error: pathValidation.error,
        auditId,
      };
      await this.logAudit({
        id: auditId,
        timestamp: new Date().toISOString(),
        operation: request.operation,
        sourcePath: this.sanitizePath(request.sourcePath),
        success: false,
        error: pathValidation.error,
        initiatedBy: agentId ? 'agent' : 'user',
        agentId,
      });
      return result;
    }

    // Determine action type and risk level
    const actionType = this.getSecurityActionType(request.operation);

    // Execute through security layer
    const securityResult = await this.security.executeSecured(
      actionType,
      `${request.operation} file: ${basename(request.sourcePath)}`,
      {
        path: request.sourcePath,
        userInitiated: !agentId,
      },
      async () => this.executeOperation(request)
    );

    const success = securityResult.success && !!securityResult.result;
    const result: FileOperationResult = {
      success,
      operation: request.operation,
      sourcePath: request.sourcePath,
      destinationPath: request.destinationPath,
      content: request.operation === 'read' ? securityResult.result : undefined,
      error: securityResult.error,
      auditId,
    };

    // Log to audit
    await this.logAudit({
      id: auditId,
      timestamp: new Date().toISOString(),
      operation: request.operation,
      sourcePath: this.sanitizePath(request.sourcePath),
      destinationPath: request.destinationPath ? this.sanitizePath(request.destinationPath) : undefined,
      success,
      error: securityResult.error,
      initiatedBy: agentId ? 'agent' : 'user',
      agentId,
    });

    return result;
  }

  private async executeOperation(request: FileOperationRequest): Promise<string> {
    const { operation, sourcePath, destinationPath, content, encoding = 'utf-8' } = request;

    switch (operation) {
      case 'read': {
        const data = await readFile(sourcePath, encoding);
        return data;
      }

      case 'write': {
        if (!content) throw new Error('Content required for write operation');
        
        // Check file size
        if (Buffer.byteLength(content, encoding) > MAX_FILE_SIZE) {
          throw new Error(`File size exceeds maximum allowed (${MAX_FILE_SIZE / 1024 / 1024}MB)`);
        }

        // Ensure directory exists
        const dir = dirname(sourcePath);
        if (!existsSync(dir)) {
          await mkdir(dir, { recursive: true });
        }

        await writeFile(sourcePath, content, encoding);
        return 'File written successfully';
      }

      case 'move': {
        if (!destinationPath) throw new Error('Destination required for move operation');
        
        // Move-not-modify: use rename for atomic move
        const destDir = dirname(destinationPath);
        if (!existsSync(destDir)) {
          await mkdir(destDir, { recursive: true });
        }

        await rename(sourcePath, destinationPath);

        // Handle companion files (e.g., .png + .yaml)
        await this.moveCompanionFiles(sourcePath, destinationPath);

        return 'File moved successfully';
      }

      case 'delete': {
        // Move to trash directory instead of hard delete
        const trashDir = join(homedir(), '.hologram', 'trash');
        if (!existsSync(trashDir)) {
          await mkdir(trashDir, { recursive: true });
        }

        const trashPath = join(trashDir, `${Date.now()}_${basename(sourcePath)}`);
        await rename(sourcePath, trashPath);

        return `File moved to trash: ${trashPath}`;
      }

      case 'list': {
        const entries = await readdir(sourcePath, { withFileTypes: true });
        const files = entries.map(e => ({
          name: e.name,
          isDirectory: e.isDirectory(),
          path: join(sourcePath, e.name),
        }));
        return JSON.stringify(files);
      }

      default:
        throw new Error(`Unknown operation: ${operation}`);
    }
  }

  /**
   * Move companion files (e.g., if moving skin.png, also move skin.yaml)
   */
  private async moveCompanionFiles(sourcePath: string, destinationPath: string): Promise<void> {
    const sourceBase = sourcePath.replace(extname(sourcePath), '');
    const destBase = destinationPath.replace(extname(destinationPath), '');

    const companionExtensions = ['.yaml', '.yml', '.json', '.meta', '.md'];

    for (const ext of companionExtensions) {
      const companionSource = sourceBase + ext;
      const companionDest = destBase + ext;

      if (existsSync(companionSource)) {
        try {
          await rename(companionSource, companionDest);
          this.logger?.debug('Moved companion file', {
            from: basename(companionSource),
            to: basename(companionDest),
          });
        } catch (error) {
          this.logger?.warn('Failed to move companion file', {
            file: basename(companionSource),
            error: error instanceof Error ? error.message : 'Unknown',
          });
        }
      }
    }
  }

  private validatePaths(request: FileOperationRequest): { valid: boolean; error?: string } {
    const { operation, sourcePath, destinationPath } = request;

    // Resolve to absolute path
    const absSource = resolve(sourcePath);

    // Check forbidden paths
    for (const pattern of FORBIDDEN_PATHS) {
      if (pattern.test(absSource)) {
        return { valid: false, error: `Access denied: ${basename(absSource)} is in a protected location` };
      }
    }

    // Check allowed directories for write operations
    if (operation !== 'read') {
      const inAllowed = this.allowedDirectories.some(dir => 
        absSource.startsWith(resolve(dir))
      );

      if (!inAllowed) {
        return {
          valid: false,
          error: `Write access denied: ${basename(absSource)} is outside allowed directories`,
        };
      }
    }

    // Check file extension
    const ext = extname(absSource).toLowerCase();
    if (ext && !this.allowedExtensions.includes(ext)) {
      return {
        valid: false,
        error: `File type not allowed: ${ext}`,
      };
    }

    // Validate destination for move
    if (destinationPath) {
      const absDest = resolve(destinationPath);

      for (const pattern of FORBIDDEN_PATHS) {
        if (pattern.test(absDest)) {
          return { valid: false, error: `Destination is in a protected location` };
        }
      }

      const destInAllowed = this.allowedDirectories.some(dir =>
        absDest.startsWith(resolve(dir))
      );

      if (!destInAllowed) {
        return {
          valid: false,
          error: `Destination is outside allowed directories`,
        };
      }
    }

    return { valid: true };
  }

  private getSecurityActionType(operation: FileOperation): string {
    switch (operation) {
      case 'read':
        return 'file:read';
      case 'write':
        return 'file:write';
      case 'move':
        return 'file:write'; // Move is a write operation
      case 'delete':
        return 'file:delete';
      case 'list':
        return 'file:read';
      default:
        return 'file:write';
    }
  }

  /**
   * Sanitize path for audit log (remove home directory prefix)
   */
  private sanitizePath(filePath: string): string {
    const home = homedir();
    if (filePath.startsWith(home)) {
      return '~' + filePath.slice(home.length);
    }
    return filePath;
  }

  private async logAudit(entry: FileAuditEntry): Promise<void> {
    try {
      const line = JSON.stringify(entry) + '\n';
      appendFileSync(this.auditLogPath, line);
    } catch (error) {
      this.logger?.error('Failed to write audit log', {
        error: error instanceof Error ? error.message : 'Unknown',
      });
    }
  }

  /**
   * Get recent audit log entries
   */
  async getAuditLog(limit = 100): Promise<FileAuditEntry[]> {
    try {
      if (!existsSync(this.auditLogPath)) {
        return [];
      }

      const content = await readFile(this.auditLogPath, 'utf-8');
      const lines = content.trim().split('\n').filter(Boolean);
      const entries = lines
        .slice(-limit)
        .map(line => {
          try {
            return JSON.parse(line) as FileAuditEntry;
          } catch {
            return null;
          }
        })
        .filter((e): e is FileAuditEntry => e !== null);

      return entries.reverse(); // Most recent first
    } catch {
      return [];
    }
  }

  /**
   * Add a directory to the allowed list
   */
  addAllowedDirectory(dir: string): boolean {
    const absDir = resolve(dir);

    // Don't allow adding forbidden paths
    for (const pattern of FORBIDDEN_PATHS) {
      if (pattern.test(absDir)) {
        return false;
      }
    }

    if (!this.allowedDirectories.includes(absDir)) {
      this.allowedDirectories.push(absDir);
      this.logger?.info('Added allowed directory', { dir: this.sanitizePath(absDir) });
      return true;
    }

    return false;
  }

  /**
   * Add allowed extensions
   */
  addAllowedExtension(ext: string): void {
    const normalizedExt = ext.startsWith('.') ? ext.toLowerCase() : `.${ext.toLowerCase()}`;
    if (!this.allowedExtensions.includes(normalizedExt)) {
      this.allowedExtensions.push(normalizedExt);
    }
  }
}
```

---

## Step 4: Create Conversation History Manager

Create `src/main/services/conversation-manager.ts`:

```typescript
import Store from 'electron-store';
import { randomUUID } from 'crypto';
import { ipcMain } from 'electron';
import type { Service } from './index';
import type { LoggerService } from './logger';
import type { ChatMessage } from '../adapters/base';

export interface Conversation {
  id: string;
  title: string;
  connectionId: string;
  messages: ConversationMessage[];
  createdAt: string;
  updatedAt: string;
  tokenCount: number;
}

export interface ConversationMessage extends ChatMessage {
  id: string;
  timestamp: string;
  tokenEstimate: number;
}

interface ConversationStore {
  conversations: Conversation[];
  activeConversationId: string | null;
}

const MAX_CONVERSATIONS = 50;
const MAX_CONTEXT_TOKENS = 100000; // Conservative default

export class ConversationManagerService implements Service {
  name = 'conversation-manager';
  private store: Store<ConversationStore>;
  private logger!: LoggerService;
  private maxContextTokens = MAX_CONTEXT_TOKENS;

  constructor() {
    this.store = new Store<ConversationStore>({
      name: 'conversations',
      defaults: {
        conversations: [],
        activeConversationId: null,
      },
    });
  }

  setDependencies(logger: LoggerService): void {
    this.logger = logger;
  }

  async initialize(): Promise<void> {
    this.registerIpcHandlers();
    this.logger?.info('ConversationManagerService initialized', {
      conversationCount: this.getConversations().length,
    });
  }

  async shutdown(): Promise<void> {
    this.logger?.info('ConversationManagerService shutdown');
  }

  private registerIpcHandlers(): void {
    ipcMain.handle('conversation:list', () => {
      return this.getConversations().map(c => ({
        id: c.id,
        title: c.title,
        connectionId: c.connectionId,
        messageCount: c.messages.length,
        createdAt: c.createdAt,
        updatedAt: c.updatedAt,
      }));
    });

    ipcMain.handle('conversation:get', (_, { id }: { id: string }) => {
      return this.getConversation(id);
    });

    ipcMain.handle('conversation:create', (_, { connectionId, title }: { connectionId: string; title?: string }) => {
      return this.createConversation(connectionId, title);
    });

    ipcMain.handle('conversation:delete', (_, { id }: { id: string }) => {
      return this.deleteConversation(id);
    });

    ipcMain.handle('conversation:add-message', (_, { conversationId, message }: { conversationId: string; message: ChatMessage }) => {
      return this.addMessage(conversationId, message);
    });

    ipcMain.handle('conversation:get-context', (_, { conversationId, maxTokens }: { conversationId: string; maxTokens?: number }) => {
      return this.getContextWindow(conversationId, maxTokens);
    });

    ipcMain.handle('conversation:set-active', (_, { id }: { id: string }) => {
      return this.setActiveConversation(id);
    });

    ipcMain.handle('conversation:get-active', () => {
      return this.getActiveConversation();
    });

    ipcMain.handle('conversation:rename', (_, { id, title }: { id: string; title: string }) => {
      return this.renameConversation(id, title);
    });
  }

  getConversations(): Conversation[] {
    return this.store.get('conversations') || [];
  }

  getConversation(id: string): Conversation | null {
    return this.getConversations().find(c => c.id === id) || null;
  }

  createConversation(connectionId: string, title?: string): Conversation {
    const conversation: Conversation = {
      id: randomUUID(),
      title: title || `Conversation ${new Date().toLocaleString()}`,
      connectionId,
      messages: [],
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      tokenCount: 0,
    };

    const conversations = this.getConversations();
    conversations.unshift(conversation);

    // Limit total conversations
    if (conversations.length > MAX_CONVERSATIONS) {
      conversations.pop();
    }

    this.store.set('conversations', conversations);
    this.store.set('activeConversationId', conversation.id);

    this.logger?.info('Conversation created', { id: conversation.id, title: conversation.title });
    return conversation;
  }

  deleteConversation(id: string): boolean {
    const conversations = this.getConversations();
    const index = conversations.findIndex(c => c.id === id);

    if (index === -1) return false;

    conversations.splice(index, 1);
    this.store.set('conversations', conversations);

    // If deleted was active, set new active
    if (this.store.get('activeConversationId') === id) {
      this.store.set('activeConversationId', conversations[0]?.id || null);
    }

    this.logger?.info('Conversation deleted', { id });
    return true;
  }

  addMessage(conversationId: string, message: ChatMessage): ConversationMessage | null {
    const conversations = this.getConversations();
    const conversation = conversations.find(c => c.id === conversationId);

    if (!conversation) return null;

    const tokenEstimate = this.estimateTokens(message.content);

    const conversationMessage: ConversationMessage = {
      ...message,
      id: randomUUID(),
      timestamp: new Date().toISOString(),
      tokenEstimate,
    };

    conversation.messages.push(conversationMessage);
    conversation.tokenCount += tokenEstimate;
    conversation.updatedAt = new Date().toISOString();

    this.store.set('conversations', conversations);

    return conversationMessage;
  }

  /**
   * Get messages that fit within the context window
   * Keeps system message + most recent messages up to token limit
   */
  getContextWindow(conversationId: string, maxTokens?: number): ChatMessage[] {
    const conversation = this.getConversation(conversationId);
    if (!conversation) return [];

    const limit = maxTokens || this.maxContextTokens;
    const messages = conversation.messages;

    // Always include system message if present
    const systemMessage = messages.find(m => m.role === 'system');
    const systemTokens = systemMessage?.tokenEstimate || 0;

    let remainingTokens = limit - systemTokens;
    const result: ChatMessage[] = [];

    // Add messages from most recent, staying within token limit
    for (let i = messages.length - 1; i >= 0; i--) {
      const msg = messages[i];
      if (msg.role === 'system') continue;

      if (msg.tokenEstimate <= remainingTokens) {
        result.unshift({
          role: msg.role,
          content: msg.content,
        });
        remainingTokens -= msg.tokenEstimate;
      } else {
        break; // Stop when we can't fit more
      }
    }

    // Prepend system message
    if (systemMessage) {
      result.unshift({
        role: systemMessage.role,
        content: systemMessage.content,
      });
    }

    return result;
  }

  setActiveConversation(id: string): boolean {
    const conversation = this.getConversation(id);
    if (!conversation) return false;

    this.store.set('activeConversationId', id);
    return true;
  }

  getActiveConversation(): Conversation | null {
    const id = this.store.get('activeConversationId');
    if (!id) return null;
    return this.getConversation(id);
  }

  renameConversation(id: string, title: string): boolean {
    const conversations = this.getConversations();
    const conversation = conversations.find(c => c.id === id);

    if (!conversation) return false;

    conversation.title = title;
    conversation.updatedAt = new Date().toISOString();
    this.store.set('conversations', conversations);

    return true;
  }

  setMaxContextTokens(tokens: number): void {
    this.maxContextTokens = tokens;
  }

  /**
   * Rough token estimation (4 chars ≈ 1 token)
   */
  private estimateTokens(text: string): number {
    return Math.ceil(text.length / 4);
  }
}
```

---

## Step 5: Add IPC Types

Add to `src/shared/ipc-types.ts`:

```typescript
// File Agent
'file-agent:execute': {
  request: {
    operation: 'read' | 'write' | 'move' | 'delete' | 'list';
    sourcePath: string;
    destinationPath?: string;
    content?: string;
    encoding?: string;
    agentId?: string;
  };
  response: import('../main/services/file-agent').FileOperationResult;
};
'file-agent:get-allowed-dirs': {
  request: void;
  response: string[];
};
'file-agent:add-allowed-dir': {
  request: { dir: string };
  response: boolean;
};
'file-agent:get-audit-log': {
  request: { limit?: number };
  response: import('../main/services/file-agent').FileAuditEntry[];
};

// Conversation Manager
'conversation:list': {
  request: void;
  response: Array<{
    id: string;
    title: string;
    connectionId: string;
    messageCount: number;
    createdAt: string;
    updatedAt: string;
  }>;
};
'conversation:get': {
  request: { id: string };
  response: import('../main/services/conversation-manager').Conversation | null;
};
'conversation:create': {
  request: { connectionId: string; title?: string };
  response: import('../main/services/conversation-manager').Conversation;
};
'conversation:delete': {
  request: { id: string };
  response: boolean;
};
'conversation:add-message': {
  request: { conversationId: string; message: import('../main/adapters/base').ChatMessage };
  response: import('../main/services/conversation-manager').ConversationMessage | null;
};
'conversation:get-context': {
  request: { conversationId: string; maxTokens?: number };
  response: import('../main/adapters/base').ChatMessage[];
};
'conversation:set-active': {
  request: { id: string };
  response: boolean;
};
'conversation:get-active': {
  request: void;
  response: import('../main/services/conversation-manager').Conversation | null;
};
'conversation:rename': {
  request: { id: string; title: string };
  response: boolean;
};
```

---

## Step 6: Add File Agent Sub-Agent Definition

Update `config/personality.json`:

```json
{
  "name": "Hologram",
  "systemPrompt": "You are Hologram, a helpful AI assistant...",
  "subAgents": [
    {
      "id": "coder-claude",
      "name": "Claude Coder",
      "role": "coder",
      "connectionId": "",
      "systemPrompt": "You are a senior software engineer...",
      "capabilities": ["code-generation", "code-review", "debugging"],
      "enabled": false
    },
    {
      "id": "file-agent",
      "name": "File Agent",
      "role": "writer",
      "connectionId": "",
      "systemPrompt": "You manage local files safely. RULES: 1) Never modify files in-place, always move. 2) Report all operations. 3) Respect file type restrictions. 4) Handle companion files together.",
      "capabilities": ["file-read", "file-write", "file-move", "file-list"],
      "enabled": true
    },
    {
      "id": "researcher",
      "name": "Research Agent",
      "role": "researcher",
      "connectionId": "",
      "systemPrompt": "You are a research assistant...",
      "capabilities": ["web-search", "summarization"],
      "enabled": false
    }
  ]
}
```

---

## Step 7: Register Services in Main

Update `src/main/index.ts`:

```typescript
import { FileAgentService } from './services/file-agent';
import { ConversationManagerService } from './services/conversation-manager';

// After existing service registrations
const fileAgentService = new FileAgentService();
const conversationManagerService = new ConversationManagerService();

registry.register(fileAgentService);
registry.register(conversationManagerService);

// In app.whenReady(), after services initialize:
fileAgentService.setDependencies(loggerService, securityService);
conversationManagerService.setDependencies(loggerService);
```

---

## Step 8: Update Preload

Add to `src/preload/index.ts`:

```typescript
// Add to HologramAPI interface
fileAgent: {
  execute: (request: {
    operation: 'read' | 'write' | 'move' | 'delete' | 'list';
    sourcePath: string;
    destinationPath?: string;
    content?: string;
  }) => invoke('file-agent:execute', request),
  getAllowedDirs: () => invoke('file-agent:get-allowed-dirs'),
  addAllowedDir: (dir: string) => invoke('file-agent:add-allowed-dir', { dir }),
  getAuditLog: (limit?: number) => invoke('file-agent:get-audit-log', { limit }),
},
conversation: {
  list: () => invoke('conversation:list'),
  get: (id: string) => invoke('conversation:get', { id }),
  create: (connectionId: string, title?: string) => invoke('conversation:create', { connectionId, title }),
  delete: (id: string) => invoke('conversation:delete', { id }),
  addMessage: (conversationId: string, message: ChatMessage) => 
    invoke('conversation:add-message', { conversationId, message }),
  getContext: (conversationId: string, maxTokens?: number) => 
    invoke('conversation:get-context', { conversationId, maxTokens }),
  setActive: (id: string) => invoke('conversation:set-active', { id }),
  getActive: () => invoke('conversation:get-active'),
  rename: (id: string, title: string) => invoke('conversation:rename', { id, title }),
},
```

---

## Step 9: Update Window Types

Add to `src/shared/types.ts` (Window.hologram interface):

```typescript
fileAgent: {
  execute: (request: {
    operation: 'read' | 'write' | 'move' | 'delete' | 'list';
    sourcePath: string;
    destinationPath?: string;
    content?: string;
  }) => Promise<import('./services/file-agent').FileOperationResult>;
  getAllowedDirs: () => Promise<string[]>;
  addAllowedDir: (dir: string) => Promise<boolean>;
  getAuditLog: (limit?: number) => Promise<import('./services/file-agent').FileAuditEntry[]>;
};
conversation: {
  list: () => Promise<Array<{ id: string; title: string; connectionId: string; messageCount: number; createdAt: string; updatedAt: string }>>;
  get: (id: string) => Promise<import('./services/conversation-manager').Conversation | null>;
  create: (connectionId: string, title?: string) => Promise<import('./services/conversation-manager').Conversation>;
  delete: (id: string) => Promise<boolean>;
  addMessage: (conversationId: string, message: import('../main/adapters/base').ChatMessage) => Promise<import('./services/conversation-manager').ConversationMessage | null>;
  getContext: (conversationId: string, maxTokens?: number) => Promise<import('../main/adapters/base').ChatMessage[]>;
  setActive: (id: string) => Promise<boolean>;
  getActive: () => Promise<import('./services/conversation-manager').Conversation | null>;
  rename: (id: string, title: string) => Promise<boolean>;
};
```

---

## Exit Criteria

- [ ] `CustomAdapter` connects to OpenAI-compatible endpoints
- [ ] Custom endpoint supports different auth types (bearer, x-api-key, custom)
- [ ] `FileAgentService` implements read/write/move/delete/list
- [ ] File operations respect allowed directories (sandbox)
- [ ] File operations respect extension whitelist
- [ ] File operations respect size limits
- [ ] Delete moves to trash (not hard delete)
- [ ] Companion files moved together
- [ ] Audit log records all file operations
- [ ] Audit log sanitizes paths (removes home directory)
- [ ] `ConversationManagerService` manages conversations
- [ ] Context window returns messages within token limit
- [ ] All file operations go through SecurityService
- [ ] IPC channels for file-agent and conversation manager
- [ ] TypeScript compiles with no errors
- [ ] Lint passes

---

## Security Verification

- [ ] File Agent cannot access forbidden paths (/etc, .ssh, etc.)
- [ ] File Agent cannot write outside allowed directories
- [ ] File Agent respects extension whitelist
- [ ] File operations logged to separate audit file
- [ ] Audit log doesn't expose full home path
- [ ] Delete is soft-delete (trash)
- [ ] All file actions go through security layer
- [ ] Custom endpoint doesn't log full API key

---

## Files Summary

### Created:
- `src/main/adapters/custom.ts` — OpenAI-compatible endpoint adapter
- `src/main/services/file-agent.ts` — Secure file operations
- `src/main/services/conversation-manager.ts` — Context window management

### Modified:
- `src/main/adapters/base.ts` — Add customConfig to ConnectionProfile (optional)
- `src/main/services/connection-manager.ts` — Support custom adapters
- `src/shared/ipc-types.ts` — File agent + conversation channels
- `src/preload/index.ts` — Expose new APIs
- `src/shared/types.ts` — Window type declarations
- `src/main/index.ts` — Register new services
- `config/personality.json` — Add file agent definition

---

Good luck! 📁

## Related Documentation

- [Doppler Secrets Management](Documents/reference/DOPPLER_SECRETS_MANAGEMENT.md) - secrets management
- [[api_design_patterns]] - API design
- [AI Model Cost Comparison](Documents/reference/MODEL_COST_COMPARISON.md) - AI models
- [AI Team Orchestration](patterns/ai-team-orchestration.md) - orchestration
- [[portfolio_content]] - portfolio/career
- [[research_methodology]] - research
- [Safety Systems](patterns/safety-systems.md) - security
