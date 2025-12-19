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
  timestamp: string;
  connectionId?: string;
}

export interface ChatMessageInput {
  role: 'user' | 'assistant' | 'system';
  content: string;
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
