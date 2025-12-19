import { net, ipcMain, BrowserWindow } from 'electron';
import type { Service } from './index';
import { createLogger } from './logger';

const log = createLogger('Network');
const POLL_INTERVAL_MS = 5000;

export class NetworkService implements Service {
  name = 'network';
  private pollInterval: NodeJS.Timeout | null = null;
  private lastOnlineState = true;

  isOnline(): boolean {
    return net.isOnline();
  }

  private broadcastStatus(online: boolean): void {
    for (const window of BrowserWindow.getAllWindows()) {
      window.webContents.send('network:status', { online });
    }
  }

  private startPolling(): void {
    this.lastOnlineState = this.isOnline();
    log.info('Starting network polling', { online: this.lastOnlineState });
    this.pollInterval = setInterval(() => {
      const currentState = this.isOnline();
      if (currentState !== this.lastOnlineState) {
        log.info('Network status changed', {
          from: this.lastOnlineState ? 'online' : 'offline',
          to: currentState ? 'online' : 'offline',
        });
        this.lastOnlineState = currentState;
        this.broadcastStatus(currentState);
      }
    }, POLL_INTERVAL_MS);
  }

  private stopPolling(): void {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  }

  async initialize(): Promise<void> {
    ipcMain.handle('network:get-status', () => {
      return { online: this.isOnline() };
    });
    this.startPolling();
    log.info('Network service initialized');
  }

  async shutdown(): Promise<void> {
    this.stopPolling();
    ipcMain.removeHandler('network:get-status');
    log.info('Network service shutdown');
  }
}
