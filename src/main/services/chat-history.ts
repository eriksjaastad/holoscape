import Store from 'electron-store';
import { ipcMain, BrowserWindow } from 'electron';
import { randomUUID } from 'crypto';
import type { Service } from './index';
import { createLogger } from './logger';
import type { ChatMessage } from '@shared/ipc-types';

const log = createLogger('ChatHistory');

interface ChatHistoryStore {
  messages: ChatMessage[];
}

const MAX_MESSAGES = 100;

export class ChatHistoryService implements Service {
  name = 'chatHistory';
  private store: Store<ChatHistoryStore>;

  constructor() {
    this.store = new Store<ChatHistoryStore>({
      name: 'chat-history',
      defaults: {
        messages: [],
      },
    });
  }

  addMessage(msg: Omit<ChatMessage, 'id' | 'timestamp'>): ChatMessage {
    const message: ChatMessage = {
      ...msg,
      id: randomUUID(),
      timestamp: new Date().toISOString(),
    };

    const messages = this.store.get('messages', []);
    messages.push(message);
    const trimmed = messages.slice(-MAX_MESSAGES);
    this.store.set('messages', trimmed);
    log.debug('Message added', { id: message.id, role: message.role });
    for (const window of BrowserWindow.getAllWindows()) {
      window.webContents.send('chat:message-added', { message });
    }
    return message;
  }

  getHistory(): ChatMessage[] {
    return this.store.get('messages', []);
  }

  clearHistory(): void {
    this.store.set('messages', []);
    log.info('Chat history cleared');
  }

  async initialize(): Promise<void> {
    ipcMain.handle('chat:get-history', () => this.getHistory());
    ipcMain.handle('chat:clear-history', () => {
      this.clearHistory();
    });
    log.info('Chat history service initialized', { existingMessages: this.getHistory().length });
  }

  async shutdown(): Promise<void> {
    ipcMain.removeHandler('chat:get-history');
    ipcMain.removeHandler('chat:clear-history');
    log.info('Chat history service shutdown');
  }
}
