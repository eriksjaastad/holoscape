# Phase 1A Week 2: Core Architecture

**Goal:** Build the foundational patterns for IPC communication, service management, logging, and error handling.

## Current State (from Week 1)
- TypeScript project structure in place
- `src/shared/types.ts` has basic types (ProcessMetrics, ChatMessage, VisualizerState)
- `src/preload/index.ts` has basic typed API (getMetrics, getApiKey)
- Working build system (Vite + esbuild)

## What You're Building
1. Comprehensive IPC type system
2. Service registry for main process
3. Structured logging (safe for production)
4. Error types and handling patterns

---

## Step 1: Expand IPC Types

Create `src/shared/ipc-types.ts`:

```typescript
// IPC Channel Definitions
// All channels must be typed here for type-safe IPC

// ============ Request/Response Channels (invoke/handle) ============

export interface IPCInvokeChannels {
  // API Key
  'get-api-key': {
    request: void;
    response: string | null;
  };
  
  // Process Metrics
  'get-process-metrics': {
    request: void;
    response: ProcessMetrics;
  };
  
  // Chat
  'chat:send': {
    request: { message: string; connectionId?: string };
    response: { success: boolean; error?: string };
  };
  
  // Connections (for future multi-AI support)
  'connection:list': {
    request: void;
    response: ConnectionProfile[];
  };
  
  'connection:test': {
    request: { connectionId: string };
    response: { success: boolean; latencyMs?: number; error?: string };
  };
}

// ============ Event Channels (send/on) ============

export interface IPCEventChannels {
  // Streaming tokens from main to renderer
  'chat:token': { token: string; done: boolean };
  
  // Visualizer state changes
  'visualizer:state': { state: VisualizerState };
  
  // Network status
  'network:status': { online: boolean };
  
  // Errors
  'error:show': { code: ErrorCode; message: string };
}

// ============ Supporting Types ============

export interface ProcessMetrics {
  cpuPercent: number;
  heapUsedMB: number;
  heapTotalMB: number;
  rssUsedMB: number;
}

export type VisualizerState = 'idle' | 'thinking' | 'speaking' | 'listening' | 'error';

export interface ConnectionProfile {
  id: string;
  name: string;
  provider: 'openai' | 'anthropic' | 'custom';
  isDefault: boolean;
  createdAt: string;
}

export type ErrorCode =
  | 'NETWORK_OFFLINE'
  | 'API_RATE_LIMITED'
  | 'API_AUTH_FAILED'
  | 'API_TIMEOUT'
  | 'API_ERROR'
  | 'UNKNOWN';

// ============ Type Helpers ============

// For type-safe invoke calls
export type InvokeChannel = keyof IPCInvokeChannels;
export type InvokeRequest<T extends InvokeChannel> = IPCInvokeChannels[T]['request'];
export type InvokeResponse<T extends InvokeChannel> = IPCInvokeChannels[T]['response'];

// For type-safe event listeners
export type EventChannel = keyof IPCEventChannels;
export type EventPayload<T extends EventChannel> = IPCEventChannels[T];
```

---

## Step 2: Update Preload with Type-Safe Bridge

Replace `src/preload/index.ts`:

```typescript
import { contextBridge, ipcRenderer } from 'electron';
import type {
  InvokeChannel,
  InvokeRequest,
  InvokeResponse,
  EventChannel,
  EventPayload,
  ProcessMetrics,
} from '@shared/ipc-types';

// Type-safe invoke wrapper
async function invoke<T extends InvokeChannel>(
  channel: T,
  ...args: InvokeRequest<T> extends void ? [] : [InvokeRequest<T>]
): Promise<InvokeResponse<T>> {
  return ipcRenderer.invoke(channel, ...args);
}

// Type-safe event listener
function on<T extends EventChannel>(
  channel: T,
  callback: (payload: EventPayload<T>) => void
): () => void {
  const handler = (_event: Electron.IpcRendererEvent, payload: EventPayload<T>) => {
    callback(payload);
  };
  ipcRenderer.on(channel, handler);
  
  // Return unsubscribe function
  return () => ipcRenderer.removeListener(channel, handler);
}

export interface HologramAPI {
  version: string;
  
  // Typed invoke methods
  getMetrics: () => Promise<ProcessMetrics>;
  getApiKey: () => Promise<string | null>;
  
  // Generic typed invoke (for future channels)
  invoke: typeof invoke;
  
  // Event subscription
  on: typeof on;
}

const api: HologramAPI = {
  version: '0.1.0-alpha',
  getMetrics: () => invoke('get-process-metrics'),
  getApiKey: () => invoke('get-api-key'),
  invoke,
  on,
};

contextBridge.exposeInMainWorld('hologram', api);
```

