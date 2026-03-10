import { describe, it, expect, beforeEach, vi } from 'vitest';
import { SecurityService } from './security';
import type { LoggerService } from './logger';

// Mock Electron
vi.mock('electron', () => ({
  BrowserWindow: {
    getAllWindows: vi.fn(() => [
      {
        webContents: {
          send: vi.fn(),
        },
      },
    ]),
  },
  ipcMain: {
    handle: vi.fn(),
  },
}));

describe('SecurityService', () => {
  let securityService: SecurityService;
  let mockLogger: LoggerService;

  beforeEach(() => {
    securityService = new SecurityService();
    mockLogger = {
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
      debug: vi.fn(),
    } as unknown as LoggerService;
    securityService.setLogger(mockLogger);
    securityService.initialize();
  });

  describe('createAction', () => {
    it('should create a green action for known safe types', () => {
      const action = securityService.createAction('chat:send', 'Send chat message');

      expect(action).toMatchObject({
        type: 'chat:send',
        category: 'chat',
        riskLevel: 'green',
        requiresApproval: false,
      });
    });

    it('should create a yellow action for file writes', () => {
      const action = securityService.createAction('file:write', 'Write file');

      expect(action).toMatchObject({
        type: 'file:write',
        category: 'file',
        riskLevel: 'yellow',
        requiresApproval: true,
      });
    });

    it('should create a red action for system commands', () => {
      const action = securityService.createAction('system:command', 'Execute command');

      expect(action).toMatchObject({
        type: 'system:command',
        category: 'system',
        riskLevel: 'red',
        requiresApproval: true,
      });
    });

    it('should treat unknown action types as red', () => {
      const action = securityService.createAction('unknown:action', 'Unknown action');

      expect(action).toMatchObject({
        type: 'unknown:action',
        category: 'system',
        riskLevel: 'red',
        requiresApproval: true,
      });
    });
  });

  describe('Risk Escalation', () => {
    it('should escalate file read for sensitive paths', () => {
      const action = securityService.createAction('file:read', 'Read sensitive file', {
        path: '/etc/passwd',
      });

      expect(action.riskLevel).toBe('yellow');
    });

    it('should escalate file write for system paths', () => {
      const action = securityService.createAction('file:write', 'Write to system', {
        path: '/usr/local/test',
      });

      expect(action.riskLevel).toBe('red');
    });

    it('should not escalate for normal paths', () => {
      const action = securityService.createAction('file:read', 'Read user file', {
        path: '/home/user/documents/test.txt',
      });

      expect(action.riskLevel).toBe('green');
    });

    it('should escalate for unknown URLs', () => {
      const action = securityService.createAction('network:external', 'External request', {
        url: 'https://unknown-domain.com',
      });

      // network:external defaults to yellow, escalates to red for unknown domains
      expect(action.riskLevel).toBe('red');
    });

    it('should not escalate for safe API domains', () => {
      const action = securityService.createAction('network:api-call', 'API call', {
        url: 'https://api.openai.com/v1/chat',
      });

      expect(action.riskLevel).toBe('green');
    });

    it('should escalate for sensitive data flag', () => {
      const action = securityService.createAction('data:export', 'Export data', {
        sensitiveData: true,
      });

      expect(action.riskLevel).toBe('red');
    });
  });

  describe('assessRisk', () => {
    it('should auto-approve green actions', () => {
      const action = securityService.createAction('chat:send', 'Send message');
      const assessment = securityService.assessRisk(action);

      expect(assessment).toMatchObject({
        approved: true,
        approvedBy: 'auto',
        reason: 'Low risk action, auto-approved',
      });
    });

    it('should require approval for yellow actions', () => {
      const action = securityService.createAction('file:write', 'Write file');
      const assessment = securityService.assessRisk(action);

      expect(assessment).toMatchObject({
        approved: false,
        reason: 'Medium risk action, requires user confirmation',
      });
    });

    it('should require approval for red actions', () => {
      const action = securityService.createAction('system:command', 'Run command');
      const assessment = securityService.assessRisk(action);

      // System commands are denied by policy (not just requiring approval)
      expect(assessment).toMatchObject({
        approved: false,
        approvedBy: 'policy',
      });
      expect(assessment.reason).toContain('Denied by policy');
    });

    it('should deny system actions by policy', () => {
      const action = securityService.createAction('system:command', 'Run command');
      const assessment = securityService.assessRisk(action);

      expect(assessment).toMatchObject({
        approved: false,
        approvedBy: 'policy',
      });
      expect(assessment.reason).toContain('Denied by policy');
    });
  });

  describe('Policy System', () => {
    it('should apply riskOverride from policy rules', () => {
      // System actions have riskOverride: 'red' in default policy
      const action = securityService.createAction('system:command', 'Command');

      // Risk should be overridden to red
      expect(action.riskLevel).toBe('red');
    });

    it('should auto-allow chat actions by policy', () => {
      const action = securityService.createAction('chat:send', 'Send message');
      const assessment = securityService.assessRisk(action);

      expect(assessment.approved).toBe(true);
      expect(assessment.approvedBy).toBe('auto');
    });
  });

  describe('PII Detection', () => {
    it('should detect SSN patterns', () => {
      const hasPII = securityService.containsPII('My SSN is 123-45-6789');
      expect(hasPII).toBe(true);
    });

    it('should detect credit card patterns', () => {
      const hasPII = securityService.containsPII('Card: 1234567812345678');
      expect(hasPII).toBe(true);
    });

    it('should detect email patterns', () => {
      const hasPII = securityService.containsPII('Contact: user@example.com');
      expect(hasPII).toBe(true);
    });

    it('should detect phone patterns', () => {
      const hasPII = securityService.containsPII('Call 555-123-4567');
      expect(hasPII).toBe(true);
    });

    it('should not flag normal text', () => {
      const hasPII = securityService.containsPII('This is normal text');
      expect(hasPII).toBe(false);
    });

    it('should redact PII', () => {
      const text = 'My SSN is 123-45-6789 and email is user@example.com';
      const redacted = securityService.redactPII(text);

      expect(redacted).not.toContain('123-45-6789');
      expect(redacted).not.toContain('user@example.com');
      expect(redacted).toContain('[PII REDACTED]');
    });
  });

  describe('Assessment Log', () => {
    it('should track assessments', () => {
      const action1 = securityService.createAction('chat:send', 'Message 1');
      const action2 = securityService.createAction('file:write', 'Write file');

      securityService.assessRisk(action1);
      securityService.assessRisk(action2);

      const log = securityService.getAssessmentLog();
      expect(log.length).toBe(2);
    });

    it('should limit log size to 1000 entries', () => {
      // Create 1100 assessments
      for (let i = 0; i < 1100; i++) {
        const action = securityService.createAction('chat:send', `Message ${i}`);
        securityService.assessRisk(action);
      }

      const log = securityService.getAssessmentLog();
      expect(log.length).toBe(1000);
    });
  });

  describe('executeSecured', () => {
    it('should execute green actions immediately', async () => {
      const executor = vi.fn(async () => 'result');

      const result = await securityService.executeSecured(
        'chat:send',
        'Send message',
        undefined,
        executor
      );

      expect(result.success).toBe(true);
      expect(executor).toHaveBeenCalled();
    });

    it('should handle executor errors', async () => {
      const executor = vi.fn(async () => {
        throw new Error('Execution failed');
      });

      const result = await securityService.executeSecured(
        'chat:send',
        'Send message',
        undefined,
        executor
      );

      expect(result.success).toBe(false);
      expect(result.error).toBe('Execution failed');
    });
  });
});
