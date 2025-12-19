import { BrowserWindow } from 'electron';
import type { Service } from './index';
import { createLogger } from './logger';

const log = createLogger('WindowService');

export class WindowService implements Service {
  name = 'window';
  private window: BrowserWindow | null = null;

  setWindow(window: BrowserWindow): void {
    this.window = window;

    window.on('show', () => log.debug('Window shown'));
    window.on('hide', () => log.debug('Window hidden'));
    window.on('focus', () => log.debug('Window focused'));
    window.on('blur', () => log.debug('Window blurred'));
  }

  getWindow(): BrowserWindow | null {
    return this.window;
  }

  toggle(): boolean {
    if (!this.window) return false;

    if (this.window.isVisible()) {
      this.window.hide();
      return false;
    } else {
      this.window.show();
      this.window.focus();
      return true;
    }
  }

  async initialize(): Promise<void> {
    log.info('Window service initialized');
  }

  async shutdown(): Promise<void> {
    this.window = null;
  }
}
