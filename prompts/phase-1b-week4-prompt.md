# Mini: Phase 1B — Week 4: Chat UI + Offline Resilience

## Your Mission
Add chat history persistence, network status detection, offline UI handling, and security foundation types.

## Context

### What exists:
- Basic chat UI with streaming (from Spike 2)
- Service registry pattern in `src/main/services/`
- Logger service with structured logging
- IPC type system in `src/shared/ipc-types.ts`
- Visualizer with 5 states (idle, thinking, speaking, listening, error)

### What you're adding:
1. **Chat History Service** — Persist messages across app restarts
2. **Orchestrator Stub** — Load personality config, placeholder for future routing
3. **Network Service** — Detect online/offline, emit events
4. **Offline UI** — Badge, disabled controls when offline
5. **Security Types + Stub** — Foundation for future permission system

---

## Step 1: Install Dependencies

```bash
cd /Users/eriksjaastad/projects/hologram
npm install electron-store
```

**Note:** `electron-store` types are included, no separate `@types` package needed.

---

## Step 2: Update IPC Types

Update `src/shared/ipc-types.ts`:

```typescript
// Supporting shared metrics definition
export interface ProcessMetrics {
  cpuPercent: number;
  heapUsedMB: number;
  heapTotalMB: number;
  rssUsedMB: number;
}

// Chat message type
export interface ChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: string; // ISO string
  connectionId?: string;
}

// IPC Invoke channels (request/response pairs)
export interface IPCInvokeChannels {
  'get-api-key': {
    request: void;
    response: string | null;
  };
  'get-process-metrics': {
    request: void;
    response: ProcessMetrics;
  };
  'chat:send': {
    request: { message: string; connectionId?: string };
    response: { success: boolean; error?: string };
  };
  'chat:get-history': {
    request: void;
    response: ChatMessage[];
  };
  'chat:clear-history': {
    request: void;
    response: void;
  };
  'connection:list': {
    request: void;
    response: ConnectionProfile[];
  };
  'connection:test': {
    request: { connectionId: string };
    response: { success: boolean; latencyMs?: number; error?: string };
  };
  'window:toggle': {
    request: void;
    response: { visible: boolean };
  };
  'window:set-always-on-top': {
    request: { enabled: boolean };
    response: void;
  };
  'network:get-status': {
    request: void;
    response: { online: boolean };
  };
}

// IPC event channels (fire-and-forget)
export interface IPCEventChannels {
  'chat:token': { token: string; done: boolean };
  'chat:message-added': { message: ChatMessage };
  'visualizer:state': { state: VisualizerState };
  'network:status': { online: boolean };
  'error:show': { code: ErrorCode; message: string };
  'preferences:open': void;
}

// Supporting shared types
export interface ConnectionProfile {
  id: string;
  name: string;
  provider: 'openai' | 'anthropic' | 'custom';
  isDefault: boolean;
  createdAt: string;
}

export type VisualizerState = 'idle' | 'thinking' | 'speaking' | 'listening' | 'error';

export type ErrorCode =
  | 'NETWORK_OFFLINE'
  | 'API_RATE_LIMITED'
  | 'API_AUTH_FAILED'
  | 'API_TIMEOUT'
  | 'API_ERROR'
  | 'UNKNOWN';

// Type helpers
export type InvokeChannel = keyof IPCInvokeChannels;
export type InvokeRequest<T extends InvokeChannel> = IPCInvokeChannels[T]['request'];
export type InvokeResponse<T extends InvokeChannel> = IPCInvokeChannels[T]['response'];
export type EventChannel = keyof IPCEventChannels;
export type EventPayload<T extends EventChannel> = IPCEventChannels[T];
```

---

## Step 3: Create Security Types

Create `src/shared/security-types.ts`:

```typescript
export type RiskLevel = 'green' | 'yellow' | 'red';

export interface Action {
  id: string;
  type: string;
  description: string;
  riskLevel: RiskLevel;
  requiresApproval: boolean;
}

export interface SecurityAssessment {
  action: Action;
  approved: boolean;
  reason?: string;
  timestamp: string;
}

// Pre-defined action types for reference
export const ACTION_TYPES = {
  CHAT_SEND: 'chat:send',
  FILE_READ: 'file:read',
  FILE_WRITE: 'file:write',
  NETWORK_REQUEST: 'network:request',
  SYSTEM_COMMAND: 'system:command',
} as const;

export type ActionType = (typeof ACTION_TYPES)[keyof typeof ACTION_TYPES];
```

