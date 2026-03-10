# Sonnet: Hologram Phase 3 — Weeks 7-8: Complete Security Layer + Permission System

## Your Mission
Transform the stub SecurityService into a complete risk assessment engine with visual permission indicators and a "Red Switch" authorization UI for high-risk actions.

## Context

### What exists (from Phase 2):
- `SecurityService` with basic `assessRisk()` and `requestApproval()` (currently auto-approves everything)
- `RiskLevel` type: 'green' | 'yellow' | 'red'
- `Action` interface with type, description, riskLevel
- Keychain storage, encrypted chat history, sanitized logging

### What you're building:
- **Risk Assessment Engine** — Classify actions by risk, apply policies
- **Permission Scope UI** — Visual Green/Yellow/Red indicators
- **Red Switch Authorization** — Sonique-style drawer for high-risk approvals
- **Router Integration** — All actions pass through security layer
- **PII Detection** — Block sensitive data from logs/errors

---

## Project Location

All work in: `..`

---

## Step 1: Expand Security Types

Update `src/shared/security-types.ts`:

```typescript
export type RiskLevel = 'green' | 'yellow' | 'red';

export type ActionCategory = 
  | 'chat'      // AI conversations
  | 'file'      // Filesystem operations
  | 'network'   // External requests
  | 'system'    // OS-level commands
  | 'data'      // User data access
  | 'config';   // Settings/configuration

export interface ActionDefinition {
  type: string;
  category: ActionCategory;
  defaultRisk: RiskLevel;
  description: string;
  canEscalate: boolean;  // Can context make this more risky?
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
  connectionId?: string;      // Which AI connection
  path?: string;              // File path if file operation
  url?: string;               // URL if network operation
  command?: string;           // Shell command if system operation
  sensitiveData?: boolean;    // Contains PII or secrets
  userInitiated?: boolean;    // Explicitly requested by user
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
  /\b\d{3}-\d{2}-\d{4}\b/g,                    // SSN
  /\b\d{16}\b/g,                                // Credit card (basic)
  /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g, // Email
  /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/g,            // Phone
  /\b\d{5}(-\d{4})?\b/g,                       // ZIP
];

export type ActionType = keyof typeof ACTION_CATALOG;
```

---

## Step 2: Enhanced Security Service

Replace `src/main/services/security.ts`:

```typescript
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
  ACTION_CATALOG,
  PII_PATTERNS,
} from '@shared/security-types';

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
const SAFE_DOMAINS = [
  'api.openai.com',
  'api.anthropic.com',
  'generativelanguage.googleapis.com',
];

export class SecurityService implements Service {
  name = 'security';
  private logger!: LoggerService;
  private assessmentLog: SecurityAssessment[] = [];
  private pendingApprovals: Map<string, {
    action: Action;
    resolve: (approved: boolean) => void;
  }> = new Map();
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

  private registerIpcHandlers(): void {
    // Handle approval response from renderer
    ipcMain.handle('security:approve', async (_, { actionId, approved, remember }) => {
      const pending = this.pendingApprovals.get(actionId);
      if (pending) {
        pending.resolve(approved);
        this.pendingApprovals.delete(actionId);
        
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
  createAction(
    type: string,
    description: string,
    context?: ActionContext
  ): Action {
    const definition = ACTION_CATALOG[type];
    
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
      reason: action.riskLevel === 'yellow'
        ? 'Medium risk action, requires user confirmation'
        : 'High risk action, requires explicit authorization',
      timestamp: new Date().toISOString(),
    };
    this.logAssessment(assessment);
    return assessment;
  }

  private applyPolicies(action: Action): { action: 'allow' | 'deny' | 'prompt'; reason: string } {
    for (const policy of this.policies) {
      if (!policy.enabled) continue;

      for (const rule of policy.rules) {
        if (this.ruleMatches(rule.match, action)) {
          if (rule.action === 'deny') {
            return { action: 'deny', reason: policy.name };
          }
          if (rule.action === 'allow' && action.riskLevel === 'green') {
            return { action: 'allow', reason: policy.name };
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

      // Send to renderer to show approval UI
      win.webContents.send('security:approval-needed', {
        action,
        isRedSwitch: action.riskLevel === 'red',
      });

      // Timeout after 60 seconds
      setTimeout(() => {
        if (this.pendingApprovals.has(action.id)) {
          this.pendingApprovals.delete(action.id);
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
```