---

## Step 3: Create Service Registry

Create `src/main/services/index.ts`:

```typescript
// Service Registry Pattern
// Centralizes service lifecycle management

export interface Service {
  name: string;
  initialize(): Promise<void>;
  shutdown(): Promise<void>;
}

class ServiceRegistry {
  private services: Map<string, Service> = new Map();
  private initialized = false;

  register(service: Service): void {
    if (this.initialized) {
      throw new Error(`Cannot register service "${service.name}" after initialization`);
    }
    if (this.services.has(service.name)) {
      throw new Error(`Service "${service.name}" already registered`);
    }
    this.services.set(service.name, service);
  }

  async initializeAll(): Promise<void> {
    if (this.initialized) return;
    
    for (const [name, service] of this.services) {
      try {
        await service.initialize();
        console.log(`[ServiceRegistry] Initialized: ${name}`);
      } catch (error) {
        console.error(`[ServiceRegistry] Failed to initialize: ${name}`, error);
        throw error;
      }
    }
    
    this.initialized = true;
  }

  async shutdownAll(): Promise<void> {
    for (const [name, service] of this.services) {
      try {
        await service.shutdown();
        console.log(`[ServiceRegistry] Shutdown: ${name}`);
      } catch (error) {
        console.error(`[ServiceRegistry] Failed to shutdown: ${name}`, error);
      }
    }
    this.services.clear();
    this.initialized = false;
  }

  get<T extends Service>(name: string): T | undefined {
    return this.services.get(name) as T | undefined;
  }
}

export const registry = new ServiceRegistry();
```

---

## Step 4: Create Logging Service

Create `src/main/services/logger.ts`:

```typescript
import type { Service } from './index';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

interface LogEntry {
  timestamp: string;
  level: LogLevel;
  context: string;
  message: string;
  data?: Record<string, unknown>;
}

// Fields that should NEVER be logged
const SENSITIVE_PATTERNS = [
  /api[_-]?key/i,
  /password/i,
  /secret/i,
  /token/i,
  /auth/i,
  /bearer/i,
  /sk-[a-zA-Z0-9]/,  // OpenAI key pattern
];

function sanitize(data: unknown): unknown {
  if (data === null || data === undefined) return data;
  if (typeof data === 'string') {
    // Redact anything that looks like a key
    for (const pattern of SENSITIVE_PATTERNS) {
      if (pattern.test(data)) {
        return '[REDACTED]';
      }
    }
    return data;
  }
  if (Array.isArray(data)) {
    return data.map(sanitize);
  }
  if (typeof data === 'object') {
    const result: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(data)) {
      // Redact sensitive field names
      const isSensitiveKey = SENSITIVE_PATTERNS.some(p => p.test(key));
      result[key] = isSensitiveKey ? '[REDACTED]' : sanitize(value);
    }
    return result;
  }
  return data;
}

class Logger {
  private minLevel: LogLevel = 'info';
  private context: string;

  constructor(context: string) {
    this.context = context;
  }

  private shouldLog(level: LogLevel): boolean {
    const levels: LogLevel[] = ['debug', 'info', 'warn', 'error'];
    return levels.indexOf(level) >= levels.indexOf(this.minLevel);
  }

  private format(level: LogLevel, message: string, data?: Record<string, unknown>): LogEntry {
    return {
      timestamp: new Date().toISOString(),
      level,
      context: this.context,
      message,
      data: data ? (sanitize(data) as Record<string, unknown>) : undefined,
    };
  }

  private output(entry: LogEntry): void {
    const prefix = `[${entry.timestamp}] [${entry.level.toUpperCase()}] [${entry.context}]`;
    const message = `${prefix} ${entry.message}`;
    
    switch (entry.level) {
      case 'error':
        console.error(message, entry.data ?? '');
        break;
      case 'warn':
        console.warn(message, entry.data ?? '');
        break;
      default:
        console.log(message, entry.data ?? '');
    }
  }

  debug(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('debug')) {
      this.output(this.format('debug', message, data));
    }
  }

  info(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('info')) {
      this.output(this.format('info', message, data));
    }
  }

  warn(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('warn')) {
      this.output(this.format('warn', message, data));
    }
  }

  error(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('error')) {
      this.output(this.format('error', message, data));
    }
  }

  setMinLevel(level: LogLevel): void {
    this.minLevel = level;
  }
}

// Factory function
export function createLogger(context: string): Logger {
  return new Logger(context);
}

// Logger service for registry
export class LoggerService implements Service {
  name = 'logger';
  private defaultLevel: LogLevel = process.env.NODE_ENV === 'development' ? 'debug' : 'info';

  async initialize(): Promise<void> {
    const logger = createLogger('LoggerService');
    logger.info('Logger initialized', { level: this.defaultLevel });
  }

  async shutdown(): Promise<void> {
    // Nothing to clean up
  }
}
```

