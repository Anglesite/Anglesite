/**
 * @file Tests for window management and DevTools functionality
 */
import * as fs from 'fs';
import * as path from 'path';

// Mock file system
jest.mock('fs');
const mockFs = fs as jest.Mocked<typeof fs>;

// Mock path module
jest.mock('path');
const mockPath = path as jest.Mocked<typeof path>;

// Mock template loader
jest.mock('../../app/ui/template-loader', () => ({
  loadTemplateAsDataUrl: jest.fn(() => 'data:text/html,mock-template'),
}));

// Mock eleventy server
const mockEleventyServer = {
  getCurrentLiveServerUrl: jest.fn(() => 'https://localhost:8080'),
  isLiveServerReady: jest.fn(() => true),
};
jest.mock('../../app/server/eleventy', () => mockEleventyServer);

// Mock theme manager
const mockThemeManager = {
  applyThemeToWindow: jest.fn(),
};
jest.mock('../../app/ui/theme-manager', () => ({
  themeManager: mockThemeManager,
}));

// Mock Electron modules
const mockWebContents = {
  isDevToolsOpened: jest.fn(),
  openDevTools: jest.fn(),
  closeDevTools: jest.fn(),
  loadURL: jest.fn(),
  loadFile: jest.fn(),
  reload: jest.fn(),
  removeAllListeners: jest.fn(),
  on: jest.fn(),
  send: jest.fn(),
};

const mockWebContentsView = {
  webContents: mockWebContents,
  setBounds: jest.fn(),
};

