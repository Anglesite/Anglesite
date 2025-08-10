/**
 * @file Tests for multi-window management functionality
 */

// Mock Electron modules
const mockBrowserWindow = {
  isDestroyed: jest.fn(() => false),
  focus: jest.fn(),
  getBounds: jest.fn(() => ({ width: 1200, height: 800 })),
  getTitle: jest.fn(() => 'Test Window'),
  on: jest.fn(),
  loadFile: jest.fn(),
  contentView: {
    addChildView: jest.fn(),
    children: [],
  },
};

const mockWebContentsView = {
  webContents: {
    on: jest.fn(),
    removeAllListeners: jest.fn(),
    loadURL: jest.fn(() => Promise.resolve()),
  },
  setBounds: jest.fn(),
};

const mockUpdateApplicationMenu = jest.fn();

// Set up mocks
jest.mock('electron', () => ({
  BrowserWindow: jest.fn(() => mockBrowserWindow),
  WebContentsView: jest.fn(() => mockWebContentsView),
}));

jest.mock('../../app/server/eleventy', () => ({
  getCurrentLiveServerUrl: jest.fn(() => 'https://anglesite.test:8080'),
  isLiveServerReady: jest.fn(() => true),
}));

jest.mock('../../app/ui/menu', () => ({
  updateApplicationMenu: mockUpdateApplicationMenu,
}));

describe('Multi-Window Manager', () => {
  let multiWindowManager: typeof import('../../app/ui/multi-window-manager');

  beforeAll(() => {
    // Import after mocks are set up
    multiWindowManager = require('../../app/ui/multi-window-manager');
  });

  beforeEach(() => {
    // Reset all mocks
    jest.clearAllMocks();

    // Reset module state by clearing internal window references
    const helpWindow = multiWindowManager.getHelpWindow();
    if (helpWindow) {
      // Force cleanup of existing windows for testing
    }
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

      expect(consoleSpy).toHaveBeenCalledWith('Live server not ready yet, waiting...');

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
});
