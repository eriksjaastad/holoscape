// Supporting shared metrics definition
export interface ProcessMetrics {
  cpuPercent: number;
  heapUsedMB: number;
  heapTotalMB: number;
  rssUsedMB: number;
}

// Import types
export type { SubAgent, AgentRole, AgentDispatchResult } from './agent-types';

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
    response: import('./types').ConnectionProfile[];
  };
  'connection:add': {
    request: Omit<import('./types').ConnectionProfile, 'id' | 'createdAt'>;
    response: import('./types').ConnectionProfile;
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
  'connection:test': {
    request: { id: string };
    response: { success: boolean; latencyMs?: number; error?: string };
  };
  'connection:get-active': {
    request: void;
    response: import('./types').ConnectionProfile | null;
  };
  'connection:update': {
    request: {
      id: string;
      updates: Partial<import('./types').ConnectionProfile>;
    };
    response: import('./types').ConnectionProfile | null;
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
  // Keychain
  'keychain:set': {
    request: { provider: string; key: string };
    response: void;
  };
  'keychain:get': {
    request: { provider: string };
    response: string | null;
  };
  'keychain:delete': {
    request: { provider: string };
    response: boolean;
  };
  'keychain:delete-all': {
    request: void;
    response: number;
  };
  'keychain:list': {
    request: void;
    response: Array<{ provider: string; hasKey: boolean; createdAt?: string }>;
  };
  'keychain:has': {
    request: { provider: string };
    response: boolean;
  };
  // Settings
  'settings:clear-logs': {
    request: void;
    response: number;
  };
  'settings:get-log-dir': {
    request: void;
    response: string;
  };
  // Security
  'security:approve': {
    request: { actionId: string; approved: boolean; remember?: boolean };
    response: void;
  };
  'security:get-pending': {
    request: void;
    response: Array<{ id: string; action: import('@shared/security-types').Action }>;
  };
  'security:get-log': {
    request: void;
    response: Array<import('@shared/security-types').SecurityAssessment>;
  };
  // Orchestrator
  'orchestrator:get-personality': {
    request: void;
    response: {
      name: string;
      systemPrompt: string;
      subAgents: import('./agent-types').SubAgent[];
    } | null;
  };
  'orchestrator:list-agents': {
    request: void;
    response: import('./agent-types').SubAgent[];
  };
  'orchestrator:dispatch': {
    request: {
      targetAgent: import('./agent-types').AgentRole;
      task: string;
      context?: Record<string, unknown>;
    };
    response: import('./agent-types').AgentDispatchResult;
  };
  'orchestrator:add-agent': {
    request: import('./agent-types').SubAgent;
    response: boolean;
  };
  'orchestrator:remove-agent': {
    request: { id: string };
    response: boolean;
  };
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
    request: {
      conversationId: string;
      message: import('../main/adapters/base').ChatMessage;
    };
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
}

// IPC event channels (fire-and-forget)
export interface IPCEventChannels {
  'chat:token': { token: string; done: boolean };
  'chat:message-added': { message: ChatMessage };
  'chat:complete': { fullResponse: string };
  'chat:error': { message: string };
  'visualizer:state': { state: VisualizerState };
  'network:status': { online: boolean };
  'error:show': { code: ErrorCode; message: string };
  'preferences:open': void;
  'security:approval-needed': {
    action: import('@shared/security-types').Action;
    isRedSwitch: boolean;
  };
  'security:status': {
    pendingCount: number;
  };
  'connection:profiles-changed': {
    profiles: import('./types').ConnectionProfile[];
  };
  'connection:active-changed': {
    profileId: string;
    profile: import('./types').ConnectionProfile | null;
  };
  'orchestrator:dispatch-progress': {
    agentId: string;
    token: string;
  };
}

// Supporting shared types

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