---

## Step 3: Update IPC Types

Add to `src/shared/ipc-types.ts`:

```typescript
// Add to IPCInvokeChannels
'security:approve': {
  request: { actionId: string; approved: boolean; remember?: boolean };
  response: void;
};
'security:get-pending': {
  request: void;
  response: Array<{ id: string; action: Action }>;
};
'security:get-log': {
  request: void;
  response: SecurityAssessment[];
};

// Add to IPCEventChannels
'security:approval-needed': {
  action: Action;
  isRedSwitch: boolean;
};
'security:status': {
  pendingCount: number;
};
```

---

## Step 4: Permission Indicator Component

Create `src/renderer/security-indicator.ts`:

```typescript
import type { RiskLevel } from '@shared/security-types';

const RISK_COLORS: Record<RiskLevel, { bg: string; border: string; text: string }> = {
  green: {
    bg: 'rgba(77, 253, 209, 0.2)',
    border: '#4dfdd1',
    text: '#4dfdd1',
  },
  yellow: {
    bg: 'rgba(255, 204, 102, 0.2)',
    border: '#ffcc66',
    text: '#ffcc66',
  },
  red: {
    bg: 'rgba(255, 102, 102, 0.2)',
    border: '#ff6666',
    text: '#ff6666',
  },
};

const RISK_LABELS: Record<RiskLevel, string> = {
  green: 'Safe',
  yellow: 'Review',
  red: 'Danger',
};

const RISK_ICONS: Record<RiskLevel, string> = {
  green: '✓',
  yellow: '⚠',
  red: '✗',
};

export function createSecurityIndicator(container: HTMLElement): {
  update: (level: RiskLevel, message?: string) => void;
  hide: () => void;
} {
  const indicator = document.createElement('div');
  indicator.className = 'security-indicator hidden';
  indicator.innerHTML = `
    <span class="security-icon"></span>
    <span class="security-label"></span>
    <span class="security-message"></span>
  `;
  container.appendChild(indicator);

  return {
    update(level: RiskLevel, message?: string) {
      const colors = RISK_COLORS[level];
      indicator.style.backgroundColor = colors.bg;
      indicator.style.borderColor = colors.border;
      indicator.style.color = colors.text;

      indicator.querySelector('.security-icon')!.textContent = RISK_ICONS[level];
      indicator.querySelector('.security-label')!.textContent = RISK_LABELS[level];
      indicator.querySelector('.security-message')!.textContent = message || '';

      indicator.classList.remove('hidden');
      indicator.dataset.risk = level;
    },
    hide() {
      indicator.classList.add('hidden');
    },
  };
}

export function initSecurityIndicator(): void {
  const container = document.getElementById('security-indicator-container');
  if (!container) return;

  const indicator = createSecurityIndicator(container);

  // Show current security status
  if (window.hologram?.on) {
    window.hologram.on('security:status', ({ pendingCount }) => {
      if (pendingCount > 0) {
        indicator.update('yellow', `${pendingCount} pending`);
      } else {
        indicator.update('green', 'All clear');
      }
    });
  }
}
```

---

## Step 5: Red Switch Authorization UI

Create `src/renderer/red-switch.ts`:

```typescript
import type { Action } from '@shared/security-types';

let currentAction: Action | null = null;
let isOpen = false;

export function initRedSwitch(): void {
  createRedSwitchOverlay();
  
  if (window.hologram?.on) {
    window.hologram.on('security:approval-needed', ({ action, isRedSwitch }) => {
      showApprovalRequest(action, isRedSwitch);
    });
  }
}

function createRedSwitchOverlay(): void {
  const overlay = document.createElement('div');
  overlay.id = 'red-switch-overlay';
  overlay.className = 'red-switch-overlay hidden';
  overlay.innerHTML = `
    <div class="red-switch-drawer">
      <div class="red-switch-header">
        <span class="red-switch-icon">⚠</span>
        <h2 class="red-switch-title">Authorization Required</h2>
      </div>
      
      <div class="red-switch-content">
        <div class="red-switch-action">
          <span class="action-type"></span>
          <p class="action-description"></p>
        </div>
        
        <div class="red-switch-details">
          <div class="detail-row">
            <span class="detail-label">Risk Level:</span>
            <span class="detail-value risk-level"></span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Reason:</span>
            <span class="detail-value reason"></span>
          </div>
          <div class="detail-row context-row hidden">
            <span class="detail-label">Context:</span>
            <span class="detail-value context"></span>
          </div>
        </div>
        
        <div class="red-switch-warning">
          <p>This action requires your explicit authorization.</p>
          <p class="red-warning">High-risk actions may affect your system or data.</p>
        </div>
      </div>
      
      <div class="red-switch-actions">
        <label class="remember-checkbox">
          <input type="checkbox" id="remember-choice">
          <span>Remember this choice</span>
        </label>
        <div class="button-group">
          <button class="btn-deny" id="red-switch-deny">Deny</button>
          <button class="btn-approve" id="red-switch-approve">Authorize</button>
        </div>
      </div>
    </div>
  `;
  
  document.body.appendChild(overlay);
  
  // Event listeners
  document.getElementById('red-switch-deny')?.addEventListener('click', () => {
    handleResponse(false);
  });
  
  document.getElementById('red-switch-approve')?.addEventListener('click', () => {
    handleResponse(true);
  });
  
  // Close on escape
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && isOpen) {
      handleResponse(false);
    }
  });
}

function showApprovalRequest(action: Action, isRedSwitch: boolean): void {
  currentAction = action;
  isOpen = true;
  
  const overlay = document.getElementById('red-switch-overlay');
  if (!overlay) return;
  
  // Update content
  overlay.querySelector('.action-type')!.textContent = action.type;
  overlay.querySelector('.action-description')!.textContent = action.description;
  overlay.querySelector('.risk-level')!.textContent = action.riskLevel.toUpperCase();
  overlay.querySelector('.risk-level')!.className = `detail-value risk-level risk-${action.riskLevel}`;
  
  // Context details
  const contextRow = overlay.querySelector('.context-row') as HTMLElement;
  if (action.context) {
    const contextStr = formatContext(action.context);
    if (contextStr) {
      overlay.querySelector('.context')!.textContent = contextStr;
      contextRow.classList.remove('hidden');
    } else {
      contextRow.classList.add('hidden');
    }
  } else {
    contextRow.classList.add('hidden');
  }
  
  // Style based on risk level
  overlay.dataset.risk = action.riskLevel;
  
  // Show red warning only for red actions
  const redWarning = overlay.querySelector('.red-warning') as HTMLElement;
  redWarning.style.display = action.riskLevel === 'red' ? 'block' : 'none';
  
  // Show overlay with animation
  overlay.classList.remove('hidden');
  setTimeout(() => {
    overlay.classList.add('open');
  }, 10);
}

function formatContext(context: Action['context']): string {
  if (!context) return '';
  
  const parts: string[] = [];
  if (context.path) parts.push(`Path: ${context.path}`);
  if (context.url) parts.push(`URL: ${context.url}`);
  if (context.command) parts.push(`Command: ${context.command}`);
  
  return parts.join(' | ');
}

function handleResponse(approved: boolean): void {
  if (!currentAction) return;
  
  const remember = (document.getElementById('remember-choice') as HTMLInputElement)?.checked;
  
  window.hologram?.invoke('security:approve', {
    actionId: currentAction.id,
    approved,
    remember,
  });
  
  closeOverlay();
}

function closeOverlay(): void {
  const overlay = document.getElementById('red-switch-overlay');
  if (!overlay) return;
  
  overlay.classList.remove('open');
  setTimeout(() => {
    overlay.classList.add('hidden');
  }, 300);
  
  currentAction = null;
  isOpen = false;
}
```

---

## Step 6: Add Styles

Add to `src/renderer/styles.css`:

