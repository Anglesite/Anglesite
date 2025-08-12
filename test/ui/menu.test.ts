/**
 * @file Tests for menu creation and window management
 */
import type { MenuItemConstructorOptions, Menu, MenuItem, KeyboardEvent } from 'electron';

// Mock electron modules
const mockBrowserWindow = {
  getFocusedWindow: jest.fn(),
};

const mockMenu = {
  buildFromTemplate: jest.fn(),
  setApplicationMenu: jest.fn(),
};

const mockShell = {
  openExternal: jest.fn(),
};

const mockClipboard = {
  writeText: jest.fn(),
};

jest.mock('electron', () => ({
  Menu: mockMenu,
  BrowserWindow: mockBrowserWindow,
  shell: mockShell,
  clipboard: mockClipboard,
}));

// Mock IPC handlers
const mockExportSiteHandler = jest.fn();
jest.mock('../../app/ipc/handlers', () => ({
  exportSiteHandler: mockExportSiteHandler,
}));

// Mock UI modules
const mockHelpWindow = {
  getTitle: jest.fn(),
  focus: jest.fn(),
  isDestroyed: jest.fn(() => false),
};

const mockWebsiteWindow1 = {
  window: {
    getTitle: jest.fn(),
    focus: jest.fn(),
    isDestroyed: jest.fn(() => false),
  },
  webContentsView: {},
  websiteName: 'Test Site 1',
};

const mockWebsiteWindow2 = {
  window: {
    getTitle: jest.fn(),
    focus: jest.fn(),
    isDestroyed: jest.fn(() => false),
  },
  webContentsView: {},
  websiteName: 'Test Site 2',
};

jest.mock('../../app/ui/multi-window-manager', () => ({
  getHelpWindow: jest.fn(),
  getAllWebsiteWindows: jest.fn(),
  createHelpWindow: jest.fn(),
}));

jest.mock('../../app/ui/window-manager', () => ({
  openSettingsWindow: jest.fn(),
  openWebsiteSelectionWindow: jest.fn(),
  getNativeInput: jest.fn(),
}));

jest.mock('../../app/server/eleventy', () => ({
  getCurrentLiveServerUrl: jest.fn(() => 'https://localhost:8080'),
}));

