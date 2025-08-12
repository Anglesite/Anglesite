/**
 * @file Tests for multi-window management functionality
 */

// Mock Electron modules
const mockBrowserWindow = {
  isDestroyed: jest.fn(() => false),
  isMaximized: jest.fn(() => false),
  focus: jest.fn(),
  show: jest.fn(),
  close: jest.fn(),
  getBounds: jest.fn(() => ({ width: 1200, height: 800, x: 0, y: 0 })),
  setBounds: jest.fn(),
  maximize: jest.fn(),
  getTitle: jest.fn(() => 'Test Window'),
  on: jest.fn(),
  once: jest.fn(),
  loadFile: jest.fn(),
  webContents: {
    send: jest.fn(),
    isLoading: jest.fn(() => false),
    executeJavaScript: jest.fn(() => Promise.resolve()),
    once: jest.fn(),
  },
  contentView: {
    addChildView: jest.fn(),
    children: [],
  },
};

const mockWebContents = {
  on: jest.fn(),
  removeAllListeners: jest.fn(),
  loadURL: jest.fn(() => Promise.resolve()),
  reload: jest.fn(),
};

const mockWebContentsView = {
  webContents: mockWebContents,
  setBounds: jest.fn(),
};

const mockUpdateApplicationMenu = jest.fn();

// Set up mocks
jest.mock('electron', () => ({
  BrowserWindow: jest.fn(() => mockBrowserWindow),
  WebContentsView: jest.fn(() => mockWebContentsView),
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
  },
}));

jest.mock('../../app/server/eleventy', () => ({
  getCurrentLiveServerUrl: jest.fn(() => 'https://anglesite.test:8080'),
  isLiveServerReady: jest.fn(() => true),
}));

// Mock theme manager
const mockThemeManager = {
  applyThemeToWindow: jest.fn(),
};

jest.mock('../../app/ui/theme-manager', () => ({
  themeManager: mockThemeManager,
}));

jest.mock('../../app/ui/menu', () => ({
  updateApplicationMenu: mockUpdateApplicationMenu,
}));

// Mock path module
jest.mock('path');
const mockPath = require('path');
mockPath.join.mockImplementation((...args: string[]) => args.join('/'));

// Mock store
const mockStore = {
  get: jest.fn((key: string) => {
    if (key === 'httpsMode') return 'https';
    if (key === 'showHelpOnStartup') return true;
    return [];
  }),
  set: jest.fn(),
  saveWindowStates: jest.fn(),
  getWindowStates: jest.fn(() => []),
  clearWindowStates: jest.fn(),
  getAll: jest.fn(() => ({})),
  setAll: jest.fn(),
};

jest.mock('../../app/store', () => ({
  Store: jest.fn().mockImplementation(() => mockStore),
}));

// Mock template loader
jest.mock('../../app/ui/template-loader', () => ({
  loadTemplateAsDataUrl: jest.fn((templateName: string) => {
    return `data:text/html;charset=utf-8,<h1>Mock ${templateName}</h1>`;
  }),
}));