---

## Step 5: Create Error Handling Utilities

Create `src/shared/errors.ts`:

```typescript
import type { ErrorCode } from './ipc-types';

export class AppError extends Error {
  readonly code: ErrorCode;
  readonly isOperational: boolean;
  readonly context?: Record<string, unknown>;

  constructor(
    code: ErrorCode,
    message: string,
    options?: {
      cause?: Error;
      isOperational?: boolean;
      context?: Record<string, unknown>;
    }
  ) {
    super(message, { cause: options?.cause });
    this.name = 'AppError';
    this.code = code;
    this.isOperational = options?.isOperational ?? true;
    this.context = options?.context;
  }

  static fromUnknown(error: unknown): AppError {
    if (error instanceof AppError) return error;
    
    if (error instanceof Error) {
      return new AppError('UNKNOWN', error.message, { cause: error });
    }
    
    return new AppError('UNKNOWN', String(error));
  }

  toJSON(): Record<string, unknown> {
    return {
      name: this.name,
      code: this.code,
      message: this.message,
      isOperational: this.isOperational,
      context: this.context,
    };
  }
}

// Error type guards
export function isNetworkError(error: unknown): boolean {
  if (error instanceof AppError) {
    return error.code === 'NETWORK_OFFLINE';
  }
  if (error instanceof Error) {
    return error.message.includes('network') || 
           error.message.includes('ENOTFOUND') ||
           error.message.includes('ECONNREFUSED');
  }
  return false;
}

export function isAuthError(error: unknown): boolean {
  if (error instanceof AppError) {
    return error.code === 'API_AUTH_FAILED';
  }
  if (error instanceof Error) {
    return error.message.includes('401') || 
           error.message.includes('unauthorized') ||
           error.message.includes('invalid_api_key');
  }
  return false;
}

export function isRateLimitError(error: unknown): boolean {
  if (error instanceof AppError) {
    return error.code === 'API_RATE_LIMITED';
  }
  if (error instanceof Error) {
    return error.message.includes('429') || 
           error.message.includes('rate limit');
  }
  return false;
}

// Convert any error to an ErrorCode for IPC
export function toErrorCode(error: unknown): ErrorCode {
  if (isNetworkError(error)) return 'NETWORK_OFFLINE';
  if (isAuthError(error)) return 'API_AUTH_FAILED';
  if (isRateLimitError(error)) return 'API_RATE_LIMITED';
  if (error instanceof AppError) return error.code;
  return 'UNKNOWN';
}
```

---

## Step 6: Update Main Process to Use Services

Update `src/main/index.ts` to use the service registry:

```typescript
import { app, BrowserWindow, ipcMain } from 'electron';
import path from 'path';
import 'dotenv/config';

import { registry } from './services';
import { LoggerService, createLogger } from './services/logger';

const log = createLogger('Main');

let mainWindow: BrowserWindow | null = null;
let lastCpuUsage = process.cpuUsage();
let lastCpuTime = process.hrtime.bigint();

// Register services
registry.register(new LoggerService());

function createWindow(): void {
  log.info('Creating main window');
  
  mainWindow = new BrowserWindow({
    width: 960,
    height: 720,
    minWidth: 500,
    minHeight: 320,
    transparent: true,
    frame: false,
    vibrancy: 'ultra-dark',
    hasShadow: true,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  if (process.env.NODE_ENV === 'development') {
    mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  } else {
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  }
  
  log.info('Window created', { 
    dev: process.env.NODE_ENV === 'development' 
  });
}

// IPC Handlers
ipcMain.handle('get-api-key', () => {
  // Note: actual key value is never logged
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

  return {
    cpuPercent,
    heapUsedMB: memUsage.heapUsed / 1024 / 1024,
    heapTotalMB: memUsage.heapTotal / 1024 / 1024,
    rssUsedMB: memUsage.rss / 1024 / 1024,
  };
});

// App lifecycle
app.whenReady().then(async () => {
  log.info('App ready, initializing services');
  await registry.initializeAll();
  createWindow();
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
  await registry.shutdownAll();
});
```

