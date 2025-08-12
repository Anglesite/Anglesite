/**
 * @file Application menu creation
 */
import { Menu, MenuItemConstructorOptions, shell, WebContents, BrowserWindow } from 'electron';
import { getCurrentLiveServerUrl } from '../server/eleventy';
import { openSettingsWindow } from './window-manager';
import { getAllWebsiteWindows, getHelpWindow } from './multi-window-manager';

/**
 * Check if the current focused window is a website window.
 */
function isWebsiteWindowFocused(): boolean {
  const focusedWindow = BrowserWindow.getFocusedWindow();
  if (!focusedWindow) return false;

  // Check if this window is in our website windows map
  const websiteWindows = getAllWebsiteWindows();
  for (const [, websiteWindow] of websiteWindows) {
    if (websiteWindow.window === focusedWindow) {
      return true;
    }
  }
  return false;
}

/**
 * Build a list of open windows for the Window menu.
 */
export function buildWindowList(): MenuItemConstructorOptions[] {
  const windowMenuItems: MenuItemConstructorOptions[] = [];
  const focusedWindow = BrowserWindow.getFocusedWindow();

  // Add help window
  const helpWindow = getHelpWindow();
  if (helpWindow && !helpWindow.isDestroyed()) {
    windowMenuItems.push({
      label: helpWindow.getTitle(),
      type: 'checkbox',
      checked: helpWindow === focusedWindow,
      click: () => {
        helpWindow.focus();
      },
    });
  }

  // Add website windows
  const websiteWindows = getAllWebsiteWindows();
  websiteWindows.forEach((websiteWindow) => {
    if (!websiteWindow.window.isDestroyed()) {
      const isChecked = websiteWindow.window === focusedWindow;
      windowMenuItems.push({
        label: websiteWindow.window.getTitle(),
        type: 'checkbox',
        checked: isChecked,
        click: () => {
          websiteWindow.window.focus();
        },
      });
    }
  });

  // If no windows are open, show a disabled item
  if (windowMenuItems.length === 0) {
    windowMenuItems.push({
      label: 'No Windows Open',
      enabled: false,
    });
  }

  return windowMenuItems;
}

/**
 * Update the application menu when window focus changes.
 */
export function updateApplicationMenu(): void {
  const menu = createApplicationMenu();
  Menu.setApplicationMenu(menu);
}

/**
 * Constructs the complete application menu structure with all submenus and menu items.
 */
