import { randomUUID } from 'crypto';
import { BrowserWindow, ipcMain } from 'electron';
import type { Service } from './index';
import { LoggerService } from './logger';
import type {
  Action,
  ActionContext,
  ActionCategory,
  SecurityAssessment,
  SecurityPolicy,
  RiskLevel,
  ActionDefinition,
} from '@shared/security-types';
import { ACTION_CATALOG, PII_PATTERNS } from '@shared/security-types';

// Sensitive path patterns (escalate file operations)
const SENSITIVE_PATHS = [
  /^\/etc\//,
  /^\/usr\//,
  /^\/System\//,
  /^\/Library\//,
  /^~\/Library\//,
  /\.ssh/,
  /\.aws/,
  /\.gnupg/,
  /\.env/,
  /password/i,
  /secret/i,
  /credentials/i,
];

// Known safe API domains
const SAFE_DOMAINS = ['api.openai.com', 'api.anthropic.com', 'generativelanguage.googleapis.com'];

export class SecurityService implements Service {
  name = 'security';
  private logger!: LoggerService;
  private assessmentLog: SecurityAssessment[] = [];
  private pendingApprovals: Map<
    string,
    {
      action: Action;
      resolve: (approved: boolean) => void;
    }
  > = new Map();
  private policies: SecurityPolicy[] = [];

  setLogger(logger: LoggerService): void {
    this.logger = logger;
  }

  async initialize(): Promise<void> {
    this.loadDefaultPolicies();
    this.registerIpcHandlers();
    console.log('SecurityService initialized');
  }

  async shutdown(): Promise<void> {
    this.logger?.info('SecurityService shutdown', {
      totalAssessments: this.assessmentLog.length,
    });
  }

  private loadDefaultPolicies(): void {
    this.policies = [
      {
        id: 'default',
        name: 'Default Security Policy',
        enabled: true,
        rules: [
          // Auto-allow chat to configured APIs
          {
            match: { category: 'chat' },
            action: 'allow',
          },
          // Block all shell commands by default
          {
            match: { category: 'system' },
            action: 'deny',
            riskOverride: 'red',
          },
          // Prompt for file writes
          {
            match: { type: 'file:write' },
            action: 'prompt',
          },
          // Prompt for external network
          {
            match: { type: 'network:external' },
            action: 'prompt',
          },
        ],
      },
    ];
  }

  private emitSecurityStatus(): void {
    const win = BrowserWindow.getAllWindows()[0];
    if (win) {
      win.webContents.send('security:status', {
        pendingCount: this.pendingApprovals.size,
      });
    }
  }

  private registerIpcHandlers(): void {
    // Handle approval response from renderer
    ipcMain.handle('security:approve', async (_, { actionId, approved, remember }) => {
      const pending = this.pendingApprovals.get(actionId);
      if (pending) {
        pending.resolve(approved);
        this.pendingApprovals.delete(actionId);

        // Emit status update after approval is processed
        this.emitSecurityStatus();

        if (remember) {
          // Add to auto-approve list (future feature)
          this.logger?.info('Action remembered', {
            actionId,
            approved,
          });
        }
      }
    });

    // Get pending approvals
    ipcMain.handle('security:get-pending', () => {
      return Array.from(this.pendingApprovals.entries()).map(([id, { action }]) => ({
        id,
        action,
      }));
    });

    // Get assessment log
    ipcMain.handle('security:get-log', () => {
      return this.assessmentLog.slice(-100); // Last 100 assessments
    });
  }

  /**
   * Create an action from a known type
   */
  createAction(type: string, description: string, context?: ActionContext): Action {
    const definition: ActionDefinition | undefined = ACTION_CATALOG[type];

    if (!definition) {
      // Unknown action type — treat as red
      return {
        id: randomUUID(),
        type,
        category: 'system',
        description,
        riskLevel: 'red',
        requiresApproval: true,
        context,
      };
    }

    let riskLevel = definition.defaultRisk;

    // Escalate based on context
    if (definition.canEscalate && context) {
      riskLevel = this.escalateRisk(riskLevel, context);
    }

    return {
      id: randomUUID(),
      type,
      category: definition.category,
      description: description || definition.description,
      riskLevel,
      requiresApproval: riskLevel !== 'green',
      context,
    };
  }

  /**
   * Escalate risk level based on context
   */
  private escalateRisk(baseRisk: RiskLevel, context: ActionContext): RiskLevel {
    // Check for sensitive file paths
    if (context.path) {
      for (const pattern of SENSITIVE_PATHS) {
        if (pattern.test(context.path)) {
          return this.raiseRisk(baseRisk);
        }
      }
    }

    // Check for unknown URLs
    if (context.url) {
      try {
        const url = new URL(context.url);
        if (!SAFE_DOMAINS.includes(url.hostname)) {
          return this.raiseRisk(baseRisk);
        }
      } catch {
        return 'red'; // Invalid URL = red
      }
    }

    // Check for PII
    if (context.sensitiveData) {
      return this.raiseRisk(baseRisk);
    }

    return baseRisk;
  }

  private raiseRisk(current: RiskLevel): RiskLevel {
    if (current === 'green') return 'yellow';
    if (current === 'yellow') return 'red';
    return 'red';
  }

