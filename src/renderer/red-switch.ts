import type { Action } from '@shared/security-types';

let currentAction: Action | null = null;
let isOpen = false;

export function initRedSwitch(): void {
  createRedSwitchOverlay();

  if (window.holoscape?.on) {
    window.holoscape.on('security:approval-needed', ({ action, isRedSwitch }) => {
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
            <span class="detail-label">Category:</span>
            <span class="detail-value category"></span>
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

function showApprovalRequest(action: Action, _isRedSwitch: boolean): void {
  currentAction = action;
  isOpen = true;

  const overlay = document.getElementById('red-switch-overlay');
  if (!overlay) return;

  // Update content
  overlay.querySelector('.action-type')!.textContent = action.type;
  overlay.querySelector('.action-description')!.textContent = action.description;
  overlay.querySelector('.risk-level')!.textContent = action.riskLevel.toUpperCase();
  overlay.querySelector('.risk-level')!.className =
    `detail-value risk-level risk-${action.riskLevel}`;
  overlay.querySelector('.category')!.textContent = action.category;

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

  window.holoscape?.invoke('security:approve', {
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
