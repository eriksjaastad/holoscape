import { randomUUID } from 'crypto';
import type { Service } from './index';
import { createLogger } from './logger';
import type { Action, SecurityAssessment, RiskLevel } from '@shared/security-types';

const log = createLogger('Security');

export class SecurityService implements Service {
  name = 'security';
  private assessmentLog: SecurityAssessment[] = [];

  private shouldAutoApprove(action: Action): boolean {
    return action.riskLevel === 'green';
  }

  private getAssessmentReason(action: Action): string {
    switch (action.riskLevel) {
      case 'green':
        return 'Low risk action, auto-approved';
      case 'yellow':
        return 'Medium risk action, requires review';
      case 'red':
        return 'High risk action, requires explicit approval';
    }
  }

  assessRisk(action: Action): SecurityAssessment {
    const assessment: SecurityAssessment = {
      action,
      approved: this.shouldAutoApprove(action),
      reason: this.getAssessmentReason(action),
      timestamp: new Date().toISOString(),
    };

    this.assessmentLog.push(assessment);
    log.info('Security assessment', {
      actionType: action.type,
      riskLevel: action.riskLevel,
      approved: assessment.approved,
      reason: assessment.reason,
    });
    return assessment;
  }

  async requestApproval(action: Action): Promise<boolean> {
    log.warn('Approval requested (auto-approving for now)', {
      actionType: action.type,
      riskLevel: action.riskLevel,
    });
    return true;
  }

  createAction(type: string, description: string, riskLevel: RiskLevel): Action {
    return {
      id: randomUUID(),
      type,
      description,
      riskLevel,
      requiresApproval: riskLevel !== 'green',
    };
  }

  getAssessmentLog(): SecurityAssessment[] {
    return [...this.assessmentLog];
  }

  async initialize(): Promise<void> {
    log.info('Security service initialized');
  }

  async shutdown(): Promise<void> {
    log.info('Security service shutdown', { total: this.assessmentLog.length });
  }
}
