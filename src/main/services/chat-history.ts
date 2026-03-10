import Store from 'electron-store';
import { createCipheriv, createDecipheriv, randomBytes, scryptSync } from 'crypto';
import { Service } from './index.js';
import { LoggerService } from './logger.js';
import { KeychainService } from './keychain.js';

export interface ChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: string;
  connectionId?: string;
}

interface EncryptedData {
  iv: string;
  encrypted: string;
}

const MAX_MESSAGES = 100;
const MAX_STORAGE_SIZE = 10 * 1024 * 1024; // 10MB
const ENCRYPTION_KEY_NAME = 'holoscape-encryption';
const ENCRYPTION_SALT_NAME = 'holoscape-encryption-salt';

export class ChatHistoryService implements Service {
  name = 'chat-history';
  private store: Store;
  private logger!: LoggerService;
  private keychain!: KeychainService;
  private encryptionKey: Buffer | null = null;

  constructor() {
    this.store = new Store({
      name: 'chat-history',
      encryptionKey: undefined, // We handle encryption ourselves
    });
  }

  async initialize(): Promise<void> {
    console.log('ChatHistoryService initialized');
  }

  setDependencies(logger: LoggerService, keychain: KeychainService): void {
    this.logger = logger;
    this.keychain = keychain;
  }

  async shutdown(): Promise<void> {
    // Clear encryption key from memory
    this.encryptionKey = null;
  }

  /**
   * Get or create the encryption key
   */
  private async getEncryptionKey(): Promise<Buffer> {
    if (this.encryptionKey) {
      return this.encryptionKey;
    }

    // Try to get existing key from keychain
    let keyMaterial = await this.keychain.getKey(ENCRYPTION_KEY_NAME);

    if (!keyMaterial) {
      // Generate new key material and store it
      keyMaterial = randomBytes(32).toString('hex');
      await this.keychain.setKey(ENCRYPTION_KEY_NAME, keyMaterial);
      this.logger?.info('Generated new encryption key');
    }

    // Get or generate salt
    let salt = await this.keychain.getKey(ENCRYPTION_SALT_NAME);
    if (!salt) {
      // Generate unique salt for this installation
      salt = randomBytes(32).toString('hex');
      await this.keychain.setKey(ENCRYPTION_SALT_NAME, salt);
      this.logger?.info('Generated new encryption salt');
    }

    // Derive actual key using scrypt with unique salt
    this.encryptionKey = scryptSync(keyMaterial, salt, 32);
    return this.encryptionKey;
  }

  /**
   * Encrypt a message
   */
  private async encrypt(text: string): Promise<EncryptedData> {
    const key = await this.getEncryptionKey();
    const iv = randomBytes(16);
    const cipher = createCipheriv('aes-256-gcm', key, iv);

    let encrypted = cipher.update(text, 'utf8', 'hex');
    encrypted += cipher.final('hex');
    const authTag = cipher.getAuthTag();

    return {
      iv: iv.toString('hex'),
      encrypted: encrypted + authTag.toString('hex'),
    };
  }

  /**
   * Decrypt a message
   */
  private async decrypt(data: EncryptedData): Promise<string> {
    const key = await this.getEncryptionKey();
    const iv = Buffer.from(data.iv, 'hex');

    // Extract auth tag (last 32 hex chars = 16 bytes)
    const encrypted = data.encrypted.slice(0, -32);
    const authTag = Buffer.from(data.encrypted.slice(-32), 'hex');

    const decipher = createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(authTag);

    let decrypted = decipher.update(encrypted, 'hex', 'utf8');
    decrypted += decipher.final('utf8');

    return decrypted;
  }

  /**
   * Add a message to history
   */
  async addMessage(message: Omit<ChatMessage, 'id' | 'timestamp'>): Promise<ChatMessage> {
    const fullMessage: ChatMessage = {
      ...message,
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
    };

    const messages = await this.getMessages();
    messages.push(fullMessage);

    // Enforce size limits
    await this.enforceLimit(messages);

    // Encrypt and store
    const encrypted = await this.encrypt(JSON.stringify(messages));
    this.store.set('messages', encrypted);

    this.logger?.debug('Message added to history', {
      messageId: fullMessage.id,
      role: fullMessage.role,
    });

    return fullMessage;
  }

  /**
   * Get all messages
   */
  async getMessages(): Promise<ChatMessage[]> {
    const encrypted = this.store.get('messages') as EncryptedData | undefined;

    if (!encrypted) {
      return [];
    }

    try {
      const decrypted = await this.decrypt(encrypted);
      return JSON.parse(decrypted);
    } catch (error) {
      this.logger?.error('Failed to decrypt messages', {
        error: error instanceof Error ? error.message : 'Unknown',
      });
      return [];
    }
  }

  /**
   * Enforce message count and size limits
   */
  private async enforceLimit(messages: ChatMessage[]): Promise<void> {
    // Remove oldest messages if over count limit
    while (messages.length > MAX_MESSAGES) {
      const removed = messages.shift();
      this.logger?.debug('Removed old message', { messageId: removed?.id });
    }

    // Check size and remove more if needed
    let size = JSON.stringify(messages).length;
    while (size > MAX_STORAGE_SIZE && messages.length > 0) {
      messages.shift();
      size = JSON.stringify(messages).length;
    }
  }

  /**
   * Clear all history (user-triggered)
   */
  async clearHistory(): Promise<void> {
    this.store.delete('messages');
    this.logger?.info('Chat history cleared');
  }

  /**
   * Get message count
   */
  async getMessageCount(): Promise<number> {
    const messages = await this.getMessages();
    return messages.length;
  }

  /**
   * Get storage size in bytes
   */
  getStorageSize(): number {
    const encrypted = this.store.get('messages') as EncryptedData | undefined;
    if (!encrypted) return 0;
    return JSON.stringify(encrypted).length;
  }
}
