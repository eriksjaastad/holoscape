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
  if (window.holoscape?.on) {
    window.holoscape.on('security:status', ({ pendingCount }) => {
      if (pendingCount > 0) {
        indicator.update('yellow', `${pendingCount} pending`);
      } else {
        indicator.update('green', 'All clear');
      }
    });
  }
}
