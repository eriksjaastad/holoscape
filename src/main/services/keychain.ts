import keytar from 'keytar';
import Store from 'electron-store';
import { Service } from './index.js';
import { LoggerService } from './logger.js';

const SERVICE_NAME = 'holoscape-ai';

export interface KeychainEntry {
  provider: string;
  hasKey: boolean;
  createdAt?: string;
}

interface KeychainMetadata {
  [provider: string]: {
    createdAt: string;
  };
}

export class KeychainService implements Service {
  name = 'keychain';
  private logger!: LoggerService;
  private metadataStore: Store<{ metadata: KeychainMetadata }>;

  constructor() {
    this.metadataStore = new Store({
      name: 'keychain-metadata',
      defaults: {
        metadata: {},
      },
    });
  }

  async initialize(): Promise<void> {
    // Logger will be injected after all services initialize
    console.log('KeychainService initialized');
  }

  setLogger(logger: LoggerService): void {
    this.logger = logger;
  }

  async shutdown(): Promise<void> {
    // Nothing to clean up
  }

  /**
   * Store an API key in the OS keychain
   * NEVER logs the actual key value
   */
  async setKey(provider: string, apiKey: string): Promise<void> {
    if (!apiKey || apiKey.trim() === '') {
      throw new Error('API key cannot be empty');
    }

    await keytar.setPassword(SERVICE_NAME, provider, apiKey);

    const now = new Date().toISOString();
    const metadata = this.metadataStore.get('metadata', {});
    metadata[provider] = { createdAt: now };
    this.metadataStore.set('metadata', metadata);

    this.logger?.info('API key stored', {
      provider,
      keyLength: apiKey.length,
      createdAt: now,
    });
  }

  /**
   * Retrieve an API key from the OS keychain
   * Returns null if not found
   */
  async getKey(provider: string): Promise<string | null> {
    const key = await keytar.getPassword(SERVICE_NAME, provider);

    if (key) {
      this.logger?.debug('API key retrieved', { provider });
    } else {
      this.logger?.debug('API key not found', { provider });
    }

    return key;
  }

  /**
   * Check if a key exists without retrieving it
   */
  async hasKey(provider: string): Promise<boolean> {
    const key = await keytar.getPassword(SERVICE_NAME, provider);
    return key !== null;
  }

  /**
   * Delete an API key from the OS keychain
   */
  async deleteKey(provider: string): Promise<boolean> {
    const deleted = await keytar.deletePassword(SERVICE_NAME, provider);

    if (deleted) {
      const metadata = this.metadataStore.get('metadata', {});
      delete metadata[provider];
      this.metadataStore.set('metadata', metadata);
      this.logger?.info('API key deleted', { provider });
    }

    return deleted;
  }

  /**
   * Delete ALL stored keys (panic button)
   */
  async deleteAllKeys(): Promise<number> {
    const credentials = await keytar.findCredentials(SERVICE_NAME);
    let count = 0;

    for (const cred of credentials) {
      await keytar.deletePassword(SERVICE_NAME, cred.account);
      count++;
    }

    this.metadataStore.set('metadata', {});
    this.logger?.warn('All API keys deleted (panic button)', { count });

    return count;
  }

  /**
   * List all stored providers (without exposing keys)
   */
  async listProviders(): Promise<KeychainEntry[]> {
    const credentials = await keytar.findCredentials(SERVICE_NAME);
    const metadata = this.metadataStore.get('metadata', {});

    return credentials.map((cred) => ({
      provider: cred.account,
      hasKey: true,
      createdAt: metadata[cred.account]?.createdAt,
    }));
  }

  /**
   * Rotate a key (delete old, store new)
   */
  async rotateKey(provider: string, newKey: string): Promise<void> {
    await this.deleteKey(provider);
    await this.setKey(provider, newKey);
    this.logger?.info('API key rotated', { provider });
  }
}