```css
/* Security Indicator */
.security-indicator {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 12px;
  border-radius: 20px;
  border: 1px solid;
  font-size: 0.8rem;
  transition: all 0.3s ease;
}

.security-indicator.hidden {
  display: none;
}

.security-icon {
  font-size: 1rem;
}

.security-label {
  font-weight: 600;
}

.security-message {
  opacity: 0.8;
}

/* Red Switch Overlay */
.red-switch-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  align-items: flex-end;
  justify-content: center;
  z-index: 10000;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.3s ease;
}

.red-switch-overlay.hidden {
  display: none;
}

.red-switch-overlay.open {
  opacity: 1;
  pointer-events: auto;
}

.red-switch-overlay.open .red-switch-drawer {
  transform: translateY(0);
}

.red-switch-drawer {
  width: 100%;
  max-width: 500px;
  background: linear-gradient(180deg, #1a1a2e 0%, #0d0d1a 100%);
  border: 1px solid rgba(255, 102, 102, 0.3);
  border-bottom: none;
  border-radius: 16px 16px 0 0;
  padding: 24px;
  transform: translateY(100%);
  transition: transform 0.3s ease;
}

.red-switch-overlay[data-risk="yellow"] .red-switch-drawer {
  border-color: rgba(255, 204, 102, 0.3);
}

.red-switch-overlay[data-risk="green"] .red-switch-drawer {
  border-color: rgba(77, 253, 209, 0.3);
}

.red-switch-header {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 20px;
}

.red-switch-icon {
  font-size: 2rem;
  color: #ff6666;
}

.red-switch-overlay[data-risk="yellow"] .red-switch-icon {
  color: #ffcc66;
}

.red-switch-title {
  margin: 0;
  font-size: 1.25rem;
  color: #fff;
}

.red-switch-action {
  background: rgba(0, 0, 0, 0.3);
  padding: 16px;
  border-radius: 8px;
  margin-bottom: 16px;
}

.action-type {
  font-family: monospace;
  font-size: 0.9rem;
  color: #7efbff;
  display: block;
  margin-bottom: 4px;
}

.action-description {
  margin: 0;
  color: #fff;
}

.red-switch-details {
  margin-bottom: 16px;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  padding: 8px 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.detail-label {
  color: rgba(255, 255, 255, 0.6);
}

.detail-value {
  color: #fff;
}

.risk-level.risk-green { color: #4dfdd1; }
.risk-level.risk-yellow { color: #ffcc66; }
.risk-level.risk-red { color: #ff6666; }

.red-switch-warning {
  background: rgba(255, 102, 102, 0.1);
  border: 1px solid rgba(255, 102, 102, 0.2);
  border-radius: 8px;
  padding: 12px;
  margin-bottom: 20px;
}

.red-switch-warning p {
  margin: 0;
  font-size: 0.85rem;
  color: rgba(255, 255, 255, 0.8);
}

.red-warning {
  color: #ff6666 !important;
  font-weight: 600;
  margin-top: 8px !important;
}

.red-switch-actions {
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.remember-checkbox {
  display: flex;
  align-items: center;
  gap: 8px;
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.85rem;
  cursor: pointer;
}

.remember-checkbox input {
  accent-color: #7efbff;
}

.button-group {
  display: flex;
  gap: 12px;
}

.button-group button {
  flex: 1;
  padding: 12px 24px;
  border-radius: 8px;
  font-size: 1rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
}

.btn-deny {
  background: transparent;
  border: 1px solid rgba(255, 255, 255, 0.3);
  color: #fff;
}

.btn-deny:hover {
  background: rgba(255, 255, 255, 0.1);
}

.btn-approve {
  background: linear-gradient(135deg, #ff6666 0%, #cc4444 100%);
  border: none;
  color: #fff;
}

.btn-approve:hover {
  background: linear-gradient(135deg, #ff8888 0%, #dd5555 100%);
}

.red-switch-overlay[data-risk="yellow"] .btn-approve {
  background: linear-gradient(135deg, #ffcc66 0%, #cc9944 100%);
}

.red-switch-overlay[data-risk="green"] .btn-approve {
  background: linear-gradient(135deg, #4dfdd1 0%, #2db89b 100%);
}
```

---

## Step 7: Update Main Process

Add to `src/main/index.ts`:

```typescript
// After service registration
securityService.setLogger(loggerService);

// Example: Wrapping an action with security
// (This pattern will be used in Phase 3 Week 9-10 for file/web agents)
async function securedFileWrite(path: string, content: string): Promise<boolean> {
  const result = await securityService.executeSecured(
    'file:write',
    `Write to ${path}`,
    { path },
    async () => {
      // Actual file write would go here
      return true;
    }
  );
  return result.success;
}
```

---

## Step 8: Update Preload

Add to `src/preload/index.ts` in the HologramAPI:

```typescript
security: {
  approve: (actionId: string, approved: boolean, remember?: boolean) =>
    invoke('security:approve', { actionId, approved, remember }),
  getPending: () => invoke('security:get-pending'),
  getLog: () => invoke('security:get-log'),
},
```