---

## Step 4: Create Chat History Service

Create `src/main/services/chat-history.ts`:

```typescript
import Store from 'electron-store';
import { ipcMain } from 'electron';
import { randomUUID } from 'crypto';
import type { Service } from './index';
import { createLogger } from './logger';
import type { ChatMessage } from '@shared/ipc-types';

const log = createLogger('ChatHistory');

interface ChatHistoryStore {
  messages: ChatMessage[];
}

const MAX_MESSAGES = 100;

export class ChatHistoryService implements Service {
  name = 'chatHistory';
  private store: Store<ChatHistoryStore>;

  constructor() {
    this.store = new Store<ChatHistoryStore>({
      name: 'chat-history',
      defaults: {
        messages: [],
      },
    });
  }

  addMessage(msg: Omit<ChatMessage, 'id' | 'timestamp'>): ChatMessage {
    const message: ChatMessage = {
      ...msg,
      id: randomUUID(),
      timestamp: new Date().toISOString(),
    };

    const messages = this.store.get('messages', []);
    messages.push(message);

    // Keep only last MAX_MESSAGES
    const trimmed = messages.slice(-MAX_MESSAGES);
    this.store.set('messages', trimmed);

    log.debug('Message added', { id: message.id, role: message.role });
    return message;
  }

  getHistory(): ChatMessage[] {
    return this.store.get('messages', []);
  }

  clearHistory(): void {
    this.store.set('messages', []);
    log.info('Chat history cleared');
  }

  async initialize(): Promise<void> {
    // Register IPC handlers
    ipcMain.handle('chat:get-history', () => {
      return this.getHistory();
    });

    ipcMain.handle('chat:clear-history', () => {
      this.clearHistory();
    });

    const count = this.getHistory().length;
    log.info('Chat history service initialized', { existingMessages: count });
  }

  async shutdown(): Promise<void> {
    ipcMain.removeHandler('chat:get-history');
    ipcMain.removeHandler('chat:clear-history');
    log.info('Chat history service shutdown');
  }
}
```

---

## Step 5: Create Personality Config

Create `config/personality.json`:

```json
{
  "name": "Hologram",
  "systemPrompt": "You are Hologram, a helpful AI assistant. You are calm, thoughtful, and slightly mysterious. You speak with quiet confidence. You help users accomplish their goals while maintaining a sense of wonder about technology and possibility.",
  "temperature": 0.7,
  "maxTokens": 2048
}
```

---

## Step 6: Create Orchestrator Service

Create `src/main/services/orchestrator.ts`:

```typescript
import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { app } from 'electron';
import type { Service } from './index';
import { createLogger } from './logger';

const log = createLogger('Orchestrator');

interface PersonalityConfig {
  name: string;
  systemPrompt: string;
  temperature: number;
  maxTokens: number;
}

const DEFAULT_PERSONALITY: PersonalityConfig = {
  name: 'Hologram',
  systemPrompt: 'You are a helpful AI assistant.',
  temperature: 0.7,
  maxTokens: 2048,
};

export class OrchestratorService implements Service {
  name = 'orchestrator';
  private personality: PersonalityConfig = DEFAULT_PERSONALITY;

  private loadPersonality(): PersonalityConfig {
    // Try multiple paths (dev vs production)
    const paths = [
      join(process.cwd(), 'config', 'personality.json'),
      join(app.getAppPath(), 'config', 'personality.json'),
    ];

    for (const configPath of paths) {
      if (existsSync(configPath)) {
        try {
          const content = readFileSync(configPath, 'utf-8');
          const config = JSON.parse(content) as PersonalityConfig;
          log.info('Personality loaded', { path: configPath, name: config.name });
          return config;
        } catch (error) {
          log.warn('Failed to parse personality config', { path: configPath, error });
        }
      }
    }

    log.warn('No personality config found, using defaults');
    return DEFAULT_PERSONALITY;
  }

  getSystemPrompt(): string {
    return this.personality.systemPrompt;
  }

  getTemperature(): number {
    return this.personality.temperature;
  }

  getMaxTokens(): number {
    return this.personality.maxTokens;
  }

  getName(): string {
    return this.personality.name;
  }

  // Placeholder for future sub-agent routing
  // async routeMessage(message: string): Promise<{ agent: string; response: string }> {
  //   // Future: analyze message intent and route to appropriate sub-agent
  //   // e.g., code questions → Coder agent, file operations → File agent
  //   return { agent: 'default', response: '' };
  // }

  async initialize(): Promise<void> {
    this.personality = this.loadPersonality();
    log.info('Orchestrator initialized', { personality: this.personality.name });
  }

  async shutdown(): Promise<void> {
    log.info('Orchestrator shutdown');
  }
}
```

