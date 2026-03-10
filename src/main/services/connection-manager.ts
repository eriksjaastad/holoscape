import Store from 'electron-store';
import { randomUUID } from 'crypto';
import { ipcMain, BrowserWindow } from 'electron';
import type { Service } from './index';
import type { LoggerService } from './logger';
import type { KeychainService } from './keychain';
import { BaseAdapter, ConnectionProfile } from '../adapters/base';
import { OpenAIAdapter } from '../adapters/openai';
import { AnthropicAdapter } from '../adapters/anthropic';
import { GoogleAdapter } from '../adapters/google';
import { CustomAdapter } from '../adapters/custom';

interface ConnectionManagerStore {
  profiles: ConnectionProfile[];
  defaultProfileId: string | null;
}

export class ConnectionManagerService implements Service {
  name = 'connection-manager';
  private store: Store<ConnectionManagerStore>;
  private logger!: LoggerService;
  private keychain!: KeychainService;
  private adapters: Map<string, BaseAdapter> = new Map();
  private activeAdapterId: string | null = null;

  constructor() {
    this.store = new Store<ConnectionManagerStore>({
      name: 'connections',
      defaults: {
        profiles: [],
        defaultProfileId: null,
      },
    });
  }

  setDependencies(logger: LoggerService, keychain: KeychainService): void {
    this.logger = logger;
    this.keychain = keychain;
  }

  async initialize(): Promise<void> {
    this.registerIpcHandlers();

    // Create adapters for existing profiles
    const profiles = this.getProfiles();
    for (const profile of profiles) {
      this.createAdapterForProfile(profile);
    }

    // Set active adapter to default if available
    const defaultId = this.store.get('defaultProfileId');
    if (defaultId && this.adapters.has(defaultId)) {
      this.activeAdapterId = defaultId;
    }

    this.logger?.info('ConnectionManagerService initialized', {
      profileCount: profiles.length,
    });
  }

  async shutdown(): Promise<void> {
    // Abort any pending requests
    for (const adapter of this.adapters.values()) {
      adapter.abort();
    }
    this.adapters.clear();
  }

  private registerIpcHandlers(): void {
    ipcMain.handle('connection:list', () => {
      return this.getProfiles();
    });

    ipcMain.handle(
      'connection:add',
      async (_, profile: Omit<ConnectionProfile, 'id' | 'createdAt'>) => {
        return this.addProfile(profile);
      }
    );

    ipcMain.handle('connection:remove', async (_, { id }: { id: string }) => {
      return this.removeProfile(id);
    });

    ipcMain.handle('connection:set-default', async (_, { id }: { id: string }) => {
      return this.setDefault(id);
    });

    ipcMain.handle('connection:switch', async (_, { id }: { id: string }) => {
      return this.switchTo(id);
    });

    ipcMain.handle('connection:test', async (_, { id }: { id: string }) => {
      return this.testConnection(id);
    });

    ipcMain.handle('connection:get-active', () => {
      return this.getActiveProfile();
    });

    ipcMain.handle(
      'connection:update',
      async (_, { id, updates }: { id: string; updates: Partial<ConnectionProfile> }) => {
        return this.updateProfile(id, updates);
      }
    );
  }

  /**
   * Get all connection profiles
   */
  getProfiles(): ConnectionProfile[] {
    return this.store.get('profiles') || [];
  }

  /**
   * Add a new connection profile
   */
  async addProfile(
    profile: Omit<ConnectionProfile, 'id' | 'createdAt'>
  ): Promise<ConnectionProfile> {
    const newProfile: ConnectionProfile = {
      ...profile,
      id: randomUUID(),
      createdAt: new Date().toISOString(),
    };

    const profiles = this.getProfiles();

    // If this is the first profile or marked as default, make it default
    if (profiles.length === 0 || profile.isDefault) {
      newProfile.isDefault = true;
      // Unset any existing default
      for (const p of profiles) {
        p.isDefault = false;
      }
      this.store.set('defaultProfileId', newProfile.id);
    }

    profiles.push(newProfile);
    this.store.set('profiles', profiles);

    // Create adapter for this profile
    this.createAdapterForProfile(newProfile);

    this.logger?.info('Connection profile added', {
      id: newProfile.id,
      name: newProfile.name,
      provider: newProfile.provider,
    });

    this.notifyProfilesChanged();
    return newProfile;
  }

  /**
   * Remove a connection profile
   */
  async removeProfile(id: string): Promise<boolean> {
    const profiles = this.getProfiles();
    const index = profiles.findIndex((p) => p.id === id);

    if (index === -1) {
      return false;
    }

    const removed = profiles[index];
    profiles.splice(index, 1);

    // If we removed the default, set a new default
    if (removed.isDefault && profiles.length > 0) {
      profiles[0].isDefault = true;
      this.store.set('defaultProfileId', profiles[0].id);
    }

    this.store.set('profiles', profiles);

    // Remove adapter
    const adapter = this.adapters.get(id);
    if (adapter) {
      adapter.abort();
      this.adapters.delete(id);
    }

    // If this was active, switch to default
    if (this.activeAdapterId === id) {
      this.activeAdapterId = this.store.get('defaultProfileId');
    }

    this.logger?.info('Connection profile removed', {
      id,
      name: removed.name,
    });

    this.notifyProfilesChanged();
    return true;
  }

