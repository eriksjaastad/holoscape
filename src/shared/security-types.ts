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

export const ACTION_TYPES = {
  CHAT_SEND: 'chat:send',
  FILE_READ: 'file:read',
  FILE_WRITE: 'file:write',
  NETWORK_REQUEST: 'network:request',
  SYSTEM_COMMAND: 'system:command',
} as const;

export type ActionType = (typeof ACTION_TYPES)[keyof typeof ACTION_TYPES];