---

## Step 7: Create Network Service

Create `src/main/services/network.ts`:

```typescript
import { net, ipcMain, BrowserWindow } from 'electron';
import type { Service } from './index';
import { createLogger } from './logger';

const log = createLogger('Network');

const POLL_INTERVAL_MS = 5000;

export class NetworkService implements Service {
  name = 'network';
  private pollInterval: NodeJS.Timeout | null = null;
  private lastOnlineState: boolean = true;

  isOnline(): boolean {
    return net.isOnline();
  }

  private broadcastStatus(online: boolean): void {
    // Send to all windows
    for (const window of BrowserWindow.getAllWindows()) {
      window.webContents.send('network:status', { online });
    }
  }

  private startPolling(): void {
    this.lastOnlineState = this.isOnline();
    log.info('Starting network polling', { online: this.lastOnlineState });

    this.pollInterval = setInterval(() => {
      const currentState = this.isOnline();
      
      if (currentState !== this.lastOnlineState) {
        log.info('Network status changed', { 
          from: this.lastOnlineState ? 'online' : 'offline',
          to: currentState ? 'online' : 'offline',
        });
        this.lastOnlineState = currentState;
        this.broadcastStatus(currentState);
      }
    }, POLL_INTERVAL_MS);
  }

  private stopPolling(): void {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  }

  async initialize(): Promise<void> {
    // Register IPC handler
    ipcMain.handle('network:get-status', () => {
      return { online: this.isOnline() };
    });

    this.startPolling();
    log.info('Network service initialized');
  }

  async shutdown(): Promise<void> {
    this.stopPolling();
    ipcMain.removeHandler('network:get-status');
    log.info('Network service shutdown');
  }
}
```

---

## Step 8: Create Security Service

Create `src/main/services/security.ts`:

```typescript
import { randomUUID } from 'crypto';
import type { Service } from './index';
import { createLogger } from './logger';
import type { Action, SecurityAssessment, RiskLevel } from '@shared/security-types';

const log = createLogger('Security');

export class SecurityService implements Service {
  name = 'security';
  private assessmentLog: SecurityAssessment[] = [];

  assessRisk(action: Action): SecurityAssessment {
    const assessment: SecurityAssessment = {
      action,
      approved: this.shouldAutoApprove(action),
      reason: this.getAssessmentReason(action),
      timestamp: new Date().toISOString(),
    };

    this.assessmentLog.push(assessment);
    
    log.info('Security assessment', {
      actionType: action.type,
      riskLevel: action.riskLevel,
      approved: assessment.approved,
      reason: assessment.reason,
    });

    return assessment;
  }

  private shouldAutoApprove(action: Action): boolean {
    // Auto-approve green actions
    // Yellow and red require explicit approval (future implementation)
    return action.riskLevel === 'green';
  }

  private getAssessmentReason(action: Action): string {
    switch (action.riskLevel) {
      case 'green':
        return 'Low risk action, auto-approved';
      case 'yellow':
        return 'Medium risk action, requires review';
      case 'red':
        return 'High risk action, requires explicit approval';
      default:
        return 'Unknown risk level';
    }
  }

  // Placeholder for future approval UI integration
  async requestApproval(action: Action): Promise<boolean> {
    log.warn('Approval requested (auto-approving for now)', {
      actionType: action.type,
      riskLevel: action.riskLevel,
    });
    
    // Future: Show UI dialog for yellow/red actions
    // For now, auto-approve everything
    return true;
  }

  // Helper to create actions with generated IDs
  createAction(
    type: string,
    description: string,
    riskLevel: RiskLevel
  ): Action {
    return {
      id: randomUUID(),
      type,
      description,
      riskLevel,
      requiresApproval: riskLevel !== 'green',
    };
  }

  getAssessmentLog(): SecurityAssessment[] {
    return [...this.assessmentLog];
  }

  async initialize(): Promise<void> {
    log.info('Security service initialized');
  }

  async shutdown(): Promise<void> {
    log.info('Security service shutdown', {
      totalAssessments: this.assessmentLog.length,
    });
  }
}
```