---

## Step 9: Update Window Type

Add to `src/shared/types.ts` in the Window interface:

```typescript
security: {
  approve: (actionId: string, approved: boolean, remember?: boolean) => Promise<void>;
  getPending: () => Promise<Array<{ id: string; action: Action }>>;
  getLog: () => Promise<SecurityAssessment[]>;
};
```

---

## Step 10: Initialize in Renderer

Update `src/renderer/main.ts`:

```typescript
import { initRedSwitch } from './red-switch';
import { initSecurityIndicator } from './security-indicator';

// In initialization
initRedSwitch();
initSecurityIndicator();
```

---

## Step 11: Add Security Indicator Container to HTML

Add to `src/renderer/index.html`:

```html
<!-- In the header/toolbar area -->
<div id="security-indicator-container"></div>
```

---

## Testing

### Test 1: Risk Assessment
```typescript
// In dev console or test file
const securityService = /* get from registry */;

// Green action (auto-approved)
const chatAction = securityService.createAction('chat:send', 'Send message');
console.log(chatAction.riskLevel); // 'green'

// Red action (requires approval)
const deleteAction = securityService.createAction('file:delete', 'Delete file');
console.log(deleteAction.riskLevel); // 'red'

// Escalated action (yellow → red due to sensitive path)
const writeAction = securityService.createAction(
  'file:write',
  'Write config',
  { path: '~/.ssh/config' }
);
console.log(writeAction.riskLevel); // 'red' (escalated)
```

### Test 2: PII Detection
```typescript
const securityService = /* get from registry */;

console.log(securityService.containsPII('My SSN is 123-45-6789')); // true
console.log(securityService.containsPII('Hello world')); // false
console.log(securityService.redactPII('Email: test@example.com')); // 'Email: [PII REDACTED]'
```

### Test 3: Red Switch UI
1. Trigger a red action (e.g., file delete)
2. Verify Red Switch drawer appears
3. Click "Deny" — action should be blocked
4. Trigger again, click "Authorize" — action should proceed

---

## Exit Criteria

- [ ] `ActionCatalog` defines all action types with default risks
- [ ] `SecurityService.createAction()` creates properly classified actions
- [ ] Risk escalation works (sensitive paths → higher risk)
- [ ] Green actions auto-approve
- [ ] Yellow actions show confirmation UI
- [ ] Red actions show Red Switch drawer
- [ ] PII detection works (SSN, email, phone, etc.)
- [ ] Security indicator shows current status (green/yellow/red)
- [ ] `security:approve` IPC works
- [ ] `security:get-pending` returns pending approvals
- [ ] `security:get-log` returns assessment history
- [ ] TypeScript compiles with no errors
- [ ] Lint passes

---

## Files Summary

### Created:
- `src/renderer/security-indicator.ts` — Visual risk indicator
- `src/renderer/red-switch.ts` — Authorization drawer UI

### Modified:
- `src/shared/security-types.ts` — Expanded types, action catalog, PII patterns
- `src/main/services/security.ts` — Complete risk assessment engine
- `src/shared/ipc-types.ts` — Security IPC channels
- `src/preload/index.ts` — Expose security APIs
- `src/shared/types.ts` — Window type with security
- `src/renderer/main.ts` — Initialize security UI
- `src/renderer/styles.css` — Security indicator + Red Switch styles
- `src/renderer/index.html` — Security indicator container

---

## Security Verification

After implementing, verify:

1. **Green actions** → Proceed without UI
2. **Yellow actions** → Show confirmation (can proceed or deny)
3. **Red actions** → Show Red Switch drawer (must explicitly authorize)
4. **Unknown action types** → Treated as red (fail-safe)
5. **Sensitive paths** → Escalate file operations
6. **Unknown URLs** → Escalate network operations
7. **PII detected** → Escalate + redact in logs

---

Good luck! 🔒

## Related Documentation

- [Doppler Secrets Management](Documents/reference/DOPPLER_SECRETS_MANAGEMENT.md) - secrets management
- [Tiered AI Sprint Planning](patterns/tiered-ai-sprint-planning.md) - prompt engineering
- [AI Model Cost Comparison](Documents/reference/MODEL_COST_COMPARISON.md) - AI models
- [Safety Systems](patterns/safety-systems.md) - security
