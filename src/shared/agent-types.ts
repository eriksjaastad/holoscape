export type AgentRole =
  | 'orchestrator' // Main coordinator (Cortana-like)
  | 'coder' // Code generation/review
  | 'researcher' // Web search and research
  | 'writer' // Content writing
  | 'analyst'; // Data analysis

export interface SubAgent {
  id: string;
  name: string;
  role: AgentRole;
  connectionId: string; // Which AI connection to use
  systemPrompt: string;
  capabilities: string[];
  enabled: boolean;
}

export interface AgentDispatchRequest {
  targetAgent: AgentRole;
  task: string;
  context?: Record<string, unknown>;
}

export interface AgentDispatchResult {
  success: boolean;
  agentId: string;
  response?: string;
  error?: string;
}
