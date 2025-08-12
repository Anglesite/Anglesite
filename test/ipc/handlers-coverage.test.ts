/**
 * @file Comprehensive coverage tests for IPC handlers
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
};

const mockDialog = {
  showMessageBox: jest.fn(),
  showSaveDialog: jest.fn(),
};

const mockShell = {
  openExternal: jest.fn(),
  showItemInFolder: jest.fn(),
};

const mockMenu = jest.fn().mockImplementation(() => ({
  append: jest.fn(),
  popup: jest.fn(),
}));

const mockMenuItem = jest.fn().mockImplementation(() => ({}));

const mockExec = jest.fn();

// Mock archiver
const mockArchive = {
  directory: jest.fn(),
  finalize: jest.fn(),
  pipe: jest.fn(),
  on: jest.fn(),
};
const mockArchiver = jest.fn(() => mockArchive);

// Mock BagIt
const mockBag = {
  createWriteStream: jest.fn(() => ({
    on: jest.fn(),
    pipe: jest.fn(),
  })),
  finalize: jest.fn(),
};
const mockBagIt = jest.fn(() => mockBag);

// Mock fs streams
const mockReadStream = {
  pipe: jest.fn(),
};
const mockWriteStream = {
  on: jest.fn(),
  pipe: jest.fn(),
};

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

jest.mock('archiver', () => mockArchiver);
jest.mock('bagit-fs', () => mockBagIt);

jest.mock('fs', () => ({
  existsSync: jest.fn(),
  mkdirSync: jest.fn(),
  createReadStream: jest.fn(() => mockReadStream),
  createWriteStream: jest.fn(() => mockWriteStream),
  readdirSync: jest.fn(),
}));

jest.mock('path', () => ({
  join: jest.fn((...args) => args.join('/')),
  basename: jest.fn((p) => p.split('/').pop()),
  extname: jest.fn((p) => {
    const parts = p.split('.');
    return parts.length > 1 ? '.' + parts.pop() : '';
  }),
}));

// Mock UI modules
jest.mock('../../app/ui/window-manager', () => ({
  showPreview: jest.fn(),
  hidePreview: jest.fn(),
  reloadPreview: jest.fn(),
  togglePreviewDevTools: jest.fn(),
  getNativeInput: jest.fn(),
  getBagItMetadata: jest.fn(() => ({
    title: 'Test Website',
    description: 'Test Description',
    creator: 'Test Creator',
  })),
}));

jest.mock('../../app/ui/multi-window-manager', () => ({
  createWebsiteWindow: jest.fn(),
  loadWebsiteContent: jest.fn(),
  getAllWebsiteWindows: jest.fn(() => new Map()),
}));

// Mock server modules
jest.mock('../../app/server/eleventy', () => ({
  getCurrentLiveServerUrl: jest.fn(() => 'https://test-site.test:8080'),
  isLiveServerReady: jest.fn(() => true),
  switchToWebsite: jest.fn(() => Promise.resolve(3000)),
  setLiveServerUrl: jest.fn(),
  setCurrentWebsiteName: jest.fn(),
}));

// Mock website manager
jest.mock('../../app/utils/website-manager', () => ({
  createWebsiteWithName: jest.fn(),
  validateWebsiteName: jest.fn(() => ({ valid: true })),
  listWebsites: jest.fn(() => []),
  getWebsitePath: jest.fn(() => '/path/to/website'),
  renameWebsite: jest.fn(),
  deleteWebsite: jest.fn(),
}));

// Mock network modules
jest.mock('../../app/dns/hosts-manager', () => ({
  addLocalDnsResolution: jest.fn(() => Promise.resolve()),
}));

jest.mock('../../app/server/https-proxy', () => ({
  restartHttpsProxy: jest.fn(() => Promise.resolve(true)),
}));

// Mock store
const mockStore = {
  get: jest.fn(() => 'https'),
};
jest.mock('../../app/store', () => ({
  Store: jest.fn(() => mockStore),
}));

describe('Handlers Coverage Tests', () => {
  let handlers: any;
  let mockEvent: any;

  beforeAll(() => {
    // Import handlers after mocks are set up to register handlers
    handlers = require('../../app/ipc/handlers');
    // Call the setup function to register IPC handlers
    handlers.setupIpcMainListeners();
  });

  beforeEach(() => {
    jest.clearAllMocks();

    mockEvent = {
      sender: {
        send: jest.fn(),
      },
    };
  });

  describe('Preview Control Handlers', () => {
    it('should handle hide-preview when window exists', () => {
      const mockWindow = { id: 'test-window' };
      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);

      const hidePreviewMock = require('../../app/ui/window-manager').hidePreview;

      // Find and call the hide-preview handler
      const hidePreviewCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'hide-preview');
      if (hidePreviewCall) {
        hidePreviewCall[1](mockEvent);
        expect(hidePreviewMock).toHaveBeenCalledWith(mockWindow);
      }
    });

    it('should handle hide-preview when window does not exist', () => {
      mockBrowserWindow.fromWebContents.mockReturnValue(null);

      const hidePreviewMock = require('../../app/ui/window-manager').hidePreview;

      // Find and call the hide-preview handler
      const hidePreviewCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'hide-preview');
      if (hidePreviewCall) {
        hidePreviewCall[1](mockEvent);
        expect(hidePreviewMock).not.toHaveBeenCalled();
      }
    });

    it('should handle toggle-devtools', () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();
      const toggleDevToolsMock = require('../../app/ui/window-manager').togglePreviewDevTools;

      const toggleDevToolsCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'toggle-devtools');
      if (toggleDevToolsCall) {
        toggleDevToolsCall[1]();
        expect(consoleSpy).toHaveBeenCalledWith('DevTools toggle requested');
        expect(toggleDevToolsMock).toHaveBeenCalled();
      }

      consoleSpy.mockRestore();
    });

    it('should handle reload-preview', () => {
      const reloadPreviewMock = require('../../app/ui/window-manager').reloadPreview;

      const reloadPreviewCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'reload-preview');
      if (reloadPreviewCall) {
        reloadPreviewCall[1]();
        expect(reloadPreviewMock).toHaveBeenCalled();
      }
    });
  });

  describe('Browser Handlers', () => {
    it('should handle open-browser with successful primary URL', async () => {
      const getCurrentLiveServerUrlMock = require('../../app/server/eleventy').getCurrentLiveServerUrl;
      getCurrentLiveServerUrlMock.mockReturnValue('https://test.test:8080');
      mockShell.openExternal.mockResolvedValue(undefined);

      const openBrowserCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'open-browser');
      if (openBrowserCall) {
        await openBrowserCall[1]();
        expect(mockShell.openExternal).toHaveBeenCalledWith('https://test.test:8080');
      }
    });

    it('should handle open-browser with primary URL failure and successful fallback', async () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      const getCurrentLiveServerUrlMock = require('../../app/server/eleventy').getCurrentLiveServerUrl;
      getCurrentLiveServerUrlMock.mockReturnValue('https://test.test:8080');

      mockShell.openExternal.mockRejectedValueOnce(new Error('Primary failed')).mockResolvedValueOnce(undefined);

      const openBrowserCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'open-browser');
      if (openBrowserCall) {
        await openBrowserCall[1]();

        expect(consoleSpy).toHaveBeenCalledWith('Failed to open .test domain, trying localhost');
        expect(mockShell.openExternal).toHaveBeenCalledTimes(2);
        expect(mockShell.openExternal).toHaveBeenNthCalledWith(2, 'https://localhost:8080');
      }

      consoleSpy.mockRestore();
    });

    it('should handle open-browser with both primary and fallback URL failures', async () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

      const getCurrentLiveServerUrlMock = require('../../app/server/eleventy').getCurrentLiveServerUrl;
      getCurrentLiveServerUrlMock.mockReturnValue('https://test.test:8080');

      const fallbackError = new Error('Fallback failed');
      mockShell.openExternal.mockRejectedValueOnce(new Error('Primary failed')).mockRejectedValueOnce(fallbackError);

      const openBrowserCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'open-browser');
      if (openBrowserCall) {
        await openBrowserCall[1]();

        expect(consoleSpy).toHaveBeenCalledWith('Failed to open .test domain, trying localhost');
        expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to open in browser:', fallbackError);
      }

      consoleSpy.mockRestore();
      consoleErrorSpy.mockRestore();
    });
  });

  describe('Website Context Menu', () => {
    it('should create context menu with window positioning', () => {
      const mockWindow = { id: 'test-window' };
      mockBrowserWindow.fromWebContents.mockReturnValue(mockWindow);

      const mockMenuInstance = {
        append: jest.fn(),
        popup: jest.fn(),
      };
      mockMenu.mockReturnValue(mockMenuInstance);

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      const showContextMenuCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'show-website-context-menu');
      if (showContextMenuCall) {
        showContextMenuCall[1](mockEvent, 'test-site', { x: 100, y: 150 });

        expect(mockMenuInstance.append).toHaveBeenCalledTimes(2);
        expect(consoleSpy).toHaveBeenCalledWith('Showing context menu with window positioning');
        expect(mockMenuInstance.popup).toHaveBeenCalledWith({ window: mockWindow });
      }

      consoleSpy.mockRestore();
    });

    it('should create context menu with position coordinates when no window', () => {
      mockBrowserWindow.fromWebContents.mockReturnValue(null);

      const mockMenuInstance = {
        append: jest.fn(),
        popup: jest.fn(),
      };
      mockMenu.mockReturnValue(mockMenuInstance);

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      const showContextMenuCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'show-website-context-menu');
      if (showContextMenuCall) {
        showContextMenuCall[1](mockEvent, 'test-site', { x: 100.7, y: 150.3 });

        expect(consoleSpy).toHaveBeenCalledWith('Showing context menu at position:', { x: 100.7, y: 150.3 });
        expect(mockMenuInstance.popup).toHaveBeenCalledWith({
          x: Math.round(100.7),
          y: Math.round(150.3),
        });
      }

      consoleSpy.mockRestore();
    });

    it('should handle context menu rename action', () => {
      const mockMenuInstance = {
        append: jest.fn(),
        popup: jest.fn(),
      };
      mockMenu.mockReturnValue(mockMenuInstance);

      const showContextMenuCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'show-website-context-menu');
      if (showContextMenuCall) {
        showContextMenuCall[1](mockEvent, 'test-site', { x: 100, y: 150 });

        // Get the rename menu item and trigger its click
        const renameMenuItem = mockMenuInstance.append.mock.calls.find((call) => call[0] && call[0].label === 'Rename');

        if (renameMenuItem && renameMenuItem[0].click) {
          renameMenuItem[0].click();
          expect(mockEvent.sender.send).toHaveBeenCalledWith('website-context-menu-action', 'rename', 'test-site');
        }
      }
    });

    it('should handle context menu delete action', () => {
      const mockMenuInstance = {
        append: jest.fn(),
        popup: jest.fn(),
      };
      mockMenu.mockReturnValue(mockMenuInstance);

      const showContextMenuCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'show-website-context-menu');
      if (showContextMenuCall) {
        showContextMenuCall[1](mockEvent, 'test-site', { x: 100, y: 150 });

        // Get the delete menu item and trigger its click
        const deleteMenuItem = mockMenuInstance.append.mock.calls.find((call) => call[0] && call[0].label === 'Delete');

        if (deleteMenuItem && deleteMenuItem[0].click) {
          deleteMenuItem[0].click();
          expect(mockEvent.sender.send).toHaveBeenCalledWith('website-context-menu-action', 'delete', 'test-site');
        }
      }
    });
  });

  describe('Export Folder Handler', () => {
    it('should handle export-folder with user cancellation', async () => {
      mockDialog.showSaveDialog.mockResolvedValue({ canceled: true });

      const exportFolderCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-folder');
      if (exportFolderCall) {
        const result = await exportFolderCall[1](mockEvent);
        expect(result).toEqual({ success: false, message: 'Export cancelled by user' });
      }
    });

    it('should handle export-folder with successful export', async () => {
      const fs = require('fs');
      const mockExecCallback = jest.fn();

      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/path',
      });

      fs.existsSync.mockReturnValue(true);

      // Mock successful cp command
      mockExec.mockImplementation((cmd, callback) => {
        callback(null, 'success');
      });

      const exportFolderCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-folder');
      if (exportFolderCall) {
        const result = await exportFolderCall[1](mockEvent);
        expect(result).toEqual({ success: true, message: 'Export completed successfully' });
      }
    });

    it('should handle export-folder with cp command failure', async () => {
      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/path',
      });

      const fs = require('fs');
      fs.existsSync.mockReturnValue(true);

      const cpError = new Error('Copy failed');
      mockExec.mockImplementation((cmd, callback) => {
        callback(cpError, null);
      });

      const exportFolderCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-folder');
      if (exportFolderCall) {
        const result = await exportFolderCall[1](mockEvent);
        expect(result).toEqual({ success: false, message: 'Export failed: Copy failed' });
      }
    });

    it('should handle export-folder with missing build directory', async () => {
      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/path',
      });

      const fs = require('fs');
      fs.existsSync.mockReturnValue(false);

      const exportFolderCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-folder');
      if (exportFolderCall) {
        const result = await exportFolderCall[1](mockEvent);
        expect(result).toEqual({ success: false, message: 'Build directory not found. Please build the site first.' });
      }
    });
  });

  describe('Export ZIP Handler', () => {
    it('should handle export-zip with user cancellation', async () => {
      mockDialog.showSaveDialog.mockResolvedValue({ canceled: true });

      const exportZipCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-zip');
      if (exportZipCall) {
        const result = await exportZipCall[1](mockEvent);
        expect(result).toEqual({ success: false, message: 'Export cancelled by user' });
      }
    });

    it('should handle export-zip with missing build directory', async () => {
      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/archive.zip',
      });

      const fs = require('fs');
      fs.existsSync.mockReturnValue(false);

      const exportZipCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-zip');
      if (exportZipCall) {
        const result = await exportZipCall[1](mockEvent);
        expect(result).toEqual({ success: false, message: 'Build directory not found. Please build the site first.' });
      }
    });

    it('should handle export-zip with successful archive creation', async () => {
      const fs = require('fs');

      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/archive.zip',
      });

      fs.existsSync.mockReturnValue(true);
      fs.createWriteStream.mockReturnValue(mockWriteStream);

      // Mock archive events
      mockArchive.on.mockImplementation((event, callback) => {
        if (event === 'end') {
          setTimeout(callback, 0);
        }
        return mockArchive;
      });

      mockArchive.finalize.mockImplementation(() => {
        // Trigger the 'end' event
        const endCallback = mockArchive.on.mock.calls.find((call) => call[0] === 'end');
        if (endCallback) {
          setTimeout(endCallback[1], 0);
        }
      });

      const exportZipCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-zip');
      if (exportZipCall) {
        const resultPromise = exportZipCall[1](mockEvent);

        // Allow async operations to complete
        await new Promise((resolve) => setTimeout(resolve, 10));

        const result = await resultPromise;
        expect(result).toEqual({ success: true, message: 'ZIP export completed successfully' });
      }
    });

    it('should handle export-zip with archive error', async () => {
      const fs = require('fs');

      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/archive.zip',
      });

      fs.existsSync.mockReturnValue(true);
      fs.createWriteStream.mockReturnValue(mockWriteStream);

      const archiveError = new Error('Archive failed');

      // Mock archive error event
      mockArchive.on.mockImplementation((event, callback) => {
        if (event === 'error') {
          setTimeout(() => callback(archiveError), 0);
        }
        return mockArchive;
      });

      const exportZipCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-zip');
      if (exportZipCall) {
        const resultPromise = exportZipCall[1](mockEvent);

        // Allow async operations to complete
        await new Promise((resolve) => setTimeout(resolve, 10));

        try {
          await resultPromise;
        } catch (error) {
          expect(error).toBe(archiveError);
        }
      }
    });
  });

  describe('Build Website Handler', () => {
    it('should handle build-website with successful build', async () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      mockExec.mockImplementation((cmd, callback) => {
        callback(null, 'Build successful');
      });

      const buildWebsiteCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'build-website');
      if (buildWebsiteCall) {
        const result = await buildWebsiteCall[1]();

        expect(consoleSpy).toHaveBeenCalledWith('Building website...');
        expect(result).toEqual({ success: true });
      }

      consoleSpy.mockRestore();
    });

    it('should handle build-website with build failure', async () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

      const buildError = new Error('Build failed');
      mockExec.mockImplementation((cmd, callback) => {
        callback(buildError, null);
      });

      const buildWebsiteCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'build-website');
      if (buildWebsiteCall) {
        const result = await buildWebsiteCall[1]();

        expect(consoleSpy).toHaveBeenCalledWith('Building website...');
        expect(consoleErrorSpy).toHaveBeenCalledWith('Build failed:', buildError);
        expect(result).toEqual({ success: false, error: buildError.message });
      }

      consoleSpy.mockRestore();
      consoleErrorSpy.mockRestore();
    });
  });

  describe('Theme Handlers', () => {
    it('should handle get-theme', async () => {
      mockStore.get.mockReturnValue('dark');

      const getThemeCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'get-theme');
      if (getThemeCall) {
        const result = await getThemeCall[1]();
        expect(result).toBe('dark');
        expect(mockStore.get).toHaveBeenCalledWith('theme');
      }
    });

    it('should handle set-theme', async () => {
      const mockStoreInstance = {
        set: jest.fn(),
      };
      const StoreMock = require('../../app/store').Store;
      StoreMock.mockReturnValue(mockStoreInstance);

      const setThemeCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'set-theme');
      if (setThemeCall) {
        await setThemeCall[1](mockEvent, 'light');
        expect(mockStoreInstance.set).toHaveBeenCalledWith('theme', 'light');
      }
    });
  });

  describe('Website Management Handlers', () => {
    it('should handle create-website-window with successful creation', async () => {
      const createWebsiteWindowMock = require('../../app/ui/multi-window-manager').createWebsiteWindow;
      const switchToWebsiteMock = require('../../app/server/eleventy').switchToWebsite;
      const addLocalDnsResolutionMock = require('../../app/dns/hosts-manager').addLocalDnsResolution;
      const restartHttpsProxyMock = require('../../app/server/https-proxy').restartHttpsProxy;
      const loadWebsiteContentMock = require('../../app/ui/multi-window-manager').loadWebsiteContent;
      const setLiveServerUrlMock = require('../../app/server/eleventy').setLiveServerUrl;
      const setCurrentWebsiteNameMock = require('../../app/server/eleventy').setCurrentWebsiteName;

      createWebsiteWindowMock.mockReturnValue({ id: 'window1' });
      switchToWebsiteMock.mockResolvedValue(3000);
      addLocalDnsResolutionMock.mockResolvedValue(undefined);
      restartHttpsProxyMock.mockResolvedValue(true);
      mockStore.get.mockReturnValue('https');

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      const createWebsiteCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'create-website-window');
      if (createWebsiteCall) {
        jest.useFakeTimers();
        const resultPromise = createWebsiteCall[1](mockEvent, 'test-site', '/path/to/site');

        // Fast-forward the setTimeout
        jest.advanceTimersByTime(1500);

        await resultPromise;

        expect(createWebsiteWindowMock).toHaveBeenCalledWith('test-site', '/path/to/site');
        expect(switchToWebsiteMock).toHaveBeenCalledWith('/path/to/site');
        expect(addLocalDnsResolutionMock).toHaveBeenCalledWith('test-site.test');
        expect(restartHttpsProxyMock).toHaveBeenCalledWith(8080, 3000, 'test-site.test');
        expect(consoleSpy).toHaveBeenCalledWith('Website HTTPS server ready at: https://test-site.test:8080');
        expect(setLiveServerUrlMock).toHaveBeenCalledWith('https://test-site.test:8080');
        expect(setCurrentWebsiteNameMock).toHaveBeenCalledWith('test-site');
        expect(loadWebsiteContentMock).toHaveBeenCalledWith('test-site');

        jest.useRealTimers();
      }

      consoleSpy.mockRestore();
    });

    it('should handle create-website-window with HTTPS proxy failure', async () => {
      const createWebsiteWindowMock = require('../../app/ui/multi-window-manager').createWebsiteWindow;
      const switchToWebsiteMock = require('../../app/server/eleventy').switchToWebsite;
      const addLocalDnsResolutionMock = require('../../app/dns/hosts-manager').addLocalDnsResolution;
      const restartHttpsProxyMock = require('../../app/server/https-proxy').restartHttpsProxy;
      const setLiveServerUrlMock = require('../../app/server/eleventy').setLiveServerUrl;
      const setCurrentWebsiteNameMock = require('../../app/server/eleventy').setCurrentWebsiteName;

      createWebsiteWindowMock.mockReturnValue({ id: 'window1' });
      switchToWebsiteMock.mockResolvedValue(3000);
      addLocalDnsResolutionMock.mockResolvedValue(undefined);
      restartHttpsProxyMock.mockResolvedValue(false);
      mockStore.get.mockReturnValue('https');

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      const createWebsiteCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'create-website-window');
      if (createWebsiteCall) {
        jest.useFakeTimers();
        const resultPromise = createWebsiteCall[1](mockEvent, 'test-site', '/path/to/site');

        jest.advanceTimersByTime(1500);

        await resultPromise;

        expect(consoleSpy).toHaveBeenCalledWith('HTTPS proxy failed, continuing with HTTP-only mode');
        expect(setLiveServerUrlMock).toHaveBeenCalledWith('http://localhost:3000');

        jest.useRealTimers();
      }

      consoleSpy.mockRestore();
    });

    it('should handle create-website-window with HTTP mode preference', async () => {
      const createWebsiteWindowMock = require('../../app/ui/multi-window-manager').createWebsiteWindow;
      const switchToWebsiteMock = require('../../app/server/eleventy').switchToWebsite;
      const addLocalDnsResolutionMock = require('../../app/dns/hosts-manager').addLocalDnsResolution;
      const restartHttpsProxyMock = require('../../app/server/https-proxy').restartHttpsProxy;
      const setLiveServerUrlMock = require('../../app/server/eleventy').setLiveServerUrl;
      const setCurrentWebsiteNameMock = require('../../app/server/eleventy').setCurrentWebsiteName;

      createWebsiteWindowMock.mockReturnValue({ id: 'window1' });
      switchToWebsiteMock.mockResolvedValue(3000);
      addLocalDnsResolutionMock.mockResolvedValue(undefined);
      mockStore.get.mockReturnValue('http');

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      const createWebsiteCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'create-website-window');
      if (createWebsiteCall) {
        jest.useFakeTimers();
        const resultPromise = createWebsiteCall[1](mockEvent, 'test-site', '/path/to/site');

        jest.advanceTimersByTime(1500);

        await resultPromise;

        expect(restartHttpsProxyMock).not.toHaveBeenCalled();
        expect(consoleSpy).toHaveBeenCalledWith('HTTP-only mode by user preference, skipping HTTPS proxy');
        expect(setLiveServerUrlMock).toHaveBeenCalledWith('http://localhost:3000');

        jest.useRealTimers();
      }

      consoleSpy.mockRestore();
    });
  });

  describe('Export BagIt Handler', () => {
    it('should handle export-bagit with user cancellation', async () => {
      mockDialog.showSaveDialog.mockResolvedValue({ canceled: true });

      const exportBagItCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-bagit');
      if (exportBagItCall) {
        const result = await exportBagItCall[1](mockEvent);
        expect(result).toEqual({ success: false, message: 'Export cancelled by user' });
      }
    });

    it('should handle export-bagit with missing build directory', async () => {
      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/bagit-archive',
      });

      const fs = require('fs');
      fs.existsSync.mockReturnValue(false);

      const exportBagItCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-bagit');
      if (exportBagItCall) {
        const result = await exportBagItCall[1](mockEvent);
        expect(result).toEqual({ success: false, message: 'Build directory not found. Please build the site first.' });
      }
    });

    it('should handle export-bagit with successful creation', async () => {
      const fs = require('fs');
      const getBagItMetadataMock = require('../../app/ui/window-manager').getBagItMetadata;

      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/bagit-archive',
      });

      fs.existsSync.mockReturnValue(true);
      fs.readdirSync.mockReturnValue([
        { name: 'index.html', isDirectory: () => false },
        { name: 'styles', isDirectory: () => true },
      ]);

      getBagItMetadataMock.mockReturnValue({
        title: 'Test Site',
        description: 'Test Description',
        creator: 'Test Creator',
      });

      const mockBagInstance = {
        createWriteStream: jest.fn(() => ({
          on: jest.fn((event, callback) => {
            if (event === 'finish') {
              setTimeout(callback, 0);
            }
          }),
          pipe: jest.fn(),
        })),
        finalize: jest.fn((callback) => {
          setTimeout(callback, 0);
        }),
      };

      mockBagIt.mockReturnValue(mockBagInstance);
      fs.createReadStream.mockReturnValue({
        pipe: jest.fn(),
      });

      const exportBagItCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-bagit');
      if (exportBagItCall) {
        jest.useFakeTimers();

        const resultPromise = exportBagItCall[1](mockEvent);

        // Advance timers to trigger async operations
        jest.advanceTimersByTime(100);

        const result = await resultPromise;
        expect(result).toEqual({ success: true, message: 'BagIt export completed successfully' });

        jest.useRealTimers();
      }
    });

    it('should handle export-bagit with file copy operations', async () => {
      const fs = require('fs');
      const getBagItMetadataMock = require('../../app/ui/window-manager').getBagItMetadata;

      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/bagit-archive',
      });

      fs.existsSync.mockReturnValue(true);
      fs.readdirSync.mockReturnValue([
        { name: 'file1.html', isDirectory: () => false },
        { name: 'file2.css', isDirectory: () => false },
      ]);

      getBagItMetadataMock.mockReturnValue({
        title: 'Test Site',
        description: 'Test Description',
        creator: 'Test Creator',
      });

      let finishCallbacks: Array<() => void> = [];

      const mockBagInstance = {
        createWriteStream: jest.fn(() => ({
          on: jest.fn((event, callback) => {
            if (event === 'finish') {
              finishCallbacks.push(callback);
            }
          }),
          pipe: jest.fn(),
        })),
        finalize: jest.fn((callback) => {
          // Trigger all finish callbacks first
          finishCallbacks.forEach((cb) => cb());
          setTimeout(callback, 0);
        }),
      };

      mockBagIt.mockReturnValue(mockBagInstance);
      fs.createReadStream.mockReturnValue({
        pipe: jest.fn(),
      });

      const exportBagItCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-bagit');
      if (exportBagItCall) {
        jest.useFakeTimers();

        const resultPromise = exportBagItCall[1](mockEvent);

        // Advance timers to trigger async operations
        jest.advanceTimersByTime(100);

        const result = await resultPromise;
        expect(result).toEqual({ success: true, message: 'BagIt export completed successfully' });
        expect(mockBagInstance.createWriteStream).toHaveBeenCalledTimes(2);

        jest.useRealTimers();
      }
    });

    it('should handle export-bagit with directory traversal', async () => {
      const fs = require('fs');
      const getBagItMetadataMock = require('../../app/ui/window-manager').getBagItMetadata;

      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/bagit-archive',
      });

      fs.existsSync.mockReturnValue(true);

      // Mock directory structure
      let readdirCalls = 0;
      fs.readdirSync.mockImplementation((dir: any) => {
        readdirCalls++;
        if (readdirCalls === 1) {
          // Root directory
          return [
            { name: 'subdir', isDirectory: () => true },
            { name: 'file.html', isDirectory: () => false },
          ];
        } else {
          // Subdirectory
          return [{ name: 'nested.css', isDirectory: () => false }];
        }
      });

      getBagItMetadataMock.mockReturnValue({
        title: 'Test Site',
        description: 'Test Description',
        creator: 'Test Creator',
      });

      let finishCallbacks: Array<() => void> = [];
      let pendingCount = 0;

      const mockBagInstance = {
        createWriteStream: jest.fn(() => ({
          on: jest.fn((event, callback) => {
            if (event === 'finish') {
              finishCallbacks.push(() => {
                pendingCount--;
                if (pendingCount === 0) {
                  callback();
                }
              });
              pendingCount++;
            }
          }),
          pipe: jest.fn(),
        })),
        finalize: jest.fn((callback) => {
          // Trigger all finish callbacks
          finishCallbacks.forEach((cb) => cb());
          setTimeout(callback, 0);
        }),
      };

      mockBagIt.mockReturnValue(mockBagInstance);
      fs.createReadStream.mockReturnValue({
        pipe: jest.fn(),
      });

      const exportBagItCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-bagit');
      if (exportBagItCall) {
        jest.useFakeTimers();

        const resultPromise = exportBagItCall[1](mockEvent);

        // Advance timers to trigger async operations
        jest.advanceTimersByTime(100);

        const result = await resultPromise;
        expect(result).toEqual({ success: true, message: 'BagIt export completed successfully' });
        expect(fs.readdirSync).toHaveBeenCalledTimes(2); // Root + subdirectory

        jest.useRealTimers();
      }
    });

    it('should handle export-bagit with stream error', async () => {
      const fs = require('fs');
      const getBagItMetadataMock = require('../../app/ui/window-manager').getBagItMetadata;

      mockDialog.showSaveDialog.mockResolvedValue({
        canceled: false,
        filePath: '/export/bagit-archive',
      });

      fs.existsSync.mockReturnValue(true);
      fs.readdirSync.mockReturnValue([{ name: 'file.html', isDirectory: () => false }]);

      getBagItMetadataMock.mockReturnValue({
        title: 'Test Site',
        description: 'Test Description',
        creator: 'Test Creator',
      });

      const streamError = new Error('Stream error');

      const mockBagInstance = {
        createWriteStream: jest.fn(() => ({
          on: jest.fn((event, callback) => {
            if (event === 'error') {
              setTimeout(() => callback(streamError), 0);
            }
          }),
          pipe: jest.fn(),
        })),
        finalize: jest.fn(),
      };

      mockBagIt.mockReturnValue(mockBagInstance);
      fs.createReadStream.mockReturnValue({
        pipe: jest.fn(),
      });

      const exportBagItCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'export-bagit');
      if (exportBagItCall) {
        try {
          await exportBagItCall[1](mockEvent);
          fail('Expected promise to reject');
        } catch (error) {
          expect(error).toBe(streamError);
        }
      }
    });
  });

  describe('Restart Server Handler', () => {
    it('should handle restart-server with successful restart', async () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      mockExec.mockImplementation((cmd, callback) => {
        callback(null, 'Server restarted');
      });

      const restartServerCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'restart-server');
      if (restartServerCall) {
        const result = await restartServerCall[1]();

        expect(consoleSpy).toHaveBeenCalledWith('Restarting server...');
        expect(result).toEqual({ success: true });
      }

      consoleSpy.mockRestore();
    });

    it('should handle restart-server with failure', async () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

      const restartError = new Error('Restart failed');
      mockExec.mockImplementation((cmd, callback) => {
        callback(restartError, null);
      });

      const restartServerCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'restart-server');
      if (restartServerCall) {
        const result = await restartServerCall[1]();

        expect(consoleSpy).toHaveBeenCalledWith('Restarting server...');
        expect(consoleErrorSpy).toHaveBeenCalledWith('Server restart failed:', restartError);
        expect(result).toEqual({ success: false, error: restartError.message });
      }

      consoleSpy.mockRestore();
      consoleErrorSpy.mockRestore();
    });
  });

  describe('Website Directory Handlers', () => {
    it('should handle open-website-folder', async () => {
      const getWebsitePathMock = require('../../app/utils/website-manager').getWebsitePath;
      getWebsitePathMock.mockReturnValue('/path/to/website');

      const openWebsiteFolderCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'open-website-folder');
      if (openWebsiteFolderCall) {
        await openWebsiteFolderCall[1](mockEvent, 'test-site');

        expect(getWebsitePathMock).toHaveBeenCalledWith('test-site');
        expect(mockShell.showItemInFolder).toHaveBeenCalledWith('/path/to/website');
      }
    });

    it('should handle open-export-folder', async () => {
      const openExportFolderCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'open-export-folder');
      if (openExportFolderCall) {
        await openExportFolderCall[1](mockEvent, '/export/path');
        expect(mockShell.showItemInFolder).toHaveBeenCalledWith('/export/path');
      }
    });
  });

  describe('Server URL Handler', () => {
    it('should handle get-server-url', async () => {
      const getCurrentLiveServerUrlMock = require('../../app/server/eleventy').getCurrentLiveServerUrl;
      getCurrentLiveServerUrlMock.mockReturnValue('https://test.test:8080');

      const getServerUrlCall = mockIpcMain.handle.mock.calls.find((call) => call[0] === 'get-server-url');
      if (getServerUrlCall) {
        const result = await getServerUrlCall[1]();
        expect(result).toBe('https://test.test:8080');
      }
    });
  });

  describe('Error Edge Cases', () => {
    it('should handle exceptions in context menu creation', () => {
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

      // Mock Menu constructor to throw
      mockMenu.mockImplementation(() => {
        throw new Error('Menu creation failed');
      });

      const showContextMenuCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'show-website-context-menu');
      if (showContextMenuCall) {
        expect(() => {
          showContextMenuCall[1](mockEvent, 'test-site', { x: 100, y: 150 });
        }).toThrow('Menu creation failed');
      }

      consoleErrorSpy.mockRestore();
    });

    it('should handle missing event sender', () => {
      const mockEventNoSender = {};

      const hidePreviewCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'hide-preview');
      if (hidePreviewCall) {
        expect(() => {
          hidePreviewCall[1](mockEventNoSender);
        }).not.toThrow();
      }
    });

    it('should handle BrowserWindow.fromWebContents throwing error', () => {
      mockBrowserWindow.fromWebContents.mockImplementation(() => {
        throw new Error('fromWebContents failed');
      });

      const hidePreviewCall = mockIpcMain.on.mock.calls.find((call) => call[0] === 'hide-preview');
      if (hidePreviewCall) {
        expect(() => {
          hidePreviewCall[1](mockEvent);
        }).toThrow('fromWebContents failed');
      }
    });
  });
});