---

## Step 9: Register All Services

Update `src/main/index.ts` to register the new services:

```typescript
import { app, BrowserWindow, ipcMain, Menu } from 'electron';
import type { BrowserWindowConstructorOptions } from 'electron';
import path from 'path';
import 'dotenv/config';

import { registry } from './services';
import { LoggerService, createLogger } from './services/logger';
import { WindowService } from './services/window';
import { ChatHistoryService } from './services/chat-history';
import { OrchestratorService } from './services/orchestrator';
import { NetworkService } from './services/network';
import { SecurityService } from './services/security';
import { registerGlobalShortcuts, unregisterGlobalShortcuts } from './shortcuts';
import { createAppMenu } from './menu';

const log = createLogger('Main');

// Register all services
const windowService = new WindowService();
registry.register(new LoggerService());
registry.register(windowService);
registry.register(new ChatHistoryService());
registry.register(new OrchestratorService());
registry.register(new NetworkService());
registry.register(new SecurityService());

let mainWindow: BrowserWindow | null = null;
let lastCpuUsage = process.cpuUsage();
let lastCpuTime = process.hrtime.bigint();

function createWindow(): void {
  log.info('Creating main window');
  const windowOptions: BrowserWindowConstructorOptions = {
    width: 960,
    height: 720,
    minWidth: 500,
    minHeight: 320,
    transparent: true,
    frame: false,
    vibrancy: 'ultra-dark' as BrowserWindowConstructorOptions['vibrancy'],
    hasShadow: true,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
  };

  mainWindow = new BrowserWindow(windowOptions);
  windowService.setWindow(mainWindow);

  if (process.env.NODE_ENV === 'development') {
    mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  } else {
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  }

  log.info('Window created', {
    dev: process.env.NODE_ENV === 'development',
  });
}

ipcMain.handle('get-api-key', () => {
  log.debug('API key requested');
  return process.env.OPENAI_API_KEY || null;
});

ipcMain.handle('get-process-metrics', () => {
  const now = process.hrtime.bigint();
  const intervalNs = Number(now - lastCpuTime);
  lastCpuTime = now;

  const cpuUsage = process.cpuUsage(lastCpuUsage);
  lastCpuUsage = process.cpuUsage();
  const memUsage = process.memoryUsage();

  const cpuMicroseconds = cpuUsage.user + cpuUsage.system;
  const intervalMs = intervalNs / 1_000_000;
  const cpuMs = cpuMicroseconds / 1000;
  const cpuPercent = intervalMs > 0 ? (cpuMs / intervalMs) * 100 : 0;

  log.debug('Process metrics requested', { cpuPercent });

  return {
    cpuPercent,
    heapUsedMB: memUsage.heapUsed / 1024 / 1024,
    heapTotalMB: memUsage.heapTotal / 1024 / 1024,
    rssUsedMB: memUsage.rss / 1024 / 1024,
  };
});

ipcMain.handle('window:toggle', () => {
  if (!mainWindow) return { visible: false };

  if (mainWindow.isVisible()) {
    mainWindow.hide();
    return { visible: false };
  }

  mainWindow.show();
  mainWindow.focus();
  return { visible: true };
});

ipcMain.handle('window:set-always-on-top', (_event, { enabled }: { enabled: boolean }) => {
  if (mainWindow) {
    mainWindow.setAlwaysOnTop(enabled);
    log.info('Always on top changed', { enabled });
  }
});

app.whenReady().then(async () => {
  log.info('App ready, initializing services');
  await registry.initializeAll();
  createWindow();
  Menu.setApplicationMenu(createAppMenu());
  registerGlobalShortcuts(() => windowService.getWindow());
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('before-quit', async () => {
  log.info('App shutting down');
  unregisterGlobalShortcuts();
  await registry.shutdownAll();
});

app.on('will-quit', () => {
  unregisterGlobalShortcuts();
});
```

---

