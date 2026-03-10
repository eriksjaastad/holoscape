export type RiskLevel = 'green' | 'yellow' | 'red';

export type ActionCategory =
  | 'chat' // AI conversations
  | 'file' // Filesystem operations
  | 'network' // External requests
  | 'system' // OS-level commands
  | 'data' // User data access
  | 'config'; // Settings/configuration

export interface ActionDefinition {
  type: string;
  category: ActionCategory;
  defaultRisk: RiskLevel;
  description: string;
  canEscalate: boolean; // Can context make this more risky?
}

export interface Action {
  id: string;
  type: string;
  category: ActionCategory;
  description: string;
  riskLevel: RiskLevel;
  requiresApproval: boolean;
  context?: ActionContext;
}

export interface ActionContext {
  connectionId?: string; // Which AI connection
  path?: string; // File path if file operation
  url?: string; // URL if network operation
  command?: string; // Shell command if system operation
  sensitiveData?: boolean; // Contains PII or secrets
  userInitiated?: boolean; // Explicitly requested by user
}

export interface SecurityAssessment {
  action: Action;
  approved: boolean;
  reason: string;
  timestamp: string;
  approvedBy?: 'auto' | 'user' | 'policy';
  escalated?: boolean;
}

export interface SecurityPolicy {
  id: string;
  name: string;
  enabled: boolean;
  rules: PolicyRule[];
}

export interface PolicyRule {
  match: {
    category?: ActionCategory;
    type?: string;
    contextMatch?: Partial<ActionContext>;
  };
  action: 'allow' | 'deny' | 'escalate' | 'prompt';
  riskOverride?: RiskLevel;
}

// Action catalog — defines all known action types
export const ACTION_CATALOG: Record<string, ActionDefinition> = {
  // Chat actions (generally green)
  'chat:send': {
    type: 'chat:send',
    category: 'chat',
    defaultRisk: 'green',
    description: 'Send message to AI',
    canEscalate: false,
  },
  'chat:clear': {
    type: 'chat:clear',
    category: 'data',
    defaultRisk: 'yellow',
    description: 'Clear chat history',
    canEscalate: false,
  },

  // File actions
  'file:read': {
    type: 'file:read',
    category: 'file',
    defaultRisk: 'green',
    description: 'Read file contents',
    canEscalate: true, // Sensitive paths escalate to yellow
  },
  'file:write': {
    type: 'file:write',
    category: 'file',
    defaultRisk: 'yellow',
    description: 'Write to file',
    canEscalate: true, // System paths escalate to red
  },
  'file:delete': {
    type: 'file:delete',
    category: 'file',
    defaultRisk: 'red',
    description: 'Delete file',
    canEscalate: false,
  },
  'file:list': {
    type: 'file:list',
    category: 'file',
    defaultRisk: 'green',
    description: 'List directory contents',
    canEscalate: false,
  },

  // Network actions
  'network:api-call': {
    type: 'network:api-call',
    category: 'network',
    defaultRisk: 'green',
    description: 'Call configured AI API',
    canEscalate: false,
  },
  'network:external': {
    type: 'network:external',
    category: 'network',
    defaultRisk: 'yellow',
    description: 'External network request',
    canEscalate: true, // Unknown URLs escalate to red
  },

  // System actions (always high risk)
  'system:command': {
    type: 'system:command',
    category: 'system',
    defaultRisk: 'red',
    description: 'Execute shell command',
    canEscalate: false,
  },
  'system:process': {
    type: 'system:process',
    category: 'system',
    defaultRisk: 'red',
    description: 'Launch external process',
    canEscalate: false,
  },

  // Data actions
  'data:export': {
    type: 'data:export',
    category: 'data',
    defaultRisk: 'yellow',
    description: 'Export user data',
    canEscalate: true,
  },
  'data:wipe': {
    type: 'data:wipe',
    category: 'data',
    defaultRisk: 'red',
    description: 'Delete all user data',
    canEscalate: false,
  },

  // Config actions
  'config:key-add': {
    type: 'config:key-add',
    category: 'config',
    defaultRisk: 'green',
    description: 'Add API key',
    canEscalate: false,
  },
  'config:key-delete': {
    type: 'config:key-delete',
    category: 'config',
    defaultRisk: 'yellow',
    description: 'Delete API key',
    canEscalate: false,
  },
  'config:key-wipe': {
    type: 'config:key-wipe',
    category: 'config',
    defaultRisk: 'red',
    description: 'Delete all API keys',
    canEscalate: false,
  },
};

// PII patterns to detect
export const PII_PATTERNS = [
  /\b\d{3}-\d{2}-\d{4}\b/g, // SSN
  /\b\d{16}\b/g, // Credit card (basic)
  /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g, // Email
  /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/g, // Phone
  /\b\d{5}(-\d{4})?\b/g, // ZIP
];

export type ActionType = keyof typeof ACTION_CATALOG;

// Legacy exports for backward compatibility
export const ACTION_TYPES = {
  CHAT_SEND: 'chat:send',
  FILE_READ: 'file:read',
  FILE_WRITE: 'file:write',
  NETWORK_REQUEST: 'network:external',
  SYSTEM_COMMAND: 'system:command',
} as const;