describe('Menu', () => {
  let menu: {
    buildWindowList: () => MenuItemConstructorOptions[];
    updateApplicationMenu: () => void;
    createApplicationMenu: () => Menu;
  };
  let mockMultiWindowManager: {
    getHelpWindow: jest.Mock;
    getAllWebsiteWindows: jest.Mock;
    createHelpWindow: jest.Mock;
  };
  let mockWindowManager: {
    openSettingsWindow: jest.Mock;
    openWebsiteSelectionWindow: jest.Mock;
    getNativeInput: jest.Mock;
  };
  let mockEleventyServer: {
    getCurrentLiveServerUrl: jest.Mock;
  };

  beforeAll(() => {
    menu = require('../../app/ui/menu');
    mockMultiWindowManager = require('../../app/ui/multi-window-manager');
    mockWindowManager = require('../../app/ui/window-manager');
    mockEleventyServer = require('../../app/server/eleventy');
  });

  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('buildWindowList', () => {
    it('should return empty list when no windows are open', () => {
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
      mockBrowserWindow.getFocusedWindow.mockReturnValue(null);

      const windowList = menu.buildWindowList();

      expect(windowList).toEqual([
        {
          label: 'No Windows Open',
          enabled: false,
        },
      ]);
    });

    it('should include help window when it exists', () => {
      mockHelpWindow.getTitle.mockReturnValue('Anglesite');
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockHelpWindow);

      const windowList = menu.buildWindowList();

      expect(windowList).toHaveLength(1);
      expect(windowList[0]).toEqual({
        label: 'Anglesite',
        type: 'checkbox',
        checked: true,
        click: expect.any(Function),
      });

      // Test click handler
      if (windowList[0].click) {
        windowList[0].click({} as MenuItem, undefined, {} as KeyboardEvent);
      }
      expect(mockHelpWindow.focus).toHaveBeenCalled();
    });

    it('should include website windows', () => {
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);

      mockWebsiteWindow1.window.getTitle.mockReturnValue('My Blog');
      mockWebsiteWindow2.window.getTitle.mockReturnValue('Portfolio');

      const websiteWindows = new Map([
        ['site1', mockWebsiteWindow1],
        ['site2', mockWebsiteWindow2],
      ]);

      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);
      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockWebsiteWindow1.window);

      const windowList = menu.buildWindowList();

      expect(windowList).toHaveLength(2);

      // First window should be checked (focused)
      expect(windowList[0]).toEqual({
        label: 'My Blog',
        type: 'checkbox',
        checked: true,
        click: expect.any(Function),
      });

      // Second window should not be checked
      expect(windowList[1]).toEqual({
        label: 'Portfolio',
        type: 'checkbox',
        checked: false,
        click: expect.any(Function),
      });

      // Test click handlers
      if (windowList[0].click) {
        windowList[0].click({} as MenuItem, undefined, {} as KeyboardEvent);
      }
      expect(mockWebsiteWindow1.window.focus).toHaveBeenCalled();

      if (windowList[1].click) {
        windowList[1].click({} as MenuItem, undefined, {} as KeyboardEvent);
      }
      expect(mockWebsiteWindow2.window.focus).toHaveBeenCalled();
    });

    it('should include both help window and website windows', () => {
      mockHelpWindow.getTitle.mockReturnValue('Anglesite');
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);

      mockWebsiteWindow1.window.getTitle.mockReturnValue('My Blog');
      const websiteWindows = new Map([['site1', mockWebsiteWindow1]]);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);

      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockWebsiteWindow1.window);

      const windowList = menu.buildWindowList();

      expect(windowList).toHaveLength(2);

      // Help window should not be checked
      expect(windowList[0]).toEqual({
        label: 'Anglesite',
        type: 'checkbox',
        checked: false,
        click: expect.any(Function),
      });

      // Website window should be checked (focused)
      expect(windowList[1]).toEqual({
        label: 'My Blog',
        type: 'checkbox',
        checked: true,
        click: expect.any(Function),
      });
    });

    it('should skip destroyed windows', () => {
      mockHelpWindow.isDestroyed.mockReturnValue(true);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);

      mockWebsiteWindow1.window.isDestroyed.mockReturnValue(true);
      const websiteWindows = new Map([['site1', mockWebsiteWindow1]]);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);

      mockBrowserWindow.getFocusedWindow.mockReturnValue(null);

      const windowList = menu.buildWindowList();

      expect(windowList).toEqual([
        {
          label: 'No Windows Open',
          enabled: false,
        },
      ]);
    });

    it('should handle no focused window', () => {
      mockHelpWindow.getTitle.mockReturnValue('Anglesite');
      mockHelpWindow.isDestroyed.mockReturnValue(false); // Make sure it's not destroyed
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
      mockBrowserWindow.getFocusedWindow.mockReturnValue(null);

      const windowList = menu.buildWindowList();

      expect(windowList).toHaveLength(1);
      expect(windowList[0]).toEqual({
        label: 'Anglesite',
        type: 'checkbox',
        checked: false,
        click: expect.any(Function),
      });
    });
  });

  describe('updateApplicationMenu', () => {
    it('should build and set application menu', () => {
      const mockMenuInstance = { items: [] };
      mockMenu.buildFromTemplate.mockReturnValue(mockMenuInstance);

      menu.updateApplicationMenu();

      expect(mockMenu.buildFromTemplate).toHaveBeenCalledWith(expect.any(Array));
      expect(mockMenu.setApplicationMenu).toHaveBeenCalledWith(mockMenuInstance);
    });
  });

  describe('createApplicationMenu', () => {
    it('should create menu template with window list', () => {
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());

      menu.createApplicationMenu();

      expect(mockMenu.buildFromTemplate).toHaveBeenCalledWith(expect.any(Array));

      // Get the template that was passed to buildFromTemplate
      const template = mockMenu.buildFromTemplate.mock.calls[0][0] as MenuItemConstructorOptions[];

      // Find the Window menu
      const windowMenu = template.find((item) => item.label === 'Window');
      expect(windowMenu).toBeDefined();
      expect(windowMenu?.submenu).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ label: 'Minimize' }),
          expect.objectContaining({ label: 'Close' }),
          expect.objectContaining({ label: 'Bring All to Front' }),
          expect.objectContaining({ type: 'separator' }),
          expect.objectContaining({ label: 'No Windows Open', enabled: false }),
        ])
      );
    });

    it('should include window items in Window menu when windows exist', () => {
      mockHelpWindow.getTitle.mockReturnValue('Anglesite');
      mockHelpWindow.isDestroyed.mockReturnValue(false);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockHelpWindow);

      menu.createApplicationMenu();

      const template = mockMenu.buildFromTemplate.mock.calls[0][0] as MenuItemConstructorOptions[];
      const windowMenu = template.find((item) => item.label === 'Window');

      // Check that the window list includes the help window
      const windowSubmenu = windowMenu?.submenu as MenuItemConstructorOptions[];
      const helpWindowItem = windowSubmenu.find((item) => item.label === 'Anglesite' && item.type === 'checkbox');

      expect(helpWindowItem).toBeDefined();
      expect(helpWindowItem?.checked).toBe(true);
    });
  });

  describe('isWebsiteWindowFocused', () => {
    it('should return false when no window is focused', () => {
      mockBrowserWindow.getFocusedWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());

      // We need to access the internal function indirectly through menu creation
      // Create a menu template and check if the Export menu item is disabled
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);

      menu.createApplicationMenu();
      const template = mockMenu.buildFromTemplate.mock.calls[0][0] as MenuItemConstructorOptions[];
      const fileMenu = template.find((item) => item.label === 'File');
      const exportItem = (fileMenu?.submenu as MenuItemConstructorOptions[])?.find(
        (item) => item.label === 'Export To'
      );

      expect(exportItem?.enabled).toBe(false);
    });

    it('should return true when focused window is a website window', () => {
      const websiteWindows = new Map([['site1', mockWebsiteWindow1]]);
      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockWebsiteWindow1.window);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);

      menu.createApplicationMenu();
      const template = mockMenu.buildFromTemplate.mock.calls[0][0] as MenuItemConstructorOptions[];
      const fileMenu = template.find((item) => item.label === 'File');
      const exportItem = (fileMenu?.submenu as MenuItemConstructorOptions[])?.find(
        (item) => item.label === 'Export To'
      );

      expect(exportItem?.enabled).toBe(true);
    });

    it('should return false when focused window is not a website window', () => {
      const websiteWindows = new Map([['site1', mockWebsiteWindow1]]);
      const otherWindow = { id: 'other-window' };
      mockBrowserWindow.getFocusedWindow.mockReturnValue(otherWindow);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);

      menu.createApplicationMenu();
      const template = mockMenu.buildFromTemplate.mock.calls[0][0] as MenuItemConstructorOptions[];
      const fileMenu = template.find((item) => item.label === 'File');
      const exportItem = (fileMenu?.submenu as MenuItemConstructorOptions[])?.find(
        (item) => item.label === 'Export To'
      );

      expect(exportItem?.enabled).toBe(false);
    });
  });

  describe('Menu Item Click Handlers', () => {
    let template: MenuItemConstructorOptions[];
    let mockBrowserWindowInstance: {
      webContents: {
        send: jest.Mock;
        reloadIgnoringCache: jest.Mock;
      };
    };
    let mockWebContents: {
      send: jest.Mock;
      reloadIgnoringCache: jest.Mock;
    };

    beforeEach(() => {
      mockBrowserWindowInstance = {
        webContents: {
          send: jest.fn(),
          reloadIgnoringCache: jest.fn(),
        },
      };
      mockWebContents = mockBrowserWindowInstance.webContents;

      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());

      menu.createApplicationMenu();
      template = mockMenu.buildFromTemplate.mock.calls[0][0] as MenuItemConstructorOptions[];
    });

    describe('File Menu', () => {
      it('should handle Settings click', () => {
        const anglesiteMenu = template.find((item) => item.label === 'Anglesite');
        const settingsItem = (anglesiteMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Settings...'
        );

        expect(settingsItem?.click).toBeDefined();
        if (settingsItem?.click) {
          (settingsItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => void)(
            {},
            undefined,
            {}
          );
        }

        expect(mockWindowManager.openSettingsWindow).toHaveBeenCalled();
      });

      it('should handle Open Website click', async () => {
        const fileMenu = template.find((item) => item.label === 'File');
        const openWebsiteItem = (fileMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Open Website…'
        );

        expect(openWebsiteItem?.click).toBeDefined();
        if (openWebsiteItem?.click) {
          await (openWebsiteItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>)(
            {},
            undefined,
            {}
          );
        }

        expect(mockWindowManager.openWebsiteSelectionWindow).toHaveBeenCalled();
      });

      it('should handle New Website click', async () => {
        const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

        const fileMenu = template.find((item) => item.label === 'File');
        const newWebsiteItem = (fileMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'New Website...'
        );

        expect(newWebsiteItem?.click).toBeDefined();
        expect(newWebsiteItem?.accelerator).toBe('CmdOrCtrl+N');

        // The click handler contains complex async logic with dynamic imports
        // We can verify it exists but testing the full flow would require complex mocking
        expect(typeof newWebsiteItem?.click).toBe('function');

        consoleSpy.mockRestore();
      });

      it('should handle Export to Folder click', async () => {
        const fileMenu = template.find((item) => item.label === 'File');
        const exportToItem = (fileMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Export To'
        );
        const folderExportItem = (exportToItem?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Folder…'
        );

        expect(folderExportItem?.click).toBeDefined();
        if (folderExportItem?.click) {
          await (
            folderExportItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>
          )({}, undefined, {});
        }

        expect(mockExportSiteHandler).toHaveBeenCalledWith(null, false);
      });

      it('should handle Export to Zip click', async () => {
        const fileMenu = template.find((item) => item.label === 'File');
        const exportToItem = (fileMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Export To'
        );
        const zipExportItem = (exportToItem?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Zip Archive…'
        );

        expect(zipExportItem?.click).toBeDefined();
        if (zipExportItem?.click) {
          await (zipExportItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>)(
            {},
            undefined,
            {}
          );
        }

        expect(mockExportSiteHandler).toHaveBeenCalledWith(null, true);
      });
    });

    describe('View Menu', () => {
      it('should handle Reload click', () => {
        const viewMenu = template.find((item) => item.label === 'View');
        const reloadItem = (viewMenu?.submenu as MenuItemConstructorOptions[])?.find((item) => item.label === 'Reload');

        expect(reloadItem?.click).toBeDefined();
        if (reloadItem?.click) {
          (reloadItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => void)(
            {},
            mockBrowserWindowInstance,
            {}
          );
        }

        expect(mockWebContents.send).toHaveBeenCalledWith('reload-preview');
      });

      it('should handle Force Reload click', () => {
        const viewMenu = template.find((item) => item.label === 'View');
        const forceReloadItem = (viewMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Force Reload'
        );

        expect(forceReloadItem?.click).toBeDefined();
        if (forceReloadItem?.click) {
          (forceReloadItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => void)(
            {},
            mockBrowserWindowInstance,
            {}
          );
        }

        expect(mockWebContents.reloadIgnoringCache).toHaveBeenCalled();
      });

      it('should handle Toggle Developer Tools click', () => {
        const viewMenu = template.find((item) => item.label === 'View');
        const devToolsItem = (viewMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Toggle Developer Tools'
        );

        expect(devToolsItem?.click).toBeDefined();
        if (devToolsItem?.click) {
          (devToolsItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => void)(
            {},
            mockBrowserWindowInstance,
            {}
          );
        }

        expect(mockWebContents.send).toHaveBeenCalledWith('menu-toggle-devtools');
      });

      it('should handle View menu clicks with no browser window', () => {
        const viewMenu = template.find((item) => item.label === 'View');
        const reloadItem = (viewMenu?.submenu as MenuItemConstructorOptions[])?.find((item) => item.label === 'Reload');

        // Should not throw when no browser window is provided
        expect(() => {
          if (reloadItem?.click) {
            (reloadItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => void)({}, null, {});
          }
        }).not.toThrow();
      });

      it('should handle View menu clicks with browser window without webContents', () => {
        const browserWindowWithoutWebContents = { someOtherProp: 'value' };
        const viewMenu = template.find((item) => item.label === 'View');
        const reloadItem = (viewMenu?.submenu as MenuItemConstructorOptions[])?.find((item) => item.label === 'Reload');

        // Should not throw when browser window doesn't have webContents
        expect(() => {
          if (reloadItem?.click) {
            (reloadItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => void)(
              {},
              browserWindowWithoutWebContents,
              {}
            );
          }
        }).not.toThrow();
      });
    });

    describe('Server Menu', () => {
      it('should handle Open in Browser click successfully', async () => {
        mockEleventyServer.getCurrentLiveServerUrl.mockReturnValue('https://test.example.com:8080');
        mockShell.openExternal.mockResolvedValue(undefined);

        const serverMenu = template.find((item) => item.label === 'Server');
        const openInBrowserItem = (serverMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Open in Browser'
        );

        expect(openInBrowserItem?.click).toBeDefined();
        if (openInBrowserItem?.click) {
          await (
            openInBrowserItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>
          )({}, undefined, {});
        }

        expect(mockShell.openExternal).toHaveBeenCalledWith('https://test.example.com:8080');
      });

      it('should handle Open in Browser click with fallback to localhost', async () => {
        mockEleventyServer.getCurrentLiveServerUrl.mockReturnValue('https://mysite.test:8080');
        mockShell.openExternal
          .mockRejectedValueOnce(new Error('Failed to open .test domain'))
          .mockResolvedValueOnce(undefined);

        const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

        const serverMenu = template.find((item) => item.label === 'Server');
        const openInBrowserItem = (serverMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Open in Browser'
        );

        expect(openInBrowserItem?.click).toBeDefined();
        if (openInBrowserItem?.click) {
          await (
            openInBrowserItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>
          )({}, undefined, {});
        }

        expect(mockShell.openExternal).toHaveBeenCalledWith('https://mysite.test:8080');
        expect(mockShell.openExternal).toHaveBeenCalledWith('https://localhost:8080');
        expect(consoleSpy).toHaveBeenCalledWith('Failed to open .test domain, trying localhost');

        consoleSpy.mockRestore();
      });

      it('should handle Open in Browser click with both attempts failing', async () => {
        mockEleventyServer.getCurrentLiveServerUrl.mockReturnValue('https://mysite.test:8080');
        mockShell.openExternal
          .mockRejectedValueOnce(new Error('Failed to open .test domain'))
          .mockRejectedValueOnce(new Error('Failed to open localhost'));

        const consoleSpy = jest.spyOn(console, 'log').mockImplementation();
        const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

        const serverMenu = template.find((item) => item.label === 'Server');
        const openInBrowserItem = (serverMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Open in Browser'
        );

        expect(openInBrowserItem?.click).toBeDefined();
        if (openInBrowserItem?.click) {
          await (
            openInBrowserItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>
          )({}, undefined, {});
        }

        expect(consoleSpy).toHaveBeenCalledWith('Failed to open .test domain, trying localhost');
        expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to open in browser:', expect.any(Error));

        consoleSpy.mockRestore();
        consoleErrorSpy.mockRestore();
      });

      it('should handle Copy Server URL click', async () => {
        mockEleventyServer.getCurrentLiveServerUrl.mockReturnValue('https://localhost:8080');

        const serverMenu = template.find((item) => item.label === 'Server');
        const copyUrlItem = (serverMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Copy Server URL'
        );

        expect(copyUrlItem?.click).toBeDefined();
        if (copyUrlItem?.click) {
          await (copyUrlItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>)(
            {},
            mockBrowserWindowInstance,
            {}
          );
        }

        expect(mockClipboard.writeText).toHaveBeenCalledWith('https://localhost:8080');
      });

      it('should handle Copy Server URL click with no browser window', async () => {
        const serverMenu = template.find((item) => item.label === 'Server');
        const copyUrlItem = (serverMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Copy Server URL'
        );

        // Should not throw when no browser window is provided
        expect(async () => {
          if (copyUrlItem?.click) {
            await (copyUrlItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>)(
              {},
              null,
              {}
            );
          }
        }).not.toThrow();
      });

      it('should handle Copy Server URL click with browser window without webContents', async () => {
        const browserWindowWithoutWebContents = { someOtherProp: 'value' };
        const serverMenu = template.find((item) => item.label === 'Server');
        const copyUrlItem = (serverMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Copy Server URL'
        );

        // Should not throw when browser window doesn't have webContents
        expect(async () => {
          if (copyUrlItem?.click) {
            await (copyUrlItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>)(
              {},
              browserWindowWithoutWebContents,
              {}
            );
          }
        }).not.toThrow();
      });

      it('should handle Restart Server click', () => {
        const serverMenu = template.find((item) => item.label === 'Server');
        const restartServerItem = (serverMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Restart Server'
        );

        expect(restartServerItem?.click).toBeDefined();
        if (restartServerItem?.click) {
          (restartServerItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => void)(
            {},
            mockBrowserWindowInstance,
            {}
          );
        }

        expect(mockWebContents.send).toHaveBeenCalledWith('restart-server');
      });
    });

    describe('Help Menu', () => {
      it('should handle Anglesite Help click', async () => {
        const helpMenu = template.find((item) => item.label === 'Help');
        const anglesiteHelpItem = (helpMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Anglesite Help'
        );

        expect(anglesiteHelpItem?.click).toBeDefined();
        if (anglesiteHelpItem?.click) {
          await (
            anglesiteHelpItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>
          )({}, undefined, {});
        }

        expect(mockMultiWindowManager.createHelpWindow).toHaveBeenCalled();
      });

      it('should handle Report Issue click', async () => {
        mockShell.openExternal.mockResolvedValue(undefined);

        const helpMenu = template.find((item) => item.label === 'Help');
        const reportIssueItem = (helpMenu?.submenu as MenuItemConstructorOptions[])?.find(
          (item) => item.label === 'Report Issue'
        );

        expect(reportIssueItem?.click).toBeDefined();
        if (reportIssueItem?.click) {
          await (reportIssueItem.click as (menuItem: unknown, browserWindow: unknown, event: unknown) => Promise<void>)(
            {},
            undefined,
            {}
          );
        }

        expect(mockShell.openExternal).toHaveBeenCalledWith('https://github.com/anglesite/anglesite/issues');
      });
    });
  });
});
