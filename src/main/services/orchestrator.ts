import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { ipcMain, BrowserWindow } from 'electron';
import type { Service } from './index';
import type { LoggerService } from './logger';
import type { SecurityService } from './security';
import type { ConnectionManagerService } from './connection-manager';
import type { SubAgent, AgentRole, AgentDispatchResult } from '@shared/agent-types';
import type { ChatMessage } from '../adapters/base';

interface PersonalityConfig {
  name: string;
  systemPrompt: string;
  subAgents: SubAgent[];
}

export class OrchestratorService implements Service {
  name = 'orchestrator';
  private logger!: LoggerService;
  private security!: SecurityService;
  private connectionManager!: ConnectionManagerService;
  private personality: PersonalityConfig | null = null;
  private subAgents: Map<string, SubAgent> = new Map();

  setDependencies(
    logger: LoggerService,
    security: SecurityService,
    connectionManager: ConnectionManagerService
  ): void {
    this.logger = logger;
    this.security = security;
    this.connectionManager = connectionManager;
  }

  async initialize(): Promise<void> {
    await this.loadPersonality();
    this.registerIpcHandlers();
    this.logger?.info('OrchestratorService initialized');
  }

  async shutdown(): Promise<void> {
    this.logger?.info('OrchestratorService shutdown');
  }

  private async loadPersonality(): Promise<void> {
    const configPath = join(process.cwd(), 'config', 'personality.json');

    if (existsSync(configPath)) {
      try {
        const content = readFileSync(configPath, 'utf-8');
        this.personality = JSON.parse(content);

        // Load sub-agents
        if (this.personality?.subAgents) {
          for (const agent of this.personality.subAgents) {
            this.subAgents.set(agent.id, agent);
          }
        }

        this.logger?.info('Personality loaded', {
          name: this.personality?.name,
          subAgentCount: this.subAgents.size,
        });
      } catch (error) {
        this.logger?.error('Failed to load personality', {
          error: error instanceof Error ? error.message : 'Unknown',
        });
      }
    }
  }

  private registerIpcHandlers(): void {
    ipcMain.handle('orchestrator:get-personality', () => {
      return this.personality;
    });

    ipcMain.handle('orchestrator:list-agents', () => {
      return Array.from(this.subAgents.values());
    });

    ipcMain.handle('orchestrator:dispatch', async (_, request) => {
      return this.dispatch(request.targetAgent, request.task, request.context);
    });

    ipcMain.handle('orchestrator:add-agent', async (_, agent: SubAgent) => {
      return this.addSubAgent(agent);
    });

    ipcMain.handle('orchestrator:remove-agent', async (_, { id }: { id: string }) => {
      return this.removeSubAgent(id);
    });
  }

  /**
   * Dispatch a task to a sub-agent
   * This goes through the security layer
   */
  async dispatch(
    targetRole: AgentRole,
    task: string,
    context?: Record<string, unknown>
  ): Promise<AgentDispatchResult> {
    // Find an agent with the target role
    const agent = Array.from(this.subAgents.values()).find(
      (a) => a.role === targetRole && a.enabled
    );

    if (!agent) {
      return {
        success: false,
        agentId: '',
        error: `No enabled agent found for role: ${targetRole}`,
      };
    }

    // Get the connection for this agent
    const adapter = this.connectionManager.getAdapter(agent.connectionId);
    if (!adapter) {
      return {
        success: false,
        agentId: agent.id,
        error: `Connection not found: ${agent.connectionId}`,
      };
    }

    // Execute through security layer
    const result = await this.security.executeSecured(
      'chat:send',
      `Dispatch to ${agent.name}: ${task.slice(0, 50)}...`,
      {
        connectionId: agent.connectionId,
        userInitiated: false, // Sub-agent requests are not user-initiated
      },
      async () => {
        return new Promise<string>((resolve, reject) => {
          const messages: ChatMessage[] = [
            { role: 'system', content: agent.systemPrompt },
            { role: 'user', content: task },
          ];

          // Add context if provided
          if (context) {
            messages[1].content += `\n\nContext: ${JSON.stringify(context)}`;
          }

          adapter.streamChat(messages, {
            onToken: (token) => {
              // Notify UI of progress
              this.notifyDispatchProgress(agent.id, token);
            },
            onComplete: (response) => {
              resolve(response);
            },
            onError: (error) => {
              reject(error);
            },
          });
        });
      }
    );

    if (result.success) {
      this.logger?.info('Sub-agent dispatch complete', {
        agentId: agent.id,
        role: targetRole,
        responseLength: result.result?.length,
      });

      return {
        success: true,
        agentId: agent.id,
        response: result.result,
      };
    } else {
      this.logger?.warn('Sub-agent dispatch failed', {
        agentId: agent.id,
        error: result.error,
      });

      return {
        success: false,
        agentId: agent.id,
        error: result.error,
      };
    }
  }

  /**
   * Add a sub-agent
   */
  async addSubAgent(agent: SubAgent): Promise<boolean> {
    if (this.subAgents.has(agent.id)) {
      return false;
    }

    this.subAgents.set(agent.id, agent);
    this.logger?.info('Sub-agent added', {
      id: agent.id,
      name: agent.name,
      role: agent.role,
    });

    return true;
  }

  /**
   * Remove a sub-agent
   */
  async removeSubAgent(id: string): Promise<boolean> {
    if (!this.subAgents.has(id)) {
      return false;
    }

    this.subAgents.delete(id);
    this.logger?.info('Sub-agent removed', { id });

    return true;
  }

  /**
   * Get system prompt for orchestrator
   */
  getSystemPrompt(): string {
    return this.personality?.systemPrompt || 'You are a helpful AI assistant.';
  }

  /**
   * Get personality name
   */
  getName(): string {
    return this.personality?.name || 'Assistant';
  }

  private notifyDispatchProgress(agentId: string, token: string): void {
    const win = BrowserWindow.getAllWindows()[0];
    if (win) {
      win.webContents.send('orchestrator:dispatch-progress', {
        agentId,
        token,
      });
    }
  }
}
