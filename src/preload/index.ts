import { contextBridge, ipcRenderer } from 'electron';
import type {
  InvokeChannel,
  InvokeRequest,
  InvokeResponse,
  EventChannel,
  EventPayload,
  ProcessMetrics,
} from '@shared/ipc-types';

async function invoke<T extends InvokeChannel>(
  channel: T,
  ...args: InvokeRequest<T> extends void ? [] : [InvokeRequest<T>]
): Promise<InvokeResponse<T>> {
  return ipcRenderer.invoke(channel, ...(args as [InvokeRequest<T>]));
}

function on<T extends EventChannel>(
  channel: T,
  callback: (payload: EventPayload<T>) => void
): () => void {
  const handler = (_event: Electron.IpcRendererEvent, payload: EventPayload<T>) => {
    callback(payload);
  };
  ipcRenderer.on(channel, handler);

  return () => ipcRenderer.removeListener(channel, handler);
}

export interface HoloscapeAPI {
  version: string;
  getMetrics: () => Promise<ProcessMetrics>;
  getApiKey: () => Promise<string | null>;
  invoke: typeof invoke;
  on: typeof on;
  keychain: {
    setKey: (provider: string, key: string) => Promise<void>;
    getKey: (provider: string) => Promise<string | null>;
    deleteKey: (provider: string) => Promise<boolean>;
    deleteAllKeys: () => Promise<number>;
    listProviders: () => Promise<Array<{ provider: string; hasKey: boolean; createdAt?: string }>>;
    hasKey: (provider: string) => Promise<boolean>;
  };
  chat: {
    send: (message: string) => Promise<{ success: boolean; error?: string }>;
    getHistory: () => Promise<unknown[]>;
    clearHistory: () => Promise<void>;
    onToken: (callback: (token: string) => void) => () => void;
    onComplete: (callback: (fullResponse: string) => void) => () => void;
    onError: (callback: (message: string) => void) => () => void;
  };
  settings: {
    clearLogs: () => Promise<number>;
    getLogDir: () => Promise<string>;
  };
  security: {
    approve: (actionId: string, approved: boolean, remember?: boolean) => Promise<void>;
    getPending: () => Promise<
      Array<{ id: string; action: import('@shared/security-types').Action }>
    >;
    getLog: () => Promise<Array<import('@shared/security-types').SecurityAssessment>>;
    onApprovalNeeded: (
      callback: (payload: {
        action: import('@shared/security-types').Action;
        isRedSwitch: boolean;
      }) => void
    ) => () => void;
    onStatus: (callback: (payload: { pendingCount: number }) => void) => () => void;
  };
  connection: {
    list: () => Promise<import('@shared/types').ConnectionProfile[]>;
    add: (
      profile: Omit<import('@shared/types').ConnectionProfile, 'id' | 'createdAt'>
    ) => Promise<import('@shared/types').ConnectionProfile>;
    remove: (id: string) => Promise<boolean>;
    setDefault: (id: string) => Promise<boolean>;
    switchTo: (id: string) => Promise<boolean>;
    test: (id: string) => Promise<{ success: boolean; latencyMs?: number; error?: string }>;
    getActive: () => Promise<import('@shared/types').ConnectionProfile | null>;
    update: (
      id: string,
      updates: Partial<import('@shared/types').ConnectionProfile>
    ) => Promise<import('@shared/types').ConnectionProfile | null>;
  };
  orchestrator: {
    getPersonality: () => Promise<{
      name: string;
      systemPrompt: string;
      subAgents: import('@shared/agent-types').SubAgent[];
    } | null>;
    listAgents: () => Promise<import('@shared/agent-types').SubAgent[]>;
    dispatch: (
      targetAgent: import('@shared/agent-types').AgentRole,
      task: string,
      context?: Record<string, unknown>
    ) => Promise<import('@shared/agent-types').AgentDispatchResult>;
    addAgent: (agent: import('@shared/agent-types').SubAgent) => Promise<boolean>;
    removeAgent: (id: string) => Promise<boolean>;
  };
  fileAgent: {
    execute: (request: {
      operation: 'read' | 'write' | 'move' | 'delete' | 'list';
      sourcePath: string;
      destinationPath?: string;
      content?: string;
      encoding?: string;
      agentId?: string;
    }) => Promise<import('../main/services/file-agent').FileOperationResult>;
    getAllowedDirs: () => Promise<string[]>;
    addAllowedDir: (dir: string) => Promise<boolean>;
    getAuditLog: (
      limit?: number
    ) => Promise<import('../main/services/file-agent').FileAuditEntry[]>;
  };
  conversation: {
    list: () => Promise<
      Array<{
        id: string;
        title: string;
        connectionId: string;
        messageCount: number;
        createdAt: string;
        updatedAt: string;
      }>
    >;
    get: (
      id: string
    ) => Promise<import('../main/services/conversation-manager').Conversation | null>;
    create: (
      connectionId: string,
      title?: string
    ) => Promise<import('../main/services/conversation-manager').Conversation>;
    delete: (id: string) => Promise<boolean>;
    addMessage: (
      conversationId: string,
      message: import('../main/adapters/base').ChatMessage
    ) => Promise<import('../main/services/conversation-manager').ConversationMessage | null>;
    getContext: (
      conversationId: string,
      maxTokens?: number
    ) => Promise<import('../main/adapters/base').ChatMessage[]>;
    setActive: (id: string) => Promise<boolean>;
    getActive: () => Promise<import('../main/services/conversation-manager').Conversation | null>;
    rename: (id: string, title: string) => Promise<boolean>;
  };
}