## Step 10: Update HTML with Offline Badge

Update `src/renderer/index.html` — add after the `<div id="chat-panel">` closing tag:

```html
<div id="offline-badge" class="offline-badge" hidden>Offline</div>
```

Full chat-panel section should look like:

```html
<div id="chat-panel">
  <input
    id="api-key-input"
    type="password"
    placeholder="OpenAI API key (optional for simulation)"
    aria-label="OpenAI API key"
  />
  <div class="chat-controls">
    <input id="chat-input" type="text" placeholder="Ask anything..." />
    <button id="send-button" type="button">Send</button>
  </div>
  <div id="response-log" aria-live="polite" role="status">
    Streaming output will appear here.
  </div>
  <div id="chat-status">Idle</div>
</div>

<div id="offline-badge" class="offline-badge" hidden>Offline</div>
```

---

## Step 11: Add Offline CSS

Add to `src/renderer/styles.css`:

```css
/* Offline indicator */
.offline-badge {
  position: fixed;
  top: 12px;
  right: 12px;
  padding: 6px 14px;
  background: linear-gradient(135deg, #ff4444, #cc3333);
  color: white;
  font-size: 12px;
  font-weight: 600;
  border-radius: 6px;
  box-shadow: 0 2px 8px rgba(255, 68, 68, 0.4);
  z-index: 1000;
  animation: pulse-offline 2s ease-in-out infinite;
}

@keyframes pulse-offline {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.7; }
}

.chat-disabled {
  opacity: 0.5;
  pointer-events: none;
}

.chat-disabled input,
.chat-disabled button {
  cursor: not-allowed;
}
```

---

## Step 12: Update Chat with Offline Handling

Update `src/renderer/chat.ts`:

```typescript
import { streamChatCompletion, StreamOptions } from '@api/openai-stream';
import { setVisualizerState } from './visualizer';

const chatInput = document.getElementById('chat-input') as HTMLInputElement | null;
const sendButton = document.getElementById('send-button') as HTMLButtonElement | null;
const responseLog = document.getElementById('response-log') as HTMLDivElement | null;
const apiKeyInput = document.getElementById('api-key-input') as HTMLInputElement | null;
const statusBadge = document.getElementById('chat-status') as HTMLDivElement | null;
const offlineBadge = document.getElementById('offline-badge') as HTMLDivElement | null;
const chatPanel = document.getElementById('chat-panel') as HTMLDivElement | null;

let isOnline = true;

function updateChatStatus(text: string) {
  if (statusBadge) {
    statusBadge.textContent = text;
  }
}

function updateOfflineState(online: boolean) {
  isOnline = online;
  
  if (offlineBadge) {
    offlineBadge.hidden = online;
  }
  
  if (chatPanel) {
    if (online) {
      chatPanel.classList.remove('chat-disabled');
    } else {
      chatPanel.classList.add('chat-disabled');
    }
  }
  
  if (sendButton) {
    sendButton.disabled = !online;
    sendButton.title = online ? '' : 'Connect to internet to send';
  }
  
  if (!online) {
    updateChatStatus('Offline');
  } else if (statusBadge?.textContent === 'Offline') {
    updateChatStatus('Idle');
  }
}

async function initializeNetworkStatus() {
  // Get initial status
  if (window.hologram?.invoke) {
    try {
      const status = await window.hologram.invoke('network:get-status');
      updateOfflineState(status.online);
    } catch (err) {
      console.warn('Failed to get initial network status:', err);
    }
  }
  
  // Subscribe to changes
  if (window.hologram?.on) {
    window.hologram.on('network:status', (payload) => {
      updateOfflineState(payload.online);
    });
  }
}

async function setApiKeyFromEnv() {
  if (apiKeyInput && window.hologram?.getApiKey) {
    const envKey = await window.hologram.getApiKey();
    if (envKey) {
      apiKeyInput.value = envKey;
      apiKeyInput.placeholder = 'Loaded from .env';
    }
  }
}

async function handleSend() {
  if (!chatInput || !responseLog || !sendButton) {
    return;
  }
  
  if (!isOnline) {
    updateChatStatus('Cannot send while offline');
    return;
  }

  const prompt = chatInput.value.trim();
  if (!prompt) {
    return;
  }

  const apiKey = apiKeyInput?.value.trim();
  sendButton.disabled = true;
  chatInput.blur();
  responseLog.textContent = '';
  updateChatStatus('Thinking...');
  setVisualizerState('thinking');

  let tokenStreamed = false;
  try {
    const streamOptions: StreamOptions = {
      apiKey: apiKey || undefined,
      messages: [{ role: 'user', content: prompt }],
    };

    for await (const chunk of streamChatCompletion(streamOptions)) {
      if (!tokenStreamed) {
        tokenStreamed = true;
        setVisualizerState('speaking');
        updateChatStatus('Speaking');
      }
      responseLog.textContent += chunk;
      responseLog.scrollTop = responseLog.scrollHeight;
    }

    updateChatStatus('Idle');
  } catch (error) {
    responseLog.textContent = `Error: ${(error as Error).message || 'stream failed'}`;
    console.error(error);
    updateChatStatus('Error');
    setVisualizerState('error');
  } finally {
    sendButton.disabled = !isOnline;
    setVisualizerState('idle');
  }
}

sendButton?.addEventListener('click', handleSend);
chatInput?.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    handleSend();
  }
});

// Initialize
setApiKeyFromEnv();
initializeNetworkStatus();
updateChatStatus('Idle');
```

