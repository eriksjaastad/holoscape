import { app, BrowserWindow, ipcMain, Menu } from 'electron';
import type { BrowserWindowConstructorOptions } from 'electron';
import path from 'path';
import 'dotenv/config';

import { registry } from './services';
import { LoggerService, createLogger } from './services/logger';
import { WindowService } from './services/window';
import { ChatHistoryService } from './services/chat-history';
import { OrchestratorService } from './services/orchestrator';
import { NetworkService } from './services/network';
import { SecurityService } from './services/security';
import { registerGlobalShortcuts, unregisterGlobalShortcuts } from './shortcuts';
import { createAppMenu } from './menu';

const log = createLogger('Main');
const windowService = new WindowService();

registry.register(new LoggerService());
registry.register(windowService);
registry.register(new ChatHistoryService());
registry.register(new OrchestratorService());
registry.register(new NetworkService());
registry.register(new SecurityService());

let mainWindow: BrowserWindow | null = null;
let lastCpuUsage = process.cpuUsage();
let lastCpuTime = process.hrtime.bigint();

function createWindow(): void {
  log.info('Creating main window');
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

  log.info('Window created', {
    dev: process.env.NODE_ENV === 'development',
  });
}

ipcMain.handle('get-api-key', () => {
  log.debug('API key requested');
  return process.env.OPENAI_API_KEY || null;
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

  log.debug('Process metrics requested', { cpuPercent });

  return {
    cpuPercent,
    heapUsedMB: memUsage.heapUsed / 1024 / 1024,
    heapTotalMB: memUsage.heapTotal / 1024 / 1024,
    rssUsedMB: memUsage.rss / 1024 / 1024,
  };
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
    log.info('Always on top changed', { enabled });
  }
});

app.whenReady().then(async () => {
  log.info('App ready, initializing services');
  await registry.initializeAll();
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
  log.info('App shutting down');
  unregisterGlobalShortcuts();
  await registry.shutdownAll();
});

app.on('will-quit', () => {
  unregisterGlobalShortcuts();
});
