import Store from 'electron-store';
import { randomUUID } from 'crypto';
import { ipcMain } from 'electron';
import type { Service } from './index';
import type { LoggerService } from './logger';
import type { ChatMessage } from '../adapters/base';

export interface Conversation {
  id: string;
  title: string;
  connectionId: string;
  messages: ConversationMessage[];
  createdAt: string;
  updatedAt: string;
  tokenCount: number;
}

export interface ConversationMessage extends ChatMessage {
  id: string;
  timestamp: string;
  tokenEstimate: number;
}

interface ConversationStore {
  conversations: Conversation[];
  activeConversationId: string | null;
}

const MAX_CONVERSATIONS = 50;
const MAX_CONTEXT_TOKENS = 100000; // Conservative default

export class ConversationManagerService implements Service {
  name = 'conversation-manager';
  private store: Store<ConversationStore>;
  private logger!: LoggerService;
  private maxContextTokens = MAX_CONTEXT_TOKENS;

  constructor() {
    this.store = new Store<ConversationStore>({
      name: 'conversations',
      defaults: {
        conversations: [],
        activeConversationId: null,
      },
    });
  }

  setDependencies(logger: LoggerService): void {
    this.logger = logger;
  }

  async initialize(): Promise<void> {
    this.registerIpcHandlers();
    this.logger?.info('ConversationManagerService initialized', {
      conversationCount: this.getConversations().length,
    });
  }

  async shutdown(): Promise<void> {
    this.logger?.info('ConversationManagerService shutdown');
  }

  private registerIpcHandlers(): void {
    ipcMain.handle('conversation:list', () => {
      return this.getConversations().map((c) => ({
        id: c.id,
        title: c.title,
        connectionId: c.connectionId,
        messageCount: c.messages.length,
        createdAt: c.createdAt,
        updatedAt: c.updatedAt,
      }));
    });

    ipcMain.handle('conversation:get', (_, { id }: { id: string }) => {
      return this.getConversation(id);
    });

    ipcMain.handle(
      'conversation:create',
      (_, { connectionId, title }: { connectionId: string; title?: string }) => {
        return this.createConversation(connectionId, title);
      }
    );

    ipcMain.handle('conversation:delete', (_, { id }: { id: string }) => {
      return this.deleteConversation(id);
    });

    ipcMain.handle(
      'conversation:add-message',
      (_, { conversationId, message }: { conversationId: string; message: ChatMessage }) => {
        return this.addMessage(conversationId, message);
      }
    );

    ipcMain.handle(
      'conversation:get-context',
      (_, { conversationId, maxTokens }: { conversationId: string; maxTokens?: number }) => {
        return this.getContextWindow(conversationId, maxTokens);
      }
    );

    ipcMain.handle('conversation:set-active', (_, { id }: { id: string }) => {
      return this.setActiveConversation(id);
    });

    ipcMain.handle('conversation:get-active', () => {
      return this.getActiveConversation();
    });

    ipcMain.handle('conversation:rename', (_, { id, title }: { id: string; title: string }) => {
      return this.renameConversation(id, title);
    });
  }

  getConversations(): Conversation[] {
    return this.store.get('conversations') || [];
  }

  getConversation(id: string): Conversation | null {
    return this.getConversations().find((c) => c.id === id) || null;
  }

  createConversation(connectionId: string, title?: string): Conversation {
    const conversation: Conversation = {
      id: randomUUID(),
      title: title || `Conversation ${new Date().toLocaleString()}`,
      connectionId,
      messages: [],
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      tokenCount: 0,
    };

    const conversations = this.getConversations();
    conversations.unshift(conversation);

    // Limit total conversations
    if (conversations.length > MAX_CONVERSATIONS) {
      conversations.pop();
    }

    this.store.set('conversations', conversations);
    this.store.set('activeConversationId', conversation.id);

    this.logger?.info('Conversation created', { id: conversation.id, title: conversation.title });
    return conversation;
  }

  deleteConversation(id: string): boolean {
    const conversations = this.getConversations();
    const index = conversations.findIndex((c) => c.id === id);

    if (index === -1) return false;

    conversations.splice(index, 1);
    this.store.set('conversations', conversations);

    // If deleted was active, set new active
    if (this.store.get('activeConversationId') === id) {
      this.store.set('activeConversationId', conversations[0]?.id || null);
    }

    this.logger?.info('Conversation deleted', { id });
    return true;
  }

  addMessage(conversationId: string, message: ChatMessage): ConversationMessage | null {
    const conversations = this.getConversations();
    const conversation = conversations.find((c) => c.id === conversationId);

    if (!conversation) return null;

    const tokenEstimate = this.estimateTokens(message.content);

    const conversationMessage: ConversationMessage = {
      ...message,
      id: randomUUID(),
      timestamp: new Date().toISOString(),
      tokenEstimate,
    };

    conversation.messages.push(conversationMessage);
    conversation.tokenCount += tokenEstimate;
    conversation.updatedAt = new Date().toISOString();

    this.store.set('conversations', conversations);

    return conversationMessage;
  }

  /**
   * Get messages that fit within the context window
   * Keeps system message + most recent messages up to token limit
   */
  getContextWindow(conversationId: string, maxTokens?: number): ChatMessage[] {
    const conversation = this.getConversation(conversationId);
    if (!conversation) return [];

    const limit = maxTokens || this.maxContextTokens;
    const messages = conversation.messages;

    // Always include system message if present
    const systemMessage = messages.find((m) => m.role === 'system');
    const systemTokens = systemMessage?.tokenEstimate || 0;

    let remainingTokens = limit - systemTokens;
    const result: ChatMessage[] = [];

    // Add messages from most recent, staying within token limit
    for (let i = messages.length - 1; i >= 0; i--) {
      const msg = messages[i];
      if (msg.role === 'system') continue;

      if (msg.tokenEstimate <= remainingTokens) {
        result.unshift({
          role: msg.role,
          content: msg.content,
        });
        remainingTokens -= msg.tokenEstimate;
      } else {
        break; // Stop when we can't fit more
      }
    }

    // Prepend system message
    if (systemMessage) {
      result.unshift({
        role: systemMessage.role,
        content: systemMessage.content,
      });
    }

    return result;
  }

  setActiveConversation(id: string): boolean {
    const conversation = this.getConversation(id);
    if (!conversation) return false;

    this.store.set('activeConversationId', id);
    return true;
  }

  getActiveConversation(): Conversation | null {
    const id = this.store.get('activeConversationId');
    if (!id) return null;
    return this.getConversation(id);
  }

  renameConversation(id: string, title: string): boolean {
    const conversations = this.getConversations();
    const conversation = conversations.find((c) => c.id === id);

    if (!conversation) return false;

    conversation.title = title;
    conversation.updatedAt = new Date().toISOString();
    this.store.set('conversations', conversations);

    return true;
  }

  setMaxContextTokens(tokens: number): void {
    this.maxContextTokens = tokens;
  }

  /**
   * Rough token estimation (4 chars ≈ 1 token)
   */
  private estimateTokens(text: string): number {
    return Math.ceil(text.length / 4);
  }
}