---

## Step 7: Update Shared Types Index

Update `src/shared/types.ts` to re-export from new files:

```typescript
// Re-export all shared types from one place
export * from './ipc-types';
export * from './errors';
```

---

## Step 8: Add Tests for Error Utilities

Create `src/shared/errors.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { AppError, toErrorCode, isNetworkError, isAuthError } from './errors';

describe('AppError', () => {
  it('creates error with code and message', () => {
    const error = new AppError('API_TIMEOUT', 'Request timed out');
    expect(error.code).toBe('API_TIMEOUT');
    expect(error.message).toBe('Request timed out');
    expect(error.isOperational).toBe(true);
  });

  it('converts unknown errors', () => {
    const original = new Error('Something broke');
    const appError = AppError.fromUnknown(original);
    expect(appError.code).toBe('UNKNOWN');
    expect(appError.message).toBe('Something broke');
  });

  it('passes through existing AppErrors', () => {
    const original = new AppError('API_AUTH_FAILED', 'Bad key');
    const result = AppError.fromUnknown(original);
    expect(result).toBe(original);
  });
});

describe('toErrorCode', () => {
  it('detects network errors', () => {
    expect(toErrorCode(new Error('ENOTFOUND'))).toBe('NETWORK_OFFLINE');
  });

  it('detects auth errors', () => {
    expect(toErrorCode(new Error('401 unauthorized'))).toBe('API_AUTH_FAILED');
  });

  it('detects rate limit errors', () => {
    expect(toErrorCode(new Error('429 rate limit exceeded'))).toBe('API_RATE_LIMITED');
  });

  it('returns UNKNOWN for unrecognized errors', () => {
    expect(toErrorCode(new Error('random error'))).toBe('UNKNOWN');
  });
});

describe('error type guards', () => {
  it('isNetworkError identifies network issues', () => {
    expect(isNetworkError(new Error('ECONNREFUSED'))).toBe(true);
    expect(isNetworkError(new Error('random'))).toBe(false);
  });

  it('isAuthError identifies auth issues', () => {
    expect(isAuthError(new Error('invalid_api_key'))).toBe(true);
    expect(isAuthError(new Error('random'))).toBe(false);
  });
});
```

---

## Verification Steps

1. `npm run typecheck` — Should pass with new types
2. `npm run lint` — Should pass
3. `npm run test` — Should run error tests
4. `npm run build` — Should bundle successfully
5. `npm run dev` — App should launch with service initialization logs

---

## Files Created/Modified Summary

**Created:**
- `src/shared/ipc-types.ts` — Comprehensive IPC type definitions
- `src/shared/errors.ts` — Error classes and utilities
- `src/shared/errors.test.ts` — Error handling tests
- `src/main/services/index.ts` — Service registry
- `src/main/services/logger.ts` — Structured logging service

**Modified:**
- `src/preload/index.ts` — Type-safe IPC bridge
- `src/main/index.ts` — Service registry integration
- `src/shared/types.ts` — Re-exports

---

## 🛑 IF YOU GET STUCK — STOP AND ASK

**Do NOT guess if you encounter:**

1. **Import resolution errors** — The path aliases may need adjustment
2. **Type mismatches** — Document exactly which types don't line up
3. **Build failures** — Capture the full error message
4. **Uncertainty about existing code** — Ask rather than break working features

### Format for questions:
```
## BLOCKED: [Brief description]

**Step I'm on:** [Step number and name]

**What I was trying to do:**
[Description]

**What went wrong:**
[Error message or confusion]

**What I've tried:**
[List of attempts]

**My question:**
[Specific question for Opus]
```