  /**
   * Update a connection profile
   */
  async updateProfile(
    id: string,
    updates: Partial<ConnectionProfile>
  ): Promise<ConnectionProfile | null> {
    const profiles = this.getProfiles();
    const profile = profiles.find((p) => p.id === id);

    if (!profile) {
      return null;
    }

    // Apply updates
    Object.assign(profile, updates);
    this.store.set('profiles', profiles);

    // Recreate adapter if config changed
    if (updates.config) {
      this.createAdapterForProfile(profile);
    }

    this.logger?.info('Connection profile updated', {
      id,
      name: profile.name,
    });

    this.notifyProfilesChanged();
    return profile;
  }

  /**
   * Set default profile
   */
  async setDefault(id: string): Promise<boolean> {
    const profiles = this.getProfiles();
    const profile = profiles.find((p) => p.id === id);

    if (!profile) {
      return false;
    }

    for (const p of profiles) {
      p.isDefault = p.id === id;
    }

    this.store.set('profiles', profiles);
    this.store.set('defaultProfileId', id);

    this.logger?.info('Default connection set', {
      id,
      name: profile.name,
    });

    this.notifyProfilesChanged();
    return true;
  }

  /**
   * Switch active connection
   */
  async switchTo(id: string): Promise<boolean> {
    if (!this.adapters.has(id)) {
      return false;
    }

    // Abort current adapter's pending request
    if (this.activeAdapterId && this.adapters.has(this.activeAdapterId)) {
      this.adapters.get(this.activeAdapterId)!.abort();
    }

    this.activeAdapterId = id;

    // Update last used
    const profiles = this.getProfiles();
    const profile = profiles.find((p) => p.id === id);
    if (profile) {
      profile.lastUsedAt = new Date().toISOString();
      this.store.set('profiles', profiles);
    }

    this.logger?.info('Switched connection', {
      id,
      name: profile?.name,
    });

    this.notifyActiveChanged(id);
    return true;
  }

  /**
   * Test a connection
   */
  async testConnection(
    id: string
  ): Promise<{ success: boolean; latencyMs?: number; error?: string }> {
    const adapter = this.adapters.get(id);
    if (!adapter) {
      return { success: false, error: 'Connection not found' };
    }

    const isConfigured = await adapter.isConfigured();
    if (!isConfigured) {
      return { success: false, error: 'API key not configured' };
    }

    const startTime = Date.now();

    return new Promise((resolve) => {
      adapter.streamChat([{ role: 'user', content: 'Say "OK" and nothing else.' }], {
        onToken: () => {},
        onComplete: () => {
          resolve({
            success: true,
            latencyMs: Date.now() - startTime,
          });
        },
        onError: (error) => {
          resolve({
            success: false,
            error: error.message,
          });
        },
      });
    });
  }

  /**
   * Get active adapter
   */
  getActiveAdapter(): BaseAdapter | null {
    if (!this.activeAdapterId) {
      return null;
    }
    return this.adapters.get(this.activeAdapterId) || null;
  }

  /**
   * Get active profile
   */
  getActiveProfile(): ConnectionProfile | null {
    if (!this.activeAdapterId) {
      return null;
    }
    return this.getProfiles().find((p) => p.id === this.activeAdapterId) || null;
  }

  /**
   * Get adapter by ID
   */
  getAdapter(id: string): BaseAdapter | null {
    return this.adapters.get(id) || null;
  }

  private createAdapterForProfile(profile: ConnectionProfile): void {
    let adapter: BaseAdapter;

    switch (profile.provider) {
      case 'openai':
        adapter = new OpenAIAdapter(this.keychain, this.logger, profile.config);
        break;
      case 'anthropic':
        adapter = new AnthropicAdapter(this.keychain, this.logger, profile.config);
        break;
      case 'google':
        adapter = new GoogleAdapter(this.keychain, this.logger, profile.config);
        break;
      case 'custom':
        if (!profile.customConfig?.baseUrl) {
          this.logger?.warn('Custom adapter missing baseUrl', { profileId: profile.id });
          return;
        }
        adapter = new CustomAdapter(
          this.keychain,
          this.logger,
          { ...profile.config, ...profile.customConfig },
          profile.keychainKey
        );
        break;
      default:
        this.logger?.error('Unknown provider', { provider: profile.provider });
        return;
    }

    this.adapters.set(profile.id, adapter);
  }

  private notifyProfilesChanged(): void {
    const win = BrowserWindow.getAllWindows()[0];
    if (win) {
      win.webContents.send('connection:profiles-changed', {
        profiles: this.getProfiles(),
      });
    }
  }

  private notifyActiveChanged(id: string): void {
    const win = BrowserWindow.getAllWindows()[0];
    if (win) {
      win.webContents.send('connection:active-changed', {
        profileId: id,
        profile: this.getActiveProfile(),
      });
    }
  }
}
