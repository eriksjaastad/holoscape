import { Menu, app, shell, BrowserWindow } from 'electron';
import type { MenuItemConstructorOptions, BaseWindow } from 'electron';
import { createLogger } from './services/logger';

const log = createLogger('Menu');

export function createAppMenu(): Menu {
  const template: MenuItemConstructorOptions[] = [
    {
      label: app.name,
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        {
          label: 'Preferences...',
          accelerator: 'Cmd+,',
          click: (_item, browserWindow: BaseWindow | undefined) => {
            log.info('Preferences clicked');
            const target = browserWindow instanceof BrowserWindow ? browserWindow : null;
            target?.webContents.send('preferences:open');
          },
        },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
      ],
    },
    {
      label: 'View',
      submenu: [
        { role: 'reload' },
        { role: 'forceReload' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
      ],
    },
    {
      label: 'Window',
      submenu: [
        { role: 'minimize' },
        { role: 'zoom' },
        { type: 'separator' },
        {
          label: 'Show/Hide Hologram',
          accelerator: 'Cmd+Shift+H',
          click: (_menuItem, browserWindow) => {
            if (browserWindow) {
              if (browserWindow.isVisible()) {
                browserWindow.hide();
              } else {
                browserWindow.show();
                browserWindow.focus();
              }
            }
          },
        },
        { type: 'separator' },
        { role: 'front' },
      ],
    },
    {
      label: 'Help',
      submenu: [
        {
          label: 'Learn More',
          click: () => {
            log.info('Learn More clicked');
            shell.openExternal('https://github.com/eriksjaastad/hologram');
          },
        },
      ],
    },
  ];

  return Menu.buildFromTemplate(template);
}
