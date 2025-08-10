/**
 * @file Application menu creation
 */
import { Menu, MenuItemConstructorOptions, shell, WebContents, BrowserWindow } from 'electron';
import { getCurrentLiveServerUrl } from '../server/eleventy';
import { openSettingsWindow } from './window-manager';
import { getAllWebsiteWindows, getHelpWindow } from './multi-window-manager';

/**
 * Check if the current focused window is a website window
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
 * Build a list of open windows for the Window menu
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
 * Update the application menu when window focus changes
 */
export function updateApplicationMenu(): void {
  const menu = createApplicationMenu();
  Menu.setApplicationMenu(menu);
}

/**
 * Create the application menu
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
            console.log('DEBUG: New Website menu clicked - calling getNativeInput directly');
            try {
              const { getNativeInput } = await import('./window-manager');
              const websiteName = await getNativeInput('New Website', 'Enter a name for your new website:');

              if (websiteName && websiteName.trim()) {
                console.log('DEBUG: User entered website name:', websiteName.trim());
                const { createWebsiteWithName } = await import('../utils/website-manager');

                // Create the website
                const websitePath = await createWebsiteWithName(websiteName.trim());
                console.log('DEBUG: Website created at:', websitePath);

                // Import and call the function that handles opening websites
                // This replicates the logic from IPC handlers openWebsiteInNewWindow
                const { createWebsiteWindow, loadWebsiteContent } = await import('../ui/multi-window-manager');
                const { switchToWebsite } = await import('../server/eleventy');
                const { addLocalDnsResolution } = await import('../dns/hosts-manager');
                const { restartHttpsProxy } = await import('../server/https-proxy');
                const { Store } = await import('../store');

                console.log('DEBUG: Opening website in new window');

                // Create a new window for this website
                createWebsiteWindow(websiteName.trim(), websitePath);

                // Switch to the selected website
                await switchToWebsite(websitePath);

                // Generate test domain and setup DNS
                const hostname = `${websiteName.trim()}.test`;
                await addLocalDnsResolution(hostname);

                // Check user's HTTPS preference
                const store = new Store();
                const httpsMode = store.get('httpsMode');

                if (httpsMode === 'https') {
                  // Start HTTPS proxy for the domain
                  const httpsProxySuccess = await restartHttpsProxy(8080, 8081, hostname);
                  if (httpsProxySuccess) {
                    console.log('DEBUG: HTTPS proxy configured for:', hostname);
                  } else {
                    console.log('DEBUG: HTTPS proxy failed, using HTTP mode');
                  }
                } else {
                  console.log('DEBUG: HTTP-only mode by user preference, skipping HTTPS proxy');
                }

                // Load the website content in its window (after HTTPS proxy is ready)
                loadWebsiteContent(websiteName.trim());
                console.log('DEBUG: Website opened successfully');
              } else {
                console.log('DEBUG: User cancelled website creation');
              }
            } catch (error) {
              console.error('DEBUG: Error creating/opening website:', error);
            }
          },
        },
        {
          label: 'Open Website...',
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
          label: 'Open Website Folder...',
          accelerator: 'CmdOrCtrl+O',
          click: async () => {
            // TODO: Implement folder picker
            console.log('Open Website Folder clicked');
          },
        },
        {
          type: 'separator',
        },
        {
          label: 'Export Website...',
          accelerator: 'CmdOrCtrl+E',
          enabled: isWebsiteWindowFocused(),
          click: () => {
            // TODO: Implement export functionality
            console.log('Export Website clicked');
          },
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
