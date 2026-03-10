import { app, BrowserWindow, ipcMain, Menu } from 'electron';
import type { BrowserWindowConstructorOptions } from 'electron';
import path from 'path';
import 'dotenv/config';

import { registry } from './services';
import { LoggerService } from './services/logger';
import { WindowService } from './services/window';
import { ChatHistoryService } from './services/chat-history';
import { OrchestratorService } from './services/orchestrator';
import { NetworkService } from './services/network';
import { SecurityService } from './services/security';
import { KeychainService } from './services/keychain';
import { ConnectionManagerService } from './services/connection-manager';
import { FileAgentService } from './services/file-agent';
import { ConversationManagerService } from './services/conversation-manager';
import { registerGlobalShortcuts, unregisterGlobalShortcuts } from './shortcuts';
import { createAppMenu } from './menu';

const windowService = new WindowService();
const loggerService = new LoggerService();
const keychainService = new KeychainService();
const chatHistoryService = new ChatHistoryService();
const securityService = new SecurityService();
const connectionManagerService = new ConnectionManagerService();
const orchestratorService = new OrchestratorService();
const fileAgentService = new FileAgentService();
const conversationManagerService = new ConversationManagerService();

registry.register(loggerService);
registry.register(windowService);
registry.register(keychainService);
registry.register(chatHistoryService);
registry.register(securityService);
registry.register(connectionManagerService);
registry.register(orchestratorService);
registry.register(new NetworkService());
registry.register(fileAgentService);
registry.register(conversationManagerService);

let mainWindow: BrowserWindow | null = null;
let lastCpuUsage = process.cpuUsage();
let lastCpuTime = process.hrtime.bigint();

function createWindow(): void {
  loggerService.info('Creating main window');
  const windowOptions: BrowserWindowConstructorOptions = {
    width: 960,
    height: 720,
    minWidth: 500,
    minHeight: 320,
    transparent: true,
    frame: false,
    vibrancy: 'ultra-dark' as BrowserWindowConstructorOptions['vibrancy'],
    hasShadow: true,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
  };

  mainWindow = new BrowserWindow(windowOptions);
  windowService.setWindow(mainWindow);

  if (process.env.NODE_ENV === 'development') {
    mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  } else {
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  }

  loggerService.info('Window created', {
    dev: process.env.NODE_ENV === 'development',
  });
}

ipcMain.handle('get-api-key', async () => {
  loggerService.debug('API key requested');
  // Try keychain first, fall back to env
  const key = await keychainService.getKey('openai');
  return key || process.env.OPENAI_API_KEY || null;
});

ipcMain.handle('get-process-metrics', () => {
  const now = process.hrtime.bigint();
  const intervalNs = Number(now - lastCpuTime);
  lastCpuTime = now;

  const cpuUsage = process.cpuUsage(lastCpuUsage);
  lastCpuUsage = process.cpuUsage();
  const memUsage = process.memoryUsage();

  const cpuMicroseconds = cpuUsage.user + cpuUsage.system;
  const intervalMs = intervalNs / 1_000_000;
  const cpuMs = cpuMicroseconds / 1000;
  const cpuPercent = intervalMs > 0 ? (cpuMs / intervalMs) * 100 : 0;

  loggerService.debug('Process metrics requested', { cpuPercent });

  return {
    cpuPercent,
    heapUsedMB: memUsage.heapUsed / 1024 / 1024,
    heapTotalMB: memUsage.heapTotal / 1024 / 1024,
    rssUsedMB: memUsage.rss / 1024 / 1024,
  };
});

// Keychain IPC handlers
ipcMain.handle('keychain:set', async (_, { provider, key }) => {
  await keychainService.setKey(provider, key);
});

ipcMain.handle('keychain:get', async (_, { provider }) => {
  return keychainService.getKey(provider);
});

ipcMain.handle('keychain:delete', async (_, { provider }) => {
  return keychainService.deleteKey(provider);
});

ipcMain.handle('keychain:delete-all', async () => {
  return keychainService.deleteAllKeys();
});

ipcMain.handle('keychain:list', async () => {
  return keychainService.listProviders();
});

ipcMain.handle('keychain:has', async (_, { provider }) => {
  return keychainService.hasKey(provider);
});

// Chat IPC handlers
ipcMain.handle('chat:send', async (event, { message, connectionId }) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) {
    return { success: false, error: 'Window not found' };
  }

  try {
    // Get adapter from connection manager (or use active)
    const adapter = connectionId
      ? connectionManagerService.getAdapter(connectionId)
      : connectionManagerService.getActiveAdapter();

    if (!adapter) {
      return {
        success: false,
        error: 'No active connection. Please add a connection in Settings.',
      };
    }

    // Add user message to history
    await chatHistoryService.addMessage({
      role: 'user',
      content: message,
      connectionId,
    });

    // Get conversation history for context
    const history = await chatHistoryService.getMessages();
    const messages = history.map((m) => ({
      role: m.role as 'user' | 'assistant' | 'system',
      content: m.content,
    }));

    // Stream response using adapter
    await adapter.streamChat(messages, {
      onToken: (token) => {
        win.webContents.send('chat:token', { token, done: false });
      },
      onComplete: async (fullResponse) => {
        // Add assistant message to history
        await chatHistoryService.addMessage({
          role: 'assistant',
          content: fullResponse,
          connectionId,
        });
        win.webContents.send('chat:complete', { fullResponse });
      },
      onError: (error) => {
        win.webContents.send('chat:error', { message: error.message });
      },
    });

    return { success: true };
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return { success: false, error: message };
  }
});

ipcMain.handle('chat:get-history', async () => {
  return chatHistoryService.getMessages();
});

ipcMain.handle('chat:clear-history', async () => {
  await chatHistoryService.clearHistory();
});

// Settings IPC handlers
ipcMain.handle('settings:clear-logs', async () => {
  return loggerService.clearAllLogs();
});

ipcMain.handle('settings:get-log-dir', () => {
  return loggerService.getLogDir();
});

ipcMain.handle('window:toggle', () => {
  if (!mainWindow) return { visible: false };

  if (mainWindow.isVisible()) {
    mainWindow.hide();
    return { visible: false };
  }

  mainWindow.show();
  mainWindow.focus();
  return { visible: true };
});

ipcMain.handle('window:set-always-on-top', (_event, { enabled }: { enabled: boolean }) => {
  if (mainWindow) {
    mainWindow.setAlwaysOnTop(enabled);
    loggerService.info('Always on top changed', { enabled });
  }
});

app.whenReady().then(async () => {
  loggerService.info('App ready, initializing services');
  await registry.initializeAll();

  // Set up service dependencies
  keychainService.setLogger(loggerService);
  chatHistoryService.setDependencies(loggerService, keychainService);
  securityService.setLogger(loggerService);
  connectionManagerService.setDependencies(loggerService, keychainService);
  orchestratorService.setDependencies(loggerService, securityService, connectionManagerService);
  fileAgentService.setDependencies(loggerService, securityService);
  conversationManagerService.setDependencies(loggerService);

  createWindow();
  Menu.setApplicationMenu(createAppMenu());
  registerGlobalShortcuts(() => windowService.getWindow());
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('before-quit', async () => {
  loggerService.info('App shutting down');
  unregisterGlobalShortcuts();
  await registry.shutdownAll();
});

app.on('will-quit', () => {
  unregisterGlobalShortcuts();
});
