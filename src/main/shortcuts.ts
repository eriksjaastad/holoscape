import { globalShortcut, BrowserWindow } from 'electron';
import { createLogger } from './services/logger';

const log = createLogger('Shortcuts');

const SHORTCUTS = {
  toggleWindow: 'CommandOrControl+Shift+H',
} as const;

let registered = false;

export function registerGlobalShortcuts(getWindow: () => BrowserWindow | null): void {
  if (registered) {
    return;
  }

  const ok = globalShortcut.register(SHORTCUTS.toggleWindow, () => {
    const window = getWindow();
    if (!window) {
      log.warn('No window to toggle');
      return;
    }

    if (window.isVisible()) {
      log.debug('Hiding window via hotkey');
      window.hide();
    } else {
      log.debug('Showing window via hotkey');
      window.show();
      window.focus();
    }
  });

  registered = true;
  if (ok) {
    log.info('Global shortcuts registered', { shortcuts: Object.values(SHORTCUTS) });
  } else {
    log.error('Failed to register global shortcuts');
  }
}

export function unregisterGlobalShortcuts(): void {
  if (!registered) {
    return;
  }
  globalShortcut.unregisterAll();
  registered = false;
  log.info('Global shortcuts unregistered');
}