export function createApplicationMenu(): Menu {
  const template: MenuItemConstructorOptions[] = [
    {
      label: 'Anglesite',
      submenu: [
        {
          label: 'About Anglesite',
          role: 'about',
        },
        {
          type: 'separator',
        },
        {
          label: 'Settings...',
          accelerator: 'CmdOrCtrl+,',
          click: () => {
            openSettingsWindow();
          },
        },
        {
          type: 'separator',
        },
        {
          label: 'Services',
          role: 'services',
          submenu: [],
        },
        {
          type: 'separator',
        },
        {
          label: 'Hide Anglesite',
          accelerator: 'Command+H',
          role: 'hide',
        },
        {
          label: 'Hide Others',
          accelerator: 'Command+Shift+H',
          role: 'hideOthers',
        },
        {
          label: 'Show All',
          role: 'unhide',
        },
        {
          type: 'separator',
        },
        {
          label: 'Quit',
          accelerator: 'CmdOrCtrl+Q',
          role: 'quit',
        },
      ],
    },
    {
      label: 'File',
      submenu: [
        {
          label: 'New Website...',
          accelerator: 'CmdOrCtrl+N',
          click: async () => {
            // Use the IPC handler which has the proper implementation
            const focusedWindow = BrowserWindow.getFocusedWindow();
            if (focusedWindow) {
              focusedWindow.webContents.send('trigger-new-website');
            }
          },
        },
        {
          label: 'Open Website…',
          accelerator: 'CmdOrCtrl+Shift+O',
          click: async () => {
            const { openWebsiteSelectionWindow } = await import('./window-manager');
            openWebsiteSelectionWindow();
          },
        },
        {
          type: 'separator',
        },
        {
          label: 'Export To',
          enabled: isWebsiteWindowFocused(),
          submenu: [
            {
              label: 'Folder…',
              accelerator: 'CmdOrCtrl+E',
              click: async () => {
                const { exportSiteHandler } = await import('../ipc/handlers');
                await exportSiteHandler(null, false);
              },
            },
            {
              label: 'Zip Archive…',
              accelerator: 'CmdOrCtrl+Shift+E',
              click: async () => {
                const { exportSiteHandler } = await import('../ipc/handlers');
                await exportSiteHandler(null, true);
              },
            },
            {
              label: 'BagIt Archive…',
              accelerator: 'CmdOrCtrl+Alt+E',
              click: async () => {
                const { exportSiteHandler } = await import('../ipc/handlers');
                await exportSiteHandler(null, 'bagit');
              },
            },
          ],
        },
      ],
    },
    {
      label: 'Edit',
      submenu: [
        {
          label: 'Undo',
          accelerator: 'CmdOrCtrl+Z',
          role: 'undo',
        },
        {
          label: 'Redo',
          accelerator: 'Shift+CmdOrCtrl+Z',
          role: 'redo',
        },
        {
          type: 'separator',
        },
        {
          label: 'Cut',
          accelerator: 'CmdOrCtrl+X',
          role: 'cut',
        },
        {
          label: 'Copy',
          accelerator: 'CmdOrCtrl+C',
          role: 'copy',
        },
        {
          label: 'Paste',
          accelerator: 'CmdOrCtrl+V',
          role: 'paste',
        },
        {
          label: 'Select All',
          accelerator: 'CmdOrCtrl+A',
          role: 'selectAll',
        },
      ],
    },
    {
      label: 'View',
      submenu: [
        {
          label: 'Reload',
          accelerator: 'CmdOrCtrl+R',
          click: (menuItem, browserWindow) => {
            if (browserWindow && 'webContents' in browserWindow) {
              (browserWindow.webContents as WebContents).send('reload-preview');
            }
          },
        },
        {
          label: 'Force Reload',
          accelerator: 'CmdOrCtrl+Shift+R',
          click: (menuItem, browserWindow) => {
            if (browserWindow && 'webContents' in browserWindow) {
              (browserWindow.webContents as WebContents).reloadIgnoringCache();
            }
          },
        },
        {
          label: 'Toggle Developer Tools',
          accelerator: 'F12',
          click: (menuItem, browserWindow) => {
            if (browserWindow && 'webContents' in browserWindow) {
              (browserWindow.webContents as WebContents).send('menu-toggle-devtools');
            }
          },
        },
        {
          type: 'separator',
        },
        {
          label: 'Actual Size',
          accelerator: 'CmdOrCtrl+0',
          role: 'resetZoom',
        },
        {
          label: 'Zoom In',
          accelerator: 'CmdOrCtrl+Plus',
          role: 'zoomIn',
        },
        {
          label: 'Zoom Out',
          accelerator: 'CmdOrCtrl+-',
          role: 'zoomOut',
        },
        {
          type: 'separator',
        },
        {
          label: 'Toggle Fullscreen',
          accelerator: 'Ctrl+Command+F',
          role: 'togglefullscreen',
        },
      ],
    },
    {
      label: 'Server',
      submenu: [
        {
          label: 'Open in Browser',
          accelerator: 'CmdOrCtrl+Shift+O',
          click: async () => {
            try {
              await shell.openExternal(getCurrentLiveServerUrl());
            } catch {
              console.log('Failed to open .test domain, trying localhost');
              const localhostUrl = getCurrentLiveServerUrl().replace(/https:\/\/[^.]+\.test:/, 'https://localhost:');
              try {
                await shell.openExternal(localhostUrl);
              } catch (fallbackError) {
                console.error('Failed to open in browser:', fallbackError);
              }
            }
          },
        },
        {
          label: 'Copy Server URL',
          click: async (menuItem, browserWindow) => {
            if (browserWindow && 'webContents' in browserWindow) {
              const { clipboard } = await import('electron');
              clipboard.writeText(getCurrentLiveServerUrl());
            }
          },
        },
        {
          type: 'separator',
        },
        {
          label: 'Restart Server',
          accelerator: 'CmdOrCtrl+Shift+R',
          click: (menuItem, browserWindow) => {
            if (browserWindow && 'webContents' in browserWindow) {
              (browserWindow.webContents as WebContents).send('restart-server');
            }
          },
        },
      ],
    },
    {
      label: 'Window',
      submenu: [
        {
          label: 'Minimize',
          accelerator: 'CmdOrCtrl+M',
          role: 'minimize',
        },
        {
          label: 'Close',
          accelerator: 'CmdOrCtrl+W',
          role: 'close',
        },
        {
          type: 'separator',
        },
        {
          label: 'Merge All Windows',
          click: () => {
            const focusedWindow = BrowserWindow.getFocusedWindow();
            if (focusedWindow) {
              focusedWindow.mergeAllWindows();
            }
          },
        },
        {
          label: 'Move Tab to New Window',
          click: () => {
            const focusedWindow = BrowserWindow.getFocusedWindow();
            if (focusedWindow) {
              focusedWindow.moveTabToNewWindow();
            }
          },
        },
        {
          type: 'separator',
        },
        {
          label: 'Bring All to Front',
          role: 'front',
        },
        {
          type: 'separator',
        },
        ...buildWindowList(),
      ],
    },
    {
      label: 'Help',
      submenu: [
        {
          label: 'Anglesite Help',
          click: async () => {
            const { createHelpWindow } = await import('./multi-window-manager');
            createHelpWindow();
          },
        },
        {
          type: 'separator',
        },
        {
          label: 'Report Issue',
          click: async () => {
            await shell.openExternal('https://github.com/anglesite/anglesite/issues');
          },
        },
      ],
    },
  ];

  return Menu.buildFromTemplate(template);
}