const mockWindow = {
  getBounds: jest.fn(() => ({ width: 1200, height: 800 })),
  loadFile: jest.fn(),
  loadURL: jest.fn(),
  on: jest.fn(),
  once: jest.fn(),
  show: jest.fn(),
  focus: jest.fn(),
  close: jest.fn(),
  isDestroyed: jest.fn(() => false),
  webContents: {
    send: jest.fn(),
  },
  contentView: {
    addChildView: jest.fn(),
    removeChildView: jest.fn(),
    children: [] as unknown[],
  },
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any;

const mockBrowserWindow = {
  getFocusedWindow: jest.fn(),
  getAllWindows: jest.fn(() => []),
};

// Mock constructor function
const BrowserWindowConstructor = jest.fn().mockImplementation(() => mockWindow);
Object.assign(BrowserWindowConstructor, mockBrowserWindow);

const WebContentsViewConstructor = jest.fn().mockImplementation(() => mockWebContentsView);

const mockHelpWindow = {
  contentView: {
    children: [mockWebContentsView],
  },
};

const mockWebsiteWindow = {
  window: {},
  webContentsView: mockWebContentsView,
  websiteName: 'test-site',
};

const mockMultiWindowManager = {
  getHelpWindow: jest.fn(),
  getAllWebsiteWindows: jest.fn(),
};

// Set up mocks
jest.mock('electron', () => ({
  BrowserWindow: BrowserWindowConstructor,
  WebContentsView: WebContentsViewConstructor,
  app: {
    getPath: jest.fn(() => '/mock/path'),
  },
  nativeTheme: {
    shouldUseDarkColors: false,
    on: jest.fn(),
  },
  ipcMain: {
    handle: jest.fn(),
    on: jest.fn(),
    removeListener: jest.fn(),
  },
}));

jest.mock('../../app/ui/multi-window-manager', () => mockMultiWindowManager);

describe('Window Manager', () => {
  let windowManager: typeof import('../../app/ui/window-manager');

  beforeAll(() => {
    // Import after mocks are set up
    windowManager = require('../../app/ui/window-manager');
  });

  beforeEach(() => {
    // Reset all mocks
    jest.clearAllMocks();

    // Reset mock window state
    mockWindow.contentView.children = [];

    // Set up default mock implementations
    mockBrowserWindow.getFocusedWindow.mockReturnValue(mockHelpWindow);
    mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);
    mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
    mockWebContents.isDevToolsOpened.mockReturnValue(false);
    mockEleventyServer.isLiveServerReady.mockReturnValue(true);
  });

  describe('togglePreviewDevTools', () => {
    it('should handle no focused window', () => {
      mockBrowserWindow.getFocusedWindow.mockReturnValue(null);

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      windowManager.togglePreviewDevTools();

      expect(consoleSpy).toHaveBeenCalledWith('No focused window found for DevTools');
      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });

    it('should open DevTools for help window when closed', async () => {
      mockWebContents.isDevToolsOpened.mockReturnValue(false);

      await windowManager.togglePreviewDevTools();

      expect(mockWebContents.isDevToolsOpened).toHaveBeenCalled();
      expect(mockWebContents.openDevTools).toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).not.toHaveBeenCalled();
    });

    it('should close DevTools for help window when open', async () => {
      mockWebContents.isDevToolsOpened.mockReturnValue(true);

      await windowManager.togglePreviewDevTools();

      expect(mockWebContents.isDevToolsOpened).toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).toHaveBeenCalled();
      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();
    });

    it('should handle help window with no WebContentsView', () => {
      const helpWindowNoViews = {
        contentView: { children: [] },
      };

      mockBrowserWindow.getFocusedWindow.mockReturnValue(helpWindowNoViews);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(helpWindowNoViews);

      windowManager.togglePreviewDevTools();

      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).not.toHaveBeenCalled();
    });

    it('should open DevTools for website window when closed', async () => {
      const mockFocusedWebsiteWindow = { id: 'test-window' };
      const websiteWindows = new Map([
        [
          'test-site',
          {
            ...mockWebsiteWindow,
            window: mockFocusedWebsiteWindow,
          },
        ],
      ]);

      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockFocusedWebsiteWindow);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);
      mockWebContents.isDevToolsOpened.mockReturnValue(false);

      await windowManager.togglePreviewDevTools();

      expect(mockWebContents.isDevToolsOpened).toHaveBeenCalled();
      expect(mockWebContents.openDevTools).toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).not.toHaveBeenCalled();
    });

    it('should close DevTools for website window when open', async () => {
      const mockFocusedWebsiteWindow = { id: 'test-window' };
      const websiteWindows = new Map([
        [
          'test-site',
          {
            ...mockWebsiteWindow,
            window: mockFocusedWebsiteWindow,
          },
        ],
      ]);

      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockFocusedWebsiteWindow);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);
      mockWebContents.isDevToolsOpened.mockReturnValue(true);

      await windowManager.togglePreviewDevTools();

      expect(mockWebContents.isDevToolsOpened).toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).toHaveBeenCalled();
      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();
    });

    it('should handle unrecognized window', async () => {
      const unrecognizedWindow = { id: 'unknown-window' };
      const websiteWindows = new Map();

      mockBrowserWindow.getFocusedWindow.mockReturnValue(unrecognizedWindow);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      await windowManager.togglePreviewDevTools();

      expect(consoleSpy).toHaveBeenCalledWith('Focused window is not a recognized Anglesite window');
      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });
  });

  describe('createWindow', () => {
    it('should create a BrowserWindow with correct configuration', () => {
      mockPath.join.mockReturnValueOnce('/mock/preload.js');
      mockPath.join.mockReturnValueOnce('/mock/index.html');

      const result = windowManager.createWindow();

      expect(BrowserWindowConstructor).toHaveBeenCalledWith({
        width: 1200,
        height: 800,
        webPreferences: {
          nodeIntegration: false,
          contextIsolation: true,
          preload: '/mock/preload.js',
        },
        titleBarStyle: 'hiddenInset',
        trafficLightPosition: { x: 20, y: 20 },
      });
      expect(mockWindow.loadFile).toHaveBeenCalledWith('/mock/index.html');
      expect(WebContentsViewConstructor).toHaveBeenCalled();
      expect(result).toBe(mockWindow);
    });

    it('should set up resize handler for WebContentsView positioning', () => {
      windowManager.createWindow();

      // Get the resize handler
      expect(mockWindow.on).toHaveBeenCalledWith('resize', expect.any(Function));
      const resizeHandler = mockWindow.on.mock.calls.find((call: [string, unknown]) => call[0] === 'resize')?.[1];

      // Test resize handler
      resizeHandler();
      expect(mockWebContentsView.setBounds).toHaveBeenCalledWith({
        x: 0,
        y: 90,
        width: 1200,
        height: 710,
      });
    });
  });

  describe('autoLoadPreview', () => {
    it('should auto-load preview when server is ready', () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      windowManager.autoLoadPreview(mockWindow);

      expect(mockEleventyServer.isLiveServerReady).toHaveBeenCalled();
      expect(mockWebContentsView.setBounds).toHaveBeenCalled();
      expect(mockWindow.contentView.addChildView).toHaveBeenCalledWith(mockWebContentsView);
      expect(mockWindow.webContents.send).toHaveBeenCalledWith('preview-loaded');
      expect(consoleSpy).toHaveBeenCalledWith('Auto-preview loaded successfully');

      consoleSpy.mockRestore();
    });

    it('should not load content when server is not ready', () => {
      mockEleventyServer.isLiveServerReady.mockReturnValue(false);
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      windowManager.autoLoadPreview(mockWindow);

      // When server is not ready, autoLoadPreview should exit early and not load anything
      expect(mockWebContentsView.webContents.loadURL).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });
  });

  describe('loadLocalFilePreview', () => {
    it('should load local file when it exists', () => {
      mockPath.resolve.mockReturnValue('/mock/dist');
      mockPath.join.mockReturnValue('/mock/dist/index.html');
      mockFs.existsSync.mockReturnValue(true);
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      windowManager.loadLocalFilePreview(mockWindow);

      expect(mockPath.resolve).toHaveBeenCalledWith(process.cwd(), 'dist');
      expect(mockPath.join).toHaveBeenCalledWith('/mock/dist', 'index.html');
      expect(mockFs.existsSync).toHaveBeenCalledWith('/mock/dist/index.html');
      expect(mockWebContentsView.webContents.loadFile).toHaveBeenCalledWith('/mock/dist/index.html');
      expect(consoleSpy).toHaveBeenCalledWith('Loading local file preview:', 'file:///mock/dist/index.html');

      consoleSpy.mockRestore();
    });

    it('should log error when index file does not exist', () => {
      mockPath.resolve.mockReturnValue('/mock/dist');
      mockPath.join.mockReturnValue('/mock/dist/index.html');
      mockFs.existsSync.mockReturnValue(false);
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();

      windowManager.loadLocalFilePreview(mockWindow);

      expect(consoleSpy).toHaveBeenCalledWith('Index file not found:', '/mock/dist/index.html');

      consoleSpy.mockRestore();
    });
  });

  describe('showPreview', () => {
    it('should show preview and load content', () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      windowManager.showPreview(mockWindow);

      expect(consoleSpy).toHaveBeenCalledWith('Showing WebContentsView and loading URL');
      expect(mockWindow.contentView.addChildView).toHaveBeenCalledWith(mockWebContentsView);
      expect(mockWebContentsView.webContents.removeAllListeners).toHaveBeenCalledWith('did-fail-load');
      expect(mockWebContentsView.webContents.removeAllListeners).toHaveBeenCalledWith('did-finish-load');
      expect(mockWebContentsView.webContents.on).toHaveBeenCalledWith('did-fail-load', expect.any(Function));
      expect(mockWebContentsView.webContents.on).toHaveBeenCalledWith('did-finish-load', expect.any(Function));
      expect(mockWebContentsView.setBounds).toHaveBeenCalled();
      expect(mockWindow.webContents.send).toHaveBeenCalledWith('preview-loaded');

      consoleSpy.mockRestore();
    });

    it('should set up event handlers for did-fail-load and did-finish-load', () => {
      windowManager.showPreview(mockWindow);

      // Get the event handlers
      const failHandler = mockWebContentsView.webContents.on.mock.calls.find(
        (call: [string, unknown]) => call[0] === 'did-fail-load'
      )[1];
      const successHandler = mockWebContentsView.webContents.on.mock.calls.find(
        (call: [string, unknown]) => call[0] === 'did-finish-load'
      )[1];

      // Test fail handler
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();
      failHandler(null, 404, 'Not Found', 'https://localhost:8080');
      expect(consoleErrorSpy).toHaveBeenCalled();
      consoleErrorSpy.mockRestore();

      // Test success handler
      const consoleLogSpy = jest.spyOn(console, 'log').mockImplementation();
      successHandler();
      expect(consoleLogSpy).toHaveBeenCalled();
      consoleLogSpy.mockRestore();
    });
  });

  describe('hidePreview', () => {
    it('should hide preview by removing WebContentsView', () => {
      // Set up mock window with WebContentsView in children
      mockWindow.contentView.children = [mockWebContentsView];

      windowManager.hidePreview(mockWindow);

      expect(mockWindow.contentView.removeChildView).toHaveBeenCalledWith(mockWebContentsView);
    });

    it('should handle case when WebContentsView is not in children', () => {
      mockWindow.contentView.children = [];

      // Should not throw error
      expect(() => windowManager.hidePreview(mockWindow)).not.toThrow();
    });
  });

  describe('reloadPreview', () => {
    it('should reload preview WebContentsView', () => {
      windowManager.reloadPreview();
      expect(mockWebContentsView.webContents.reload).toHaveBeenCalled();
    });
  });

  describe('openWebsiteSelectionWindow', () => {
    it('should create and configure website selection window with existing file', () => {
      mockPath.join.mockReturnValueOnce('/mock/ui/website-selection.html');
      mockFs.existsSync.mockReturnValue(true);

      windowManager.openWebsiteSelectionWindow();

      expect(BrowserWindowConstructor).toHaveBeenCalledWith({
        width: 600,
        height: 500,
        title: 'Open Website',
        resizable: true,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        show: false,
        titleBarStyle: 'hiddenInset',
        webPreferences: {
          nodeIntegration: true,
          contextIsolation: false,
        },
      });

      expect(mockWindow.loadFile).toHaveBeenCalledWith('/mock/ui/website-selection.html');
    });

    it('should create and configure website selection window with template fallback', () => {
      const mockLoadTemplateAsDataUrl = require('../../app/ui/template-loader').loadTemplateAsDataUrl;
      mockPath.join.mockReturnValueOnce('/mock/ui/website-selection.html');
      mockFs.existsSync.mockReturnValue(false); // File doesn't exist, use template

      windowManager.openWebsiteSelectionWindow();

      expect(mockLoadTemplateAsDataUrl).toHaveBeenCalledWith('website-selection');
      expect(mockWindow.loadURL).toHaveBeenCalledWith('data:text/html,mock-template');
      expect(mockWindow.once).toHaveBeenCalledWith('ready-to-show', expect.any(Function));
    });

    it('should apply theme when window is ready to show (fallback case)', () => {
      mockPath.join.mockReturnValueOnce('/mock/ui/website-selection.html');
      mockFs.existsSync.mockReturnValue(false); // Use template fallback

      windowManager.openWebsiteSelectionWindow();

      // Simulate the ready-to-show event being called
      expect(mockWindow.once).toHaveBeenCalledWith('ready-to-show', expect.any(Function));

      // Find and call the ready-to-show handler
      const onceCalls = mockWindow.once.mock.calls;
      const readyCall = onceCalls.find((call: [string, unknown]) => call[0] === 'ready-to-show');
      expect(readyCall).toBeDefined();

      if (readyCall) {
        const readyHandler = readyCall[1];
        readyHandler();
        expect(mockThemeManager.applyThemeToWindow).toHaveBeenCalledWith(mockWindow);
        expect(mockWindow.show).toHaveBeenCalled();
      }
    });
  });

  describe('openSettingsWindow', () => {
    it('should create and configure settings window', () => {
      const mockLoadTemplateAsDataUrl = require('../../app/ui/template-loader').loadTemplateAsDataUrl;
      mockPath.join.mockReturnValueOnce('/mock/preload.js');

      windowManager.openSettingsWindow();

      expect(BrowserWindowConstructor).toHaveBeenCalledWith({
        width: 500,
        height: 300,
        title: 'Settings',
        resizable: false,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        show: false,
        titleBarStyle: 'default',
        webPreferences: {
          nodeIntegration: false,
          contextIsolation: true,
          preload: '/mock/preload.js',
        },
      });

      expect(mockLoadTemplateAsDataUrl).toHaveBeenCalledWith('settings');
      expect(mockWindow.loadURL).toHaveBeenCalledWith('data:text/html,mock-template');
      expect(mockWindow.once).toHaveBeenCalledWith('ready-to-show', expect.any(Function));
    });

    it('should apply theme and show window when ready', () => {
      // Mock window as destroyed to force creation of new window
      mockWindow.isDestroyed.mockReturnValue(true);

      windowManager.openSettingsWindow();

      // Reset the mock so we can test the new window
      mockWindow.isDestroyed.mockReturnValue(false);

      // Simulate the ready-to-show event being called
      expect(mockWindow.once).toHaveBeenCalledWith('ready-to-show', expect.any(Function));

      // Find and call the ready-to-show handler
      const onceCalls = mockWindow.once.mock.calls;
      const readyCall = onceCalls.find((call: [string, unknown]) => call[0] === 'ready-to-show');
      expect(readyCall).toBeDefined();

      if (readyCall) {
        const readyHandler = readyCall[1];
        readyHandler();
        expect(mockThemeManager.applyThemeToWindow).toHaveBeenCalledWith(mockWindow);
        expect(mockWindow.show).toHaveBeenCalled();
      }
    });
  });

  describe('Module Exports', () => {
    it('should export all required functions', () => {
      expect(typeof windowManager.createWindow).toBe('function');
      expect(typeof windowManager.autoLoadPreview).toBe('function');
      expect(typeof windowManager.loadLocalFilePreview).toBe('function');
      expect(typeof windowManager.showPreview).toBe('function');
      expect(typeof windowManager.hidePreview).toBe('function');
      expect(typeof windowManager.reloadPreview).toBe('function');
      expect(typeof windowManager.togglePreviewDevTools).toBe('function');
      expect(typeof windowManager.openWebsiteSelectionWindow).toBe('function');
      expect(typeof windowManager.openSettingsWindow).toBe('function');
    });
  });
});