  /**
   * Assess an action and determine if it should proceed
   */
  assessRisk(action: Action): SecurityAssessment {
    // Apply policies
    const policyResult = this.applyPolicies(action);

    if (policyResult.action === 'deny') {
      const assessment: SecurityAssessment = {
        action,
        approved: false,
        reason: `Denied by policy: ${policyResult.reason}`,
        timestamp: new Date().toISOString(),
        approvedBy: 'policy',
      };
      this.logAssessment(assessment);
      return assessment;
    }

    // Auto-approve green actions
    if (action.riskLevel === 'green') {
      const assessment: SecurityAssessment = {
        action,
        approved: true,
        reason: 'Low risk action, auto-approved',
        timestamp: new Date().toISOString(),
        approvedBy: 'auto',
      };
      this.logAssessment(assessment);
      return assessment;
    }

    // Yellow and red require approval
    const assessment: SecurityAssessment = {
      action,
      approved: false,
      reason:
        action.riskLevel === 'yellow'
          ? 'Medium risk action, requires user confirmation'
          : 'High risk action, requires explicit authorization',
      timestamp: new Date().toISOString(),
    };
    this.logAssessment(assessment);
    return assessment;
  }

  private applyPolicies(action: Action): {
    action: 'allow' | 'deny' | 'prompt';
    reason: string;
    riskOverride?: RiskLevel;
  } {
    for (const policy of this.policies) {
      if (!policy.enabled) continue;

      for (const rule of policy.rules) {
        if (this.ruleMatches(rule.match, action)) {
          // Apply risk override if specified
          if (rule.riskOverride) {
            action.riskLevel = rule.riskOverride;
          }

          if (rule.action === 'deny') {
            return { action: 'deny', reason: policy.name, riskOverride: rule.riskOverride };
          }
          if (rule.action === 'allow' && action.riskLevel === 'green') {
            return { action: 'allow', reason: policy.name, riskOverride: rule.riskOverride };
          }
        }
      }
    }

    return { action: 'prompt', reason: 'default' };
  }

  private ruleMatches(
    match: { category?: ActionCategory; type?: string },
    action: Action
  ): boolean {
    if (match.category && action.category !== match.category) {
      return false;
    }
    if (match.type && action.type !== match.type) {
      return false;
    }
    return true;
  }

  /**
   * Request user approval for an action
   * Shows the Red Switch UI for red actions
   */
  async requestApproval(action: Action): Promise<boolean> {
    const win = BrowserWindow.getAllWindows()[0];
    if (!win) {
      this.logger?.error('No window for approval request');
      return false;
    }

    return new Promise((resolve) => {
      this.pendingApprovals.set(action.id, { action, resolve });

      // Emit status update
      this.emitSecurityStatus();

      // Send to renderer to show approval UI
      win.webContents.send('security:approval-needed', {
        action,
        isRedSwitch: action.riskLevel === 'red',
      });

      // Timeout after 60 seconds
      setTimeout(() => {
        if (this.pendingApprovals.has(action.id)) {
          this.pendingApprovals.delete(action.id);
          this.emitSecurityStatus();
          this.logger?.warn('Approval request timed out', { actionId: action.id });
          resolve(false);
        }
      }, 60000);
    });
  }

  /**
   * Execute an action through the security layer
   * This is the main entry point for all protected operations
   */
  async executeSecured<T>(
    actionType: string,
    description: string,
    context: ActionContext | undefined,
    executor: () => Promise<T>
  ): Promise<{ success: boolean; result?: T; error?: string }> {
    const action = this.createAction(actionType, description, context);
    const assessment = this.assessRisk(action);

    // If auto-approved, execute
    if (assessment.approved) {
      try {
        const result = await executor();
        return { success: true, result };
      } catch (error) {
        return {
          success: false,
          error: error instanceof Error ? error.message : 'Unknown error',
        };
      }
    }

    // Request user approval
    const approved = await this.requestApproval(action);

    if (!approved) {
      return {
        success: false,
        error: `Action denied: ${assessment.reason}`,
      };
    }

    // User approved, execute
    try {
      const result = await executor();

      // Update assessment
      const updatedAssessment: SecurityAssessment = {
        ...assessment,
        approved: true,
        approvedBy: 'user',
      };
      this.logAssessment(updatedAssessment);

      return { success: true, result };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error',
      };
    }
  }

  private logAssessment(assessment: SecurityAssessment): void {
    this.assessmentLog.push(assessment);

    // Keep only last 1000 assessments in memory
    if (this.assessmentLog.length > 1000) {
      this.assessmentLog = this.assessmentLog.slice(-1000);
    }

    this.logger?.info('Security assessment', {
      actionType: assessment.action.type,
      riskLevel: assessment.action.riskLevel,
      approved: assessment.approved,
      approvedBy: assessment.approvedBy,
    });
  }

  /**
   * Check text for PII
   */
  containsPII(text: string): boolean {
    for (const pattern of PII_PATTERNS) {
      if (pattern.test(text)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Redact PII from text
   */
  redactPII(text: string): string {
    let result = text;
    for (const pattern of PII_PATTERNS) {
      result = result.replace(pattern, '[PII REDACTED]');
    }
    return result;
  }

  getAssessmentLog(): SecurityAssessment[] {
    return [...this.assessmentLog];
  }
}
