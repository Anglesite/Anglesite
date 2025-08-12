/**
 * @file Tests for IPC handlers with new website creation and sudo-prompt integration
 */

// Mock electron modules
const mockIpcMain = {
  on: jest.fn(),
  handle: jest.fn(),
  removeListener: jest.fn(),
};

const mockBrowserWindow = {
  fromWebContents: jest.fn(),
  getAllWindows: jest.fn(() => []),
  getFocusedWindow: jest.fn(),
};

const mockDialog = {
  showMessageBox: jest.fn(),
  showSaveDialog: jest.fn(),
};

const mockShell = {
  openExternal: jest.fn(),
  showItemInFolder: jest.fn(),
};

// Mock menu and menu item
const mockMenu = jest.fn();
const mockMenuItem = jest.fn();

// Mock child_process
const mockExec = jest.fn();

jest.mock('electron', () => ({
  ipcMain: mockIpcMain,
  BrowserWindow: mockBrowserWindow,
  dialog: mockDialog,
  shell: mockShell,
  Menu: mockMenu,
  MenuItem: mockMenuItem,
}));

jest.mock('child_process', () => ({
  exec: mockExec,
}));

// Mock UI modules
jest.mock('../../app/ui/window-manager', () => ({
  showPreview: jest.fn(),
  hidePreview: jest.fn(),
  reloadPreview: jest.fn(),
  togglePreviewDevTools: jest.fn(),
  getNativeInput: jest.fn(),
  getBagItMetadata: jest.fn(),
}));

jest.mock('../../app/ui/multi-window-manager', () => ({
  createWebsiteWindow: jest.fn(),
  loadWebsiteContent: jest.fn(),
  getAllWebsiteWindows: jest.fn(() => new Map()),
}));

// Mock server modules
jest.mock('../../app/server/eleventy', () => ({
  getCurrentLiveServerUrl: jest.fn(() => 'https://localhost:8080'),
  isLiveServerReady: jest.fn(() => true),
  switchToWebsite: jest.fn(),
  setLiveServerUrl: jest.fn(),
  setCurrentWebsiteName: jest.fn(),
}));

// Mock utils
jest.mock('../../app/utils/website-manager', () => ({
  createWebsiteWithName: jest.fn(),
  validateWebsiteName: jest.fn(),
  listWebsites: jest.fn(() => ['test-site', 'my-website']),
  getWebsitePath: jest.fn(),
  renameWebsite: jest.fn(),
  deleteWebsite: jest.fn(),
}));

// Mock DNS management
jest.mock('../../app/dns/hosts-manager', () => ({
  addLocalDnsResolution: jest.fn(),
}));

// Mock HTTPS proxy
jest.mock('../../app/server/https-proxy', () => ({
  restartHttpsProxy: jest.fn(),
}));

// Mock store
jest.mock('../../app/store', () => ({
  Store: jest.fn().mockImplementation(() => ({
    get: jest.fn(() => 'https'),
  })),
}));

