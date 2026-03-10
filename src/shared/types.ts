import type {
  InvokeChannel,
  InvokeRequest,
  InvokeResponse,
  EventChannel,
  EventPayload,
  ProcessMetrics,
  VisualizerState,
} from './ipc-types';

export * from './ipc-types';
export * from './errors';
export * from './security-types';

// Re-export adapter types to avoid renderer importing from main/
export type {
  ConnectionProfile,
  ProviderType,
  AdapterConfig,
  AdapterCapabilities,
} from '../main/adapters/base';

declare global {
  interface Window {
    holoscape: {
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
      keychain: {
        setKey: (provider: string, key: string) => Promise<void>;
        getKey: (provider: string) => Promise<string | null>;
        deleteKey: (provider: string) => Promise<boolean>;
        deleteAllKeys: () => Promise<number>;
        listProviders: () => Promise<
          Array<{ provider: string; hasKey: boolean; createdAt?: string }>
        >;
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
        getPending: () => Promise<Array<{ id: string; action: import('./security-types').Action }>>;
        getLog: () => Promise<Array<import('./security-types').SecurityAssessment>>;
        onApprovalNeeded: (
          callback: (payload: {
            action: import('./security-types').Action;
            isRedSwitch: boolean;
          }) => void
        ) => () => void;
        onStatus: (callback: (payload: { pendingCount: number }) => void) => () => void;
      };
      connection: {
        list: () => Promise<import('../main/adapters/base').ConnectionProfile[]>;
        add: (
          profile: Omit<import('../main/adapters/base').ConnectionProfile, 'id' | 'createdAt'>
        ) => Promise<import('../main/adapters/base').ConnectionProfile>;
        remove: (id: string) => Promise<boolean>;
        setDefault: (id: string) => Promise<boolean>;
        switchTo: (id: string) => Promise<boolean>;
        test: (id: string) => Promise<{ success: boolean; latencyMs?: number; error?: string }>;
        getActive: () => Promise<import('../main/adapters/base').ConnectionProfile | null>;
        update: (
          id: string,
          updates: Partial<import('../main/adapters/base').ConnectionProfile>
        ) => Promise<import('../main/adapters/base').ConnectionProfile | null>;
      };
      orchestrator: {
        getPersonality: () => Promise<{
          name: string;
          systemPrompt: string;
          subAgents: import('./agent-types').SubAgent[];
        } | null>;
        listAgents: () => Promise<import('./agent-types').SubAgent[]>;
        dispatch: (
          targetAgent: import('./agent-types').AgentRole,
          task: string,
          context?: Record<string, unknown>
        ) => Promise<import('./agent-types').AgentDispatchResult>;
        addAgent: (agent: import('./agent-types').SubAgent) => Promise<boolean>;
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
        getActive: () => Promise<
          import('../main/services/conversation-manager').Conversation | null
        >;
        rename: (id: string, title: string) => Promise<boolean>;
      };
    };
    setVisualizerState?: (state: VisualizerState) => void;
  }
}
