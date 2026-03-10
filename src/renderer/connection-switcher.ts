import type { ConnectionProfile, ProviderType } from '@shared/types';

let activeProfileId: string | null = null;

export async function initConnectionSwitcher(): Promise<void> {
  await loadProfiles();
  setupEventListeners();
}

async function loadProfiles(): Promise<void> {
  const container = document.getElementById('connection-switcher');
  if (!container) return;

  const profiles = (await window.holoscape.invoke('connection:list')) as ConnectionProfile[];
  const active = (await window.holoscape.invoke(
    'connection:get-active'
  )) as ConnectionProfile | null;
  activeProfileId = active?.id || null;

  renderProfiles(container, profiles);
}

function renderProfiles(container: HTMLElement, profiles: ConnectionProfile[]): void {
  container.innerHTML = `
    <div class="connection-header">
      <span class="connection-label">Connection</span>
      <button class="add-connection-btn" id="add-connection-btn">+</button>
    </div>
    <div class="connection-list" id="connection-list">
      ${
        profiles.length === 0
          ? '<div class="no-connections">No connections. Click + to add one.</div>'
          : profiles.map((p) => renderProfile(p)).join('')
      }
    </div>
    <div id="connection-form" class="connection-form hidden">
      <h4>Add Connection</h4>
      <select id="provider-select">
        <option value="openai">OpenAI</option>
        <option value="anthropic">Anthropic</option>
        <option value="google">Google</option>
      </select>
      <input type="text" id="connection-name" placeholder="Connection name" />
      <input type="password" id="connection-key" placeholder="API key" />
      <div class="form-actions">
        <button id="cancel-connection">Cancel</button>
        <button id="save-connection">Save</button>
      </div>
    </div>
  `;

  // Add click handlers for each profile
  profiles.forEach((p) => {
    const el = container.querySelector(`[data-profile-id="${p.id}"]`);
    el?.addEventListener('click', () => switchConnection(p.id));
  });

  // Add/Cancel/Save handlers
  document.getElementById('add-connection-btn')?.addEventListener('click', showAddForm);
  document.getElementById('cancel-connection')?.addEventListener('click', hideAddForm);
  document.getElementById('save-connection')?.addEventListener('click', saveConnection);
}

function renderProfile(profile: ConnectionProfile): string {
  const isActive = profile.id === activeProfileId;
  const providerIcon: Record<ProviderType, string> = {
    openai: '🤖',
    anthropic: '🧠',
    google: '✨',
    custom: '🔧',
  };

  return `
    <div class="connection-item ${isActive ? 'active' : ''}" data-profile-id="${profile.id}">
      <span class="provider-icon">${providerIcon[profile.provider]}</span>
      <span class="connection-name">${profile.name}</span>
      ${profile.isDefault ? '<span class="default-badge">Default</span>' : ''}
    </div>
  `;
}

function showAddForm(): void {
  document.getElementById('connection-form')?.classList.remove('hidden');
}

function hideAddForm(): void {
  document.getElementById('connection-form')?.classList.add('hidden');
  // Clear inputs
  (document.getElementById('connection-name') as HTMLInputElement).value = '';
  (document.getElementById('connection-key') as HTMLInputElement).value = '';
}

async function saveConnection(): Promise<void> {
  const provider = (document.getElementById('provider-select') as HTMLSelectElement)
    .value as ProviderType;
  const name = (document.getElementById('connection-name') as HTMLInputElement).value.trim();
  const key = (document.getElementById('connection-key') as HTMLInputElement).value.trim();

  if (!name || !key) {
    alert('Please fill in all fields');
    return;
  }

  try {
    // Store API key in keychain
    await window.holoscape.keychain.setKey(provider, key);

    // Add connection profile
    await window.holoscape.invoke('connection:add', {
      name,
      provider,
      keychainKey: provider,
      config: {},
      isDefault: false,
    });

    hideAddForm();
    await loadProfiles();
  } catch (error) {
    console.error('Failed to save connection:', error);
    alert('Failed to save connection');
  }
}

async function switchConnection(id: string): Promise<void> {
  const success = (await window.holoscape.invoke('connection:switch', { id })) as boolean;
  if (success) {
    activeProfileId = id;
    await loadProfiles();
  }
}

function setupEventListeners(): void {
  // Listen for profile changes
  window.holoscape.on('connection:profiles-changed', () => {
    loadProfiles();
  });

  window.holoscape.on('connection:active-changed', ({ profileId }) => {
    activeProfileId = profileId;
    loadProfiles();
  });
}