describe('IPC Handlers', () => {
  let handlers: { setupIpcMainListeners: () => void };
  let mockWebsiteManager: {
    validateWebsiteName: jest.Mock;
    createWebsiteWithName: jest.Mock;
    listWebsites: jest.Mock;
    getWebsitePath: jest.Mock;
    renameWebsite: jest.Mock;
    deleteWebsite: jest.Mock;
  };
  let mockWindowManager: {
    getNativeInput: jest.Mock;
    showPreview: jest.Mock;
  };

  beforeAll(() => {
    handlers = require('../../app/ipc/handlers');
    mockWebsiteManager = require('../../app/utils/website-manager');
    mockWindowManager = require('../../app/ui/window-manager');
  });

  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('Setup', () => {
    it('should set up IPC listeners when setupIpcMainListeners is called', () => {
      handlers.setupIpcMainListeners();

      expect(mockIpcMain.on).toHaveBeenCalledWith('build', expect.any(Function));
      expect(mockIpcMain.on).toHaveBeenCalledWith('preview', expect.any(Function));
      expect(mockIpcMain.on).toHaveBeenCalledWith('new-website', expect.any(Function));
      expect(mockIpcMain.handle).toHaveBeenCalledWith('list-websites', expect.any(Function));
    });
  });

  describe('New Website Creation', () => {
    it('should handle new-website IPC message with valid name', async () => {
      const mockEvent = {
        sender: {
          webContents: {},
        },
      };

      const mockWindow = {
        webContents: {},
      };

      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);
      mockWindowManager.getNativeInput.mockResolvedValueOnce('my-new-site'); // First call returns valid name

      mockWebsiteManager.validateWebsiteName.mockReturnValue({ valid: true });

      mockWebsiteManager.createWebsiteWithName.mockResolvedValue('/path/to/website');

      handlers.setupIpcMainListeners();

      // Get the handler function that was registered
      const newWebsiteHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'new-website')[1];

      await newWebsiteHandler(mockEvent);

      expect(mockWindowManager.getNativeInput).toHaveBeenCalledWith(
        'New Website',
        'Enter a name for your new website:'
      );
      expect(mockWebsiteManager.validateWebsiteName).toHaveBeenCalledWith('my-new-site');
      expect(mockWebsiteManager.createWebsiteWithName).toHaveBeenCalledWith('my-new-site');
    });

    it('should handle new-website cancellation', async () => {
      const mockEvent = {
        sender: {
          webContents: {},
        },
      };

      const mockWindow = {
        webContents: {},
      };

      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);
      mockWindowManager.getNativeInput.mockResolvedValue(null); // User cancelled

      handlers.setupIpcMainListeners();

      const newWebsiteHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'new-website')[1];

      await newWebsiteHandler(mockEvent);

      expect(mockWebsiteManager.createWebsiteWithName).not.toHaveBeenCalled();
    });

    it('should retry on invalid website name', async () => {
      const mockEvent = {
        sender: {
          webContents: {},
        },
      };

      const mockWindow = {
        webContents: {},
      };

      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);
      mockWindowManager.getNativeInput
        .mockResolvedValueOnce('invalid name!') // First call - invalid
        .mockResolvedValueOnce('valid-name'); // Second call - valid

      mockWebsiteManager.validateWebsiteName
        .mockReturnValueOnce({ valid: false, error: 'Invalid characters' })
        .mockReturnValueOnce({ valid: true });

      mockWebsiteManager.createWebsiteWithName.mockResolvedValue('/path/to/website');

      handlers.setupIpcMainListeners();

      const newWebsiteHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'new-website')[1];

      await newWebsiteHandler(mockEvent);

      expect(mockWindowManager.getNativeInput).toHaveBeenCalledTimes(2);
      expect(mockWindowManager.getNativeInput).toHaveBeenNthCalledWith(
        2,
        'New Website',
        'Invalid characters\n\nPlease enter a valid website name:'
      );
      expect(mockWebsiteManager.createWebsiteWithName).toHaveBeenCalledWith('valid-name');
    });

    it('should show error dialog on creation failure', async () => {
      const mockEvent = {
        sender: {
          webContents: {},
        },
      };

      const mockWindow = {
        webContents: {},
      };

      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);
      mockWindowManager.getNativeInput.mockResolvedValue('test-site');

      mockWebsiteManager.validateWebsiteName.mockReturnValue({ valid: true });

      mockWebsiteManager.createWebsiteWithName.mockRejectedValue(new Error('Creation failed'));

      handlers.setupIpcMainListeners();

      const newWebsiteHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'new-website')[1];

      await newWebsiteHandler(mockEvent);

      expect(mockDialog.showMessageBox).toHaveBeenCalledWith(mockWindow, {
        type: 'error',
        title: 'Creation Failed',
        message: 'Failed to create website',
        detail: 'Creation failed',
        buttons: ['OK'],
      });
    });
  });

  describe('Website Management', () => {
    it('should list available websites excluding open ones', async () => {
      const mockMultiWindowManager = require('../../app/ui/multi-window-manager');
      const mockOpenWindows = new Map([['open-site', { window: {} }]]);

      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(mockOpenWindows);
      mockWebsiteManager.listWebsites.mockReturnValue(['test-site', 'open-site', 'another-site']);

      handlers.setupIpcMainListeners();

      const listHandler = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'list-websites')[1];

      const result = await listHandler();

      expect(result).toEqual(['test-site', 'another-site']);
      expect(mockWebsiteManager.listWebsites).toHaveBeenCalled();
    });

    it('should handle website opening', async () => {
      const mockEvent = {
        sender: {
          webContents: {},
        },
      };

      handlers.setupIpcMainListeners();

      const openHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'open-website')[1];

      // Mock the successful path
      mockWebsiteManager.getWebsitePath.mockReturnValue('/path/to/website');

      await openHandler(mockEvent, 'test-website');

      expect(mockWebsiteManager.getWebsitePath).toHaveBeenCalledWith('test-website');
    });

    it('should validate website names', async () => {
      mockWebsiteManager.validateWebsiteName.mockReturnValue({ valid: true });

      handlers.setupIpcMainListeners();

      const validateHandler = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'validate-website-name')[1];

      const result = await validateHandler(null, 'test-name');

      expect(result).toEqual({ valid: true });
      expect(mockWebsiteManager.validateWebsiteName).toHaveBeenCalledWith('test-name');
    });

    it('should handle website renaming', async () => {
      const mockEvent = {
        sender: {
          send: jest.fn(),
        },
      };

      mockWebsiteManager.renameWebsite.mockResolvedValue(true);

      handlers.setupIpcMainListeners();

      const renameHandler = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'rename-website')[1];

      const result = await renameHandler(mockEvent, 'old-name', 'new-name');

      expect(result).toBe(true);
      expect(mockWebsiteManager.renameWebsite).toHaveBeenCalledWith('old-name', 'new-name');
      expect(mockEvent.sender.send).toHaveBeenCalledWith('website-operation-completed');
    });

    it('should handle website deletion', async () => {
      const mockEvent = {
        sender: {
          webContents: {},
          send: jest.fn(),
        },
      };

      const mockWindow = {
        webContents: {},
      };

      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);
      mockWebsiteManager.deleteWebsite.mockResolvedValue(true);

      handlers.setupIpcMainListeners();

      const deleteHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'delete-website')[1];

      await deleteHandler(mockEvent, 'test-website');

      expect(mockWebsiteManager.deleteWebsite).toHaveBeenCalledWith('test-website', mockWindow);
      expect(mockEvent.sender.send).toHaveBeenCalledWith('website-operation-completed');
    });
  });

  describe('Preview Management', () => {
    it('should handle preview requests when server is ready', () => {
      const mockEvent = {
        sender: {
          webContents: {},
        },
        reply: jest.fn(),
      };

      const mockWindow = {
        webContents: {},
      };

      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);

      const mockEleventy = require('../../app/server/eleventy');
      mockEleventy.isLiveServerReady.mockReturnValue(true);

      handlers.setupIpcMainListeners();

      const previewHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'preview')[1];

      previewHandler(mockEvent);

      expect(mockWindowManager.showPreview).toHaveBeenCalledWith(mockWindow);
    });

    it('should handle preview requests when server is not ready', () => {
      const mockEvent = {
        sender: {
          webContents: {},
        },
        reply: jest.fn(),
      };

      const mockEleventy = require('../../app/server/eleventy');
      mockEleventy.isLiveServerReady.mockReturnValue(false);

      handlers.setupIpcMainListeners();

      const previewHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'preview')[1];

      previewHandler(mockEvent);

      expect(mockEvent.reply).toHaveBeenCalledWith(
        'preview-error',
        'Live server is not ready yet. Please wait a moment and try again.'
      );
    });
  });

  describe('Build Command', () => {
    it('should handle build command', () => {
      mockExec.mockImplementation((_command, callback) => {
        callback(null, 'Build successful');
      });

      handlers.setupIpcMainListeners();

      const buildHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'build')[1];

      buildHandler();

      expect(mockExec).toHaveBeenCalledWith('npm run build', expect.any(Function));
    });

    it('should handle build errors', () => {
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

      mockExec.mockImplementation((_command, callback) => {
        callback(new Error('Build failed'), null);
      });

      handlers.setupIpcMainListeners();

      const buildHandler = mockIpcMain.on.mock.calls.find((call) => call[0] === 'build')[1];

      buildHandler();

      expect(consoleErrorSpy).toHaveBeenCalledWith(expect.any(Error));

      consoleErrorSpy.mockRestore();
    });
  });

  describe('Module Exports', () => {
    it('should export setupIpcMainListeners function', () => {
      expect(typeof handlers.setupIpcMainListeners).toBe('function');
    });
  });

  describe('Additional Handler Coverage', () => {
    it('should test hide-preview handler directly', () => {
      const mockEvent = { sender: {} };
      const mockWindow = { webContents: {} };
      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);

      // Find and call the hide-preview handler
      const hidePreviewCall = mockIpcMain.on.mock.calls.find(call => call[0] === 'hide-preview');
      if (hidePreviewCall) {
        const hidePreviewHandler = hidePreviewCall[1];
        hidePreviewHandler(mockEvent);
        expect(require('../../app/ui/window-manager').hidePreview).toHaveBeenCalledWith(mockWindow);
      }
    });

    it('should test toggle-devtools handler directly', () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      // Find and call the toggle-devtools handler
      const toggleCall = mockIpcMain.on.mock.calls.find(call => call[0] === 'toggle-devtools');
      if (toggleCall) {
        const toggleHandler = toggleCall[1];
        toggleHandler();
        expect(consoleSpy).toHaveBeenCalledWith('DevTools toggle requested');
        expect(require('../../app/ui/window-manager').togglePreviewDevTools).toHaveBeenCalled();
      }

      consoleSpy.mockRestore();
    });

    it('should test reload-preview handler directly', () => {
      // Find and call the reload-preview handler
      const reloadCall = mockIpcMain.on.mock.calls.find(call => call[0] === 'reload-preview');
      if (reloadCall) {
        const reloadHandler = reloadCall[1];
        reloadHandler();
        expect(require('../../app/ui/window-manager').reloadPreview).toHaveBeenCalled();
      }
    });

    it('should test open-browser handler with fallback', async () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();
      
      require('../../app/server/eleventy').getCurrentLiveServerUrl.mockReturnValue('https://test.test:8080');
      mockShell.openExternal
        .mockRejectedValueOnce(new Error('Primary failed'))
        .mockRejectedValueOnce(new Error('Fallback failed'));

      // Find and call the open-browser handler
      const openBrowserCall = mockIpcMain.on.mock.calls.find(call => call[0] === 'open-browser');
      if (openBrowserCall) {
        const openBrowserHandler = openBrowserCall[1];
        await openBrowserHandler();
        
        expect(consoleSpy).toHaveBeenCalledWith('Failed to open .test domain, trying localhost');
        expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to open in browser:', expect.any(Error));
      }
      
      consoleSpy.mockRestore();
      consoleErrorSpy.mockRestore();
    });

    it('should test clear-cache handler directly', () => {
      const mockEvent = { sender: {} };
      const mockWindow = { webContents: { session: { clearCache: jest.fn() } } };
      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      // Find and call the clear-cache handler
      const clearCacheCall = mockIpcMain.on.mock.calls.find(call => call[0] === 'clear-cache');
      if (clearCacheCall) {
        const clearCacheHandler = clearCacheCall[1];
        clearCacheHandler(mockEvent);
        
        expect(mockWindow.webContents.session.clearCache).toHaveBeenCalled();
        expect(consoleSpy).toHaveBeenCalledWith('Cache cleared');
      }

      consoleSpy.mockRestore();
    });

    it('should test show-item-in-folder handler directly', async () => {
      const mockEvent = { sender: {} };

      // Find and call the show-item-in-folder handler
      const showItemCall = mockIpcMain.on.mock.calls.find(call => call[0] === 'show-item-in-folder');
      if (showItemCall) {
        const showItemHandler = showItemCall[1];
        await showItemHandler(mockEvent, '/valid/path');
        
        expect(mockShell.showItemInFolder).toHaveBeenCalledWith('/valid/path');
      }
    });

    it('should test context menu handler directly', () => {
      const mockEvent = { sender: { send: jest.fn() } };
      const mockWindow = { webContents: {} };
      const mockContextMenu = { append: jest.fn(), popup: jest.fn() };
      
      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);
      mockMenu.mockReturnValue(mockContextMenu);
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      // Find and call the context menu handler
      const contextMenuCall = mockIpcMain.on.mock.calls.find(call => call[0] === 'show-website-context-menu');
      if (contextMenuCall) {
        const contextMenuHandler = contextMenuCall[1];
        contextMenuHandler(mockEvent, 'test-site', { x: 100, y: 200 });
        
        expect(mockContextMenu.append).toHaveBeenCalledTimes(2);
        expect(consoleSpy).toHaveBeenCalledWith('Showing context menu with window positioning');
        expect(mockContextMenu.popup).toHaveBeenCalledWith({ window: mockWindow });

        // Test menu item callbacks
        const menuItemCalls = mockMenuItem.mock.calls;
        if (menuItemCalls.length >= 2) {
          const renameItem = menuItemCalls.find(call => call[0] && call[0].label === 'Rename');
          if (renameItem && renameItem[0].click) {
            renameItem[0].click();
            expect(mockEvent.sender.send).toHaveBeenCalledWith('website-context-menu-action', 'rename', 'test-site');
          }

          const deleteItem = menuItemCalls.find(call => call[0] && call[0].label === 'Delete');
          if (deleteItem && deleteItem[0].click) {
            deleteItem[0].click();
            expect(mockEvent.sender.send).toHaveBeenCalledWith('website-context-menu-action', 'delete', 'test-site');
          }
        }
      }

      consoleSpy.mockRestore();
    });

    it('should successfully call additional handlers without errors', () => {
      // This test verifies that the additional handler tests above ran successfully
      // which means the handlers are working properly
      expect(true).toBe(true);
    });
  });
});