const api: HoloscapeAPI = {
  version: '0.1.0-alpha',
  getMetrics: () => invoke('get-process-metrics'),
  getApiKey: () => invoke('get-api-key'),
  invoke,
  on,
  keychain: {
    setKey: (provider: string, key: string) => invoke('keychain:set', { provider, key }),
    getKey: (provider: string) => invoke('keychain:get', { provider }),
    deleteKey: (provider: string) => invoke('keychain:delete', { provider }),
    deleteAllKeys: () => invoke('keychain:delete-all'),
    listProviders: () => invoke('keychain:list'),
    hasKey: (provider: string) => invoke('keychain:has', { provider }),
  },
  chat: {
    send: (message: string) => invoke('chat:send', { message }),
    getHistory: () => invoke('chat:get-history'),
    clearHistory: () => invoke('chat:clear-history'),
    onToken: (callback: (token: string) => void) => {
      return on('chat:token', (data) => callback(data.token));
    },
    onComplete: (callback: (fullResponse: string) => void) => {
      return on('chat:complete', (data) => callback(data.fullResponse));
    },
    onError: (callback: (message: string) => void) => {
      return on('chat:error', (data) => callback(data.message));
    },
  },
  settings: {
    clearLogs: () => invoke('settings:clear-logs'),
    getLogDir: () => invoke('settings:get-log-dir'),
  },
  security: {
    approve: (actionId: string, approved: boolean, remember?: boolean) =>
      invoke('security:approve', { actionId, approved, remember }),
    getPending: () => invoke('security:get-pending'),
    getLog: () => invoke('security:get-log'),
    onApprovalNeeded: (callback) => on('security:approval-needed', callback),
    onStatus: (callback) => on('security:status', callback),
  },
  connection: {
    list: () => invoke('connection:list'),
    add: (profile) => invoke('connection:add', profile),
    remove: (id: string) => invoke('connection:remove', { id }),
    setDefault: (id: string) => invoke('connection:set-default', { id }),
    switchTo: (id: string) => invoke('connection:switch', { id }),
    test: (id: string) => invoke('connection:test', { id }),
    getActive: () => invoke('connection:get-active'),
    update: (id: string, updates) => invoke('connection:update', { id, updates }),
  },
  orchestrator: {
    getPersonality: () => invoke('orchestrator:get-personality'),
    listAgents: () => invoke('orchestrator:list-agents'),
    dispatch: (targetAgent, task, context) =>
      invoke('orchestrator:dispatch', { targetAgent, task, context }),
    addAgent: (agent) => invoke('orchestrator:add-agent', agent),
    removeAgent: (id: string) => invoke('orchestrator:remove-agent', { id }),
  },
  fileAgent: {
    execute: (request) => invoke('file-agent:execute', request),
    getAllowedDirs: () => invoke('file-agent:get-allowed-dirs'),
    addAllowedDir: (dir: string) => invoke('file-agent:add-allowed-dir', { dir }),
    getAuditLog: (limit?: number) => invoke('file-agent:get-audit-log', { limit }),
  },
  conversation: {
    list: () => invoke('conversation:list'),
    get: (id: string) => invoke('conversation:get', { id }),
    create: (connectionId: string, title?: string) =>
      invoke('conversation:create', { connectionId, title }),
    delete: (id: string) => invoke('conversation:delete', { id }),
    addMessage: (conversationId: string, message) =>
      invoke('conversation:add-message', { conversationId, message }),
    getContext: (conversationId: string, maxTokens?: number) =>
      invoke('conversation:get-context', { conversationId, maxTokens }),
    setActive: (id: string) => invoke('conversation:set-active', { id }),
    getActive: () => invoke('conversation:get-active'),
    rename: (id: string, title: string) => invoke('conversation:rename', { id, title }),
  },
};

contextBridge.exposeInMainWorld('holoscape', api);