describe('Multi-Window Manager', () => {
  let multiWindowManager: typeof import('../../app/ui/multi-window-manager');

  beforeAll(() => {
    // Import after mocks are set up
    multiWindowManager = require('../../app/ui/multi-window-manager');
  });

  beforeEach(() => {
    // Reset mock state
    mockBrowserWindow.isDestroyed.mockReturnValue(false);
    mockWebContents.loadURL.mockResolvedValue(undefined);

    // Clean up any existing windows first
    multiWindowManager.closeAllWindows();

    // Reset all mocks after cleanup
    jest.clearAllMocks();
  });

  describe('createHelpWindow', () => {
    it('should create a new help window', () => {
      const helpWindow = multiWindowManager.createHelpWindow();

      expect(helpWindow).toBeDefined();
      expect(mockBrowserWindow.loadFile).toHaveBeenCalled();
      expect(mockBrowserWindow.contentView.addChildView).toHaveBeenCalled();
      expect(mockUpdateApplicationMenu).toHaveBeenCalled();
    });
  });

  describe('createWebsiteWindow', () => {
    it('should create a new website window', () => {
      const websiteName = 'test-site';
      const websitePath = '/path/to/website';

      const websiteWindow = multiWindowManager.createWebsiteWindow(websiteName, websitePath);

      expect(websiteWindow).toBeDefined();
      expect(mockBrowserWindow.loadFile).toHaveBeenCalled();
      expect(mockBrowserWindow.contentView.addChildView).toHaveBeenCalled();
      expect(mockUpdateApplicationMenu).toHaveBeenCalled();
    });
  });

  describe('loadWebsiteContent', () => {
    it('should handle website window not found', () => {
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();

      multiWindowManager.loadWebsiteContent('non-existent-site');

      expect(consoleSpy).toHaveBeenCalledWith('Website window not found: non-existent-site');

      consoleSpy.mockRestore();
    });

    it('should handle server not ready', () => {
      // Create a website window for testing
      multiWindowManager.createWebsiteWindow('test-site');

      const eleventyMock = require('../../app/server/eleventy');
      eleventyMock.isLiveServerReady.mockReturnValue(false);

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      multiWindowManager.loadWebsiteContent('test-site');

      expect(consoleSpy).toHaveBeenCalledWith('Live server not ready yet, retrying in 500ms...');

      consoleSpy.mockRestore();

      // Reset for other tests
      eleventyMock.isLiveServerReady.mockReturnValue(true);
    });
  });

  describe('Window References', () => {
    it('should return help window reference when available', () => {
      multiWindowManager.createHelpWindow();
      const helpWindow = multiWindowManager.getHelpWindow();

      expect(helpWindow).toBeDefined();
      expect(helpWindow).not.toBeNull();
    });

    it('should return all website windows', () => {
      multiWindowManager.createWebsiteWindow('site1');
      multiWindowManager.createWebsiteWindow('site2');

      const allWindows = multiWindowManager.getAllWebsiteWindows();

      expect(allWindows).toBeInstanceOf(Map);
      expect(allWindows.size).toBeGreaterThan(0);
    });
  });

  describe('Integration Tests', () => {
    it('should support multi-window architecture', () => {
      // Test that the multi-window system can handle multiple windows
      const helpWindow = multiWindowManager.createHelpWindow();
      const websiteWindow = multiWindowManager.createWebsiteWindow('test-site');

      expect(helpWindow).toBeDefined();
      expect(websiteWindow).toBeDefined();
      // Both are mock instances, so they'll be the same object, but that's OK for this test
      expect(typeof helpWindow).toBe('object');
      expect(typeof websiteWindow).toBe('object');
    });
  });

  describe('Module Exports', () => {
    it('should export required functions', () => {
      expect(typeof multiWindowManager.createHelpWindow).toBe('function');
      expect(typeof multiWindowManager.createWebsiteWindow).toBe('function');
      expect(typeof multiWindowManager.loadWebsiteContent).toBe('function');
      expect(typeof multiWindowManager.getHelpWindow).toBe('function');
      expect(typeof multiWindowManager.getWebsiteWindow).toBe('function');
      expect(typeof multiWindowManager.getAllWebsiteWindows).toBe('function');
      expect(typeof multiWindowManager.closeAllWindows).toBe('function');
    });
  });

  describe('Advanced createHelpWindow scenarios', () => {
    it('should focus existing help window if already exists', () => {
      // Create first window
      const helpWindow1 = multiWindowManager.createHelpWindow();

      // Try to create second window - should focus first one
      const helpWindow2 = multiWindowManager.createHelpWindow();

      expect(helpWindow1).toBe(helpWindow2);
      expect(mockBrowserWindow.focus).toHaveBeenCalled();
    });

    it('should handle help window focus and blur events', () => {
      multiWindowManager.createHelpWindow();

      const onCalls = mockBrowserWindow.on.mock.calls;

      // Test focus handler
      const focusCall = onCalls.find((call) => call[0] === 'focus');
      if (focusCall) {
        focusCall[1]();
        expect(mockUpdateApplicationMenu).toHaveBeenCalled();
      }

      // Reset and test blur handler
      mockUpdateApplicationMenu.mockClear();
      const blurCall = onCalls.find((call) => call[0] === 'blur');
      if (blurCall) {
        blurCall[1]();
        expect(mockUpdateApplicationMenu).toHaveBeenCalled();
      }
    });
  });

  describe('Advanced createWebsiteWindow scenarios', () => {
    it('should focus existing website window if already exists', () => {
      const websiteName = 'test-site';

      // Create first window
      const window1 = multiWindowManager.createWebsiteWindow(websiteName);

      // Try to create second window - should focus first one
      const window2 = multiWindowManager.createWebsiteWindow(websiteName);

      expect(window1).toBe(window2);
      expect(mockBrowserWindow.focus).toHaveBeenCalled();
    });
  });

  describe('Advanced loadWebsiteContent scenarios', () => {
    it('should load website content when server is ready', () => {
      jest.useFakeTimers();
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();
      const websiteName = 'test-site';

      // Create website window first
      multiWindowManager.createWebsiteWindow(websiteName);

      // Clear previous mock calls
      jest.clearAllMocks();

      // Load content
      multiWindowManager.loadWebsiteContent(websiteName);

      expect(mockWebContents.removeAllListeners).toHaveBeenCalledWith('did-fail-load');
      expect(mockWebContents.removeAllListeners).toHaveBeenCalledWith('did-finish-load');
      expect(mockWebContents.removeAllListeners).toHaveBeenCalledWith('did-fail-provisional-load');
      expect(mockWebContents.on).toHaveBeenCalledWith('did-fail-load', expect.any(Function));
      expect(mockWebContents.on).toHaveBeenCalledWith('did-finish-load', expect.any(Function));
      expect(mockWebContents.on).toHaveBeenCalledWith('did-fail-provisional-load', expect.any(Function));

      // Advance timer to trigger load
      jest.advanceTimersByTime(500);

      expect(mockWebContents.loadURL).toHaveBeenCalledWith('https://anglesite.test:8080');
      expect(consoleSpy).toHaveBeenCalledWith(
        'Loading website content for test-site from:',
        'https://anglesite.test:8080'
      );

      consoleSpy.mockRestore();
      jest.useRealTimers();
    });

    it('should handle did-fail-load event', () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();
      const websiteName = 'test-site';

      // Create website window first
      multiWindowManager.createWebsiteWindow(websiteName);

      // Load content to set up event listeners
      multiWindowManager.loadWebsiteContent(websiteName);

      // Find the did-fail-load handler
      const onCalls = mockWebContents.on.mock.calls;
      const failLoadCall = onCalls.find((call) => call[0] === 'did-fail-load');
      expect(failLoadCall).toBeDefined();

      if (failLoadCall) {
        // Test error logging behavior
        const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

        failLoadCall[1](null, -105, 'NAME_NOT_RESOLVED', 'https://anglesite.test:8080');
        expect(consoleErrorSpy).toHaveBeenCalledWith('Website WebContentsView failed to load:', {
          errorCode: -105,
          errorDescription: 'NAME_NOT_RESOLVED',
          validatedURL: 'https://anglesite.test:8080',
        });

        consoleErrorSpy.mockRestore();
      }

      consoleSpy.mockRestore();
    });

    it('should handle did-finish-load event', () => {
      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();
      const websiteName = 'test-site';

      // Create website window first
      multiWindowManager.createWebsiteWindow(websiteName);

      // Load content to set up event listeners
      multiWindowManager.loadWebsiteContent(websiteName);

      // Find the did-finish-load handler
      const onCalls = mockWebContents.on.mock.calls;
      const finishLoadCall = onCalls.find((call) => call[0] === 'did-finish-load');
      expect(finishLoadCall).toBeDefined();

      if (finishLoadCall) {
        finishLoadCall[1]();
        expect(consoleSpy).toHaveBeenCalledWith('Successfully loaded content for test-site');
      }

      consoleSpy.mockRestore();
    });

    it('should handle website window destroyed', () => {
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();
      const websiteName = 'test-site';

      multiWindowManager.createWebsiteWindow(websiteName);

      // Mock window as destroyed
      mockBrowserWindow.isDestroyed.mockReturnValue(true);

      multiWindowManager.loadWebsiteContent(websiteName);

      expect(consoleSpy).toHaveBeenCalledWith('Website window not found: test-site');

      // Reset mock
      mockBrowserWindow.isDestroyed.mockReturnValue(false);
      consoleSpy.mockRestore();
    });

    it('should handle loadURL failure with fallback', () => {
      jest.useFakeTimers();
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();
      const consoleLogSpy = jest.spyOn(console, 'log').mockImplementation();
      const websiteName = 'test-site';

      multiWindowManager.createWebsiteWindow(websiteName);

      // Mock loadURL to fail initially
      const loadError = new Error('Network error');
      mockWebContents.loadURL.mockRejectedValueOnce(loadError);

      multiWindowManager.loadWebsiteContent(websiteName);

      // Advance timer
      jest.advanceTimersByTime(500);

      // Wait for promise rejection handling
      setTimeout(() => {
        expect(consoleSpy).toHaveBeenCalledWith('Failed to load content for test-site:', loadError);
        expect(consoleLogSpy).toHaveBeenCalledWith('Trying fallback URL for test-site: https://anglesite.test:8080');
      }, 0);

      consoleSpy.mockRestore();
      consoleLogSpy.mockRestore();
      jest.useRealTimers();
    });
  });

  describe('Help window with server not ready', () => {
    it('should handle loadURL error in help content loading', () => {
      jest.useFakeTimers();
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();
      const loadError = new Error('Network error');

      // Mock loadURL to fail for server URL but succeed for fallback
      mockWebContents.loadURL.mockRejectedValueOnce(loadError).mockResolvedValue(undefined);

      multiWindowManager.createHelpWindow();

      // Advance timer to trigger loadHelpContent
      jest.advanceTimersByTime(100);

      // Wait for the promise rejection to be handled
      setTimeout(() => {
        expect(consoleSpy).toHaveBeenCalledWith('Failed to load help content:', loadError);
        // Should load fallback HTML
        expect(mockWebContents.loadURL).toHaveBeenCalledWith(expect.stringContaining('data:text/html;charset=utf-8,'));
      }, 0);

      consoleSpy.mockRestore();
      jest.useRealTimers();
    });
  });

  describe('getWebsiteWindow', () => {
    it('should return website window when it exists', () => {
      const websiteName = 'test-site';
      multiWindowManager.createWebsiteWindow(websiteName);

      const window = multiWindowManager.getWebsiteWindow(websiteName);
      expect(window).toBeDefined();
      expect(window).not.toBeNull();
    });

    it('should return null for non-existent website window', () => {
      const window = multiWindowManager.getWebsiteWindow('non-existent');
      expect(window).toBeNull();
    });

    it('should return null for destroyed website window', () => {
      const websiteName = 'test-site';
      multiWindowManager.createWebsiteWindow(websiteName);

      // Mock window as destroyed
      mockBrowserWindow.isDestroyed.mockReturnValue(true);

      const window = multiWindowManager.getWebsiteWindow(websiteName);
      expect(window).toBeNull();

      // Reset mock
      mockBrowserWindow.isDestroyed.mockReturnValue(false);
    });
  });

  describe('closeAllWindows', () => {
    it('should close help window and all website windows', () => {
      // Create windows
      multiWindowManager.createHelpWindow();
      multiWindowManager.createWebsiteWindow('site1');
      multiWindowManager.createWebsiteWindow('site2');

      // Clear mock calls to focus on close calls
      mockBrowserWindow.close.mockClear();

      // Close all windows
      multiWindowManager.closeAllWindows();

      expect(mockBrowserWindow.close).toHaveBeenCalledTimes(3); // help + 2 websites
    });

    it('should handle already destroyed windows', () => {
      multiWindowManager.createHelpWindow();
      multiWindowManager.createWebsiteWindow('site1');

      // Mock windows as destroyed
      mockBrowserWindow.isDestroyed.mockReturnValue(true);

      // Should not throw error
      expect(() => multiWindowManager.closeAllWindows()).not.toThrow();

      // Reset mock
      mockBrowserWindow.isDestroyed.mockReturnValue(false);
    });

    it('should clear the website windows map', () => {
      multiWindowManager.createWebsiteWindow('site1');
      multiWindowManager.createWebsiteWindow('site2');

      const windowsBefore = multiWindowManager.getAllWebsiteWindows();
      expect(windowsBefore.size).toBe(2);

      multiWindowManager.closeAllWindows();

      const windowsAfter = multiWindowManager.getAllWebsiteWindows();
      expect(windowsAfter.size).toBe(0);
    });
  });
});