---

## Step 13: Export Security Types

Update `src/shared/types.ts` to export security types:

```typescript
import type {
  InvokeChannel,
  InvokeRequest,
  InvokeResponse,
  EventChannel,
  EventPayload,
  ProcessMetrics,
  VisualizerState,
  ChatMessage,
} from './ipc-types';

export * from './ipc-types';
export * from './errors';
export * from './security-types';

declare global {
  interface Window {
    hologram: {
      version: string;
      getMetrics: () => Promise<ProcessMetrics>;
      getApiKey: () => Promise<string | null>;
      invoke: <T extends InvokeChannel>(
        channel: T,
        ...args: InvokeRequest<T> extends void ? [] : [InvokeRequest<T>]
      ) => Promise<InvokeResponse<T>>;
      on: <T extends EventChannel>(
        channel: T,
        callback: (payload: EventPayload<T>) => void
      ) => () => void;
    };
    setVisualizerState?: (state: VisualizerState) => void;
  }
}
```

---

## Step 14: Verify Everything

Run these commands to verify:

```bash
# Build
npm run build

# Lint
npm run lint

# Test
npm run test

# Start dev
npm run dev
```

---

## Exit Criteria Checklist

- [ ] `npm run build` succeeds with no errors
- [ ] `npm run lint` passes
- [ ] `npm test` passes
- [ ] App opens with breathing particles
- [ ] Chat history persists:
  - Send a message, close app, reopen → history still there
  - Check `~/Library/Application Support/hologram/chat-history.json` exists
- [ ] Offline detection works:
  - Disconnect WiFi → "Offline" badge appears, send button disabled
  - Reconnect WiFi → badge disappears, send button enabled
- [ ] Visualizer keeps running at 60fps while offline
- [ ] Console shows service initialization messages:
  - `[ChatHistory] Chat history service initialized`
  - `[Orchestrator] Orchestrator initialized`
  - `[Network] Network service initialized`
  - `[Security] Security service initialized`

---

## Files Created/Modified

### Created:
- `src/main/services/chat-history.ts`
- `src/main/services/orchestrator.ts`
- `src/main/services/network.ts`
- `src/main/services/security.ts`
- `src/shared/security-types.ts`
- `config/personality.json`

### Modified:
- `src/shared/ipc-types.ts` — Added ChatMessage, new IPC channels
- `src/shared/types.ts` — Export security types
- `src/main/index.ts` — Register 4 new services
- `src/renderer/index.html` — Add offline badge
- `src/renderer/styles.css` — Add offline styles
- `src/renderer/chat.ts` — Add offline handling

---

## IF STUCK — STOP AND ASK

If you encounter any of these, stop and create a question:

1. **electron-store import errors** — May need different import syntax
2. **net.isOnline() not found** — Check Electron version compatibility
3. **IPC type errors** — Verify all type definitions match
4. **Service registration order** — Services may have dependencies

Format questions like:
```
## BLOCKED: [Brief description]
**What I tried:** [List]
**Error:** [Exact message]
**Question:** [What you need to know]
```

---

Good luck! 🛡️

